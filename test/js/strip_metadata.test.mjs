// `node --test test/js`: the metadata a photo loses before it is uploaded
// (assets/js/strip_metadata.js). The pictures are tiny ones made by ImageMagick,
// with metadata spliced into them here.
import assert from "node:assert/strict"
import { test } from "node:test"

import { stripMetadata } from "../../assets/js/strip_metadata.js"

const b64 = text => new Uint8Array(Buffer.from(text, "base64"))
const concat = (...parts) => {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0))
  let at = 0
  for (const part of parts) {
    out.set(part, at)
    at += part.length
  }
  return out
}
const text = string => new Uint8Array(Buffer.from(string, "latin1"))
const bytesOf = async file => new Uint8Array(await file.arrayBuffer())
const fileOf = (bytes, name = "photo.jpg", type = "image/jpeg") =>
  new File([bytes], name, { type, lastModified: 1_700_000_000_000 })
const has = (bytes, string) => Buffer.from(bytes).includes(Buffer.from(string, "latin1"))

const TINY_JPEG = b64(
  "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wAARCAAEAAQDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAb/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFAEBAAAAAAAAAAAAAAAAAAAABv/EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAMAwEAAhEDEQA/AJAAnHX/2Q=="
)
const PROGRESSIVE_JPEG = b64(
  "/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAYEBQYFBAYGBQYHBwYIChAKCgkJChQODwwQFxQYGBcUFhYaHSUfGhsjHBYWICwgIyYnKSopGR8tMC0oMCUoKSj/2wBDAQcHBwoIChMKChMoGhYaKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCgoKCj/wgARCAAEAAQDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAX/xAAUAQEAAAAAAAAAAAAAAAAAAAAF/9oADAMBAAIQAxAAAAGOEzv/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAEFAn//xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAEDAQE/AX//xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAECAQE/AX//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAY/An//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAE/IX//2gAMAwEAAgADAAAAEPv/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAEDAQE/EH//xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oACAECAQE/EH//xAAUEAEAAAAAAAAAAAAAAAAAAAAA/9oACAEBAAE/EH//2Q=="
)
const TINY_PNG = b64(
  "iVBORw0KGgoAAAANSUhEUgAAAAQAAAAEAQMAAACTPww9AAAAA1BMVEUzZpk7I4HSAAAAC0lEQVQI12NggAAAAAgAAS8g3TEAAAAASUVORK5CYII="
)
const TINY_WEBP = b64("UklGRjYAAABXRUJQVlA4ICoAAACwAQCdASoEAAQAAgA0JaACdLoABGaAAP7udn/3BmfV2OH9zcW5+hQAAAA=")

// A little-endian TIFF block: IFD0 with the orientation (when given) and a
// pointer to a GPS directory holding a latitude.
function exifTiff(orientation) {
  const entries = []
  if (orientation) entries.push([0x0112, 3, 1, orientation])
  entries.push([0x8825, 4, 1, 0]) // GPS IFD offset, set below
  const ifd0Size = 2 + entries.length * 12 + 4
  const gpsAt = 8 + ifd0Size
  const out = new Uint8Array(gpsAt + 2 + 12 + 4 + 8)
  const view = new DataView(out.buffer)
  out.set(text("II"), 0)
  view.setUint16(2, 42, true)
  view.setUint32(4, 8, true)
  view.setUint16(8, entries.length, true)
  entries.forEach(([tag, type, count, value], i) => {
    const at = 10 + i * 12
    view.setUint16(at, tag, true)
    view.setUint16(at + 2, type, true)
    view.setUint32(at + 4, count, true)
    if (type === 3) view.setUint16(at + 8, value, true)
    else view.setUint32(at + 8, tag === 0x8825 ? gpsAt : value, true)
  })
  view.setUint16(gpsAt, 1, true)
  view.setUint16(gpsAt + 2, 0x0001, true) // GPSLatitudeRef
  view.setUint16(gpsAt + 4, 2, true)
  view.setUint32(gpsAt + 6, 2, true)
  out.set(text("N\0"), gpsAt + 10)
  out.set(text("GPSDATA!"), gpsAt + 18)
  return out
}

function segment(marker, body) {
  const length = body.length + 2
  return concat(new Uint8Array([0xff, marker, length >> 8, length & 0xff]), body)
}

