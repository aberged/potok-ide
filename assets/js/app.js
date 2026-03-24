// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/potok_ide"
import topbar from "../vendor/topbar"

const HeaderDrawer = {
  mounted() {
    this.toggle = this.el.querySelector(".drawer-toggle")

    this.handleClick = event => {
      const trigger = event.target.closest("[data-nav-link], [data-drawer-close]")

      if (!trigger || !this.toggle) {
        return
      }

      this.toggle.checked = false
    }

    this.el.addEventListener("click", this.handleClick)
  },

  destroyed() {
    this.el.removeEventListener("click", this.handleClick)
  },
}

const DropdownMenu = {
  mounted() {
    this.handleClick = event => {
      const trigger = event.target.closest("[data-dropdown-close], [data-dropdown-content] a")

      if (!trigger || !this.el.contains(trigger)) {
        return
      }

      requestAnimationFrame(() => {
        if (document.activeElement && this.el.contains(document.activeElement)) {
          document.activeElement.blur()
        }
      })
    }

    this.el.addEventListener("click", this.handleClick)
  },

  destroyed() {
    this.el.removeEventListener("click", this.handleClick)
  },
}

const PushNotifications = {
  mounted() {
    this.status = this.el.querySelector("[data-push-status]")
    this.enableButton = this.el.querySelector("[data-push-enable]")
    this.testButton = this.el.querySelector("[data-push-test]")
    this.disableButton = this.el.querySelector("[data-push-disable]")
    this.vapidPublicKey = this.el.dataset.vapidPublicKey || ""
    this.subscribeUrl = this.el.dataset.subscribeUrl
    this.testUrl = this.el.dataset.testUrl
    this.csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || ""

    this.handleEnableClick = () => {
      void this.enableNotifications()
    }

    this.handleDisableClick = () => {
      void this.disableNotifications()
    }

    this.handleTestClick = () => {
      void this.sendTestNotification()
    }

    this.enableButton?.addEventListener("click", this.handleEnableClick)
    this.disableButton?.addEventListener("click", this.handleDisableClick)
    this.testButton?.addEventListener("click", this.handleTestClick)

    void this.syncState()
  },

  destroyed() {
    this.enableButton?.removeEventListener("click", this.handleEnableClick)
    this.disableButton?.removeEventListener("click", this.handleDisableClick)
    this.testButton?.removeEventListener("click", this.handleTestClick)
  },

  async syncState(message) {
    if (!window.isSecureContext) {
      this.renderUnsupported("Push notifications require HTTPS or localhost.")
      return
    }

    if (!("serviceWorker" in navigator) || !("PushManager" in window) || !("Notification" in window)) {
      this.renderUnsupported("This browser does not support Web Push notifications.")
      return
    }

    if (!this.vapidPublicKey) {
      this.renderUnsupported("Push notifications are not configured on this server yet.")
      return
    }

    if (Notification.permission === "denied") {
      this.renderDenied("Browser permission for notifications is blocked.")
      return
    }

    try {
      const registration = await navigator.serviceWorker.ready
      const subscription = await registration.pushManager.getSubscription()

      if (subscription) {
        await this.saveSubscription(subscription)
        this.renderEnabled(message || "Push notifications are enabled.")
        return
      }

      this.renderIdle(message || "Push notifications are disabled for this browser.")
    } catch (error) {
      console.error("Unable to inspect push notification state", error)
      this.renderUnsupported("Push notifications are unavailable in this browser session.")
    }
  },

  async enableNotifications() {
    this.setPendingState("Requesting notification permission...")

    try {
      const permission = await Notification.requestPermission()

      if (permission !== "granted") {
        if (permission === "denied") {
          this.renderDenied("Browser permission for notifications is blocked.")
        } else {
          this.renderIdle("Notification permission was not granted.")
        }

        return
      }

      const registration = await navigator.serviceWorker.ready
      let subscription = await registration.pushManager.getSubscription()

      if (!subscription) {
        subscription = await registration.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: this.urlBase64ToUint8Array(this.vapidPublicKey),
        })
      }

      await this.saveSubscription(subscription)
      this.renderEnabled("Push notifications are enabled.")
    } catch (error) {
      console.error("Unable to enable push notifications", error)
      this.renderIdle(error.message || "Unable to enable push notifications.")
    }
  },

  async disableNotifications() {
    this.setPendingState("Removing push subscription...")

    try {
      const registration = await navigator.serviceWorker.ready
      const subscription = await registration.pushManager.getSubscription()

      if (subscription) {
        await this.request(this.subscribeUrl, {
          method: "DELETE",
          body: JSON.stringify({endpoint: subscription.endpoint}),
        })

        await subscription.unsubscribe()
      }

      this.renderIdle("Push notifications are disabled for this browser.")
    } catch (error) {
      console.error("Unable to disable push notifications", error)
      this.renderEnabled(error.message || "Unable to remove the push subscription.")
    }
  },

  async sendTestNotification() {
    this.setPendingState("Sending test notification...")

    try {
      const registration = await navigator.serviceWorker.ready
      const subscription = await registration.pushManager.getSubscription()

      if (!subscription) {
        this.renderIdle("Enable notifications before sending a test push.")
        return
      }

      await this.saveSubscription(subscription)
      await this.request(this.testUrl, {
        method: "POST",
        body: JSON.stringify({endpoint: subscription.endpoint}),
      })

      this.renderEnabled("Test notification sent. Minimize the app if the browser suppresses foreground notifications.")
    } catch (error) {
      console.error("Unable to send test push notification", error)
      this.renderEnabled(error.message || "Unable to send the test notification.")
    }
  },

  async saveSubscription(subscription) {
    return this.request(this.subscribeUrl, {
      method: "POST",
      body: JSON.stringify({subscription: subscription.toJSON()}),
    })
  },

  async request(url, options) {
    const response = await fetch(url, {
      credentials: "same-origin",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/json",
        "x-csrf-token": this.csrfToken,
      },
      ...options,
    })

    const payload = await response.json().catch(() => ({}))

    if (!response.ok) {
      throw new Error(payload.error || "Push notification request failed.")
    }

    return payload
  },

  setPendingState(message) {
    this.setStatus(message, "pending")
    this.setButtons({enable: true, test: true, disable: true})
  },

  renderEnabled(message) {
    this.setStatus(message, "success")
    this.setButtons({enable: true, test: false, disable: false})
  },

  renderIdle(message) {
    this.setStatus(message, "idle")
    this.setButtons({enable: false, test: true, disable: true})
  },

  renderDenied(message) {
    this.setStatus(message, "danger")
    this.setButtons({enable: true, test: true, disable: true})
  },

  renderUnsupported(message) {
    this.setStatus(message, "danger")
    this.setButtons({enable: true, test: true, disable: true})
  },

  setButtons(hidden) {
    if (this.enableButton) {
      this.enableButton.hidden = hidden.enable
      this.enableButton.disabled = false
    }

    if (this.testButton) {
      this.testButton.hidden = hidden.test
      this.testButton.disabled = false
    }

    if (this.disableButton) {
      this.disableButton.hidden = hidden.disable
      this.disableButton.disabled = false
    }
  },

  setStatus(message, tone) {
    if (!this.status) {
      return
    }

    this.status.textContent = message
    this.status.className = [
      "rounded-2xl border px-4 py-3 text-sm",
      tone === "success" && "border-emerald-300 bg-emerald-50 text-emerald-900",
      tone === "pending" && "border-amber-300 bg-amber-50 text-amber-900",
      tone === "danger" && "border-rose-300 bg-rose-50 text-rose-900",
      tone === "idle" && "border-base-300 bg-base-200/70 text-base-content/70",
    ].filter(Boolean).join(" ")
  },

  urlBase64ToUint8Array(base64String) {
    const padding = "=".repeat((4 - (base64String.length % 4)) % 4)
    const base64 = `${base64String}${padding}`.replace(/-/g, "+").replace(/_/g, "/")
    const rawData = atob(base64)

    return Uint8Array.from(rawData, char => char.charCodeAt(0))
  },
}

