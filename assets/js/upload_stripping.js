// Every file a LiveView upload takes passes `stripMetadata` first
// (strip_metadata.js), so a photo's EXIF, GPS and XMP never leave the device.
//
// LiveView listens on `window` as events bubble; these listeners sit on
// `window` in the capture phase, which runs before them. Each one stops the
// event, strips the files and hands them to LiveView through its own
// programmatic path, a `track-uploads` event on the input, as `this.upload()`
// of a hook does. What a hook uploads itself (shared files, a keyboard's GIFs)
// comes as such an event too, and is stripped the same way. The size LiveView
// announces is then the stripped one, as the presigned upload needs.
//
// The app frame announces a file's size before it uploads it
// (`GroupAppFrame.sendFile` in app.js), so it strips first, with `stripForUpload`.

import { stripMetadata } from "./strip_metadata"

const TRACK = "track-uploads"
const stripped = new WeakSet()
// The file list of an input already taken from its `input` event, so its
// `change` event, which follows, is swallowed too.
const taken = new WeakMap()

const isUploadInput = el =>
  el instanceof HTMLInputElement && el.type === "file" && el.hasAttribute("data-phx-upload-ref")

async function stripAll(files) {
  const out = await Promise.all(files.map(file => stripMetadata(file)))
  out.forEach(file => stripped.add(file))
  return out
}

function track(input, files) {
  input.dispatchEvent(new CustomEvent(TRACK, { bubbles: true, detail: { files } }))
}

function onPick(event) {
  const input = event.target
  if (!isUploadInput(input)) return

  // LiveView's own input event after `track-uploads` finds the input empty.
  const list = input.files
  if (!list || list.length === 0 || Array.from(list).every(file => stripped.has(file))) return

  event.stopImmediatePropagation()
  if (taken.get(input) === list) return
  taken.set(input, list)

  const files = Array.from(list)
  // LiveView reads `input.files` on every input event: emptied, it sees only
  // the files handed to it.
  input.value = ""
  stripAll(files).then(out => track(input, out))
}

function onDrop(event) {
  const zone = event.target instanceof Element && event.target.closest("[phx-drop-target]")
  if (!zone) return

  const input = document.getElementById(zone.getAttribute("phx-drop-target"))
  const files = Array.from(event.dataTransfer?.files || [])
  if (!isUploadInput(input) || input.disabled || files.length === 0) return

  event.preventDefault()
  event.stopImmediatePropagation()
  zone.classList.remove("phx-drop-target-active")
  stripAll(files).then(out => track(input, out))
}

function onTrack(event) {
  const files = Array.from(event.detail?.files || [])
  if (files.every(file => stripped.has(file))) return

  event.stopImmediatePropagation()
  const input = event.target
  stripAll(files).then(out => track(input, out))
}

// For a file whose size is announced before it is handed to LiveView (the app
// frame's `prepare_upload`): stripped now, and marked so `onTrack` lets it by.
export async function stripForUpload(file) {
  const [out] = await stripAll([file])
  return out
}

export function installUploadStripping() {
  window.addEventListener("input", onPick, true)
  window.addEventListener("change", onPick, true)
  window.addEventListener("drop", onDrop, true)
  window.addEventListener(TRACK, onTrack, true)
}
