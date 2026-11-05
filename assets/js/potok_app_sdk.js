// Potok app SDK, loaded first inside the sandboxed iframe of `uses_api`
// groups (see `Components.app_frame/1`). It talks to the parent page's
// `GroupAppFrame` hook over postMessage; the server re-checks every call.
//
//   await potok.insertValue({score: 10})
//   const {values, has_more} = await potok.listValues({afterId: lastSeenId})
//   potok.onNewValue(value => render(value))
//
// `window.__potokLegacy` keeps the pre-sandbox API working:
// `document.getElementById("group-panel-description").potok.insertGroupValue(...)`.

const CALL_TIMEOUT_MS = 10_000
const LEGACY_PAGE_SIZE = 200
const LEGACY_MAX_ROWS = 5_000
const STORAGE_SAVE_DELAY_MS = 200

let nextCallId = 1
const pendingCalls = new Map()
// listener -> whether it gets the values of every app in the group.
const newValueListeners = new Map()

// A group has one app per description: "" for the default description, an
// alternative description's id otherwise. Values carry it as `description_id`.
const ownAppId = document.querySelector('meta[name="potok-app"]')?.content ?? ""
const ownValue = value => String(value?.description_id ?? "") === ownAppId

// The frame can start before the page's LiveView has connected and mounted
// the hook, so calls wait for its "ready" (sent on mount and in reply to
// our "hello", whichever comes last).
let markParentReady
const parentReady = new Promise(resolve => { markParentReady = resolve })
window.parent.postMessage({potok: 1, event: "hello"}, "*")

// A sandboxed frame has an opaque origin, so reading `localStorage` throws.
// Apps get an in-memory Storage instead: the parent keeps `localStorage` per
// group, sends it with "ready" and saves it again after every change.
const memoryStorage = onChange => {
  const items = new Map()

  const storage = {
    get length() { return items.size },
    key: index => Array.from(items.keys())[index] ?? null,
    getItem: key => items.get(String(key)) ?? null,
    setItem(key, value) {
      items.set(String(key), String(value))
      onChange()
    },
    removeItem(key) {
      items.delete(String(key))
      onChange()
    },
    clear() {
      items.clear()
      onChange()
    },
  }

  return {items, storage}
}

let storageSaveTimer = null

const saveLocalStorage = () => {
  clearTimeout(storageSaveTimer)
  storageSaveTimer = null

  void parentReady.then(() =>
    window.parent.postMessage({potok: 1, event: "storage", items: Object.fromEntries(local.items)}, "*")
  )
}

const local = memoryStorage(() => {
  clearTimeout(storageSaveTimer)
  storageSaveTimer = setTimeout(saveLocalStorage, STORAGE_SAVE_DELAY_MS)
})

const session = memoryStorage(() => {})

const installStorage = (name, storage) => {
  try {
    void window[name]
  } catch (_error) {
    Object.defineProperty(window, name, {value: storage, configurable: true})
  }
}

installStorage("localStorage", local.storage)
installStorage("sessionStorage", session.storage)

// Apps often save state right before `location.reload()`.
window.addEventListener("pagehide", () => {
  if (storageSaveTimer) saveLocalStorage()
})

let storageSeeded = false

const seedLocalStorage = snapshot => {
  if (storageSeeded || !snapshot || typeof snapshot !== "object") return
  storageSeeded = true

  // Writes made before "ready" win over the saved copy.
  Object.entries(snapshot).forEach(([key, value]) => {
    if (typeof value === "string" && !local.items.has(key)) local.items.set(key, value)
  })
}

// Same daisyUI theme as the page around the frame ("system" has no attribute).
const applyTheme = theme => {
  if (typeof theme === "string" && theme) {
    document.documentElement.setAttribute("data-theme", theme)
  } else {
    document.documentElement.removeAttribute("data-theme")
  }
}

const subgroupPage = options => ({
  limit: options.limit ?? null,
  before_id: options.beforeId ?? options.before_id ?? null,
  from: options.from ?? null,
  to: options.to ?? null,
  around_id: options.aroundId ?? null,
})

// `waits`: the answer depends on the viewer, who can take as long as they like.
const call = (method, params = {}, {waits = false} = {}) =>
  new Promise((resolve, reject) => {
    const id = nextCallId++

    const timer = waits
      ? null
      : setTimeout(() => {
          pendingCalls.delete(id)
          reject(new Error(`potok.${method} timed out`))
        }, CALL_TIMEOUT_MS)

    pendingCalls.set(id, {resolve, timer})
    void parentReady.then(() => window.parent.postMessage({potok: 1, id, method, params}, "*"))
  })

