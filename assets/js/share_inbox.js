// Content shared to Potok from another app. It stays on the device until a
// group is picked: `/share` (ShareLive) shows what it is, and the picked
// group's composer takes the text and the files into its usual upload, so
// the size, count and permission checks are the composer's own.
//
// It comes from one of three places:
// - the native apps' `ShareInbox` plugin, which copies shared files into the
//   app's storage (Android: ShareInboxPlugin.java, iOS: the Share Extension);
// - the installed web app's share target, which the service worker keeps in
//   IndexedDB (`priv/static/sw.js`);
// - `/share?title=&text=&url=`, where the server sends a share target post
//   that no service worker took (ShareTargetController), text only.

import {Capacitor, registerPlugin} from "@capacitor/core"

const NativeShareInbox = registerPlugin("ShareInbox")

// The service worker writes the same database; see `receiveShare` there.
const DB_NAME = "potok-share"
const DB_STORE = "shares"
const DB_KEY = "pending"

const OPENED_KEY = "potok:share-opened"
const CHUNK_SIZE = 1024 * 1024

// Builds without the plugin keep working; they just never receive shares.
const nativeInbox = () =>
  Capacitor.isNativePlatform() && Capacitor.isPluginAvailable("ShareInbox")

// A query share when IndexedDB is unavailable; live navigation to the
// group keeps this module, so the composer still finds it.
let memoryShare = null

const withStore = (mode, callback) =>
  new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, 1)

    request.onupgradeneeded = () => request.result.createObjectStore(DB_STORE)
    request.onerror = () => reject(request.error)
    request.onsuccess = () => {
      const db = request.result
      const transaction = db.transaction(DB_STORE, mode)
      const result = callback(transaction.objectStore(DB_STORE))

      transaction.oncomplete = () => {
        db.close()
        resolve(result?.result)
      }
      transaction.onerror = () => {
        db.close()
        reject(transaction.error)
      }
    }
  })

const readStoredShare = () =>
  withStore("readonly", store => store.get(DB_KEY)).catch(() => null)

const storeShare = record => withStore("readwrite", store => store.put(record, DB_KEY))

const newShareId = prefix =>
  `${prefix}${Date.now().toString(36)}${Math.random().toString(36).slice(2, 8)}`

const fromNative = share => ({
  id: share.id,
  source: "native",
  title: share.title || "",
  texts: Array.isArray(share.texts) ? share.texts : [],
  files: (share.files || []).map(file => ({
    id: file.id,
    name: file.name || "file",
    type: file.mimeType || "",
    size: Number(file.size) || 0,
  })),
})

const fromRecord = record => ({
  id: record.id,
  source: "web",
  title: record.title || "",
  texts: [record.text, record.url],
  files: (record.files || []).map((file, index) => ({
    id: String(index),
    name: file.name || "file",
    type: file.type || "",
    size: file.size,
    file,
  })),
})

// `/share?title=&text=&url=` becomes a stored share, so the group page,
// which has no query, finds it too.
const takeQueryShare = async () => {
  if (window.location.pathname !== "/share") {
    return memoryShare
  }

  const params = new URLSearchParams(window.location.search)
  const record = {
    id: newShareId("q"),
    title: params.get("title") || "",
    text: params.get("text") || "",
    url: params.get("url") || "",
    files: [],
  }

  if (!record.title && !record.text && !record.url) {
    return memoryShare
  }

  window.history.replaceState(window.history.state, "", "/share")

  try {
    await storeShare(record)
  } catch (_error) {
    memoryShare = fromRecord(record)
    return memoryShare
  }

  return fromRecord(record)
}

// The newest share waiting on this device, or null.
export const pendingShare = async ({includeQuery = false} = {}) => {
  if (nativeInbox()) {
    try {
      const {share} = await NativeShareInbox.getPending()

      if (share?.id) {
        return fromNative(share)
      }
    } catch (_error) {
      // Fall through to what the web app may hold.
    }
  }

  const record = await readStoredShare()

  if (record?.id) {
    return fromRecord(record)
  }

  return includeQuery ? takeQueryShare() : memoryShare
}

export const clearShare = async share => {
  if (memoryShare?.id === share.id) {
    memoryShare = null
  }

  if (share.source === "native") {
    await NativeShareInbox.clear({shareId: share.id})
    return
  }

  const record = await readStoredShare()

  if (record?.id === share.id) {
    await withStore("readwrite", store => store.delete(DB_KEY))
  }
}

// The text of a share for the composer: apps often send the title, a text
// and a URL that repeat each other, so a part already inside another one
// is left out.
export const shareText = share => {
  const parts = []

  share.texts
    .map(text => (typeof text === "string" ? text.trim() : ""))
    .filter(Boolean)
    .forEach(text => {
      if (parts.some(part => part.includes(text))) {
        return
      }

      const kept = parts.filter(part => !text.includes(part))
      parts.length = 0
      parts.push(...kept, text)
    })

  const title = share.title.trim()

  if (title && !parts.some(part => part.includes(title))) {
    parts.unshift(title)
  }

  return parts.join("\n\n")
}

