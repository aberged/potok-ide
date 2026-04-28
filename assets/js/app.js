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
import {App} from "@capacitor/app"
import {Capacitor} from "@capacitor/core"
import {PushNotifications as NativePushNotifications} from "@capacitor/push-notifications"
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/potok_ide"
import {marked} from "marked"
import Quill from "quill"
import topbar from "../vendor/topbar"
import TurndownService from "turndown"
import { installLongPressLinkMenu } from "./longpress"

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

const flashDismissTimers = new WeakMap()

const clearFlashDismissTimer = element => {
  const timer = flashDismissTimers.get(element)

  if (timer) {
    window.clearTimeout(timer)
    flashDismissTimers.delete(element)
  }
}

const dismissFlashElement = element => {
  clearFlashDismissTimer(element)

  if (!element?.isConnected) {
    return
  }

  const liveSocketCommand = element.getAttribute("phx-click")
  const liveViewRoot = element.closest("[data-phx-session]")

  if (window.liveSocket && liveSocketCommand && liveViewRoot) {
    window.liveSocket.execJS(element, liveSocketCommand)
    return
  }

  element.setAttribute("hidden", "")
  element.remove()
}

const scheduleFlashDismiss = element => {
  if (!element || !element.hasAttribute("data-auto-dismiss-flash")) {
    return
  }

  clearFlashDismissTimer(element)

  const dismissAfterMs = Number.parseInt(element.dataset.dismissAfterMs || "3000", 10)

  if (Number.isNaN(dismissAfterMs) || dismissAfterMs <= 0) {
    return
  }

  const timer = window.setTimeout(() => {
    flashDismissTimers.delete(element)
    dismissFlashElement(element)
  }, dismissAfterMs)

  flashDismissTimers.set(element, timer)
}

const AutoDismissFlash = {
  mounted() {
    scheduleFlashDismiss(this.el)
  },

  updated() {
    scheduleFlashDismiss(this.el)
  },

  destroyed() {
    clearFlashDismissTimer(this.el)
  },
}

const POTOK_PUSH_TOKEN_KEY = "potok:push-token"
const POTOK_PUSH_CHANNEL_ID = "potok-default"
const nativePushListeners = new Set()

const NativePushManager = {
  initialized: false,

  isSupported() {
    return Capacitor.isNativePlatform() && ["android", "ios"].includes(Capacitor.getPlatform())
  },

  async initialize() {
    if (!this.isSupported() || this.initialized) {
      return this.isSupported()
    }

    this.initialized = true

    if (Capacitor.getPlatform() === "android") {
      try {
        await NativePushNotifications.createChannel({
          id: POTOK_PUSH_CHANNEL_ID,
          name: "Potok",
          description: "Activity and invitation updates",
          importance: 5,
          visibility: 1,
          vibration: true,
        })
      } catch (error) {
        console.warn("Unable to create Potok notification channel", error)
      }
    }

    await NativePushNotifications.addListener("registration", token => {
      nativePushListeners.forEach(listener => listener({type: "registration", token: token.value}))
    })

    await NativePushNotifications.addListener("registrationError", error => {
      nativePushListeners.forEach(listener => listener({type: "registrationError", error}))
    })

    await NativePushNotifications.addListener("pushNotificationReceived", notification => {
      nativePushListeners.forEach(listener => listener({type: "received", notification}))
    })

    await NativePushNotifications.addListener("pushNotificationActionPerformed", event => {
      nativePushListeners.forEach(listener => listener({type: "action", notification: event.notification}))
      openNotificationUrl(event.notification?.data?.url || event.notification?.link || "")
    })

    return true
  },

  subscribe(listener) {
    nativePushListeners.add(listener)
    return () => nativePushListeners.delete(listener)
  },

  async checkPermissions() {
    await this.initialize()
    return NativePushNotifications.checkPermissions()
  },

  async requestPermissions() {
    await this.initialize()
    return NativePushNotifications.requestPermissions()
  },

  async register() {
    await this.initialize()
    await NativePushNotifications.register()
  },

  async unregister() {
    await this.initialize()
    await NativePushNotifications.unregister()
  },
}