function minimalApp1(orientation) {
  return concat(
    new Uint8Array([0xff, 0xe1, 0x00, 0x22]),
    text("Exif\0\0MM\0*\0\0\0\x08\0\x01\x01\x12\0\x03\0\0\0\x01\0"),
    new Uint8Array([orientation, 0, 0, 0, 0, 0, 0])
  )
}

const JPEG_HEAD = TINY_JPEG.subarray(0, 20) // SOI + APP0 (JFIF)
const JPEG_REST = TINY_JPEG.subarray(20) // tables, frame, scan, EOI

test("a JPEG loses EXIF, GPS, XMP, comments and what follows the picture, and keeps its orientation", async () => {
  const meta = concat(
    segment(0xe1, concat(text("Exif\0\0"), exifTiff(6))),
    segment(0xe1, text("http://ns.adobe.com/xap/1.0/\0<x:xmpmeta>secret</x:xmpmeta>")),
    segment(0xfe, text("taken at home")),
    segment(0xed, text("Photoshop 3.0\0IPTC"))
  )
  const trailing = concat(new Uint8Array([0xff, 0xd8]), segment(0xe1, text("Exif\0\0GPSDATA!")), new Uint8Array([0xff, 0xd9]))
  const original = fileOf(concat(JPEG_HEAD, meta, JPEG_REST, trailing))

  const stripped = await stripMetadata(original)
  const bytes = await bytesOf(stripped)

  assert.deepEqual(bytes, concat(JPEG_HEAD, minimalApp1(6), JPEG_REST))
  assert.equal(stripped.size, bytes.length)
  assert.equal(stripped.name, "photo.jpg")
  assert.equal(stripped.type, "image/jpeg")
  for (const word of ["GPSDATA", "xmpmeta", "taken at home", "IPTC"]) assert.ok(!has(bytes, word), word)

  // Stripping again changes nothing.
  assert.equal(await stripMetadata(stripped), stripped)
})

test("a JPEG with no orientation gets no EXIF at all", async () => {
  const head = PROGRESSIVE_JPEG.subarray(0, 20)
  const rest = PROGRESSIVE_JPEG.subarray(20)
  const original = fileOf(concat(head, segment(0xe1, concat(text("Exif\0\0"), exifTiff(null))), rest))

  const bytes = await bytesOf(await stripMetadata(original))
  assert.deepEqual(bytes, PROGRESSIVE_JPEG)
})

test("a JPEG with nothing to cut comes back as the same file", async () => {
  const original = fileOf(TINY_JPEG)
  assert.equal(await stripMetadata(original), original)
})

test("a JPEG keeps its colour profile", async () => {
  const icc = segment(0xe2, text("ICC_PROFILE\0\x01\x01profile-bytes"))
  const mpf = segment(0xe2, text("MPF\0index"))
  const original = fileOf(concat(JPEG_HEAD, icc, mpf, JPEG_REST))

  const bytes = await bytesOf(await stripMetadata(original))
  assert.deepEqual(bytes, concat(JPEG_HEAD, icc, JPEG_REST))
})

function pngChunk(type, data) {
  const out = new Uint8Array(12 + data.length)
  const view = new DataView(out.buffer)
  view.setUint32(0, data.length)
  out.set(text(type), 4)
  out.set(data, 8)
  view.setUint32(8 + data.length, 0) // the CRC is not checked here
  return out
}

function pngParts(bytes) {
  const parts = []
  let at = 8
  while (at < bytes.length) {
    const length = new DataView(bytes.buffer, bytes.byteOffset + at, 4).getUint32(0)
    parts.push(bytes.subarray(at, at + 12 + length))
    at += 12 + length
  }
  return parts
}

test("a PNG keeps only the chunks that draw it, and its orientation", async () => {
  const [ihdr, ...rest] = pngParts(TINY_PNG)
  const original = fileOf(
    concat(
      TINY_PNG.subarray(0, 8),
      ihdr,
      pngChunk("tEXt", text("Comment\0taken at home")),
      pngChunk("iTXt", text("XML:com.adobe.xmp\0\0\0\0\0<x:xmpmeta/>")),
      pngChunk("eXIf", exifTiff(3)),
      pngChunk("tIME", new Uint8Array(7)),
      ...rest
    ),
    "photo.png",
    "image/png"
  )

  const bytes = await bytesOf(await stripMetadata(original))
  const parts = pngParts(bytes)
  const types = parts.map(part => Buffer.from(part.subarray(4, 8)).toString("latin1"))

  assert.deepEqual(types, ["IHDR", "eXIf", "PLTE", "IDAT", "IEND"])
  assert.deepEqual(parts[0], ihdr)
  assert.deepEqual(concat(...parts.slice(2)), concat(...rest))
  assert.equal(parts[1][8 + 19], 3) // the orientation's value
  assert.ok(!has(bytes, "GPSDATA") && !has(bytes, "taken at home") && !has(bytes, "xmpmeta"))
})

