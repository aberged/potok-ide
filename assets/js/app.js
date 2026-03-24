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
  hooks: {HeaderDrawer, DropdownMenu, ...colocatedHooks},
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

