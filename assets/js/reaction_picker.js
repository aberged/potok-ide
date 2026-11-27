// One emoji picker per page. Every value renders a `[data-reaction-trigger]`
// button, as does a description; clicks are delegated here, so stream items
// never carry their own picker. The chat composer's emoji button
// (`[data-emoji-insert]`, shown only with a mouse) puts emoji in the text at
// the caret, and the picker stays open for the next one. An app in the page
// asks for it with `potok:pick-emoji`. The picker library is loaded on first use.
//
// Emoji data is self-hosted in priv/static/emoji (emoji-picker-element-data
// 1.8.0: en/emojibase as en.json), so no CDN is contacted. Emojibase has no
// Serbian data, so every language searches with English keywords. The picker
// caches it in IndexedDB.
//
// LiveView keeps this container's non-data attributes (`hidden`, class,
// style, aria-label) as set here because the element is `phx-update="ignore"`.

let pickerModule = null
const loadPicker = () =>
  pickerModule || (pickerModule = import("emoji-picker-element"))

const SHEET_MAX_WIDTH_PX = 640
const EDGE_GAP_PX = 8
const CLOSE_TRANSITION_MS = 150
const CLOSED_CLASSES = ["opacity-0", "translate-y-1"]

// Stands in for a button when an app asks: the picker sits at the bottom of its
// frame, over the app's own button, and `done` gets the emoji or null.
const appTrigger = (frame, done) => ({
  dataset: {},
  done,
  getBoundingClientRect() {
    const {bottom, right} = frame.getBoundingClientRect()
    return {top: bottom, bottom, left: right, right}
  },
})

// The text field a composer's emoji button writes into, or null for any other trigger.
const insertTarget = trigger => {
  const id = trigger?.dataset?.emojiInsert
  return id ? document.getElementById(id) : null
}

// The field keeps its selection while the picker's search has focus, so the
// emoji replaces what was selected, or goes where the caret was. LiveView, the
// composer's height and send button, the draft and the mention menu all follow
// the field's input event.
const insertAtCaret = (field, text) => {
  field.setRangeText(text, field.selectionStart, field.selectionEnd, "end")
  const caret = field.selectionEnd
  field.focus({preventScroll: true})
  field.setSelectionRange(caret, caret)
  field.dispatchEvent(new Event("input", {bubbles: true}))
}

