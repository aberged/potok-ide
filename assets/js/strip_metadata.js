// What a photo says about where and when it was taken stays on the device.
//
// Before a picture is uploaded, `stripMetadata(file)` cuts EXIF (often with the
// GPS position), XMP and the like out of a JPEG, PNG or WebP, by its bytes and
// never by drawing it again, so the picture itself loses nothing. Only the
// orientation is kept, written anew as the one tag of a tiny EXIF, or the
// picture would turn on its side. HEIC, AVIF, GIF, videos and every other file
// go as they are. It returns the same file when there is nothing to cut, and
// the original when it cannot read the file, so an upload never breaks on it.
//
// The parts of the original are sliced, never copied, so a big file is read a
// window at a time.

const WINDOW = 1 << 20

class Reader {
  constructor(blob) {
    this.blob = blob
    this.size = blob.size
    this.start = 0
    this.bytes = new Uint8Array(0)
  }

  // `length` bytes at `offset`, as a view; fewer at the end of the file.
  async at(offset, length) {
    const end = Math.min(offset + length, this.size)

    if (offset < this.start || end > this.start + this.bytes.length) {
      const size = Math.max(WINDOW, length)
      this.start = offset
      this.bytes = new Uint8Array(await this.blob.slice(offset, offset + size).arrayBuffer())
    }

    return this.bytes.subarray(offset - this.start, end - this.start)
  }

  async byte(offset) {
    const bytes = await this.at(offset, 1)
    if (bytes.length < 1) throw new Error("unexpected end")
    return bytes[0]
  }
}

const ascii = (bytes, from, length) =>
  String.fromCharCode(...bytes.subarray(from, from + length))

const startsWith = (bytes, values) => values.every((value, i) => bytes[i] === value)

const JPEG = [0xff, 0xd8, 0xff]
const PNG = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]

export async function stripMetadata(file) {
  if (!file || typeof file.slice !== "function" || file.size < 12) return file

  try {
    const head = new Uint8Array(await file.slice(0, 16).arrayBuffer())

    if (startsWith(head, JPEG)) return await stripJpeg(file)
    if (startsWith(head, PNG)) return await stripPng(file)
    if (ascii(head, 0, 4) === "RIFF" && ascii(head, 8, 4) === "WEBP") return await stripWebp(file)
    return file
  } catch (error) {
    console.warn("Potok: the picture's metadata stays, it could not be read", error)
    return file
  }
}

// The same file when nothing was cut, or a new one of the kept parts.
function rebuild(file, parts, changed) {
  if (!changed) return file

  return new File(parts, file.name, {
    type: file.type,
    lastModified: file.lastModified,
  })
}

// ---- Orientation ----------------------------------------------------------

// The orientation (1-8) a TIFF block of EXIF holds in its first directory, or 1.
function orientationOf(tiff) {
  if (tiff.length < 8) return 1
  const order = ascii(tiff, 0, 2)
  if (order !== "II" && order !== "MM") return 1

  const little = order === "II"
  const view = new DataView(tiff.buffer, tiff.byteOffset, tiff.byteLength)
  const u16 = at => view.getUint16(at, little)
  const u32 = at => view.getUint32(at, little)

  if (u16(2) !== 42) return 1
  const ifd = u32(4)
  if (ifd + 2 > tiff.length) return 1

  const count = u16(ifd)

  for (let i = 0; i < count; i++) {
    const entry = ifd + 2 + i * 12
    if (entry + 12 > tiff.length) return 1

    if (u16(entry) === 0x0112 && u16(entry + 2) === 3) {
      const value = u16(entry + 8)
      return value >= 1 && value <= 8 ? value : 1
    }
  }

  return 1
}

// Whether a TIFF block holds nothing but the orientation, as the one this
// file writes: kept as it is, so stripping twice changes nothing.
function onlyOrientation(tiff) {
  if (tiff.length > 64 || orientationOf(tiff) === 1) return false
  const little = ascii(tiff, 0, 2) === "II"
  const view = new DataView(tiff.buffer, tiff.byteOffset, tiff.byteLength)
  const ifd = view.getUint32(4, little)
  if (ifd + 18 > tiff.length) return false
  return view.getUint16(ifd, little) === 1 && view.getUint32(ifd + 14, little) === 0
}

// A TIFF block of EXIF with nothing but the orientation: 26 bytes.
function orientationTiff(orientation) {
  return new Uint8Array([
    0x4d, 0x4d, 0x00, 0x2a, 0x00, 0x00, 0x00, 0x08, // big-endian, directory at 8
    0x00, 0x01, // one entry
    0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, // orientation, SHORT, one
    0x00, orientation, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00, // no next directory
  ])
}