window.addEventListener("message", event => {
  const message = event.data

  if (event.source !== window.parent || !message || message.potok !== 1) return

  if (message.event === "ready") {
    seedLocalStorage(message.storage)
    applyTheme(message.theme)
    markParentReady()
    return
  }

  if (message.event === "theme") {
    applyTheme(message.theme)
    return
  }

  // Values pushed while the page was offline never arrive, and apps load
  // their data once, so the app starts again (the old hook re-ran its scripts).
  if (message.event === "reconnected") {
    window.location.reload()
    return
  }

  if (message.event === "new_value") {
    const own = ownValue(message.value)

    newValueListeners.forEach((allApps, listener) => {
      if (!own && !allApps) return

      try {
        listener(message.value)
      } catch (error) {
        console.error(error)
      }
    })

    if (own) window.dispatchEvent(new CustomEvent("phx:new_data_value", {detail: message.value}))
    return
  }

  const pending = pendingCalls.get(message.id)
  if (!pending) return

  pendingCalls.delete(message.id)
  clearTimeout(pending.timer)

  const {potok: _version, id: _id, ...reply} = message
  pending.resolve(reply)
})

const toData = data => (typeof data === "string" ? data : JSON.stringify(data ?? {}))

const listParams = (options = {}) => ({
  limit: options.limit ?? null,
  offset: options.offset ?? null,
  after_id: options.afterId ?? options.after_id ?? null,
  before_id: options.beforeId ?? options.before_id ?? null,
  search_field: options.searchField ?? options.search_field ?? null,
  search_value: options.searchValue ?? options.search_value ?? null,
  order_by: options.orderBy ?? options.order_by ?? null,
  order_dir: options.orderDir ?? options.order_dir ?? null,
  scope: options.scope ?? null,
})

// What an app may set on a group below it. A field left out stays as it is.
const childParams = ({name, description, descriptionFormat, isPublic, inheritsMembers, picture} = {}) =>
  Object.fromEntries(
    Object.entries({
      name,
      description,
      description_format: descriptionFormat,
      is_public: isPublic,
      inherits_members: inheritsMembers,
      picture,
    }).filter(([_field, value]) => value !== undefined)
  )

