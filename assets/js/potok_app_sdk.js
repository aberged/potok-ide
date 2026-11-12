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
const pollListeners = new Set()
const subgroupListeners = new Set()
const sheetListeners = new Set()
// listener -> the collection it follows (null: all of them).
const collectionListeners = new Map()
// call id -> progress callback of a file on its way.
const uploadProgress = new Map()

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

// `waits`: the answer depends on the viewer, who can take as long as they like,
// or on a file on its way. `file` goes along with the call (`uploadFile`).
const call = (method, params = {}, {waits = false, file = null, onProgress = null} = {}) =>
  new Promise((resolve, reject) => {
    const id = nextCallId++

    const timer = waits
      ? null
      : setTimeout(() => {
          pendingCalls.delete(id)
          reject(new Error(`potok.${method} timed out`))
        }, CALL_TIMEOUT_MS)

    pendingCalls.set(id, {resolve, timer})
    if (typeof onProgress === "function") uploadProgress.set(id, onProgress)

    const message = file ? {potok: 1, id, method, params, file} : {potok: 1, id, method, params}
    void parentReady.then(() => window.parent.postMessage(message, "*"))
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

  if (message.event === "children_changed") {
    subgroupListeners.forEach(listener => {
      try {
        listener()
      } catch (error) {
        console.error(error)
      }
    })
    return
  }

  if (message.event === "group_sheet_closed") {
    sheetListeners.forEach(listener => {
      try {
        listener(message.id)
      } catch (error) {
        console.error(error)
      }
    })
    return
  }

  if (message.event === "poll_changed") {
    pollListeners.forEach(listener => {
      try {
        listener(message.id)
      } catch (error) {
        console.error(error)
      }
    })
    return
  }

  if (message.event === "app_value") {
    const change = message.change || {}

    collectionListeners.forEach((collection, listener) => {
      if (collection !== null && collection !== change.collection) return

      try {
        listener(change)
      } catch (error) {
        console.error(error)
      }
    })
    return
  }

  if (message.event === "upload_progress") {
    const listener = uploadProgress.get(message.id)

    try {
      listener?.(message.progress)
    } catch (error) {
      console.error(error)
    }
    return
  }

  if (message.event === "new_value") {
    // Values in a collection come as `app_value`, to those the rules allow.
    if (message.value?.collection != null) return

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
  uploadProgress.delete(message.id)
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
  collection: options.collection ?? null,
  mine: options.mine === true,
  total: options.total === true,
  match: options.match ?? null,
})

// What an app may set on a group below it. A field left out stays as it is;
// `lat` and `lng` both null take its place on a map away, `pin` null shows its
// kind's.
const childParams = ({name, description, descriptionFormat, isPublic, inheritsMembers, picture, lat, lng, pin} = {}) =>
  Object.fromEntries(
    Object.entries({
      name,
      description,
      description_format: descriptionFormat,
      is_public: isPublic,
      inherits_members: inheritsMembers,
      picture,
      lat,
      lng,
      pin,
    }).filter(([_field, value]) => value !== undefined)
  )

// A child of `createChildren`: what `childParams` takes, and the app's `key`.
const newChildParams = ({key, ...attrs} = {}) => ({
  ...childParams(attrs),
  ...(key === undefined ? {} : {key}),
})

// The filters of a big map's view, or of the spot of a cluster.
const placeFilters = ({search, pins} = {}) => ({
  ...(typeof search === "string" && search.trim() !== "" ? {search} : {}),
  ...(Array.isArray(pins) && pins.length > 0 ? {pins} : {}),
})

const potok = {
  // With `{collection}` the value goes into that collection, as its rule in the
  // app's config allows (`getConfig`), and it resolves to `{ok: true, value}`.
  insertValue: (data, options = {}) =>
    call("insert_value", {
      data: toData(data),
      content_format: options.contentFormat || options.content_format || "markdown",
      collection: options.collection ?? null,
    }),

  // Up to 200 values per call, oldest first; `orderDir: "desc"` for the newest
  // first. A page lies right next to its cursor: `beforeId` gives the values
  // just before it, `afterId` those just after it, and `has_more` tells
  // whether more lie beyond, away from the cursor. `offset` counts on from it.
  // `total: true` adds the count, `match` keeps the values whose data contains
  // it (`{status: "open"}`), and `scope: "group"` also lists the values of the
  // group's other apps. With `orderBy` the cursors only narrow by id.
  // With `{collection}`: up to 100, every value for those who read the
  // collection, otherwise only the viewer's own (`mine: true` asks for those
  // anyway).
  listValues: (options = {}) => call("list_values", listParams(options)),

  // The app's config (its `secret` part only for its editors), its `revision`,
  // and per collection with a rule what the viewer may do there (`caps`).
  getConfig: () => call("get_config"),

  // Saves the config, for the app's editors. Pass the revision you started
  // from (0 for the first); someone else's save in between gives
  // `{ok: false, error: "conflict", current}`. `rules` is what Potok holds to.
  saveConfig: (data, options = {}) =>
    call("save_config", {data: toData(data), revision: options.revision ?? null}),

  // Changes the viewer's own value in a collection whose rule allows it.
  updateValue: (id, data, options = {}) =>
    call("update_value", {id, data: toData(data), revision: options.revision ?? null}),

  // For the app's editors: one value of a collection, or all of one.
  deleteValue: id => call("delete_value", {id}),
  deleteValues: collection => call("delete_values", {collection}),

  // Counts over the answers under `under` (a path in each value), for `keys`
  // only: one bucket per choice, per element of a list, per row of a map.
  // `score: true` adds a quiz's scores, for those who read everything.
  summarizeValues: (collection, options = {}) =>
    call("summarize_values", {
      collection,
      under: options.under ?? null,
      keys: options.keys ?? [],
      score: options.score === true,
    }),

  // Sums over the numbers in the values `listValues` would page through with
  // the same `match`, `searchField` / `searchValue` and `scope`: for each of
  // up to 5 `fields`, how many hold a number and their sum, average, lowest
  // and highest, read at `under` (a path, the top by default). With
  // `groupBy` the same per value of that field, 50 biggest groups first.
  // `{collection}` works for those who read all of it.
  aggregateValues: (options = {}) =>
    call("aggregate_values", {
      collection: options.collection ?? null,
      scope: options.scope ?? null,
      match: options.match ?? null,
      search_field: options.searchField ?? options.search_field ?? null,
      search_value: options.searchValue ?? options.search_value ?? null,
      under: options.under ?? null,
      group_by: options.groupBy ?? options.group_by ?? null,
      fields: options.fields ?? null,
    }),

  // An editor's points and words for the answers of one value of a quiz.
  gradeValue: (id, items) => call("grade_value", {id, items}),

  // The group's roles, to pick from: `{key, name, builtin}`.
  listRoles: () => call("list_roles"),

  // Whether the viewer gets a push for each new value of the collection.
  setNotifications: (collection, on) => call("set_notifications", {collection, on: on === true}),

  // For the app's editors: makes the sub-groups that keep its files.
  ensureFileGroups: () => call("ensure_file_groups"),

  // An address the frame can show a file by, valid for ten minutes.
  fileUrl: id => call("file_url", {id}),

  // Sends a file for `slot` of `collection`, as its rule allows. Resolves to
  // `{ok: true, file: {file, name, size, type}}`; put `{file}` in the value.
  uploadFile: (file, options = {}) =>
    call(
      "upload_file",
      {collection: options.collection ?? null, slot: options.slot ?? null},
      {waits: true, file, onProgress: options.onProgress}
    ),

  // A picture of the app itself, for its editors. Resolves with `file.url`,
  // an address anyone who sees the app can open.
  uploadImage: (file, options = {}) =>
    call("upload_image", {}, {waits: true, file, onProgress: options.onProgress}),

  // Calls `listener` with each change in the app's collections the viewer may
  // see: `{event, collection, value?, id?, revision?}`, where `event` is
  // "created", "updated", "deleted", "cleared", "regraded" or "config".
  onValues(listener, options = {}) {
    if (typeof listener !== "function") return () => {}

    collectionListeners.set(listener, options.collection ?? null)
    return () => collectionListeners.delete(listener)
  },

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

  // For a guest (`getCurrentProfile()` is null): takes the page to Potok's
  // log-in, which brings them back to this group afterwards. Resolves to
  // `{ok: true}` as the page leaves, or `unavailable` where there is no guest.
  // The frame goes away with the page, so a pending `localStorage` save goes
  // first: the same browser finds it again once signed in.
  openLogin: () => {
    if (storageSaveTimer) saveLocalStorage()
    return call("open_login")
  },

  // This group, its parent and what the viewer may do here.
  getGroup: () => call("get_group"),

  // The calls below keep the groups right under this one. They act in the
  // viewer's name, so they need a viewer who may edit this group
  // (`can_manage_children` in `getGroup`). Up to 50 per call (default 20),
  // the newest publication first; page with `beforeId`.
  listChildren: (options = {}) => call("list_children", subgroupPage(options)),

  getChild: id => call("get_child", {id}),

  createChild: attrs => call("create_child", childParams(attrs)),

  // Up to 100 children at once, all or none: `invalid_group` with the `index`
  // of the one that failed, and nothing saved. A child whose `key` (1 to 64
  // characters, unique under this group) is there already is not made again:
  // `{ok: true, groups: [{id, key, created}]}` in the order sent, `created`
  // false for those. So a call that timed out can be sent again as it was.
  // One write for the rate limit; open pages hear of the call once. Groups
  // with a key are records: the root's map does not show them.
  createChildren: (children, options = {}) =>
    call("create_children", {
      children: Array.isArray(children) ? children.map(newChildParams) : children,
      ...(options.onExisting === undefined ? {} : {on_existing: options.onExisting}),
    }),

  updateChild: (id, attrs) => call("update_child", {...childParams(attrs), id}),

  // Closes the group again, and its inherited members leave.
  withdrawChild: id => call("withdraw_child", {id}),

  // The description as it will be shown, sanitized on the server.
  previewDescription: (description, options = {}) =>
    call("preview_description", {
      description: typeof description === "string" ? description : "",
      description_format: options.descriptionFormat || options.description_format || null,
    }),

  // The polls of this group, the newest first, 30 per call; page with `beforeId`.
  // `status` is "open" (the default), "closed" or "waiting", those the viewer can
  // still vote in. A poll holds only what its rules show this viewer, so
  // `votes_count` of an answer may be null. An app cannot vote or change a poll:
  // `openPoll` and `openPollForm` do that on Potok's own page.
  listPolls: (options = {}) =>
    call("list_polls", {
      status: options.status ?? null,
      before_id: options.beforeId ?? null,
    }),

  getPoll: id => call("get_poll", {id}),

  // Opens the poll in a dialog of Potok's, over the app, where the viewer votes.
  openPoll: id => call("open_poll", {id}),

  // Opens Potok's form for a new poll in this group, over the app.
  openPollForm: () => call("open_poll_form"),

  // Calls `listener` with the id of a poll that changed, or got a vote or was
  // deleted. Read it again with `getPoll`; a deleted one is `not_found`.
  onPollChange(listener) {
    if (typeof listener !== "function") return () => {}

    pollListeners.add(listener)
    return () => pollListeners.delete(listener)
  },

  // `{scope: "group"}` also passes on the values of the group's other apps.
  onNewValue(listener, options = {}) {
    if (typeof listener !== "function") return () => {}

    newValueListeners.set(listener, options.scope === "group")
    return () => newValueListeners.delete(listener)
  },

  // What a map needs before its first pin: `tiles` (`url` with {z}, {x} and
  // {y}, `attribution` as HTML, `max_zoom`), `default_bounds` ([[south, west],
  // [north, east]], where a map opens until its editors save a view),
  // `pins` (how every pin is drawn: `drop`, `glyph_transform`, `tones`,
  // `kinds` and `icons` with SVG `paths` and names in the viewer's language;
  // each kind's small `mark`, nil for "none", goes by `mark_transform` in the
  // top right corner of a pin the group picked, the lock of a closed group in
  // the top left), `place_kinds` for `createPlace`, `can_create_places` and
  // `can_edit_view`.
  getMapConfig: () => call("map_config"),

  // The sub-groups right under this group that the viewer sees and that have a
  // place: `{ok: true, places: [{id, name, lat, lng, kind, pin, picture_url,
  // is_public, shape, areas}], truncated}`, up to 2000. `pin` is the group's
  // own choice (a key of `pins.icons`, or "picture" for its picture), null for
  // its kind's. `shape` is "point", "area" for a group that covers an area
  // (then `lat`, `lng` are its pin, a point inside it), or "route" for a group
  // that runs along a line, such as a walk or a bike path (then `lat`, `lng`
  // are its start, and `length` is in metres). An area and a route also have
  // `bbox` ([west, south, east, north]) and `v`, which changes with its shape.
  // `areas` are the ids of the areas among these places that hold this one,
  // smallest first (an area holds another only when it is the bigger one; a
  // route lies in every area it passes through).
  //
  // With a view, `{bbox: [west, south, east, north], zoom, search, pins,
  // extent, counts}`, a map of up to 2000 places gets them all as above, with
  // `mode: "all"`, and a bigger one what its view shows, gathered by Potok
  // into cells of about 64 pixels: `{ok: true, mode: "view", places (each
  // alone in its cell), clusters: [{count, lat, lng, bounds: [[south, west],
  // [north, east]], tones: {tone: count}}], total, truncated}`, with `extent:
  // {count, bounds}` when asked for (`extent: true`) and `pins: [{pin, count}]`
  // over the whole map (`counts: true`). `search` and `pins` (keys of
  // `pins.icons`, and "kind") filter a big map only. Ask again when the view
  // moves; a view slower than 4 seconds is `timeout`.
  listPlaces: view =>
    view === undefined
      ? call("list_places")
      : call("list_places", {
          bbox: view.bbox,
          zoom: view.zoom,
          ...placeFilters(view),
          ...(view.extent === true ? {extent: true} : {}),
          ...(view.counts === true ? {counts: true} : {}),
        }),

  // The places of a big map whose pins stand inside `bounds` ([[south, west],
  // [north, east]], edges included), by name, at most 50: what a cluster holds
  // that cannot spread any further. `{ok: true, places, has_more}`.
  listPlacesAt: (bounds, options = {}) => call("list_places_at", {bounds, ...placeFilters(options)}),

  // The shapes of areas and routes among `listPlaces`, simplified for `zoom`
  // (at most 100 ids): `{ok: true, level, shapes: [{id, v, geojson}]}`, where
  // `geojson` is a MultiPolygon for an area and a MultiLineString for a route,
  // and `level` the zoom they were simplified for (one of 6, 8, 10, 12, 14,
  // 16); keep them by `id`, `v` and `level`.
  placeShapes: (ids, zoom) => call("place_shapes", {ids, zoom}),

  // Makes a sub-group standing at `lat`, `lng`, as the page's "Create
  // sub-group" menu does: `kind` is one of `place_kinds`, `isPublic` and `pin`
  // may be left out. Needs `can_create_places`. Resolves to `{ok: true, place}`.
  createPlace: ({name, kind, lat, lng, isPublic, pin} = {}) =>
    call("create_place", {
      name,
      kind,
      lat,
      lng,
      ...(isPublic === undefined ? {} : {is_public: isPublic}),
      ...(pin === undefined ? {} : {pin}),
    }),

  // Opens a sub-group's description on Potok's page, over the app, with a
  // link to the group: where its own app, a form or a poll, runs with that
  // group's rights. Only for a sub-group right under this group.
  showGroup: id => call("show_group", {id}),

  // Calls `listener` with the group's id when the viewer closes what
  // `showGroup` opened.
  onGroupSheetClose(listener) {
    if (typeof listener !== "function") return () => {}

    sheetListeners.add(listener)
    return () => sheetListeners.delete(listener)
  },

  // Calls `listener` when a sub-group of this group was made, changed or
  // deleted. It says no more, as the group could be one the viewer does not
  // see: read again what the app shows (`listPlaces`, `listChildren`).
  onSubgroupsChange(listener) {
    if (typeof listener !== "function") return () => {}

    subgroupListeners.add(listener)
    return () => subgroupListeners.delete(listener)
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
