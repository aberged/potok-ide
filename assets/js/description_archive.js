// An app's description as a file, for the description card
// (`Components.app_archive`): it goes in as a ZIP with one HTML file, or as
// the HTML file itself, and comes out as a ZIP holding `index.html`. No file
// reaches the server: the HTML goes into the form's hidden field, which the
// form sends as it sends typed text, and the download is made right here.
//
// ZIP is read and written with the browser's own deflate
// (`DecompressionStream` / `CompressionStream`), enough for an archive of a
// few MB: stored or deflated entries, no ZIP64, no passwords.

import {Capacitor} from "@capacitor/core"

// The socket takes frames up to 4 MB (`max_frame_size` in the endpoint) and a
// form goes out URL-encoded, so a bigger description would drop the socket.
const MAX_ENCODED = 3_500_000

const LOCAL = 0x04034b50
const CENTRAL = 0x02014b50
const END = 0x06054b50
const UTF8_NAME = 0x0800

class ArchiveError extends Error {
  constructor(code) {
    super(code)
    this.code = code
  }
}

const CRC_TABLE = (() => {
  const table = new Uint32Array(256)

  for (let n = 0; n < 256; n++) {
    let c = n
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
    table[n] = c >>> 0
  }

  return table
})()

export const crc32 = bytes => {
  let crc = 0xffffffff
  for (let i = 0; i < bytes.length; i++) crc = CRC_TABLE[(crc ^ bytes[i]) & 0xff] ^ (crc >>> 8)
  return (crc ^ 0xffffffff) >>> 0
}

export const zipSupported = () =>
  typeof DecompressionStream === "function" && typeof CompressionStream === "function"

const through = async (bytes, stream) =>
  new Uint8Array(await new Response(new Blob([bytes]).stream().pipeThrough(stream)).arrayBuffer())

const inflate = bytes => through(bytes, new DecompressionStream("deflate-raw"))
const deflate = bytes => through(bytes, new CompressionStream("deflate-raw"))

const viewOf = bytes => new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength)

export const looksLikeZip = bytes =>
  bytes.length >= 4 &&
  bytes[0] === 0x50 &&
  bytes[1] === 0x4b &&
  ((bytes[2] === 3 && bytes[3] === 4) || (bytes[2] === 5 && bytes[3] === 6))

// The end record sits last, before a comment of at most 64 KB.
const findEnd = view => {
  const last = view.byteLength - 22
  const first = Math.max(0, last - 0xffff)

  for (let at = last; at >= first; at--) {
    if (view.getUint32(at, true) === END) return at
  }

  return -1
}

// Only a name's folder and extension matter here, so a name that is not
// UTF-8 (old archivers write CP437) is read as Latin-1.
const decodeName = bytes => {
  try {
    return new TextDecoder("utf-8", {fatal: true}).decode(bytes)
  } catch (_error) {
    return new TextDecoder("latin1").decode(bytes)
  }
}

// The entries of an archive, from its central directory.
export const zipEntries = bytes => {
  if (bytes.length < 22) throw new ArchiveError("not-zip")

  const view = viewOf(bytes)
  const end = findEnd(view)
  if (end < 0) throw new ArchiveError("not-zip")

  const count = view.getUint16(end + 10, true)
  const size = view.getUint32(end + 12, true)
  let at = view.getUint32(end + 16, true)

  if (count === 0xffff || size === 0xffffffff || at === 0xffffffff) {
    throw new ArchiveError("unsupported")
  }

  if (at + size > end) throw new ArchiveError("not-zip")

  const entries = []

  for (let i = 0; i < count; i++) {
    if (at + 46 > end || view.getUint32(at, true) !== CENTRAL) throw new ArchiveError("not-zip")

    const nameLength = view.getUint16(at + 28, true)

    entries.push({
      flags: view.getUint16(at + 8, true),
      method: view.getUint16(at + 10, true),
      crc: view.getUint32(at + 16, true),
      packedSize: view.getUint32(at + 20, true),
      size: view.getUint32(at + 24, true),
      offset: view.getUint32(at + 42, true),
      name: decodeName(bytes.subarray(at + 46, at + 46 + nameLength)),
    })

    at += 46 + nameLength + view.getUint16(at + 30, true) + view.getUint16(at + 32, true)
  }

  return entries
}