const PushNotifications = {
  mounted() {
    this.status = this.el.querySelector("[data-push-status]")
    this.enableButton = this.el.querySelector("[data-push-enable]")
    this.testButton = this.el.querySelector("[data-push-test]")
    this.disableButton = this.el.querySelector("[data-push-disable]")
    this.nativePlatform = Capacitor.getPlatform()
    this.vapidPublicKey = this.el.dataset.vapidPublicKey || ""
    this.subscribeUrl = this.el.dataset.subscribeUrl
    this.testUrl = this.el.dataset.testUrl
    this.csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || ""
    this.nativePendingMessage = null

    this.handleNativePushEvent = event => {
      switch (event.type) {
      case "registration":
        void this.handleNativeRegistration(event.token)
        break
      case "registrationError":
        this.handleNativeRegistrationError(event.error)
        break
      default:
        break
      }
    }

    this.unsubscribeNativePush = this.isNativePushEnvironment()
      ? NativePushManager.subscribe(this.handleNativePushEvent)
      : null

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
    this.unsubscribeNativePush?.()
  },

  async syncState(message) {
    if (this.isNativePushEnvironment()) {
      await this.syncNativeState(message)
      return
    }

    await this.syncWebState(message)
  },

  isNativePushEnvironment() {
    return NativePushManager.isSupported()
  },

  async syncNativeState(message) {
    try {
      const permissions = await NativePushManager.checkPermissions()

      if (permissions.receive === "denied") {
        this.renderDenied("Device notification permission is blocked.")
        return
      }

      const storedToken = window.localStorage.getItem(POTOK_PUSH_TOKEN_KEY)

      if (permissions.receive !== "granted") {
        this.renderIdle(message || "Push notifications are disabled for this device.")
        return
      }

      if (storedToken) {
        await this.saveNativeToken(storedToken)
      }

      this.nativePendingMessage = message || "Push notifications are enabled."
      this.setPendingState("Refreshing device notification token...")
      await NativePushManager.register()
    } catch (error) {
      console.error("Unable to inspect native push state", error)
      this.renderUnsupported(error.message || "Native push notifications are unavailable in this app session.")
    }
  },

  async syncWebState(message) {
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
    if (this.isNativePushEnvironment()) {
      await this.enableNativeNotifications()
      return
    }

    await this.enableWebNotifications()
  },

  async enableNativeNotifications() {
    this.setPendingState("Requesting device notification permission...")

    try {
      let permissions = await NativePushManager.checkPermissions()

      if (permissions.receive === "prompt" || permissions.receive === "prompt-with-rationale") {
        permissions = await NativePushManager.requestPermissions()
      }

      if (permissions.receive !== "granted") {
        if (permissions.receive === "denied") {
          this.renderDenied("Device notification permission is blocked.")
        } else {
          this.renderIdle("Notification permission was not granted.")
        }

        return
      }

      this.nativePendingMessage = "Push notifications are enabled."
      await NativePushManager.register()
    } catch (error) {
      console.error("Unable to enable native push notifications", error)
      this.renderIdle(error.message || "Unable to enable push notifications.")
    }
  },

  async enableWebNotifications() {
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
    if (this.isNativePushEnvironment()) {
      await this.disableNativeNotifications()
      return
    }

    await this.disableWebNotifications()
  },

  async disableNativeNotifications() {
    this.setPendingState("Removing device notification token...")

    try {
      const token = window.localStorage.getItem(POTOK_PUSH_TOKEN_KEY)

      if (token) {
        await this.request(this.subscribeUrl, {
          method: "DELETE",
          body: JSON.stringify({identifier: token}),
        })
      }

      await NativePushManager.unregister()
      window.localStorage.removeItem(POTOK_PUSH_TOKEN_KEY)
      await this.refreshPushSubscriptions()
      this.renderIdle("Push notifications are disabled for this device.")
    } catch (error) {
      console.error("Unable to disable native push notifications", error)
      this.renderEnabled(error.message || "Unable to remove the push subscription.")
    }
  },

  async disableWebNotifications() {
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

      await this.refreshPushSubscriptions()
      this.renderIdle("Push notifications are disabled for this browser.")
    } catch (error) {
      console.error("Unable to disable push notifications", error)
      this.renderEnabled(error.message || "Unable to remove the push subscription.")
    }
  },

  async sendTestNotification() {
    if (this.isNativePushEnvironment()) {
      await this.sendNativeTestNotification()
      return
    }

    await this.sendWebTestNotification()
  },

  async sendNativeTestNotification() {
    this.setPendingState("Sending test notification...")

    try {
      const token = window.localStorage.getItem(POTOK_PUSH_TOKEN_KEY)

      if (!token) {
        this.renderIdle("Enable notifications before sending a test push.")
        return
      }

      await this.saveNativeToken(token)
      await this.request(this.testUrl, {
        method: "POST",
        body: JSON.stringify({identifier: token}),
      })

      await this.refreshPushSubscriptions()
      this.renderEnabled("Test notification sent. Background the app if Android suppresses foreground banners.")
    } catch (error) {
      console.error("Unable to send native test push notification", error)
      await this.refreshPushSubscriptions()
      this.renderEnabled(error.message || "Unable to send the test notification.")
    }
  },

  async sendWebTestNotification() {
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

      await this.refreshPushSubscriptions()
      this.renderEnabled("Test notification sent. Minimize the app if the browser suppresses foreground notifications.")
    } catch (error) {
      console.error("Unable to send test push notification", error)
      await this.refreshPushSubscriptions()
      this.renderEnabled(error.message || "Unable to send the test notification.")
    }
  },

  async handleNativeRegistration(token) {
    try {
      await this.saveNativeToken(token)
      this.renderEnabled(this.nativePendingMessage || "Push notifications are enabled.")
    } catch (error) {
      console.error("Unable to store native push token", error)
      this.renderEnabled(error.message || "Push notifications are active on this device but Potok could not save the token.")
    } finally {
      this.nativePendingMessage = null
    }
  },

  handleNativeRegistrationError(error) {
    console.error("Native push registration failed", error)
    this.nativePendingMessage = null
    this.renderIdle(this.nativeRegistrationErrorMessage(error))
  },

  nativeRegistrationErrorMessage(error) {
    const rawError = error?.error || error?.message || ""

    if (rawError.includes("SERVICE_NOT_AVAILABLE")) {
      return "FCM is unavailable on this device right now. Ensure Google Play services are installed and updated, verify network access to Google services, then try again."
    }

    if (rawError.includes("MISSING_INSTANCEID_SERVICE")) {
      return "Google Play services are missing or outdated on this device, so push registration cannot complete."
    }

    return rawError || "Unable to register this device for push notifications."
  },

  async saveSubscription(subscription) {
    const response = await this.request(this.subscribeUrl, {
      method: "POST",
      body: JSON.stringify({subscription: subscription.toJSON()}),
    })

    await this.refreshPushSubscriptions()

    return response
  },

  async saveNativeToken(token) {
    window.localStorage.setItem(POTOK_PUSH_TOKEN_KEY, token)

    const response = await this.request(this.subscribeUrl, {
      method: "POST",
      body: JSON.stringify({
        subscription: {
          type: "fcm",
          token,
          platform: this.nativePlatform,
        },
      }),
    })

    await this.refreshPushSubscriptions()

    return response
  },

  async refreshPushSubscriptions() {
    if (typeof this.pushEvent !== "function") {
      return
    }

    try {
      await this.pushEvent("refresh_push_subscriptions", {})
    } catch (error) {
      console.error("Unable to refresh push subscriptions", error)
    }
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

const GroupDescriptionActions = {
  
  groupPanelDescription: new WeakSet(),
  newValueCallback: null,
  
  mounted() {
    this.abortController = new AbortController()
    console.debug("<#HOOK-LC#> Mounting GroupDescriptionActions hook for element", this.el.id)
    window.addEventListener( "phx:new_data_value", e => {
      if (this.newValueCallback) {
        this.newValueCallback(e)
      }
      console.debug("Received new_data_value event in GroupDescriptionActions hook", e)
    }, {signal: this.abortController.signal});
    this.exposePOTOK()
    this.reloadDescriptionScriptsIfNeeded()
  },

  updated() {
    console.debug("<#HOOK-LC#> Updating GroupDescriptionActions hook for element", this.el.id)
    this.abortController.abort()
    this.abortController = new AbortController()
    this.exposePOTOK()
    this.reloadDescriptionScriptsIfNeeded()
  },

  destroyed() {
    console.debug("<#HOOK-LC#> Destroying GroupDescriptionActions hook for element", this.el.id)
    this.abortController.abort()
    if (this.el.potok === this) {
      delete this.el.potok
    }
  },

  exposePOTOK() {
    this.el.potok = this;
    console.debug("<#HOOK#> Exposing Potok API for element", this.el.id)

    this.insertGroupValue = async (content, options = {}) => {
      const normalizedContent = typeof content === "string" ? content : ""
      const res = await this.pushEvent("create_data_value", {
        value: {
          content: "data:",
          data: normalizedContent,
          content_format: options.contentFormat || options.content_format || "markdown",
          is_data: true, //options.isData === true || options.is_data === true,
          parent_id: "" //options.parentId || options.parent_id || "",
        },
      })
      return res;
    }

    this.updateGroupDescription = async (description, options = {}) => {
      const normalizedDescription = typeof description === "string" ? description : ""
      const descriptionFormat =
        options.descriptionFormat ||
        options.description_format ||
        this.el.dataset.descriptionFormat ||
        "html"

      const res = await this.pushEvent("update_group_description", {
        description: normalizedDescription,
        description_format: descriptionFormat,
      })

      return res
    }

    this.getGroupDescription = async () => ({
      description: this.el.dataset.description || "",
      descriptionFormat: this.el.dataset.descriptionFormat || "html",
    })

    this.getGroupDataValues = async () => {
      const res = await this.pushEvent("list_group_data_values", {})
      return res
    }

    this.getCurrentProfile = async () => {
      const serializedCurrentProfile = this.el.dataset.currentProfile || ""

      if (!serializedCurrentProfile) {
        return null
      }

      try {
        return JSON.parse(serializedCurrentProfile)
      } catch (_error) {
        return null
      }
    }

    this.setNewValueCallback = (fn) => {
      if (typeof fn === "function") {
        this.newValueCallback = fn
      }
    }

  },

  async reloadDescriptionScriptsIfNeeded() {
    console.debug("<#HOOK#> reloadDescriptionScriptsIfNeeded for element", this.el)
    const contentElement = this.el;
    const descriptionSignature = `${this.el.dataset.descriptionFormat || ""}:${this.el.dataset.description || ""}`

    if (!contentElement) {
      this.lastDescriptionSignature = descriptionSignature
      console.debug("<#HOOK#> No content element found for description, skipping script reload")
      return
    }

    this.lastDescriptionSignature = descriptionSignature

    const scripts = Array.from(contentElement.querySelectorAll("script"))
    console.debug("<#HOOK#> Found description content scripts to reload:", scripts)

    for (const existingScript of scripts) {
      const replacementScript = document.createElement("script")

      for (const {name, value} of Array.from(existingScript.attributes)) {
        replacementScript.setAttribute(name, value)
      }

      if (
        existingScript.src &&
        !existingScript.hasAttribute("async") &&
        !existingScript.hasAttribute("defer") &&
        existingScript.type !== "module"
      ) {
        replacementScript.async = false
      }

      if (existingScript.src) {
        const loadPromise = new Promise(resolve => {
          replacementScript.addEventListener("load", resolve, {once: true})
          replacementScript.addEventListener("error", resolve, {once: true})
        })
        try {
          existingScript.replaceWith(replacementScript)
        } catch (error) {}
        await loadPromise
        continue
      }

      replacementScript.textContent = existingScript.textContent
      try {
        existingScript.replaceWith(replacementScript)
      } catch (error) {}
    }
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

marked.setOptions({
  breaks: true,
  gfm: true,
})

const markdownTurndown = new TurndownService({
  bulletListMarker: "-",
  codeBlockStyle: "fenced",
  headingStyle: "atx",
})
markdownTurndown.addRule('strikethroughS', {
  filter: ['s', 'del'],
  replacement: function (content) {
    return '~~' + content + '~~';
  }
});
markdownTurndown.addRule('underline', {
  filter: ['u'],
  replacement: function (content) {
    return '<u>' + content + '</u>'
  }
})

const normalizeMarkdown = markdown => markdown.replace(/\r\n/g, "\n").trimEnd()
const normalizeQuillHtml = html => html
  .replace(/<del>/g, "<s>")
  .replace(/<\/del>/g, "</s>")

const quillEditorIsBlank = quill => quill.getText().trim().length === 0

const renderMarkdownInQuill = (quill, markdown) => {
  const normalizedMarkdown = normalizeMarkdown(markdown || "")

  quill.setContents([])

  if (normalizedMarkdown === "") {
    quill.setText("")
    return
  }

  quill.clipboard.dangerouslyPasteHTML(normalizeQuillHtml(marked.parse(normalizedMarkdown)))
}

const serializeQuillToMarkdown = quill => {
  if (quillEditorIsBlank(quill)) {
    return ""
  }

  return normalizeMarkdown(
    markdownTurndown
      .turndown(quill.root.innerHTML)
      .replace(/\n{3,}/g, "\n\n")
  )
}

const MarkdownEditor = {
  mounted() {
    this.hiddenInput = this.el.querySelector("[data-markdown-target='input']")
    this.editorSurface = this.el.querySelector("[data-markdown-target='editor']")
    this.form = this.el.closest("form")

    if (!this.hiddenInput || !this.editorSurface) {
      return
    }

    this.quill = new Quill(this.editorSurface, {
      modules: {
        toolbar: [
          // [{header: [2, 3, false]}],
          ["bold", "italic", "blockquote", "underline", "strike"/*, "code-block", "link"*/],
          // [{list: "ordered"}, {list: "bullet"}],
          ["clean"],
        ],
      },
      placeholder: this.el.dataset.placeholder || "Write something...",
      theme: "snow",
    })

    renderMarkdownInQuill(this.quill, this.hiddenInput.value)
    this.lastSyncedValue = normalizeMarkdown(this.hiddenInput.value || "")

    this.handleTextChange = () => {
      const markdown = serializeQuillToMarkdown(this.quill)

      if (markdown === this.lastSyncedValue) {
        return
      }

      this.hiddenInput.value = markdown
      this.lastSyncedValue = markdown
      this.hiddenInput.dispatchEvent(new Event("input", {bubbles: true}))
      this.hiddenInput.dispatchEvent(new Event("change", {bubbles: true}))
    }

    this.handleSubmit = () => {
      const markdown = serializeQuillToMarkdown(this.quill)

      this.hiddenInput.value = markdown
      this.lastSyncedValue = markdown
    }

    this.quill.on("text-change", this.handleTextChange)
    this.form?.addEventListener("submit", this.handleSubmit)
  },

  updated() {
    if (!this.quill || !this.hiddenInput) {
      return
    }

    const serverValue = normalizeMarkdown(this.hiddenInput.value || "")

    if (serverValue === this.lastSyncedValue) {
      return
    }

    const selection = this.quill.getSelection()

    renderMarkdownInQuill(this.quill, serverValue)
    this.lastSyncedValue = serverValue

    if (selection) {
      this.quill.setSelection(selection.index, selection.length, "silent")
    }
  },

  destroyed() {
    this.form?.removeEventListener("submit", this.handleSubmit)
  },
}

const APP_LINK_HOST = "potok.rs"
const APP_LINK_PATH_PATTERN = /^\/accounts\/log-in\/([^/]+)\/?$/
const CAPACITOR_LAST_ROUTE_KEY = "potok:last-route"

const parseTokenFromLoginPath = pathname => {
  const match = pathname.match(APP_LINK_PATH_PATTERN)

  if (!match) {
    return null
  }

  const token = decodeURIComponent(match[1] || "").trim()

  return token || null
}

const parseCapacitorMagicLinkToken = urlString => {
  if (!urlString) {
    return null
  }

  try {
    const url = new URL(urlString)

    if (url.protocol === "potok:" && url.hostname === "login") {
      const token = url.pathname.replace(/^\/+/, "").trim()

      return token || null
    }

    if (url.protocol !== "https:") {
      return null
    }

    const allowedHosts = new Set([APP_LINK_HOST, window.location.hostname].filter(Boolean))

    if (!allowedHosts.has(url.hostname)) {
      return null
    }

    return parseTokenFromLoginPath(url.pathname)
  } catch (_error) {
    return null
  }
}

const openMagicLinkInAppSession = token => {
  const normalizedToken = typeof token === "string" ? token.trim() : ""

  if (!normalizedToken) {
    return
  }

  const targetUrl = new URL(`/accounts/log-in/${encodeURIComponent(normalizedToken)}`, window.location.origin)

  if (window.location.href === targetUrl.toString()) {
    window.location.reload()
    return
  }

  window.location.assign(targetUrl.toString())
}

const handleCapacitorMagicLink = urlString => {
  const token = parseCapacitorMagicLinkToken(urlString)

  if (!token) {
    return false
  }

  openMagicLinkInAppSession(token)
  return true
}

const openNotificationUrl = urlString => {
  const normalizedUrl = typeof urlString === "string" ? urlString.trim() : ""

  if (!normalizedUrl) {
    return false
  }

  if (handleCapacitorMagicLink(normalizedUrl)) {
    return true
  }

  try {
    const incomingUrl = new URL(normalizedUrl, window.location.origin)
    if (!["http:", "https:"].includes(incomingUrl.protocol)) {
      return false
    }

    const allowedHosts = new Set([APP_LINK_HOST, window.location.hostname].filter(Boolean))

    if (!allowedHosts.has(incomingUrl.hostname)) {
      return false
    }

    const targetUrl = new URL(
      `${incomingUrl.pathname}${incomingUrl.search}${incomingUrl.hash}`,
      window.location.origin
    )

    if (window.location.href === targetUrl.toString()) {
      window.location.reload()
      return true
    }

    window.location.assign(targetUrl.toString())
    return true
  } catch (_error) {
    return false
  }
}

const registerCapacitorMagicLinks = () => {
  if (!Capacitor.isNativePlatform()) {
    return
  }

  void App.addListener("appUrlOpen", ({url}) => {
    openNotificationUrl(url)
  })

  void App.getLaunchUrl()
    .then(result => {
      const openedLaunchUrl = openNotificationUrl(result?.url || "")

      if (!openedLaunchUrl) {
        restoreLastCapacitorRoute()
      }
    })
    .catch(() => {})
}

const persistCurrentCapacitorRoute = () => {
  if (!Capacitor.isNativePlatform()) {
    return
  }

  const route = `${window.location.pathname}${window.location.search}${window.location.hash}`

  try {
    window.localStorage.setItem(CAPACITOR_LAST_ROUTE_KEY, route)
  } catch (_error) {
    // Ignore storage failures (private mode/quota/etc.).
  }
}

const restoreLastCapacitorRoute = () => {
  if (!Capacitor.isNativePlatform()) {
    return false
  }

  try {
    const storedRoute = window.localStorage.getItem(CAPACITOR_LAST_ROUTE_KEY)

    if (!storedRoute) {
      return false
    }

    const targetUrl = new URL(storedRoute, window.location.origin)
    const currentRoute = `${window.location.pathname}${window.location.search}${window.location.hash}`
    const targetRoute = `${targetUrl.pathname}${targetUrl.search}${targetUrl.hash}`

    if (currentRoute === targetRoute) {
      return false
    }

    window.location.assign(targetUrl.toString())
    return true
  } catch (_error) {
    return false
  }
}

const registerCapacitorRoutePersistence = () => {
  if (!Capacitor.isNativePlatform()) {
    return
  }

  persistCurrentCapacitorRoute()

  window.addEventListener("phx:page-loading-stop", persistCurrentCapacitorRoute)
  window.addEventListener("popstate", persistCurrentCapacitorRoute)

  void App.addListener("appStateChange", ({isActive}) => {
    if (!isActive) {
      persistCurrentCapacitorRoute()
    }
  })
}

const registerCapacitorPushNotifications = () => {
  if (!NativePushManager.isSupported()) {
    return
  }

  void NativePushManager.initialize().catch(error => {
    console.error("Unable to initialize native push notifications", error)
  })
}

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {
    HeaderDrawer,
    DropdownMenu,
    AutoDismissFlash,
    PushNotifications,
    GroupDescriptionActions,
    MarkdownEditor,
    ...colocatedHooks,
  },
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
window.addEventListener("DOMContentLoaded", () => {
  document.querySelectorAll("[data-auto-dismiss-flash]").forEach(scheduleFlashDismiss)
})
window.addEventListener("phx:page-loading-stop", () => {
  document.querySelectorAll("[data-auto-dismiss-flash]").forEach(scheduleFlashDismiss)
})
window.addEventListener("load", () => {
  void registerServiceWorker()
})

window.addEventListener("phx:current_profile_updated", ({detail}) => {
  const brandTitle = document.getElementById("nav-brand-title")
  const brandAvatar = document.getElementById("nav-brand-profile-avatar")
  const brandInitials = document.getElementById("nav-brand-profile-initials")
  const brandLogo = document.getElementById("nav-brand-logo")
  const invitationsLink = document.getElementById("nav-invitations-link")
  const invitationsBadge = document.getElementById("nav-invitations-count-badge")
  const rootGroupBadge = document.getElementById("nav-root-group-unread-badge")
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

  if (invitationsLink) {
    invitationsLink.hidden = !hasProfile
  }

  if (brandAvatar) {
    brandAvatar.alt = detail.username || "Potok"
  }

  if (!hasProfile) {
    if (invitationsBadge) {
      invitationsBadge.hidden = true
      invitationsBadge.textContent = ""
    }

    if (rootGroupBadge) {
      rootGroupBadge.hidden = true
      rootGroupBadge.textContent = ""
    }

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
    if (brandAvatar && detail.id) {
      brandAvatar.src = `/avatar/profile/${detail.id}`
      brandAvatar.classList.remove("hidden")
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

window.addEventListener("phx:pending_invitations_count_updated", ({detail}) => {
  const invitationsBadge = document.getElementById("nav-invitations-count-badge")

  if (!invitationsBadge) {
    return
  }

  const count = Number(detail.count || 0)

  invitationsBadge.hidden = count <= 0
  invitationsBadge.textContent = count > 99 ? "99+" : String(count)
})

window.addEventListener("phx:pending_group_join_requests_count_updated", ({detail}) => {
  const requestsBadge = document.getElementById("nav-requests-count-badge")

  if (!requestsBadge) {
    return
  }

  const count = Number(detail.count || 0)

  requestsBadge.hidden = count <= 0
  requestsBadge.textContent = count > 999 ? "999+" : String(count)
})

window.addEventListener("phx:root_group_unread_count_updated", ({detail}) => {
  const rootGroupBadge = document.getElementById("nav-root-group-unread-badge")

  if (!rootGroupBadge) {
    return
  }

  const count = Number(detail.count || 0)

  rootGroupBadge.hidden = count <= 0
  rootGroupBadge.textContent = count > 999 ? "999+" : String(count)
})

registerCapacitorMagicLinks()
registerCapacitorPushNotifications()
registerCapacitorRoutePersistence()

window.addEventListener("DOMContentLoaded", () => {
  installLongPressLinkMenu()
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

