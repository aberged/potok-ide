// One emoji picker per page for message reactions. Every value renders a
// `[data-reaction-trigger]` button; clicks are delegated here, so stream items
// never carry their own picker. The picker library is loaded on first use.
//
// Emoji data is self-hosted in priv/static/emoji (emoji-picker-element-data
// 1.8.0: en/emojibase as en.json, pl/cldr as pl.json), so no CDN is contacted.
// The picker caches it in IndexedDB.
//
// LiveView keeps this container's non-data attributes (`hidden`, class,
// style) as set here because the element is `phx-update="ignore"`.

let pickerModule = null
const loadPicker = () =>
  pickerModule || (pickerModule = import("emoji-picker-element"))

const SHEET_MAX_WIDTH_PX = 640
const VIEWPORT_GAP_PX = 8
const CLOSE_TRANSITION_MS = 150
const CLOSED_CLASSES = ["opacity-0", "translate-y-1"]

export const ReactionPicker = {
  mounted() {
    this.trigger = null
    this.picker = null
    this.closeTimer = null

    this.handleDocumentClick = event => {
      const trigger = event.target.closest("[data-reaction-trigger]")

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

    // The first load fetches and indexes the emoji data (about a second), so
    // it starts as soon as a pointer reaches a trigger instead of on click.
    this.handleWarmUp = event => {
      if (!this.picker && event.target.closest?.("[data-reaction-trigger]")) {
        this.ensurePicker().catch(() => {})
      }
    }

    this.handleKeydown = event => {
      if (event.key === "Escape" && this.isOpen()) {
        const trigger = this.trigger
        this.close()
        trigger?.focus()
      }
    }

    // An anchored popover would drift from its button while the feed
    // scrolls; the bottom sheet is not anchored, so it stays open.
    this.handleFeedScroll = () => {
      if (this.isOpen() && !this.sheetMode()) {
        this.close()
      }
    }

    this.handleResize = () => {
      if (this.isOpen()) {
        this.position()
      }
    }

    this.feed = document.getElementById("group-values-feed")

    document.addEventListener("click", this.handleDocumentClick)
    document.addEventListener("pointerover", this.handleWarmUp, {passive: true})
    document.addEventListener("pointerdown", this.handleWarmUp, {passive: true})
    document.addEventListener("keydown", this.handleKeydown)
    window.addEventListener("resize", this.handleResize)
    this.feed?.addEventListener("scroll", this.handleFeedScroll, {passive: true})
  },

  destroyed() {
    window.clearTimeout(this.closeTimer)
    document.removeEventListener("click", this.handleDocumentClick)
    document.removeEventListener("pointerover", this.handleWarmUp)
    document.removeEventListener("pointerdown", this.handleWarmUp)
    document.removeEventListener("keydown", this.handleKeydown)
    window.removeEventListener("resize", this.handleResize)
    this.feed?.removeEventListener("scroll", this.handleFeedScroll)
  },

  isOpen() {
    return this.trigger !== null
  },

  sheetMode() {
    return window.innerWidth < SHEET_MAX_WIDTH_PX
  },

  async open(trigger) {
    this.trigger = trigger

    let picker

    try {
      picker = await this.ensurePicker()
    } catch (error) {
      console.error("Emoji picker failed to load", error)
      this.trigger = null
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
    if (window.matchMedia("(pointer: fine)").matches) {
      picker.shadowRoot?.querySelector("input[type='search']")?.focus({preventScroll: true})
    }
  },

  close() {
    this.trigger = null
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
      const valueId = this.trigger?.dataset.valueId

      if (emoji && valueId) {
        this.pushEvent("toggle_reaction", {id: valueId, emoji})
      }

      this.close()
    })

    this.el.appendChild(this.picker)

    return this.picker
  },

  // Bottom sheet on narrow screens; otherwise a popover under the button,
  // flipped above it when there is no room below.
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

    const rect = this.trigger.getBoundingClientRect()
    const width = this.el.offsetWidth
    const height = this.el.offsetHeight
    const viewportWidth = document.documentElement.clientWidth
    const viewportHeight = window.innerHeight

    let top = rect.bottom + VIEWPORT_GAP_PX

    if (top + height > viewportHeight - VIEWPORT_GAP_PX) {
      top = Math.max(VIEWPORT_GAP_PX, rect.top - VIEWPORT_GAP_PX - height)
    }

    const left = Math.max(
      VIEWPORT_GAP_PX,
      Math.min(rect.right - width, viewportWidth - width - VIEWPORT_GAP_PX)
    )

    Object.assign(this.el.style, {
      left: `${left}px`,
      top: `${top}px`,
      right: "auto",
      bottom: "auto",
    })
  },
}