// What an entry holds, checked against its CRC.
export const entryBytes = async (bytes, entry) => {
  if (entry.flags & 0x1) throw new ArchiveError("unsupported")
  if (entry.packedSize === 0xffffffff || entry.size === 0xffffffff || entry.offset === 0xffffffff) {
    throw new ArchiveError("unsupported")
  }

  const view = viewOf(bytes)
  const at = entry.offset

  if (at + 30 > bytes.length || view.getUint32(at, true) !== LOCAL) throw new ArchiveError("not-zip")

  const start = at + 30 + view.getUint16(at + 26, true) + view.getUint16(at + 28, true)
  const packed = bytes.subarray(start, start + entry.packedSize)

  if (packed.length !== entry.packedSize) throw new ArchiveError("not-zip")

  let data

  if (entry.method === 0) {
    data = packed
  } else if (entry.method === 8) {
    try {
      data = await inflate(packed)
    } catch (_error) {
      throw new ArchiveError("not-zip")
    }
  } else {
    throw new ArchiveError("unsupported")
  }

  if (data.length !== entry.size || crc32(data) !== entry.crc) throw new ArchiveError("not-zip")

  return data
}

const baseName = name => name.split("/").pop()

// Folders and what macOS adds to the archives it makes.
const junk = name =>
  name.endsWith("/") ||
  name.startsWith("__MACOSX/") ||
  name.includes("/__MACOSX/") ||
  baseName(name) === ".DS_Store"

const htmlName = name => /\.html?$/i.test(name)

const decodeHtml = bytes => {
  try {
    return new TextDecoder("utf-8", {fatal: true}).decode(bytes)
  } catch (_error) {
    throw new ArchiveError("not-utf8")
  }
}

// The HTML a picked file brings: `{html, inner, skipped}`, `inner` naming the
// HTML file inside an archive and `skipped` counting the archive's other files.
export const readDescriptionFile = async file => {
  const bytes = new Uint8Array(await file.arrayBuffer())

  if (!looksLikeZip(bytes)) {
    if (htmlName(file.name) || file.type === "text/html") {
      return {html: decodeHtml(bytes), inner: null, skipped: 0}
    }

    throw new ArchiveError("not-zip")
  }

  if (!zipSupported()) throw new ArchiveError("browser")

  const files = zipEntries(bytes).filter(entry => !junk(entry.name))
  const pages = files.filter(entry => htmlName(entry.name))

  if (pages.length === 0) throw new ArchiveError("no-html")
  if (pages.length > 1) throw new ArchiveError("many-html")

  const [page] = pages
  const html = decodeHtml(await entryBytes(bytes, page))

  return {html, inner: baseName(page.name), skipped: files.length - 1}
}

const dosStamp = date => ({
  time: (date.getHours() << 11) | (date.getMinutes() << 5) | Math.floor(date.getSeconds() / 2),
  day: ((Math.max(date.getFullYear(), 1980) - 1980) << 9) | ((date.getMonth() + 1) << 5) | date.getDate(),
})

// An archive of one deflated file.
export const zipOne = async (name, data, date = new Date()) => {
  const nameBytes = new TextEncoder().encode(name)
  const packed = await deflate(data)
  const crc = crc32(data)
  const {time, day} = dosStamp(date)

  const local = new Uint8Array(30 + nameBytes.length)
  const lv = viewOf(local)
  lv.setUint32(0, LOCAL, true)
  lv.setUint16(4, 20, true) // needs version 2.0
  lv.setUint16(6, UTF8_NAME, true)
  lv.setUint16(8, 8, true) // deflate
  lv.setUint16(10, time, true)
  lv.setUint16(12, day, true)
  lv.setUint32(14, crc, true)
  lv.setUint32(18, packed.length, true)
  lv.setUint32(22, data.length, true)
  lv.setUint16(26, nameBytes.length, true)
  local.set(nameBytes, 30)

  const central = new Uint8Array(46 + nameBytes.length)
  const cv = viewOf(central)
  cv.setUint32(0, CENTRAL, true)
  cv.setUint16(4, 20, true) // made by version 2.0
  cv.setUint16(6, 20, true)
  cv.setUint16(8, UTF8_NAME, true)
  cv.setUint16(10, 8, true)
  cv.setUint16(12, time, true)
  cv.setUint16(14, day, true)
  cv.setUint32(16, crc, true)
  cv.setUint32(20, packed.length, true)
  cv.setUint32(24, data.length, true)
  cv.setUint16(28, nameBytes.length, true)
  cv.setUint32(42, 0, true) // the local header comes first
  central.set(nameBytes, 46)

  const end = new Uint8Array(22)
  const ev = viewOf(end)
  ev.setUint32(0, END, true)
  ev.setUint16(8, 1, true)
  ev.setUint16(10, 1, true)
  ev.setUint32(12, central.length, true)
  ev.setUint32(16, local.length + packed.length, true)

  return new Blob([local, packed, central, end], {type: "application/zip"})
}