const potok = {
  insertValue: (data, options = {}) =>
    call("insert_value", {
      data: toData(data),
      content_format: options.contentFormat || options.content_format || "markdown",
    }),

  // Up to 200 values per call; page with `afterId` / `beforeId` or `offset`.
  // `scope: "group"` also lists the values of the group's other apps.
  listValues: (options = {}) => call("list_values", listParams(options)),

  updateDescription: (description, options = {}) =>
    call("update_description", {
      description: typeof description === "string" ? description : "",
      description_format: options.descriptionFormat || options.description_format || null,
    }),

  getDescription: () => call("get_description"),

  getCurrentProfile: async () => {
    const reply = await call("current_profile")
    return reply.ok ? reply.profile : null
  },

  // The groups under this group's direct sub-group called `name`, newest
  // first, up to 50 per call (default 20); page with `beforeId`. `from` and `to`
  // (ISO 8601 with a zone) keep those published in that period: `from` counts
  // in, `to` does not. `aroundId` gives the groups around that one instead of
  // the first page, however far down it lies, and `has_newer` says there is more
  // above them.
  listSubgroups: (name, options = {}) => call("list_subgroups", {name, ...subgroupPage(options)}),

  // Takes the viewer to this group's parent, a sub-group of it or a group
  // `listSubgroups` can return: to its chat, with `tab: "description"` to its
  // description, where a group that is an app runs, or with `tab: "settings"`
  // to its settings. The frame goes away with the page, so a pending
  // `localStorage` save goes first.
  openGroup: (id, options = {}) => {
    if (storageSaveTimer) saveLocalStorage()
    return call("open_group", {id, tab: options.tab ?? null})
  },

  // Adds the viewer's reaction to a group below this one, or takes it back, as a
  // click on a reaction does. Works for any viewer with `can_react` on that
  // group and counts as a write. Resolves to `{ok: true, reactions}`.
  toggleGroupReaction: (id, emoji) => call("toggle_group_reaction", {id, emoji}),

  // Lets the viewer choose any emoji in Potok's own picker. Resolves to
  // `{ok: true, emoji}`, or `{ok: false, error: "cancelled"}` when they close it.
  pickEmoji: () => call("pick_emoji", {}, {waits: true}),

  // Opens the page's way of sharing with the link of a group `openGroup` can
  // reach. A frame has neither Web Share nor the clipboard. With `{inApp: true}`
  // the link is to this app open on that group, which must lie below it.
  shareGroup: (id, options = {}) => call("share_group", {id, in_app: options.inApp === true}),

  // Puts a group in the page's address, so that the address opens this app on
  // it: what a feed does with the story on screen. The app itself finds the
  // group again, with `getLinkedGroup`.
  linkGroup: id => call("link_group", {id}),

  // Resolves to `{ok: true, group_id}`: the group in the address, or null.
  getLinkedGroup: () => call("linked_group"),

  // This group, its parent and what the viewer may do here.
  getGroup: () => call("get_group"),

  // The calls below keep the groups right under this one. They act in the
  // viewer's name, so they need a viewer who may edit this group
  // (`can_manage_children` in `getGroup`). Up to 50 per call (default 20),
  // the newest publication first; page with `beforeId`.
  listChildren: (options = {}) => call("list_children", subgroupPage(options)),

  getChild: id => call("get_child", {id}),

  createChild: attrs => call("create_child", childParams(attrs)),

  updateChild: (id, attrs) => call("update_child", {...childParams(attrs), id}),

  // Closes the group again, and its inherited members leave.
  withdrawChild: id => call("withdraw_child", {id}),

  // The description as it will be shown, sanitized on the server.
  previewDescription: (description, options = {}) =>
    call("preview_description", {
      description: typeof description === "string" ? description : "",
      description_format: options.descriptionFormat || options.description_format || null,
    }),

  // `{scope: "group"}` also passes on the values of the group's other apps.
  onNewValue(listener, options = {}) {
    if (typeof listener !== "function") return () => {}

    newValueListeners.set(listener, options.scope === "group")
    return () => newValueListeners.delete(listener)
  },
}

// Before the sandbox, `getGroupDataValues()` without a limit returned every
// row; the legacy wrapper pages through the capped API to keep that contract.
const legacyListAll = async options => {
  const values = []
  let offset = 0

  while (values.length < LEGACY_MAX_ROWS) {
    const reply = await potok.listValues({...options, limit: LEGACY_PAGE_SIZE, offset})
    if (!reply.ok) return reply

    values.push(...reply.values)
    if (!reply.has_more) break
    offset += reply.values.length
  }

  return {ok: true, values}
}

let legacyCallback = null

// The old `el.potok` was the LiveView hook itself, so apps also use its
// `el` and `abortController` (for `{signal}` listener options).
const legacy = {
  get el() {
    return document.getElementById("group-panel-description")
  },

  abortController: new AbortController(),

  insertGroupValue: (content, options = {}) =>
    potok.insertValue(typeof content === "string" ? content : "", options),

  updateGroupDescription: (description, options = {}) =>
    potok.updateDescription(description, options),

  getGroupDescription: async () => {
    const reply = await potok.getDescription()

    return {
      description: reply.group?.description || "",
      descriptionFormat: reply.group?.description_format || "html",
    }
  },

  getGroupDataValues: (options = {}) =>
    options.limit == null ? legacyListAll(options) : potok.listValues(options),

  getCurrentProfile: () => potok.getCurrentProfile(),

  setNewValueCallback(fn) {
    if (typeof fn !== "function") return

    // The old callback received the `phx:new_data_value` event itself.
    if (legacyCallback) newValueListeners.delete(legacyCallback)
    legacyCallback = value => fn(new CustomEvent("phx:new_data_value", {detail: value}))
    newValueListeners.set(legacyCallback, false)
  },
}

window.potok = potok
window.__potokLegacy = legacy

// Like the old hook, `el.potok` appears once the page is connected, so apps
// that poll for it start with `localStorage` and the theme already in place.
const exposeLegacy = () => {
  const host = legacy.el
  if (host) host.potok = legacy
}

void parentReady.then(() => {
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", exposeLegacy, {once: true})
  } else {
    exposeLegacy()
  }
})
