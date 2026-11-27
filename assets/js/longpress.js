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

// A value in the chat, unless the press is on something of its own inside it.
const pressableValue = el => {
  const bubble = el?.closest?.("[data-value-press]")
  if (!bubble || el.closest("a, button, input, label, audio, video")) return null
  return bubble
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
  // On the web it is Web Share, and a closed share sheet comes back as a failure.
  share: url => void Share.share({ url }).catch(() => {}),
}

const showLinkActionSheet = (urlString, isExternal) => {
  const dialog = document.getElementById(ACTION_SHEET_ID)
  if (!dialog) return

  dialog.dataset.url = urlString
  dialog.querySelector(`#${ACTION_SHEET_ID}-url`).textContent = urlString
  dialog.querySelector('[data-lp-action="browser"]').hidden = !isExternal
  dialog.querySelector('[data-lp-action="share"]').hidden =
    !Capacitor.isNativePlatform() && !navigator.share

  if (!dialog.open) dialog.showModal()
}

// For a link that comes from an app in the page. The web gets the sheet, so the
// copying and sharing start with a click on the page itself: iOS Safari does not
// count the click in the frame, which came before a trip to the server.
export const shareLink = url => {
  if (Capacitor.isNativePlatform()) {
    linkActions.share(url)
  } else {
    showLinkActionSheet(url, false)
  }
}

// What a link from an app may open: a web address, mail or a phone number.
const APP_LINK_PROTOCOLS = new Set(["http:", "https:", "mailto:", "tel:"])
const APP_LINK_MAX_LENGTH = 4096

// A link that an app opens in a new tab (`open_link` from `potok_app_sdk.js`).
// The phone app's WebView opens no windows, and the frame's sandbox keeps it
// from leading the page, so on a phone the page opens it as it opens a link in
// the chat: Capacitor sends another host to the browser and keeps Potok's own
// in the app. Only right after a tap: the tap in the frame counts for the page
// too, so an app cannot send its reader away on its own.
export const openAppLink = href => {
  if (!Capacitor.isNativePlatform()) return
  if (navigator.userActivation && !navigator.userActivation.isActive) return
  if (typeof href !== "string" || href.length > APP_LINK_MAX_LENGTH) return

  const url = toAbsoluteUrl(href)
  if (!url || !APP_LINK_PROTOCOLS.has(url.protocol)) return

  window.location.assign(url.href)
}

const installLinkActionSheet = () => {
  // A button that shares the link of what it stands for, with no trip to the
  // server: iOS Safari only lets the click itself copy or share.
  document.addEventListener("click", event => {
    const button = event.target.closest?.("[data-share-link]")
    if (button) shareLink(button.dataset.shareLink)
  })

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
// browser's own right-click menu. A touch held on a chat value anywhere else
// is passed on as `potok:value-press` (`value_sheet.js`).
export const installLongPressLinkMenu = () => {
  let timer = null
  let startX = 0
  let startY = 0
  let activeLink = null
  let activeValue = null
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
    activeValue = null
  }

  const openMenu = link => {
    const href = link.getAttribute("href") || ""
    const url = toAbsoluteUrl(href)
    if (!url) return

    fired = true

    const isExternal = url.origin !== window.location.origin
    showLinkActionSheet(url.toString(), isExternal)
  }

  const pressValue = bubble => {
    fired = true
    bubble.dispatchEvent(new CustomEvent("potok:value-press", { bubbles: true }))
  }

  document.addEventListener("pointerdown", event => {
    fired = false
    pointerType = event.pointerType
    const link = isNavigableLink(event.target)
    const value = !link && isTouch() ? pressableValue(event.target) : null
    if (!link && !value) return

    activeLink = link
    activeValue = value
    startX = event.clientX
    startY = event.clientY

    timer = setTimeout(() => {
      if (activeLink) {
        openMenu(activeLink)
      } else if (activeValue) {
        pressValue(activeValue)
      }
    }, LONG_PRESS_MS)
  }, { passive: true })

  document.addEventListener("pointermove", event => {
    if (!activeLink && !activeValue) return
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
    if (!isTouch()) return

    const link = isNavigableLink(event.target)
    const value = link ? null : pressableValue(event.target)
    if (!link && !value) return

    event.preventDefault()

    if (!fired) {
      link ? openMenu(link) : pressValue(value)
    }

    clear()
  })
}