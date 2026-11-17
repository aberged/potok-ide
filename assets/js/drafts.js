// Drafts of the chat composer, kept in this browser only: a message begun in
// a group and left stays for when the viewer comes back, per profile and
// group (`potok:draft:<profile>:<group>`). Nothing reaches the server until
// it is sent. Storage can be missing or refuse (a private window, cleared
// data), so every access is guarded and a draft is only ever a convenience.

const PREFIX = "potok:draft:"
const MAX_DRAFTS = 50
const WRITE_DELAY_MS = 300

function storage() {
  try {
    return window.localStorage
  } catch (_error) {
    return null
  }
}

export function readDraft(key) {
  if (!key) return null

  try {
    const stored = JSON.parse(storage()?.getItem(key) || "null")
    return typeof stored?.t === "string" && stored.t.trim() !== "" ? stored.t : null
  } catch (_error) {
    return null
  }
}

function draftKeys(store) {
  const keys = []

  for (let i = 0; i < store.length; i++) {
    const key = store.key(i)
    if (key?.startsWith(PREFIX)) keys.push(key)
  }

  return keys
}

// The oldest drafts give way once there are more than `MAX_DRAFTS`.
function prune(store) {
  const keys = draftKeys(store)
  if (keys.length <= MAX_DRAFTS) return

  const at = key => {
    try {
      return JSON.parse(store.getItem(key) || "null")?.at || 0
    } catch (_error) {
      return 0
    }
  }

  keys
    .sort((a, b) => at(a) - at(b))
    .slice(0, keys.length - MAX_DRAFTS)
    .forEach(key => store.removeItem(key))
}

export function writeDraft(key, text) {
  const store = storage()
  if (!key || !store) return

  try {
    if (text.trim() === "") {
      store.removeItem(key)
    } else {
      store.setItem(key, JSON.stringify({t: text, at: Date.now()}))
      prune(store)
    }
  } catch (_error) {}
}

export function clearDraft(key) {
  try {
    if (key) storage()?.removeItem(key)
  } catch (_error) {}
}

// On logging out: the computer may be a shared one.
export function clearAllDrafts() {
  const store = storage()
  if (!store) return

  try {
    draftKeys(store).forEach(key => store.removeItem(key))
  } catch (_error) {}
}

// On the composer's form (`data-draft-key`). It brings a draft back into an
// empty composer when the form appears, and keeps what is typed, a moment
// after the typing stops and at once when the page goes away. A sent message
// (`value_composer_reset`) drops it.
export const ComposerDraft = {
  mounted() {
    this.key = this.el.dataset.draftKey
    this.textarea = this.el.querySelector("textarea")
    if (!this.key || !this.textarea) return

    const draft = readDraft(this.key)

    if (draft && this.textarea.value.trim() === "") {
      this.textarea.value = draft
      // LiveView takes it as typed text, so the server's form holds it too.
      this.textarea.dispatchEvent(new Event("input", {bubbles: true}))
    }

    this.write = () => {
      clearTimeout(this.timer)
      this.timer = null
      writeDraft(this.key, this.textarea.value)
    }

    this.handleInput = () => {
      clearTimeout(this.timer)
      this.timer = setTimeout(this.write, WRITE_DELAY_MS)
    }

    this.handleLeave = () => {
      if (this.timer) this.write()
    }

    this.textarea.addEventListener("input", this.handleInput)
    // A send keeps the draft until it went out; a refused one stays typed.
    this.el.addEventListener("submit", this.handleLeave)
    window.addEventListener("pagehide", this.handleLeave)

    this.handleEvent("value_composer_reset", () => {
      clearTimeout(this.timer)
      this.timer = null
      clearDraft(this.key)
    })
  },

  destroyed() {
    if (!this.textarea) return

    this.handleLeave()
    this.textarea.removeEventListener("input", this.handleInput)
    window.removeEventListener("pagehide", this.handleLeave)
  },
}

// On a group's row (`data-draft-key`, `data-label`): "Draft: …" in place of
// its last message while this browser holds a draft for it. The element is
// ignored by patches, so the text it draws stays; the row hides its last
// message through `group-has-[[data-draft-text]]`.
export const DraftMark = {
  mounted() {
    this.render()
    this.handleStorage = event => {
      if (event.key === null || event.key === this.el.dataset.draftKey) this.render()
    }
    window.addEventListener("storage", this.handleStorage)
  },

  destroyed() {
    window.removeEventListener("storage", this.handleStorage)
  },

  render() {
    const draft = readDraft(this.el.dataset.draftKey)
    this.el.replaceChildren()
    if (!draft) return

    const line = document.createElement("p")
    line.dataset.draftText = ""
    line.className = "truncate text-xs leading-4 text-error"

    const label = document.createElement("span")
    label.className = "font-semibold"
    label.textContent = this.el.dataset.label

    line.append(label, " ", draft.replace(/\s+/g, " ").trim())
    this.el.append(line)
  },
}