const registerServiceWorker = async () => {
  if (!("serviceWorker" in navigator)) {
    return
  }

  try {
    const registration = await navigator.serviceWorker.register("/sw.js", {scope: "/"})

    if (registration.waiting) {
      registration.waiting.postMessage({type: "SKIP_WAITING"})
    }

    registration.addEventListener("updatefound", () => {
      const installing = registration.installing

      if (!installing) {
        return
      }

      installing.addEventListener("statechange", () => {
        if (installing.state === "installed" && navigator.serviceWorker.controller) {
          window.location.reload()
        }
      })
    })

    let refreshing = false

    navigator.serviceWorker.addEventListener("controllerchange", () => {
      if (refreshing) {
        return
      }

      refreshing = true
      window.location.reload()
    })
  } catch (error) {
    console.error("Service worker registration failed", error)
  }
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {HeaderDrawer, DropdownMenu, PushNotifications, ...colocatedHooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

const updateDrawerActiveLinks = () => {
  const pathname = window.location.pathname

  document.querySelectorAll("[data-nav-link]").forEach(link => {
    const target = link.dataset.navTarget || ""
    const match = link.dataset.navMatch || "exact"
    const isActive = match === "prefix"
      ? pathname === target || pathname.startsWith(`${target}/`)
      : pathname === target

    link.dataset.active = isActive ? "true" : "false"

    link.classList.toggle("bg-base-content", isActive)
    link.classList.toggle("text-base-100", isActive)
    link.classList.toggle("border-base-content", isActive)
    link.classList.toggle("shadow-sm", isActive)

    link.classList.toggle("bg-base-200", !isActive && !link.dataset.navPrimary)
    link.classList.toggle("text-base-content/70", !isActive && !link.dataset.navPrimary)

    if (isActive) {
      link.setAttribute("aria-current", "page")
    } else {
      link.removeAttribute("aria-current")
    }
  })
}

window.addEventListener("DOMContentLoaded", updateDrawerActiveLinks)
window.addEventListener("phx:page-loading-stop", updateDrawerActiveLinks)
window.addEventListener("load", () => {
  void registerServiceWorker()
})

window.addEventListener("phx:current_profile_updated", ({detail}) => {
  const brandTitle = document.getElementById("nav-brand-title")
  const brandAvatar = document.getElementById("nav-brand-profile-avatar")
  const brandInitials = document.getElementById("nav-brand-profile-initials")
  const brandLogo = document.getElementById("nav-brand-logo")
  const selectedProfileCard = document.getElementById("nav-selected-profile-card")
  const selectedProfileName = document.getElementById("nav-selected-profile-name")
  const defaultTitle = brandTitle?.dataset.defaultTitle || ""
  const hasProfile = Boolean(detail.username)
  const initials = (detail.username || "")
    .split(/[\s_-]+/)
    .filter(Boolean)
    .slice(0, 2)
    .map(part => part[0]?.toUpperCase() || "")
    .join("") || "?"

  if (brandTitle) {
    brandTitle.textContent = detail.username || defaultTitle
  }

  if (selectedProfileName) {
    selectedProfileName.textContent = detail.username || ""
  }

  if (selectedProfileCard) {
    selectedProfileCard.hidden = !hasProfile
  }

  if (brandAvatar) {
    brandAvatar.alt = detail.username || "Potok"
  }

  if (!hasProfile) {
    if (brandAvatar) {
      brandAvatar.classList.add("hidden")
    }

    if (brandInitials) {
      brandInitials.classList.add("hidden")
    }

    if (brandLogo) {
      brandLogo.classList.remove("hidden")
    }

    return
  }

  if (detail.profile_picture_url) {
    if (brandAvatar) {
      brandAvatar.src = detail.profile_picture_url
      brandAvatar.classList.remove("hidden")
    }

    if (brandLogo) {
      brandLogo.classList.add("hidden")
    }

    if (brandInitials) {
      brandInitials.classList.add("hidden")
    }
  } else {
    if (brandAvatar) {
      brandAvatar.classList.add("hidden")
    }

    if (brandInitials) {
      brandInitials.textContent = initials
      brandInitials.classList.remove("hidden")
    }

    if (brandLogo) {
      brandLogo.classList.add("hidden")
    }
  }
})

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", _e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}

