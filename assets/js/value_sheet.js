// The menu of a value on touch screens, where its toolbar never shows: a long
// press on a value (`longpress.js`) opens it. The rows are the value's own
// action buttons, so what a member may do stays decided in one place
// (`Components.value_message/1`), and a row only clicks the button it stands for.

const ROW_CLASS =
  "flex w-full items-center gap-3 rounded-2xl px-3 py-2.5 text-left text-sm font-medium transition duration-150 hover:bg-base-200 active:scale-[0.99]"

const iconOf = button => {
  const icon = button.querySelector("[class*='hero-']")
  return [...(icon?.classList || [])].find(name => name.startsWith("hero-"))
}

const rowFor = button => {
  const row = document.createElement("button")
  row.type = "button"
  row.id = `value-sheet-row-${button.dataset.valueAction}`
  row.dataset.sheetTarget = button.id
  row.className = button.hasAttribute("data-confirm") ? `${ROW_CLASS} text-error` : ROW_CLASS

  const icon = document.createElement("span")
  icon.className = `${iconOf(button)} size-5 shrink-0 opacity-60`

  const label = document.createElement("span")
  label.textContent = button.getAttribute("aria-label")

  row.append(icon, label)
  return row
}

export const ValueSheet = {
  mounted() {
    this.value = null
    this.title = this.el.querySelector("[data-sheet-title]")
    this.time = this.el.querySelector("[data-sheet-time]")
    this.text = this.el.querySelector("[data-sheet-text]")
    this.reactions = this.el.querySelector("[data-sheet-reactions]")
    this.actions = this.el.querySelector("[data-sheet-actions]")
    this.copy = this.el.querySelector("[data-sheet-copy]")

    this.handlePress = event => this.open(event.target.closest("[data-creator-id]"))

    this.handleClick = event => {
      const reaction = event.target.closest("[data-sheet-reaction]")
      const target = event.target.closest("[data-sheet-target]")

      if (reaction) {
        this.pushEvent("toggle_reaction", {
          id: this.value.dataset.valueId,
          emoji: reaction.dataset.sheetReaction,
        })
        this.el.close()
      } else if (target) {
        // After this click is over: the emoji picker closes on any click
        // outside of it, and this one would count as such.
        const id = target.dataset.sheetTarget
        this.el.close()
        requestAnimationFrame(() => document.getElementById(id)?.click())
      } else if (event.target.closest("[data-sheet-copy]")) {
        void navigator.clipboard?.writeText(this.messageText())
        this.el.close()
      } else if (event.target.closest("[data-sheet-close]")) {
        this.el.close()
      }
    }

    window.addEventListener("potok:value-press", this.handlePress)
    this.el.addEventListener("click", this.handleClick)
  },

  destroyed() {
    window.removeEventListener("potok:value-press", this.handlePress)
    this.el.removeEventListener("click", this.handleClick)
  },

  messageText() {
    return this.value?.querySelector(".rich-content")?.innerText.trim() || ""
  },

  open(value) {
    if (!value) {
      return
    }

    this.value = value

    const buttons = [...value.querySelectorAll("[data-value-action]")]
    const reactTrigger = buttons.find(button => button.hasAttribute("data-reaction-trigger"))
    const text = this.messageText()

    this.title.textContent = value.dataset.author
    this.time.textContent = value.querySelector("time")?.title || ""
    this.text.textContent = text
    this.text.hidden = text === ""
    this.copy.hidden = text === ""

    this.reactions.hidden = !reactTrigger
    this.reactions.querySelector("[data-sheet-more]").dataset.sheetTarget = reactTrigger?.id || ""

    // The picker opens from the row of emoji, so it needs no row of its own.
    this.actions.replaceChildren(
      ...buttons.filter(button => button !== reactTrigger).map(rowFor)
    )

    if (!this.el.open) {
      this.el.showModal()
    }
  },
}
