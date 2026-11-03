import { Browser } from "@capacitor/browser"
import { Share } from "@capacitor/share"
import { Capacitor } from "@capacitor/core"

const LONG_PRESS_MS = 500
const MOVE_TOLERANCE = 12

const isNavigableLink = el => {
  const link = el?.closest?.("a[href]")
  if (!link) return null
  if (link.hasAttribute("download")) return null
  const href = link.getAttribute("href") || ""
  if (!href || href.startsWith("#")) return null
  return link
}

const toAbsoluteUrl = href => {
  try {
    return new URL(href, window.location.origin)
  } catch (_e) {
    return null
  }
}

// The sheet is a modal <dialog> of the root layout, translated and styled
// there; this fills in the link and shows the actions that apply to it.
const ACTION_SHEET_ID = "lp-action-sheet"

const linkActions = {
  open: url => window.location.assign(url),
  browser: url => void Browser.open({ url }),
  copy: url => void navigator.clipboard?.writeText(url),
  share: url => void Share.share({ url }),
}

const showLinkActionSheet = (urlString, isExternal) => {
  const dialog = document.getElementById(ACTION_SHEET_ID)
  if (!dialog) return

  dialog.dataset.url = urlString
  dialog.querySelector(`#${ACTION_SHEET_ID}-url`).textContent = urlString
  dialog.querySelector('[data-lp-action="browser"]').hidden = !isExternal
  dialog.querySelector('[data-lp-action="share"]').hidden = !Capacitor.isNativePlatform()

  if (!dialog.open) dialog.showModal()
}

const installLinkActionSheet = () => {
  const dialog = document.getElementById(ACTION_SHEET_ID)
  if (!dialog) return

  dialog.addEventListener("click", event => {
    const action = event.target.closest("[data-lp-action]")?.dataset.lpAction

    if (action) {
      dialog.close()
      linkActions[action]?.(dialog.dataset.url)
    } else if (event.target.closest("[data-lp-close]")) {
      dialog.close()
    }
  })
}

// The menu opens after LONG_PRESS_MS of holding a link, or on touch when the
// system recognizes the long press: Android fires `contextmenu` then, at the
// phone's own touch-and-hold delay. That delay can be shorter than ours, and
// right after it the WebView starts dragging the link and cancels the
// pointer, which used to stop the timer before it fired, so no menu opened.
// Touch drags of links are blocked for the same reason. A mouse keeps the
// browser's own right-click menu.
export const installLongPressLinkMenu = () => {
  let timer = null
  let startX = 0
  let startY = 0
  let activeLink = null
  let fired = false
  let pointerType = null

  const isTouch = () => pointerType === "touch" || pointerType === "pen"

  installLinkActionSheet()

  const clear = () => {
    if (timer) {
      clearTimeout(timer)
      timer = null
    }
    activeLink = null
  }

  const openMenu = link => {
    const href = link.getAttribute("href") || ""
    const url = toAbsoluteUrl(href)
    if (!url) return

    fired = true

    const isExternal = url.origin !== window.location.origin
    showLinkActionSheet(url.toString(), isExternal)
  }

  document.addEventListener("pointerdown", event => {
    fired = false
    pointerType = event.pointerType
    const link = isNavigableLink(event.target)
    if (!link) return

    activeLink = link
    startX = event.clientX
    startY = event.clientY

    timer = setTimeout(() => {
      if (activeLink) {
        openMenu(activeLink)
      }
    }, LONG_PRESS_MS)
  }, { passive: true })

  document.addEventListener("pointermove", event => {
    if (!activeLink) return
    const dx = Math.abs(event.clientX - startX)
    const dy = Math.abs(event.clientY - startY)
    if (dx > MOVE_TOLERANCE || dy > MOVE_TOLERANCE) {
      clear()
    }
  }, { passive: true })

  document.addEventListener("pointerup", () => {
    clear()
  }, { passive: true })

  document.addEventListener("pointercancel", () => {
    clear()
  }, { passive: true })

  document.addEventListener("click", event => {
    if (fired) {
      event.preventDefault()
      event.stopPropagation()
      fired = false
    }
  }, true)

  document.addEventListener("dragstart", event => {
    if (isTouch() && isNavigableLink(event.target)) event.preventDefault()
  }, true)

  document.addEventListener("contextmenu", event => {
    const link = isNavigableLink(event.target)
    if (!link || !isTouch()) return
    event.preventDefault()
    if (!fired) openMenu(link)
    clear()
  })
}