test("the new eXIf chunk has a right CRC", async () => {
  const [ihdr, ...rest] = pngParts(TINY_PNG)
  const original = fileOf(concat(TINY_PNG.subarray(0, 8), ihdr, pngChunk("eXIf", exifTiff(6)), ...rest))
  const exif = pngParts(await bytesOf(await stripMetadata(original)))[1]
  const { crc32 } = await import("node:zlib")
  const crc = new DataView(exif.buffer, exif.byteOffset + exif.length - 4, 4).getUint32(0)
  assert.equal(crc, crc32(exif.subarray(4, exif.length - 4)))
})

function riffChunk(type, data) {
  const pad = data.length & 1
  const out = new Uint8Array(8 + data.length + pad)
  out.set(text(type), 0)
  new DataView(out.buffer).setUint32(4, data.length, true)
  out.set(data, 8)
  return out
}

function riff(...chunks) {
  const body = concat(text("WEBP"), ...chunks)
  const header = new Uint8Array(8)
  header.set(text("RIFF"), 0)
  new DataView(header.buffer).setUint32(4, body.length, true)
  return concat(header, body)
}

test("a WebP loses EXIF and XMP, its flags and size follow, and the orientation stays", async () => {
  const vp8 = TINY_WEBP.subarray(12)
  const vp8x = riffChunk("VP8X", new Uint8Array([0x08 | 0x04, 0, 0, 0, 3, 0, 0, 3, 0, 0]))
  const original = fileOf(
    riff(vp8x, vp8, riffChunk("EXIF", concat(text("Exif\0\0"), exifTiff(8))), riffChunk("XMP ", text("<x:xmpmeta/>"))),
    "photo.webp",
    "image/webp"
  )

  const stripped = await stripMetadata(original)
  const bytes = await bytesOf(stripped)
  const view = new DataView(bytes.buffer)

  assert.equal(view.getUint32(4, true), bytes.length - 8)
  assert.equal(bytes[20], 0x08) // VP8X: EXIF stays, XMP goes
  assert.deepEqual(bytes.subarray(30, 30 + vp8.length), vp8)
  const exif = bytes.subarray(30 + vp8.length)
  assert.equal(Buffer.from(exif.subarray(0, 4)).toString("latin1"), "EXIF")
  assert.equal(exif[8 + 19], 8)
  assert.ok(!has(bytes, "GPSDATA") && !has(bytes, "xmpmeta"))
})

test("a stripped PNG or WebP comes back as the same file when stripped again", async () => {
  const [ihdr, ...rest] = pngParts(TINY_PNG)
  const png = await stripMetadata(
    fileOf(concat(TINY_PNG.subarray(0, 8), ihdr, pngChunk("eXIf", exifTiff(6)), ...rest), "p.png", "image/png")
  )
  assert.equal(await stripMetadata(png), png)

  const vp8x = riffChunk("VP8X", new Uint8Array([0x08, 0, 0, 0, 3, 0, 0, 3, 0, 0]))
  const webp = await stripMetadata(
    fileOf(riff(vp8x, TINY_WEBP.subarray(12), riffChunk("EXIF", exifTiff(6))), "p.webp", "image/webp")
  )
  assert.equal(await stripMetadata(webp), webp)
})

test("HEIC and other files go as they are", async () => {
  const heic = fileOf(concat(new Uint8Array([0, 0, 0, 24]), text("ftypheic\0\0\0\0mif1heic")), "photo.heic", "image/heic")
  assert.equal(await stripMetadata(heic), heic)

  const pdf = fileOf(text("%PDF-1.7 and some more bytes"), "doc.pdf", "application/pdf")
  assert.equal(await stripMetadata(pdf), pdf)
})

test("a broken picture is uploaded as it is", async () => {
  const warn = console.warn
  console.warn = () => {}
  try {
    const broken = fileOf(concat(new Uint8Array([0xff, 0xd8, 0xff, 0xe1, 0xff, 0xff]), text("garbage-garbage")))
    assert.equal(await stripMetadata(broken), broken)
  } finally {
    console.warn = warn
  }
})