export const ReactionPicker = {
  mounted() {
    this.trigger = null
    this.picker = null
    this.closeTimer = null
    this.formObserver = null

    this.handleDocumentClick = event => {
      const trigger = this.ownTrigger(event.target)

      if (trigger) {
        event.preventDefault()

        if (this.isOpen() && this.trigger === trigger) {
          this.close()
        } else {
          void this.open(trigger)
        }

        return
      }

      if (this.isOpen() && !this.el.contains(event.target)) {
        this.close()
      }
    }

    // The composer's text keeps focus and its selection while its emoji
    // button is pressed.
    this.handleMouseDown = event => {
      if (insertTarget(this.ownTrigger(event.target))) {
        event.preventDefault()
      }
    }

    // Nor does a click on an emoji or a category take focus from the text
    // while the composer's picker is open; only the search field does. The
    // picker tells of a click a moment later, and keys typed meanwhile go
    // to the text.
    this.handlePickerMouseDown = event => {
      const search = event.composedPath().some(node => node instanceof HTMLInputElement)

      if (insertTarget(this.trigger) && !search) {
        event.preventDefault()
      }
    }

    // The first load fetches and indexes the emoji data (about a second), so
    // it starts as soon as a pointer reaches a trigger instead of on click.
    this.handleWarmUp = event => {
      if (!this.picker && this.ownTrigger(event.target)) {
        this.ensurePicker().catch(() => {})
      }
    }

    // Caught before it reaches the composer's text, where Escape would also
    // cancel a reply or an edit.
    this.handleKeydown = event => {
      if (event.key === "Escape" && this.isOpen()) {
        event.preventDefault()
        event.stopPropagation()

        const trigger = this.trigger
        const field = insertTarget(trigger)
        this.close()
        ;(field || trigger)?.focus?.()
      }
    }

    // Sending the message closes the picker its emoji went into.
    this.handleSubmit = event => {
      if (this.isOpen() && insertTarget(this.trigger)?.form === event.target) {
        this.close()
      }
    }

    // An anchored popover would drift from its button while the feed
    // scrolls; the bottom sheet is not anchored, so it stays open. Nor does
    // the composer move with the feed, which scrolls by itself when a new
    // message comes.
    this.handleFeedScroll = () => {
      if (this.isOpen() && !this.sheetMode() && !insertTarget(this.trigger)) {
        this.close()
      }
    }

    this.handleResize = () => {
      if (this.isOpen()) {
        this.position()
      }
    }

    this.handlePickRequest = ({detail: {anchor, done}}) => {
      this.close()
      void this.open(appTrigger(anchor, done))
    }

    this.feed = document.getElementById("group-values-feed")

    this.el.addEventListener("potok:pick-emoji", this.handlePickRequest)
    this.el.addEventListener("mousedown", this.handlePickerMouseDown)
    document.addEventListener("click", this.handleDocumentClick)
    document.addEventListener("mousedown", this.handleMouseDown)
    document.addEventListener("pointerover", this.handleWarmUp, {passive: true})
    document.addEventListener("pointerdown", this.handleWarmUp, {passive: true})
    document.addEventListener("keydown", this.handleKeydown, true)
    document.addEventListener("submit", this.handleSubmit, true)
    window.addEventListener("resize", this.handleResize)
    this.feed?.addEventListener("scroll", this.handleFeedScroll, {passive: true})
  },

  destroyed() {
    window.clearTimeout(this.closeTimer)
    this.formObserver?.disconnect()
    document.removeEventListener("click", this.handleDocumentClick)
    document.removeEventListener("mousedown", this.handleMouseDown)
    document.removeEventListener("pointerover", this.handleWarmUp)
    document.removeEventListener("pointerdown", this.handleWarmUp)
    document.removeEventListener("keydown", this.handleKeydown, true)
    document.removeEventListener("submit", this.handleSubmit, true)
    window.removeEventListener("resize", this.handleResize)
    this.feed?.removeEventListener("scroll", this.handleFeedScroll)
  },

  isOpen() {
    return this.trigger !== null
  },

  // A sheet over a map is a LiveView inside the page's, with a picker of its
  // own: each picker answers the buttons of its own LiveView, which gets the reaction.
  ownTrigger(target) {
    const trigger = target?.closest?.("[data-reaction-trigger], [data-emoji-insert]")
    if (!trigger) return null

    const view = "[data-phx-session]"
    return trigger.closest(view) === this.el.closest(view) ? trigger : null
  },

  sheetMode() {
    return window.innerWidth < SHEET_MAX_WIDTH_PX
  },

  // Who the picker answers now. An app that asked hears that it got nothing
  // when the picker closes or moves to another button. A composer's button
  // shows that its picker is open, and while it is, the picker follows the
  // composer as it grows.
  setTrigger(trigger) {
    if (this.trigger === trigger) return

    this.trigger?.done?.(null)

    if (insertTarget(this.trigger)) {
      this.trigger.setAttribute("aria-expanded", "false")
    }

    this.formObserver?.disconnect()
    this.formObserver = null
    this.trigger = trigger

    const form = insertTarget(trigger)?.form

    if (form) {
      trigger.setAttribute("aria-expanded", "true")
      this.formObserver = new ResizeObserver(() => this.isOpen() && this.position())
      this.formObserver.observe(form)
    }

    if (trigger) {
      this.el.setAttribute(
        "aria-label",
        (form && trigger.getAttribute("aria-label")) || this.el.dataset.label
      )
    }
  },

  async open(trigger) {
    this.setTrigger(trigger)

    let picker

    try {
      picker = await this.ensurePicker()
    } catch (error) {
      console.error("Emoji picker failed to load", error)
      this.close()
      return
    }

    // Closed or moved to another message while the library was loading.
    if (this.trigger !== trigger) {
      return
    }

    window.clearTimeout(this.closeTimer)
    this.el.hidden = false
    this.position()

    requestAnimationFrame(() => {
      if (this.trigger === trigger) {
        this.el.classList.remove(...CLOSED_CLASSES)
      }
    })

    // Touch keyboards would cover the sheet, so search is focused on desktop only.
    if (window.matchMedia("(hover: hover)").matches) {
      picker.shadowRoot?.querySelector("input[type='search']")?.focus({preventScroll: true})
    }
  },

  close() {
    this.setTrigger(null)
    this.el.classList.add(...CLOSED_CLASSES)

    window.clearTimeout(this.closeTimer)
    this.closeTimer = window.setTimeout(() => {
      if (!this.isOpen()) {
        this.el.hidden = true
        this.clearSearch()
      }
    }, CLOSE_TRANSITION_MS)
  },

  // Each opening starts from the category grid, not the previous search.
  clearSearch() {
    const search = this.picker?.shadowRoot?.querySelector("input[type='search']")

    if (search?.value) {
      search.value = ""
      search.dispatchEvent(new Event("input", {bubbles: true}))
    }
  },

  async ensurePicker() {
    if (this.picker) {
      return this.picker
    }

    const {Picker} = await loadPicker()

    if (this.picker) {
      return this.picker
    }

    this.picker = new Picker({
      dataSource: this.el.dataset.dataSource,
      locale: this.el.dataset.locale,
      i18n: JSON.parse(this.el.dataset.i18n),
    })

    this.picker.addEventListener("emoji-click", event => {
      const emoji = event.detail?.unicode
      const trigger = this.trigger

      if (emoji && trigger) {
        this.choose(trigger, emoji)
      }

      // The composer's picker stays for the next emoji, unless it is a
      // sheet over the text.
      if (!insertTarget(trigger) || this.sheetMode()) {
        this.close()
      }
    })

    this.el.appendChild(this.picker)

    return this.picker
  },

  choose(trigger, emoji) {
    const field = insertTarget(trigger)

    if (field) {
      insertAtCaret(field, emoji)
    } else if (trigger.done) {
      trigger.done(emoji)
      trigger.done = null
    } else if ("groupReaction" in trigger.dataset) {
      this.pushEvent("toggle_group_reaction", {emoji})
    } else if (trigger.dataset.valueId) {
      this.pushEvent("toggle_reaction", {id: trigger.dataset.valueId, emoji})
    }
  },

  // A composer's picker stands over the whole composer, so it never covers
  // the text; any other one over its button.
  anchorRect(trigger) {
    const rect = trigger.getBoundingClientRect()
    const form = insertTarget(trigger)?.form

    if (!form) {
      return rect
    }

    const {top, bottom} = form.getBoundingClientRect()
    return {top, bottom, left: rect.left, right: rect.right}
  },

  // Bottom sheet on narrow screens; otherwise a popover under the button,
  // flipped above it when there is no room below. It stays inside <main>: the
  // page is a stacking context below the sidebar and the top bar, so outside
  // that box it would slide under them.
  position() {
    const sheet = this.sheetMode()

    this.el.classList.toggle("reaction-picker-sheet", sheet)

    if (sheet) {
      Object.assign(this.el.style, {left: "0px", right: "0px", top: "auto", bottom: "0px"})
      return
    }

    if (!this.trigger) {
      return
    }

    const rect = this.anchorRect(this.trigger)
    const width = this.el.offsetWidth
    const height = this.el.offsetHeight
    const page = this.el.closest("main").getBoundingClientRect()

    let top = rect.bottom + EDGE_GAP_PX

    if (top + height > page.bottom - EDGE_GAP_PX) {
      top = Math.max(page.top + EDGE_GAP_PX, rect.top - EDGE_GAP_PX - height)
    }

    const left = Math.max(
      page.left + EDGE_GAP_PX,
      Math.min(rect.right - width, page.right - width - EDGE_GAP_PX)
    )

    Object.assign(this.el.style, {
      left: `${left}px`,
      top: `${top}px`,
      right: "auto",
      bottom: "auto",
    })
  },
}