// ---- JPEG -----------------------------------------------------------------

// Segments a picture needs: the JFIF header, the colour profile, Adobe's
// colour transform, the tables, the frame and the restart interval.
const KEPT_JPEG = new Set([0xe0, 0xee, 0xdb, 0xc4, 0xcc, 0xdd])
const isFrame = marker =>
  marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc

async function stripJpeg(file) {
  const reader = new Reader(file)
  const parts = [file.slice(0, 2)]
  let orientation = 1
  let changed = false
  let afterApp0 = 1
  let offset = 2

  // The header: segments up to the first scan.
  while (true) {
    const ff = await reader.byte(offset)
    if (ff !== 0xff) throw new Error("not a marker")

    let marker = await reader.byte(offset + 1)
    // Fill bytes before a marker.
    while (marker === 0xff) {
      offset += 1
      marker = await reader.byte(offset + 1)
    }

    const lengthBytes = await reader.at(offset + 2, 2)
    const length = (lengthBytes[0] << 8) | lengthBytes[1]
    if (length < 2) throw new Error("bad segment")
    const end = offset + 2 + length

    if (marker === 0xda) break

    if (marker === 0xe1) {
      const body = await reader.at(offset + 4, Math.min(length - 2, 65533))
      const exif = ascii(body, 0, 6) === "Exif\0\0"

      if (exif && orientation === 1 && onlyOrientation(body.subarray(6))) {
        parts.push(file.slice(offset, end))
        orientation = -1
      } else {
        if (exif && orientation === 1) orientation = orientationOf(body.subarray(6))
        changed = true
      }
    } else if (marker === 0xe2) {
      const body = await reader.at(offset + 4, 12)
      if (ascii(body, 0, 12) === "ICC_PROFILE\0") parts.push(file.slice(offset, end))
      else changed = true
    } else if (KEPT_JPEG.has(marker) || isFrame(marker)) {
      parts.push(file.slice(offset, end))
      if (marker === 0xe0 && parts.length === 2) afterApp0 = 2
    } else {
      // APP3-APP13, APP15, comments and anything else.
      changed = true
    }

    offset = end
  }

  // The scans, up to the end of the main picture: whatever follows (other
  // pictures of the file, with their own EXIF) goes.
  const scanStart = offset
  const eoi = await findEoi(reader, offset)
  const scanEnd = eoi === null ? file.size : eoi + 2
  if (scanEnd < file.size) changed = true
  if (!changed) return file

  parts.push(file.slice(scanStart, scanEnd))

  if (orientation > 1) {
    const tiff = orientationTiff(orientation)
    const length = 2 + 6 + tiff.length
    const app1 = new Uint8Array(2 + length)
    app1.set([0xff, 0xe1, length >> 8, length & 0xff])
    app1.set([0x45, 0x78, 0x69, 0x66, 0x00, 0x00], 4)
    app1.set(tiff, 10)
    parts.splice(afterApp0, 0, app1)
  }

  return rebuild(file, parts, true)
}

// The offset of the main picture's EOI marker, walking the scans and the
// segments between them (a progressive JPEG has several), or null.
async function findEoi(reader, offset) {
  while (offset + 4 <= reader.size) {
    // A segment: SOS, or DHT/DQT/DRI between progressive scans.
    const marker = await reader.byte(offset + 1)
    if (marker === 0xd9) return offset

    const lengthBytes = await reader.at(offset + 2, 2)
    const length = (lengthBytes[0] << 8) | lengthBytes[1]
    offset += 2 + length
    if (marker !== 0xda) continue

    // Entropy-coded data: a 0xFF there is followed by 0x00 or a restart marker.
    while (true) {
      const bytes = await reader.at(offset, WINDOW)
      if (bytes.length < 2) return null
      let found = -1

      for (let i = 0; i < bytes.length - 1; i++) {
        if (bytes[i] !== 0xff) continue
        const next = bytes[i + 1]
        if (next === 0x00 || next === 0xff || (next >= 0xd0 && next <= 0xd7)) continue
        found = i
        break
      }

      if (found >= 0) {
        offset += found
        break
      }

      // Look again from the last byte, which may be the 0xFF of a marker.
      offset += bytes.length - 1
    }
  }

  return null
}

// ---- PNG ------------------------------------------------------------------

// Chunks that draw the picture; everything else (text, XMP, EXIF, time,
// private chunks) goes.
const KEPT_PNG = new Set([
  "IHDR", "PLTE", "IDAT", "IEND", "tRNS", "gAMA", "cHRM", "sRGB", "iCCP", "sBIT",
  "bKGD", "hIST", "pHYs", "sPLT", "acTL", "fcTL", "fdAT", "cICP", "mDCv", "cLLi",
])