export const base64ToBytes = data => {
  const binary = atob(data)
  const bytes = new Uint8Array(binary.length)

  for (let index = 0; index < binary.length; index++) {
    bytes[index] = binary.charCodeAt(index)
  }

  return bytes
}

// Native files come over the bridge in base64 chunks: a page served from
// the site cannot fetch the app's local files on iOS.
const readNativeFile = async (share, file) => {
  const parts = []

  for (let offset = 0; offset < file.size; offset += CHUNK_SIZE) {
    const {data} = await NativeShareInbox.readChunk({
      shareId: share.id,
      fileId: file.id,
      offset,
      length: CHUNK_SIZE,
    })

    if (!data) {
      break
    }

    parts.push(base64ToBytes(data))
  }

  return new File(parts, file.name, {type: file.type})
}

// The share's files as `File`s for a LiveView upload, with the names of
// those left out by reason. Files that are left out are never read.
export const readShareFiles = async (share, {canAttach, maxFiles, maxFileSize}) => {
  const files = []
  const skipped = {too_large: [], too_many: [], not_allowed: [], failed: []}

  for (const file of share.files) {
    if (!canAttach) {
      skipped.not_allowed.push(file.name)
    } else if (file.size > maxFileSize) {
      skipped.too_large.push(file.name)
    } else if (files.length >= maxFiles) {
      skipped.too_many.push(file.name)
    } else if (file.file) {
      files.push(file.file)
    } else {
      try {
        files.push(await readNativeFile(share, file))
      } catch (_error) {
        skipped.failed.push(file.name)
      }
    }
  }

  return {files, skipped}
}

const openedShareId = () => {
  try {
    return window.localStorage.getItem(OPENED_KEY)
  } catch (_error) {
    return null
  }
}

// `/share` opens once per share: a share the user walked away from must
// not take over the app at every later start.
const markShareOpened = id => {
  try {
    window.localStorage.setItem(OPENED_KEY, id)
  } catch (_error) {
    // Ignore storage failures (private mode/quota/etc.).
  }
}

// In the native apps: goes to `/share` when a share that was not opened yet
// is waiting. True when there is one. Logged out, the login page would send
// `/share` back to itself; the first page after logging in opens it.
export const openPendingNativeShare = async () => {
  if (!nativeInbox() || document.body.dataset.signedIn !== "true") {
    return false
  }

  const share = await pendingShare()

  if (!share || share.id === openedShareId()) {
    return false
  }

  if (window.location.pathname !== "/share") {
    window.location.assign("/share")
  }

  return true
}

// Shares that arrive while the app is open (Android) or when it becomes
// active (iOS, besides the `potok://share` URL the extension opens).
export const onNativeShareReceived = callback => {
  if (nativeInbox()) {
    void NativeShareInbox.addListener("shareReceived", callback)
  }
}

export const SharePreview = {
  mounted() {
    this.handleClick = event => {
      if (event.target.closest("#share-cancel")) {
        void this.cancel()
      }
    }

    this.el.addEventListener("click", this.handleClick)
    void this.load()
  },

  // A new LiveView process starts without the share.
  reconnected() {
    void this.load()
  },

  destroyed() {
    this.el.removeEventListener("click", this.handleClick)
  },

  async load() {
    const share = await pendingShare({includeQuery: true}).catch(() => null)
    this.share = share

    if (!share) {
      this.pushEvent("share_missing", {})
      return
    }

    markShareOpened(share.id)
    this.pushEvent("share_loaded", {
      id: share.id,
      text: shareText(share),
      files: share.files.map(({name, type, size}) => ({name, type, size})),
    })
  },

  async cancel() {
    if (this.share) {
      await clearShare(this.share).catch(() => {})
    }

    this.pushEvent("share_cancelled", {})
  },
}

// Shares already put into a composer: the hook mounts again when the
// composer comes back (after editing a value), and must not add them twice.
const filledShareIds = new Set()

export const ShareComposer = {
  mounted() {
    // Sent after a value is posted; the share is done once it went out.
    this.handleEvent("value_composer_reset", () => void this.finish())
    void this.fill()
  },

  async fill() {
    const {shareId, canAttach, maxFiles, maxFileSize} = this.el.dataset
    const share = await pendingShare().catch(() => null)

    if (share?.id !== shareId) {
      this.pushEvent("share_done", {})
      return
    }

    this.share = share

    if (filledShareIds.has(shareId)) {
      return
    }

    filledShareIds.add(shareId)

    const textarea = document.getElementById("group-value-content")
    const text = shareText(share)

    if (textarea && text && textarea.value.trim() === "") {
      textarea.value = text
      textarea.dispatchEvent(new Event("input", {bubbles: true}))
    }

    const {files, skipped} = await readShareFiles(share, {
      canAttach: canAttach === "true",
      maxFiles: Number(maxFiles),
      maxFileSize: Number(maxFileSize),
    })

    if (files.length > 0) {
      this.upload("attachments", files)
    }

    if (Object.values(skipped).some(names => names.length > 0)) {
      this.pushEvent("share_files_skipped", skipped)
    }
  },

  async finish() {
    const share = this.share

    if (!share) {
      return
    }

    this.share = null
    await clearShare(share).catch(() => {})
    this.pushEvent("share_done", {})
  },
}