// Sizes as the server writes them (`Components.format_bytes/1`).
const formatBytes = bytes => {
  if (bytes < 1000) return `${bytes} B`

  const [size, unit] = [[1e9, "GB"], [1e6, "MB"], [1e3, "kB"]].find(([size]) => bytes >= size)
  const value = bytes / size

  return `${value < 10 ? value.toFixed(1) : Math.round(value)} ${unit}`
}

export const DescriptionArchive = {
  mounted() {
    this.fileInput = this.el.querySelector("[data-archive-file]")
    this.message = this.el.querySelector("[data-archive-message]")

    this.el.querySelector("[data-archive-upload]").addEventListener("click", () => this.fileInput.click())
    this.el.querySelector("[data-archive-download]").addEventListener("click", () => this.download())

    this.fileInput.addEventListener("change", event => {
      // The form's `phx-change` would go to the server for nothing: the file
      // stays here.
      event.stopPropagation()

      const file = this.fileInput.files?.[0]
      this.fileInput.value = ""

      if (file) this.load(file)
    })

    // Discarding the changes puts another description in the field, and the
    // line about the file read before no longer holds.
    this.observer = new MutationObserver(() => {
      if (this.loaded !== undefined && this.input()?.value !== this.loaded) this.say(null)
    })

    const input = this.input()
    if (input) this.observer.observe(input, {attributes: true, attributeFilter: ["value"]})
  },

  destroyed() {
    this.observer?.disconnect()
  },

  input() {
    return document.getElementById(this.el.dataset.input)
  },

  text(code, values = {}) {
    const key = `msg${code.replace(/(^|-)(\w)/g, (_all, _dash, letter) => letter.toUpperCase())}`
    const template = this.el.dataset[key] || this.el.dataset.msgFailed || ""

    return template.replace(/\{(\w+)\}/g, (all, name) => (name in values ? values[name] : all))
  },

  say(text, error = false) {
    this.loaded = undefined
    this.message.textContent = text || ""
    this.message.hidden = !text
    this.message.toggleAttribute("data-error", Boolean(text) && error)
  },

  async load(file) {
    try {
      const {html, inner, skipped} = await readDescriptionFile(file)

      if (encodeURIComponent(html).length > MAX_ENCODED) throw new ArchiveError("too-big")

      const input = this.input()
      if (!input) return

      input.value = html
      input.dispatchEvent(new Event("input", {bubbles: true}))

      const name = inner ? `${file.name} → ${inner}` : file.name
      const size = formatBytes(new TextEncoder().encode(html).length)
      const lines = [this.text("loaded", {file: name, size})]

      if (skipped > 0) lines.push(this.text("skipped", {count: skipped}))

      this.say(lines.join(" "))
      this.loaded = html
    } catch (error) {
      if (!(error instanceof ArchiveError)) console.error("Unable to read the description file", error)
      this.say(this.text(error instanceof ArchiveError ? error.code : "failed"), true)
    }
  },

  async download() {
    const html = this.input()?.value || ""

    if (html.trim() === "") return this.say(this.text("empty"), true)
    // The phone apps' web views save no file a page makes.
    if (Capacitor.isNativePlatform()) return this.say(this.text("native"), true)
    if (!zipSupported()) return this.say(this.text("browser"), true)

    try {
      const blob = await zipOne("index.html", new TextEncoder().encode(html))
      const address = URL.createObjectURL(blob)
      const link = document.createElement("a")

      link.href = address
      link.download = `${this.el.dataset.fileName || "app"}.zip`
      link.hidden = true
      document.body.append(link)
      link.click()
      link.remove()

      // Some browsers read the address only after the click returns.
      setTimeout(() => URL.revokeObjectURL(address), 30_000)
      this.say(null)
    } catch (error) {
      console.error("Unable to make the description's ZIP", error)
      this.say(this.text("failed"), true)
    }
  },
}
