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

const ACTION_SHEET_ID = "lp-action-sheet"

const showLinkActionSheet = (urlString, isExternal) => {
  document.getElementById(ACTION_SHEET_ID)?.remove()

  const overlay = document.createElement("div")
  overlay.id = ACTION_SHEET_ID
  Object.assign(overlay.style, {
    position: "fixed",
    inset: "0",
    zIndex: "99999",
    display: "flex",
    flexDirection: "column",
    justifyContent: "flex-end",
  })

  const backdrop = document.createElement("div")
  Object.assign(backdrop.style, {
    position: "absolute",
    inset: "0",
    background: "rgba(0,0,0,0.45)",
  })

  const sheet = document.createElement("div")
  Object.assign(sheet.style, {
    position: "relative",
    background: "var(--color-base-100, #fff)",
    borderRadius: "1rem 1rem 0 0",
    padding: "1.25rem 1rem 2.5rem",
    display: "flex",
    flexDirection: "column",
    gap: "0.5rem",
    boxShadow: "0 -4px 32px rgba(0,0,0,0.18)",
  })

  const urlLabel = document.createElement("p")
  urlLabel.textContent = urlString
  Object.assign(urlLabel.style, {
    fontSize: "0.75rem",
    color: "var(--color-base-content, #333)",
    opacity: "0.5",
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
    marginBottom: "0.5rem",
    padding: "0 0.25rem",
  })
  sheet.appendChild(urlLabel)

  const close = () => overlay.remove()
  backdrop.addEventListener("click", close)

  const addBtn = (label, handler) => {
    const btn = document.createElement("button")
    btn.textContent = label
    Object.assign(btn.style, {
      padding: "0.85rem 1rem",
      borderRadius: "0.5rem",
      background: "var(--color-base-200, #f3f4f6)",
      border: "none",
      fontSize: "1rem",
      cursor: "pointer",
      textAlign: "left",
      color: "var(--color-base-content, #111)",
    })
    btn.addEventListener("click", () => {
      close()
      handler()
    })
    sheet.appendChild(btn)
  }

  addBtn("Open link", () => {
    window.location.assign(urlString)
  })

  if (isExternal) {
    addBtn("Open in browser", () => {
      void Browser.open({ url: urlString })
    })
  }

  addBtn("Copy link", () => {
    void navigator.clipboard?.writeText(urlString)
  })

  if (Capacitor.isNativePlatform()) {
    addBtn("Share", () => {
      void Share.share({ url: urlString })
    })
  }

  const cancelBtn = document.createElement("button")
  cancelBtn.textContent = "Cancel"
  Object.assign(cancelBtn.style, {
    padding: "0.85rem 1rem",
    borderRadius: "0.5rem",
    background: "transparent",
    border: "1.5px solid var(--color-base-300, #ddd)",
    fontSize: "1rem",
    cursor: "pointer",
    textAlign: "center",
    color: "var(--color-base-content, #111)",
    marginTop: "0.25rem",
  })
  cancelBtn.addEventListener("click", close)
  sheet.appendChild(cancelBtn)

  overlay.appendChild(backdrop)
  overlay.appendChild(sheet)
  document.body.appendChild(overlay)
}

export const installLongPressLinkMenu = () => {
  let timer = null
  let startX = 0
  let startY = 0
  let activeLink = null
  let fired = false

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

  document.addEventListener("contextmenu", event => {
    const link = isNavigableLink(event.target)
    if (!link) return
    event.preventDefault()
  })
}