const CRC_TABLE = (() => {
  const table = new Uint32Array(256)
  for (let n = 0; n < 256; n++) {
    let c = n
    for (let k = 0; k < 8; k++) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
    table[n] = c >>> 0
  }
  return table
})()

function crc32(bytes) {
  let crc = 0xffffffff
  for (const byte of bytes) crc = CRC_TABLE[(crc ^ byte) & 0xff] ^ (crc >>> 8)
  return (crc ^ 0xffffffff) >>> 0
}

async function stripPng(file) {
  const reader = new Reader(file)
  const parts = [file.slice(0, 8)]
  let orientation = 1
  let changed = false
  let afterHeader = 1
  let offset = 8

  while (offset + 12 <= file.size) {
    const head = await reader.at(offset, 8)
    const length = new DataView(head.buffer, head.byteOffset, 8).getUint32(0)
    const type = ascii(head, 4, 4)
    const end = offset + 12 + length
    if (end > file.size) throw new Error("bad chunk")

    const exif = type === "eXIf" && length <= 65536 ? await reader.at(offset + 8, length) : null

    if (KEPT_PNG.has(type) || (exif && orientation === 1 && onlyOrientation(exif))) {
      parts.push(file.slice(offset, end))
      if (type === "IHDR") afterHeader = parts.length
      if (exif) orientation = -1
    } else {
      if (exif && orientation === 1) orientation = orientationOf(exif)
      changed = true
    }

    offset = end
    if (type === "IEND") break
  }

  if (offset < file.size) changed = true
  if (!changed) return file

  if (orientation > 1) {
    const tiff = orientationTiff(orientation)
    const chunk = new Uint8Array(12 + tiff.length)
    const view = new DataView(chunk.buffer)
    view.setUint32(0, tiff.length)
    chunk.set([0x65, 0x58, 0x49, 0x66], 4) // eXIf
    chunk.set(tiff, 8)
    view.setUint32(8 + tiff.length, crc32(chunk.subarray(4, 8 + tiff.length)))
    parts.splice(afterHeader, 0, chunk)
  }

  return rebuild(file, parts, true)
}

// ---- WebP -----------------------------------------------------------------

const VP8X_EXIF = 0x08
const VP8X_XMP = 0x04

async function stripWebp(file) {
  const reader = new Reader(file)
  const kept = []
  let orientation = 1
  let changed = false
  let vp8x = null
  let offset = 12

  while (offset + 8 <= file.size) {
    const head = await reader.at(offset, 8)
    const type = ascii(head, 0, 4)
    const size = new DataView(head.buffer, head.byteOffset, 8).getUint32(4, true)
    const end = offset + 8 + size + (size & 1)
    if (offset + 8 + size > file.size) throw new Error("bad chunk")

    const body = type === "EXIF" && size <= 65536 ? await reader.at(offset + 8, size) : null
    const tiff = body && (ascii(body, 0, 6) === "Exif\0\0" ? body.subarray(6) : body)

    if (tiff && orientation === 1 && onlyOrientation(tiff)) {
      kept.push(file.slice(offset, Math.min(end, file.size)))
      orientation = -1
    } else if (type === "EXIF" || type === "XMP ") {
      if (tiff && orientation === 1) orientation = orientationOf(tiff)
      changed = true
    } else if (type === "VP8X") {
      vp8x = new Uint8Array(await reader.at(offset, Math.min(end, file.size) - offset))
      kept.push(vp8x)
    } else {
      kept.push(file.slice(offset, Math.min(end, file.size)))
    }

    offset = end
  }

  if (!changed) return file

  if (vp8x) {
    vp8x[8] &= ~(VP8X_EXIF | VP8X_XMP) & 0xff
    if (orientation !== 1) vp8x[8] |= VP8X_EXIF
  }

  if (orientation > 1 && vp8x) {
    const tiff = orientationTiff(orientation)
    const chunk = new Uint8Array(8 + tiff.length)
    chunk.set([0x45, 0x58, 0x49, 0x46], 0) // EXIF
    new DataView(chunk.buffer).setUint32(4, tiff.length, true)
    chunk.set(tiff, 8)
    kept.push(chunk)
  }

  const body = kept.reduce((sum, part) => sum + (part.size ?? part.byteLength), 0)
  const header = new Uint8Array(12)
  header.set([0x52, 0x49, 0x46, 0x46], 0) // RIFF
  new DataView(header.buffer).setUint32(4, body + 4, true)
  header.set([0x57, 0x45, 0x42, 0x50], 8) // WEBP

  return rebuild(file, [header, ...kept], true)
}
