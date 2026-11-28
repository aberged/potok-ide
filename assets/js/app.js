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
import {Capacitor, SystemBars, SystemBarsStyle} from "@capacitor/core"
import {PushNotifications as NativePushNotifications} from "@capacitor/push-notifications"
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/potok_ide"
import topbar from "../vendor/topbar"
import { installDomainMap } from "./domain_map"
import { installGalleries } from "./gallery"
import { installHelpAccess } from "./help_access"
import { DescriptionArchive } from "./description_archive"
import { ComposerDraft, DraftMark, clearAllDrafts } from "./drafts"
import { KeyboardMedia } from "./keyboard_media"
import { LocationPicker } from "./location_picker"
import { ProcessCanvas } from "./process_canvas"
import { RootMap } from "./root_map"
import { installLongPressLinkMenu, openAppLink, shareLink } from "./longpress"
import { installPageLoader } from "./page_loader"
import { installNotificationTray } from "./notification_tray"
import { ReactionPicker } from "./reaction_picker"
import {
  ShareComposer,
  SharePreview,
  onNativeShareReceived,
  openPendingNativeShare,
} from "./share_inbox"
import { Uploaders } from "./uploaders"
import { installUploadStripping, stripForUpload } from "./upload_stripping"
import { ValueSheet } from "./value_sheet"

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

// The menu is open while it holds the focus. A choice closes it, and so does
// any tap outside the card, its button included (daisyUI lets taps go through
// the button while the menu is open, so that a browser takes the focus away).
// WebKit on an iPhone does not take the focus away on a tap on something that
// cannot take it, so without this the menu stayed open until something was
// chosen.
const DropdownMenu = {
  mounted() {
    this.button = this.el.querySelector(":scope > button")
    this.content = this.el.querySelector("[data-dropdown-content]")

    const close = () => {
      if (document.activeElement && this.el.contains(document.activeElement)) {
        document.activeElement.blur()
      }
    }

    this.handleClick = event => {
      const trigger = event.target.closest("[data-dropdown-close], [data-dropdown-content] a")

      if (this.closedByTap) {
        // The tap that closed the menu ends in a click on its button, which
        // would open it again (WebKit focuses the button on that click).
        this.closedByTap = false
        requestAnimationFrame(close)
      } else if (trigger && this.el.contains(trigger)) {
        requestAnimationFrame(close)
      } else if (this.button?.contains(event.target) && !this.el.contains(document.activeElement)) {
        // Safari may leave a tapped button without the focus.
        this.button.focus()
      }
    }

    this.handlePointerDown = event => {
      const open = document.activeElement && this.el.contains(document.activeElement)
      this.closedByTap = false

      if (open && !this.content?.contains(event.target)) {
        close()
        this.closedByTap = this.el.contains(event.target)
      }
    }

    this.el.addEventListener("click", this.handleClick)
    document.addEventListener("pointerdown", this.handlePointerDown, true)
  },

  destroyed() {
    this.el.removeEventListener("click", this.handleClick)
    document.removeEventListener("pointerdown", this.handlePointerDown, true)
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

const syncPasswordToggleButton = button => {
  const field = button.closest("[data-password-field]")
  const input = field?.querySelector("input")

  if (!input) {
    return
  }

  const isVisible = input.type === "text"
  const showIcon = button.querySelector("[data-password-show-icon]")
  const hideIcon = button.querySelector("[data-password-hide-icon]")

  button.setAttribute("aria-pressed", isVisible ? "true" : "false")
  button.setAttribute("aria-label", isVisible ? button.dataset.hideLabel : button.dataset.showLabel)

  showIcon?.classList.toggle("hidden", isVisible)
  hideIcon?.classList.toggle("hidden", !isVisible)
}

const syncPasswordToggleButtons = root => {
  root.querySelectorAll("[data-password-toggle]").forEach(syncPasswordToggleButton)
}

const installPasswordToggleButtons = () => {
  document.addEventListener("click", event => {
    const button = event.target.closest("[data-password-toggle]")

    if (!button) {
      return
    }

    const field = button.closest("[data-password-field]")
    const input = field?.querySelector("input")

    if (!input || !["password", "text"].includes(input.type)) {
      return
    }

    event.preventDefault()
    input.type = input.type === "password" ? "text" : "password"
    syncPasswordToggleButton(button)
  })

  syncPasswordToggleButtons(document)
  window.addEventListener("phx:page-loading-stop", () => syncPasswordToggleButtons(document))
}

const POTOK_PUSH_TOKEN_KEY = "potok:push-token"
// What this device saved last (an FCM token or a web push endpoint): the
// log-out sends it, so the account stops pushing to this device.
const POTOK_PUSH_DEVICE_KEY = "potok:push-device"
// Set by "Disable" in the settings: nothing turns the app's notifications
// back on by itself while it is there.
const POTOK_PUSH_OFF_KEY = "potok:push-off"
// The app has asked for the permission by itself once.
const POTOK_PUSH_ASKED_KEY = "potok:push-asked"
const POTOK_PUSH_CHANNEL_ID = "potok-default"

const readPushStore = key => {
  try {
    return window.localStorage.getItem(key)
  } catch (_error) {
    return null
  }
}

const writePushStore = (key, value) => {
  try {
    if (value === null) {
      window.localStorage.removeItem(key)
    } else {
      window.localStorage.setItem(key, value)
    }
  } catch (_error) {
    // Without storage the device is saved again on the next start.
  }
}

const signedIn = () => document.body.dataset.signedIn === "true"

const pushChannels = () => {
  try {
    const content = document.querySelector("meta[name='potok-push-channels']")?.getAttribute("content")
    const channels = content ? JSON.parse(content) : []
    if (Array.isArray(channels) && channels.length > 0) return channels
  } catch (_error) {
    // The default channel below.
  }

  return [{id: POTOK_PUSH_CHANNEL_ID, name: "Potok", importance: 4}]
}

const POTOK_IOS_PUSH_REGISTRATION_EVENT = "potokNativePushRegistration"
const POTOK_IOS_PUSH_REGISTRATION_ERROR_EVENT = "potokNativePushRegistrationError"
const nativePushListeners = new Set()

const NativePushManager = {
  ready: null,

  isSupported() {
    return Capacitor.isNativePlatform() && ["android", "ios"].includes(Capacitor.getPlatform())
  },

  // Every caller waits for the same setup, so nothing registers before the
  // listeners that take the token are in place.
  initialize() {
    if (!this.isSupported()) {
      return Promise.resolve(false)
    }

    this.ready ||= this.setUp()
    return this.ready
  },

  async setUp() {
    keepOldPushSwitch()

    // One channel per kind of push, named in the page's language
    // (`PotokIdeWeb.PushChannels`): creating an existing channel renames it.
    if (Capacitor.getPlatform() === "android") {
      for (const channel of pushChannels()) {
        try {
          await NativePushNotifications.createChannel({...channel, visibility: 1, vibration: true})
        } catch (error) {
          console.warn("Unable to create Potok notification channel", channel.id, error)
        }
      }
    }

    if (Capacitor.getPlatform() === "ios") {
      this.handleIosPushRegistration = event => {
        if (!event?.token) {
          return
        }

        nativePushListeners.forEach(listener =>
          listener({type: "registration", token: event.token, provider: event.provider || "fcm"}))
      }

      this.handleIosPushRegistrationError = event => {
        nativePushListeners.forEach(listener =>
          listener({
            type: "registrationError",
            error: {
              error: event?.message || "Unable to register this iOS device for Firebase push notifications.",
            },
            provider: event?.provider || "fcm",
          }))
      }

      window.addEventListener(POTOK_IOS_PUSH_REGISTRATION_EVENT, this.handleIosPushRegistration)
      window.addEventListener(POTOK_IOS_PUSH_REGISTRATION_ERROR_EVENT, this.handleIosPushRegistrationError)
    }

    await NativePushNotifications.addListener("registration", token => {
      if (Capacitor.getPlatform() === "ios") {
        return
      }

      nativePushListeners.forEach(listener =>
        listener({type: "registration", token: token.value, provider: "fcm"}))
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

    // Wherever the token comes from, the signed-in account gets it, unless
    // notifications were turned off in the settings or not allowed: Firebase
    // also hands over a new token by itself, before anyone was asked.
    nativePushListeners.add(async event => {
      if (event.type !== "registration" || event.provider !== "fcm") return
      if (!signedIn() || readPushStore(POTOK_PUSH_OFF_KEY)) return

      try {
        const {receive} = await NativePushNotifications.checkPermissions()
        if (receive === "granted") await saveNativeDeviceToken(event.token)
      } catch (error) {
        console.warn("Unable to save this device for notifications", error)
      }
    })

    // iOS lists and removes delivered notifications only after `register()`
    // in this session, which clearing a read conversation needs. It also
    // brings the token, saved above.
    if (Capacitor.getPlatform() === "ios") {
      try {
        const status = await NativePushNotifications.checkPermissions()
        if (status.receive === "granted") await NativePushNotifications.register()
      } catch (error) {
        console.warn("Unable to register for Potok notifications", error)
      }
    }

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
    this.i18n = JSON.parse(this.el.dataset.i18n)
    this.csrfToken = document.querySelector("meta[name='csrf-token']")?.getAttribute("content") || ""
    this.nativePendingMessage = null

    this.handleNativePushEvent = event => {
      switch (event.type) {
      case "registration":
        // iOS registers on every start, also while turned off here.
        if (readPushStore(POTOK_PUSH_OFF_KEY)) {
          break
        }

        if (this.nativePlatform === "ios" && event.provider !== "fcm") {
          this.setPendingState(this.i18n.finishingIphone)
          break
        }

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
        this.renderDenied(this.i18n.devicePermissionBlocked)
        return
      }

      const storedToken = window.localStorage.getItem(POTOK_PUSH_TOKEN_KEY)

      // Turned off here: the device's permission stays, the subscription does not.
      if (permissions.receive !== "granted" || readPushStore(POTOK_PUSH_OFF_KEY)) {
        this.renderIdle(message || this.i18n.disabledForDevice)
        return
      }

      if (storedToken) {
        await this.saveNativeToken(storedToken)
      }

      this.nativePendingMessage = message || this.i18n.enabled
      this.setPendingState(this.i18n.refreshingToken)
      await NativePushManager.register()
    } catch (error) {
      console.error("Unable to inspect native push state", error)
      this.renderUnsupported(error.message || this.i18n.nativeUnavailable)
    }
  },

  async syncWebState(message) {
    if (!window.isSecureContext) {
      this.renderUnsupported(this.i18n.requiresHttps)
      return
    }

    if (!("serviceWorker" in navigator) || !("PushManager" in window) || !("Notification" in window)) {
      this.renderUnsupported(this.i18n.webPushUnsupported)
      return
    }

    if (!this.vapidPublicKey) {
      this.renderUnsupported(this.i18n.notConfigured)
      return
    }

    if (Notification.permission === "denied") {
      this.renderDenied(this.i18n.browserPermissionBlocked)
      return
    }

    try {
      const registration = await navigator.serviceWorker.ready
      const subscription = await registration.pushManager.getSubscription()

      if (subscription) {
        await this.saveSubscription(subscription)
        this.renderEnabled(message || this.i18n.enabled)
        return
      }

      this.renderIdle(message || this.i18n.disabledForBrowser)
    } catch (error) {
      console.error("Unable to inspect push notification state", error)
      this.renderUnsupported(this.i18n.browserUnavailable)
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
    this.setPendingState(this.i18n.requestingDevicePermission)
    writePushStore(POTOK_PUSH_OFF_KEY, null)

    try {
      let permissions = await NativePushManager.checkPermissions()

      if (permissions.receive === "prompt" || permissions.receive === "prompt-with-rationale") {
        permissions = await NativePushManager.requestPermissions()
      }

      if (permissions.receive !== "granted") {
        if (permissions.receive === "denied") {
          this.renderDenied(this.i18n.devicePermissionBlocked)
        } else {
          this.renderIdle(this.i18n.permissionNotGranted)
        }

        return
      }

      this.nativePendingMessage = this.i18n.enabled
      await NativePushManager.register()
    } catch (error) {
      console.error("Unable to enable native push notifications", error)
      this.renderIdle(error.message || this.i18n.enableFailed)
    }
  },

  async enableWebNotifications() {
    this.setPendingState(this.i18n.requestingPermission)

    try {
      const permission = await Notification.requestPermission()

      if (permission !== "granted") {
        if (permission === "denied") {
          this.renderDenied(this.i18n.browserPermissionBlocked)
        } else {
          this.renderIdle(this.i18n.permissionNotGranted)
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
      this.renderEnabled(this.i18n.enabled)
    } catch (error) {
      console.error("Unable to enable push notifications", error)
      this.renderIdle(error.message || this.i18n.enableFailed)
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
    this.setPendingState(this.i18n.removingToken)

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
      writePushStore(POTOK_PUSH_OFF_KEY, "1")
      forgetPushDevice()
      await this.refreshPushSubscriptions()
      this.renderIdle(this.i18n.disabledForDevice)
    } catch (error) {
      console.error("Unable to disable native push notifications", error)
      this.renderEnabled(error.message || this.i18n.removeFailed)
    }
  },

  async disableWebNotifications() {
    this.setPendingState(this.i18n.removingSubscription)

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

      forgetPushDevice()
      await this.refreshPushSubscriptions()
      this.renderIdle(this.i18n.disabledForBrowser)
    } catch (error) {
      console.error("Unable to disable push notifications", error)
      this.renderEnabled(error.message || this.i18n.removeFailed)
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
    this.setPendingState(this.i18n.sendingTest)

    try {
      const token = window.localStorage.getItem(POTOK_PUSH_TOKEN_KEY)

      if (!token) {
        this.renderIdle(this.i18n.enableBeforeTest)
        return
      }

      await this.saveNativeToken(token)
      await this.request(this.testUrl, {
        method: "POST",
        body: JSON.stringify({identifier: token}),
      })

      await this.refreshPushSubscriptions()
      this.renderEnabled(this.i18n.testSentNative)
    } catch (error) {
      console.error("Unable to send native test push notification", error)
      await this.refreshPushSubscriptions()
      this.renderEnabled(error.message || this.i18n.testFailed)
    }
  },

  async sendWebTestNotification() {
    this.setPendingState(this.i18n.sendingTest)

    try {
      const registration = await navigator.serviceWorker.ready
      const subscription = await registration.pushManager.getSubscription()

      if (!subscription) {
        this.renderIdle(this.i18n.enableBeforeTest)
        return
      }

      await this.saveSubscription(subscription)
      await this.request(this.testUrl, {
        method: "POST",
        body: JSON.stringify({endpoint: subscription.endpoint}),
      })

      await this.refreshPushSubscriptions()
      this.renderEnabled(this.i18n.testSentWeb)
    } catch (error) {
      console.error("Unable to send test push notification", error)
      await this.refreshPushSubscriptions()
      this.renderEnabled(error.message || this.i18n.testFailed)
    }
  },

  async handleNativeRegistration(token) {
    try {
      // A token Firebase hands over by itself, while notifications are not allowed.
      const {receive} = await NativePushManager.checkPermissions()
      if (receive !== "granted") return

      await this.saveNativeToken(token)
      this.renderEnabled(this.nativePendingMessage || this.i18n.enabled)
    } catch (error) {
      console.error("Unable to store native push token", error)
      this.renderEnabled(error.message || this.i18n.saveFailed)
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
      return this.i18n.fcmUnavailable
    }

    if (rawError.includes("MISSING_INSTANCEID_SERVICE")) {
      return this.i18n.playServicesMissing
    }

    return rawError || this.i18n.registerFailed
  },

  async saveSubscription(subscription) {
    const response = await saveWebPushSubscription(subscription)
    await this.refreshPushSubscriptions()

    return response
  },

  async saveNativeToken(token) {
    const response = await saveNativeDeviceToken(token)
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
      throw new Error(payload.error || this.i18n.requestFailed)
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

// Bridge between a sandboxed app iframe (see `Components.app_frame/1` and
// `potok_app_sdk.js`) and the LiveView. The iframe has an opaque origin, so
// messages are matched by `event.source` and every method is checked again
// on the server (`GroupLive.Show.AppApi`).
const APP_FRAME_METHODS = new Set([
  "insert_value",
  "list_values",
  "update_description",
  "get_description",
  "current_profile",
  "list_subgroups",
  "get_subgroup",
  "search_subgroups",
  "open_group",
  "open_map",
  "get_group",
  "list_children",
  "get_child",
  "create_child",
  "create_children",
  "update_child",
  "withdraw_child",
  "move_child",
  "apply_access_to_children",
  "preview_description",
  "list_templates",
  "render_template",
  "toggle_group_reaction",
  "share_group",
  "pick_emoji",
  "linked_group",
  "link_group",
  "open_login",
  "list_polls",
  "get_poll",
  "open_poll",
  "open_poll_form",
  "get_config",
  "save_config",
  "update_value",
  "delete_value",
  "delete_values",
  "summarize_values",
  "aggregate_values",
  "grade_value",
  "list_roles",
  "set_notifications",
  "ensure_file_groups",
  "file_url",
  "upload_file",
  "upload_image",
  "upload_media",
  "map_config",
  "list_places",
  "list_places_at",
  "create_place",
  "show_group",
  "place_shapes",
  "list_processes",
  "complete_task",
  "retry_process",
  "cancel_process",
  "list_waiting",
  "open_process_form",
  "list_startable",
  "open_process_start",
  "list_personal",
  "get_personal",
  "set_personal",
  "delete_personal",
])

// The app's personal memory (`PotokIde.Social.AppProfileStore`). A guest has
// no profile, so a guest's frame keeps it in this browser, in one key of the
// page's storage per app (`data-personal-key`), under the server's limits.
const APP_FRAME_GUEST_LOCAL = new Set(["list_personal", "get_personal", "set_personal", "delete_personal"])
const PERSONAL_MAX_KEYS = 100
const PERSONAL_MAX_BYTES = 16384
const PERSONAL_KEY = /^[A-Za-z0-9_.:-]{1,64}$/

// Calls that carry a file of the frame's, sent through the page's upload.
const APP_FRAME_UPLOADS = new Set(["upload_file", "upload_image", "upload_media"])

// A link into an app: `?at=<group id>` on the group's page. It stays in the
// browser, as the page has nothing to do with it and an app moves on it often.
const APP_LINK_PARAM = "at"

const positiveId = value => (Number.isSafeInteger(value) && value > 0 ? value : null)

const linkedGroupId = () =>
  positiveId(Number(new URLSearchParams(window.location.search).get(APP_LINK_PARAM)))

// The entry of the history an app is on: a number its pushed entries carry
// (`potokEntry`), so the app can find its place again (where it had scrolled)
// when Back or Forward brings it there; null for an entry it did not push.
const linkedEntry = () => {
  const entry = window.history.state?.potokEntry
  return Number.isSafeInteger(entry) ? entry : null
}

let lastEntry = 0
const nextEntry = () => {
  lastEntry = Math.max(lastEntry + 1, Date.now())
  return lastEntry
}

// `history.state` is LiveView's, for the way back to this entry. With `push`
// the group gets an entry of its own, so Back comes back to the one before
// (`registerAppHistory`): a site's pages. It keeps LiveView's state, its
// position too, so when LiveView itself goes back to such an entry (after
// the viewer left the page) it finds what it put there. `id` null takes the
// group out of the address.
const linkGroup = (id, push = false) => {
  if (id !== null && positiveId(id) === null) {
    return {ok: false, error: "invalid_group"}
  }

  const url = new URL(window.location.href)
  if (id === null) url.searchParams.delete(APP_LINK_PARAM)
  else url.searchParams.set(APP_LINK_PARAM, id)

  try {
    if (push && url.href !== window.location.href) {
      const entry = nextEntry()
      window.history.pushState({...(window.history.state || {}), potokEntry: entry}, "", url)
      persistCurrentCapacitorRoute()
      return {ok: true, entry}
    }

    window.history.replaceState(window.history.state, "", url)
    return {ok: true, entry: linkedEntry()}
  } catch (_error) {
    // Safari refuses too many of these in a row.
    return {ok: false, error: "rate_limited"}
  }
}

// The app on the page that owns its entries of the history, while it lives
// (`GroupAppFrame`, host "page").
let appHistoryFrame = null

// Back and Forward between the entries an app pushed (`linkGroup` with
// `push`) stay inside the app: the frame hears of it, and LiveView must not,
// as it would patch the page or load it again, and the app with it. So this
// listener comes before LiveView's (`liveSocket.connect()` adds that one),
// in the capture phase, and stops the event for an entry of the same page
// whose address differs only in the app's `?at=`. Anything else (another
// page, another tab, another description) goes on to LiveView as before. On
// a guest's page, which has no LiveView of its own around the app, LiveView
// would fail on such an entry, so this is needed there too. What LiveView
// would have done on its way back is done here: the dialogs and the menu
// close, and the phone app keeps the address.
const registerAppHistory = () => {
  window.addEventListener(
    "popstate",
    event => {
      const frame = appHistoryFrame
      if (!frame || !frame.ownsAddress()) return

      event.stopImmediatePropagation()
      closeOverlaysOnPop()
      persistCurrentCapacitorRoute()
      frame.post({potok: 1, event: "linked_group", group_id: linkedGroupId(), entry: linkedEntry()})
    },
    {capture: true}
  )
}

// The address of a page without the app's `?at=`.
const addressWithoutLink = location => {
  const url = new URL(location.href)
  url.searchParams.delete(APP_LINK_PARAM)
  url.hash = ""
  return url.href
}

// A link to a page of a site in an app's frame: `?page=<path>`. The SDK checks
// it against the site's own address (`site_path.js`); here it only has to be
// a path.
const SITE_PAGE_PARAM = "page"

const linkedPage = () => {
  const page = new URLSearchParams(window.location.search).get(SITE_PAGE_PARAM)
  return page && page.length <= 1024 && page.startsWith("/") && !page.startsWith("//") ? page : null
}

// The address follows the reader of the site, as `linkGroup` follows an app.
const linkPage = page => {
  const url = new URL(window.location.href)

  if (typeof page === "string" && page.startsWith("/") && !page.startsWith("//") && page.length <= 1024) {
    url.searchParams.set(SITE_PAGE_PARAM, page)
  } else {
    url.searchParams.delete(SITE_PAGE_PARAM)
  }

  if (url.href === window.location.href) return

  try {
    window.history.replaceState(window.history.state, "", url)
  } catch (_error) {
    // Safari refuses too many in a row; the next page puts it right.
  }
}

// The app's `localStorage` lives in one key of the page's storage per app
// (`data-storage-key`), capped so an app cannot fill the page's quota.
const APP_FRAME_STORAGE_MAX_CHARS = 256 * 1024

const GroupAppFrame = {
  mounted() {
    this.iframe = this.el.querySelector("iframe")
    // ref of a file on its way -> {resolve, callId}
    this.pendingUploads = new Map()
    this.uploadQueue = Promise.resolve()

    this.handleMessage = event => {
      const message = event.data

      if (!this.iframe || event.source !== this.iframe.contentWindow) return
      if (!message || message.potok !== 1) return

      // The SDK may have loaded before this hook mounted; answer its hello.
      if (message.event === "hello") {
        this.postReady()
        return
      }

      if (message.event === "storage") {
        this.writeStorage(message.items)
        return
      }

      if (message.event === "site_page") {
        if (this.host() === "page") linkPage(message.page)
        return
      }

      // A link to a new tab, from the app or a site in it, in the phone app.
      if (message.event === "open_link") {
        openAppLink(message.url)
        return
      }

      if (typeof message.id === "number") {
        void this.handleCall(message)
      }
    }

    window.addEventListener("message", this.handleMessage)
    this.postReady()

    // Only the app of the page has the address to itself.
    if (this.host() === "page") {
      this.address = addressWithoutLink(window.location)
      appHistoryFrame = this
    }

    this.themeObserver = new MutationObserver(() => {
      this.post({potok: 1, event: "theme", theme: this.theme()})
    })
    this.themeObserver.observe(document.documentElement, {attributeFilter: ["data-theme"]})

    // A pushed event reaches every hook of the page, and a sheet over a map
    // runs a second frame (`AppHost`): each frame takes only its host's.
    const own = handler => ({host, ...payload}) => {
      if ((host || "page") === this.host()) handler(payload)
    }

    this.handleEvent("new_data_value", own(value => {
      this.post({potok: 1, event: "new_value", value})
    }))

    this.handleEvent("poll_changed", own(({id}) => {
      this.post({potok: 1, event: "poll_changed", id})
    }))

    // What changed in the app's collections, already cut to what this viewer sees.
    this.handleEvent("app_value", own(change => {
      this.post({potok: 1, event: "app_value", change})
    }))

    this.handleEvent("app_upload_progress", own(({ref, progress}) => {
      const pending = this.pendingUploads.get(ref)
      if (pending) this.post({potok: 1, event: "upload_progress", id: pending.callId, progress})
    }))

    this.handleEvent("app_upload_done", own(({ref, ...result}) => {
      const pending = this.pendingUploads.get(ref)
      if (!pending) return

      this.pendingUploads.delete(ref)
      pending.resolve(result)
    }))

    this.handleEvent("app_share_link", own(({url}) => shareLink(url)))

    // Something changed among the group's sub-groups; the app reads them again.
    this.handleEvent("app_children_changed", own(() => {
      this.post({potok: 1, event: "children_changed"})
    }))

    // The sheet the app opened (`showGroup`) closed.
    this.handleEvent("group_sheet_closed", own(({id}) => {
      this.post({potok: 1, event: "group_sheet_closed", id})
    }))

    // What waits for the viewer in the group's processes changed.
    this.handleEvent("app_waiting_changed", own(() => {
      this.post({potok: 1, event: "waiting_changed"})
    }))
  },

  host() {
    return this.el.dataset.host || "page"
  },

  reconnected() {
    this.post({potok: 1, event: "reconnected"})
  },

  // Whether the page's address is still this app's, but for its `?at=`.
  ownsAddress() {
    return this.address === addressWithoutLink(window.location)
  },

  destroyed() {
    if (appHistoryFrame === this) appHistoryFrame = null
    window.removeEventListener("message", this.handleMessage)
    this.themeObserver?.disconnect()
    this.pendingUploads.forEach(({resolve}) => resolve({ok: false, error: "disconnected"}))
    this.pendingUploads.clear()
  },

  postReady() {
    this.post({
      potok: 1,
      event: "ready",
      theme: this.theme(),
      storage: this.readStorage(),
      page: this.host() === "page" ? linkedPage() : null,
      // In the phone app the frame hands its new-tab links to the page.
      native: Capacitor.isNativePlatform(),
    })
  },

  // A guest's personal memory, in this browser: `{key: value}`.
  readPersonal() {
    try {
      const items = JSON.parse(localStorage.getItem(this.el.dataset.personalKey) || "{}")
      return items && typeof items === "object" && !Array.isArray(items) ? items : {}
    } catch (_error) {
      return {}
    }
  },

  personalCall(method, params) {
    const items = this.readPersonal()
    const key = params?.key

    if (method === "list_personal") {
      const list = Object.keys(items).sort().map(name => ({key: name, value: items[name]}))
      return {ok: true, items: list}
    }

    if (typeof key !== "string" || !PERSONAL_KEY.test(key)) return {ok: false, error: "invalid_key"}
    if (method === "get_personal") return {ok: true, value: items[key] ?? null}

    if (method === "delete_personal") {
      delete items[key]
    } else {
      const json = JSON.stringify(params?.value ?? null)
      if (new TextEncoder().encode(json).length > PERSONAL_MAX_BYTES) return {ok: false, error: "too_big"}
      if (!(key in items) && Object.keys(items).length >= PERSONAL_MAX_KEYS) {
        return {ok: false, error: "too_many_keys"}
      }
      items[key] = JSON.parse(json)
    }

    try {
      localStorage.setItem(this.el.dataset.personalKey, JSON.stringify(items))
      return {ok: true}
    } catch (_error) {
      return {ok: false, error: "unavailable"}
    }
  },

  theme() {
    return document.documentElement.getAttribute("data-theme")
  },

  readStorage() {
    const key = this.el.dataset.storageKey
    if (!key) return {}

    try {
      const items = JSON.parse(localStorage.getItem(key) || "{}")
      return items && typeof items === "object" && !Array.isArray(items) ? items : {}
    } catch (_error) {
      return {}
    }
  },

  writeStorage(items) {
    const key = this.el.dataset.storageKey
    if (!key || !items || typeof items !== "object" || Array.isArray(items)) return

    try {
      const serialized = JSON.stringify(items)

      if (serialized.length <= APP_FRAME_STORAGE_MAX_CHARS) {
        localStorage.setItem(key, serialized)
      }
    } catch (_error) {
      // Storage full or blocked: the app keeps working with its in-memory copy.
    }
  },

  async handleCall({id, method, params, file}) {
    if (this.el.dataset.api !== "true") {
      this.post({potok: 1, id, ok: false, error: "preview"})
      return
    }

    if (!APP_FRAME_METHODS.has(method)) {
      this.post({potok: 1, id, ok: false, error: "unknown_method"})
      return
    }

    if (APP_FRAME_UPLOADS.has(method)) {
      // One file at a time: the page keeps one upload for the frame.
      const run = this.uploadQueue.then(() => this.sendFile(id, method, params, file))
      this.uploadQueue = run.catch(() => {})
      await run
      return
    }

    if (method === "pick_emoji") {
      this.post({potok: 1, id, ...(await this.pickEmoji())})
      return
    }

    if (APP_FRAME_GUEST_LOCAL.has(method) && this.el.dataset.personalKey) {
      this.post({potok: 1, id, ...this.personalCall(method, params)})
      return
    }

    // The page's address belongs to the app under the sheet, not to the one in it.
    if (method === "linked_group") {
      const page = this.host() === "page"
      this.post({
        potok: 1,
        id,
        ok: true,
        group_id: page ? linkedGroupId() : null,
        entry: page ? linkedEntry() : null,
      })
      return
    }

    if (method === "link_group") {
      const result =
        this.host() === "page"
          ? linkGroup(params?.id ?? null, params?.push === true)
          : {ok: false, error: "unavailable"}

      this.post({potok: 1, id, ...result})
      return
    }

    // Only a guest's page (`public_group_page`) has a log-in to go to, and it
    // comes back to this same page afterwards; the frame cannot leave it itself.
    if (method === "open_login") {
      if (document.getElementById("guest-group")) {
        this.post({potok: 1, id, ok: true})
        window.location.assign("/accounts/log-in")
      } else {
        this.post({potok: 1, id, ok: false, error: "unavailable"})
      }
      return
    }

    try {
      // The server refuses calls whose app is no longer the one on screen.
      const reply = await this.pushEvent("app_api", {
        method,
        params: params || {},
        app_id: this.el.dataset.appId || "",
      })
      // A call that navigates (`open_group`) gets no reply: the page is leaving.
      this.post({potok: 1, id, ...(reply ?? {ok: true})})
    } catch (_error) {
      this.post({potok: 1, id, ok: false, error: "disconnected"})
    }
  },

  // The server first says whether the file may go and where; the file then goes
  // through the page's own upload (`:app_file`), straight to the bucket when it
  // can, and the answer comes back as `app_upload_done`.
  async sendFile(id, method, params, file) {
    if (!(file instanceof Blob)) {
      this.post({potok: 1, id, ok: false, error: "invalid_files"})
      return
    }

    // Stripped before its size is announced, which the upload must match.
    const named = await stripForUpload(
      file instanceof File ? file : new File([file], "file", {type: file.type})
    )
    let prepared

    try {
      prepared = await this.pushEvent("app_api", {
        method: "prepare_upload",
        params: {
          ...(params || {}),
          image: method === "upload_image",
          media: method === "upload_media",
          name: named.name || "file",
          size: named.size,
          type: named.type || "",
        },
        app_id: this.el.dataset.appId || "",
      })
    } catch (_error) {
      this.post({potok: 1, id, ok: false, error: "disconnected"})
      return
    }

    if (!prepared?.ok) {
      this.post({potok: 1, id, ...(prepared ?? {ok: false, error: "invalid_files"})})
      return
    }

    const result = await new Promise(resolve => {
      this.pendingUploads.set(prepared.ref, {resolve, callId: id})
      this.upload(this.el.dataset.upload || "app_file", [named])
    })

    this.post({potok: 1, id, ...result})
  },

  // The page's own picker, as the frame has neither its code nor its data. Taps
  // on the frame have to reach the page for the picker to close on them.
  pickEmoji() {
    const picker = document.getElementById(this.el.dataset.picker || "reaction-picker")

    if (!picker) {
      return Promise.resolve({ok: false, error: "forbidden"})
    }

    return new Promise(resolve => {
      this.iframe.style.pointerEvents = "none"

      const done = emoji => {
        this.iframe.style.pointerEvents = ""
        resolve(emoji ? {ok: true, emoji} : {ok: false, error: "cancelled"})
      }

      picker.dispatchEvent(new CustomEvent("potok:pick-emoji", {detail: {anchor: this.iframe, done}}))
    })
  },

  post(message) {
    // "*" is required: a sandboxed frame without allow-same-origin has an opaque origin.
    this.iframe?.contentWindow?.postMessage(message, "*")
  },
}

// A waiting worker means a new version is installed. Instead of reloading on
// its own (possibly while someone is typing), the page shows the update toast
// from the root layout and only switches when the user asks for it.
const showUpdateToast = registration => {
  const toast = document.getElementById("app-update-toast")
  const reloadButton = document.getElementById("app-update-reload")

  if (!toast || !reloadButton || !registration.waiting || !navigator.serviceWorker.controller) {
    return
  }

  reloadButton.onclick = () => {
    reloadButton.disabled = true
    registration.waiting?.postMessage({type: "SKIP_WAITING"})
  }

  toast.hidden = false
}

const registerServiceWorker = async () => {
  if (!("serviceWorker" in navigator)) {
    return
  }

  // On a first visit the new worker claims the page as it activates, which
  // also fires `controllerchange`; such a page has no old version to swap out.
  const hadController = Boolean(navigator.serviceWorker.controller)

  try {
    const registration = await navigator.serviceWorker.register("/sw.js", {scope: "/"})

    showUpdateToast(registration)

    registration.addEventListener("updatefound", () => {
      const installing = registration.installing

      if (!installing) {
        return
      }

      installing.addEventListener("statechange", () => {
        if (installing.state === "installed") {
          showUpdateToast(registration)
        }
      })
    })

    let refreshing = false

    // Fires once the waiting worker took over after the toast's button.
    navigator.serviceWorker.addEventListener("controllerchange", () => {
      if (refreshing || !hadController) {
        return
      }

      refreshing = true
      window.location.reload()
    })
  } catch (error) {
    console.error("Service worker registration failed", error)
  }
}

const APP_LINK_HOST = "potok.rs"
const APP_LINK_PATH_PATTERN = /^\/accounts\/log-in\/([^/]+)\/?$/
const CAPACITOR_LAST_ROUTE_KEY = "potok:last-route"
const CAPACITOR_LAST_MAGIC_LINK_TOKEN_KEY = "potok:last-magic-link-token"
const CAPACITOR_ROUTE_RESTORE_DELAY_MS = 500
const CAPACITOR_URL_DEDUPE_WINDOW_MS = 1500
const CAPACITOR_MAGIC_LINK_TOKEN_TTL_MS = 10 * 60 * 1000
const KEYBOARD_OPEN_DELTA_PX = 120
const KEYBOARD_CLOSE_DELTA_PX = 80

let pendingCapacitorRouteRestore = null
let lastHandledCapacitorUrl = null
let lastHandledCapacitorUrlAt = 0

const editableElementFocused = () => {
  const activeElement = document.activeElement

  if (!(activeElement instanceof HTMLElement)) {
    return false
  }

  return activeElement.matches(
    "input:not([type='button']):not([type='checkbox']):not([type='color']):not([type='file']):not([type='hidden']):not([type='image']):not([type='radio']):not([type='range']):not([type='reset']):not([type='submit']), textarea, select, [contenteditable=''], [contenteditable='true']"
  )
}

// Nothing tells a page that the on-screen keyboard opened, but it takes a big
// part of the visible height while a field has the focus. `data-keyboard-open`
// on <html> lets the page give that height back to its content (the
// `keyboard-open:` and `cramped:` variants in app.css).
const registerKeyboardWatcher = () => {
  // Not `pointer: coarse`: a phone with a stylus reports a fine pointer.
  if (!window.matchMedia("(hover: none)").matches) {
    return
  }

  const root = document.documentElement
  const viewport = window.visualViewport

  // Scaled back, so zooming in does not read as a keyboard.
  const visibleHeight = () => (viewport ? viewport.height * viewport.scale : window.innerHeight)

  let keyboardOpen = false
  let stableViewportHeight = visibleHeight()

  // iOS browsers keep the page's height under the keyboard and slide the page
  // up instead, so there the shell is sized to what stays visible.
  const fitShell = viewportHeight => {
    if (keyboardOpen && window.innerHeight - viewportHeight >= KEYBOARD_CLOSE_DELTA_PX) {
      root.style.setProperty("--app-visual-height", `${viewportHeight}px`)
      window.scrollTo(0, 0)
    } else {
      root.style.removeProperty("--app-visual-height")
    }
  }

  const syncKeyboardState = () => {
    const viewportHeight = visibleHeight()
    const editableFocused = editableElementFocused()

    // Only a height seen with no field in focus is the full one: with a focus,
    // a keyboard on its way in may already have taken a part of it.
    if (!keyboardOpen && !editableFocused) {
      stableViewportHeight = viewportHeight
    }

    const viewportDelta = Math.max(0, stableViewportHeight - viewportHeight)
    const threshold = keyboardOpen ? KEYBOARD_CLOSE_DELTA_PX : KEYBOARD_OPEN_DELTA_PX

    keyboardOpen = editableFocused && viewportDelta >= threshold
    root.dataset.keyboardOpen = keyboardOpen ? "true" : "false"
    fitShell(viewportHeight)
  }

  const scheduleSyncKeyboardState = () => {
    window.requestAnimationFrame(syncKeyboardState)
  }

  viewport?.addEventListener("resize", scheduleSyncKeyboardState)
  viewport?.addEventListener("scroll", scheduleSyncKeyboardState)
  window.addEventListener("resize", scheduleSyncKeyboardState)
  window.addEventListener("orientationchange", scheduleSyncKeyboardState)
  window.addEventListener("focusin", scheduleSyncKeyboardState)
  window.addEventListener("focusout", scheduleSyncKeyboardState)

  scheduleSyncKeyboardState()
}

// The apps run under the status bar, so its clock and icons follow the app's
// theme rather than the phone's: light on a dark page, dark on a light one.
// Every theme sets `color-scheme`, "system" included.
const registerSystemBarsStyle = () => {
  if (!Capacitor.isNativePlatform()) {
    return
  }

  const root = document.documentElement

  const applyStyle = () => {
    const dark = window.getComputedStyle(root).colorScheme === "dark"

    SystemBars.setStyle({style: dark ? SystemBarsStyle.Dark : SystemBarsStyle.Light}).catch(() => {})
  }

  new MutationObserver(applyStyle).observe(root, {attributeFilter: ["data-theme"]})
  window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", applyStyle)

  applyStyle()
}

const recentlyHandledCapacitorMagicLinkToken = token => {
  const normalizedToken = typeof token === "string" ? token.trim() : ""

  if (!normalizedToken) {
    return false
  }

  try {
    const rawValue = window.localStorage.getItem(CAPACITOR_LAST_MAGIC_LINK_TOKEN_KEY)

    if (!rawValue) {
      return false
    }

    const storedValue = JSON.parse(rawValue)

    if (storedValue?.token !== normalizedToken || !Number.isFinite(storedValue?.handledAt)) {
      return false
    }

    if (Date.now() - storedValue.handledAt > CAPACITOR_MAGIC_LINK_TOKEN_TTL_MS) {
      window.localStorage.removeItem(CAPACITOR_LAST_MAGIC_LINK_TOKEN_KEY)
      return false
    }

    return true
  } catch (_error) {
    return false
  }
}

const rememberCapacitorMagicLinkToken = token => {
  const normalizedToken = typeof token === "string" ? token.trim() : ""

  if (!normalizedToken) {
    return
  }

  try {
    window.localStorage.setItem(
      CAPACITOR_LAST_MAGIC_LINK_TOKEN_KEY,
      JSON.stringify({token: normalizedToken, handledAt: Date.now()})
    )
  } catch (_error) {
    // Ignore storage failures (private mode/quota/etc.).
  }
}

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
    return
  }

  window.location.assign(targetUrl.toString())
}

const handleCapacitorMagicLink = urlString => {
  const token = parseCapacitorMagicLinkToken(urlString)

  if (!token) {
    return false
  }

  if (recentlyHandledCapacitorMagicLinkToken(token)) {
    return true
  }

  rememberCapacitorMagicLinkToken(token)

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
      return true
    }

    window.location.assign(targetUrl.toString())
    return true
  } catch (_error) {
    return false
  }
}

const cancelPendingCapacitorRouteRestore = () => {
  if (pendingCapacitorRouteRestore === null) {
    return
  }

  window.clearTimeout(pendingCapacitorRouteRestore)
  pendingCapacitorRouteRestore = null
}

const scheduleCapacitorRouteRestore = () => {
  cancelPendingCapacitorRouteRestore()

  pendingCapacitorRouteRestore = window.setTimeout(() => {
    pendingCapacitorRouteRestore = null
    restoreLastCapacitorRoute()
  }, CAPACITOR_ROUTE_RESTORE_DELAY_MS)
}

// The iOS Share Extension opens `potok://share/<id>` after storing the share
// where the app's `ShareInbox` plugin reads it.
const openCapacitorShareUrl = urlString => {
  try {
    const url = new URL(urlString)

    if (url.protocol !== "potok:" || url.hostname !== "share") {
      return false
    }
  } catch (_error) {
    return false
  }

  void openPendingNativeShare().catch(() => {})
  return true
}

const handleCapacitorAppUrl = urlString => {
  const normalizedUrl = typeof urlString === "string" ? urlString.trim() : ""

  if (!normalizedUrl) {
    return false
  }

  cancelPendingCapacitorRouteRestore()

  const now = Date.now()

  if (
    normalizedUrl === lastHandledCapacitorUrl &&
    now - lastHandledCapacitorUrlAt < CAPACITOR_URL_DEDUPE_WINDOW_MS
  ) {
    return true
  }

  const handled = openCapacitorShareUrl(normalizedUrl) || openNotificationUrl(normalizedUrl)

  if (handled) {
    lastHandledCapacitorUrl = normalizedUrl
    lastHandledCapacitorUrlAt = now
  }

  return handled
}

const registerCapacitorMagicLinks = () => {
  if (!Capacitor.isNativePlatform()) {
    return
  }

  void App.addListener("appUrlOpen", ({url}) => {
    handleCapacitorAppUrl(url)
  })

  onNativeShareReceived(() => {
    cancelPendingCapacitorRouteRestore()
    void openPendingNativeShare().catch(() => {})
  })

  void App.getLaunchUrl()
    .then(async result => {
      if (handleCapacitorAppUrl(result?.url || "")) {
        return
      }

      // An app opened from the share sheet goes to `/share`, not the last route.
      if (!(await openPendingNativeShare().catch(() => false))) {
        scheduleCapacitorRouteRestore()
      }
    })
    .catch(() => {})
}

const persistCurrentCapacitorRoute = () => {
  if (!Capacitor.isNativePlatform()) {
    return
  }

  const route = `${window.location.pathname}${window.location.search}${window.location.hash}`

  // A share is opened once; a later start must not come back to it.
  if (
    window.location.pathname === "/share" ||
    new URLSearchParams(window.location.search).has("share")
  ) {
    return
  }

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

// Closes a dialog the way Escape does: a cancelable `cancel` event first, so
// a dialog that closes through the server can take over.
const closeDialogAsEscape = dialog => {
  if (dialog.dispatchEvent(new Event("cancel", {cancelable: true}))) {
    dialog.close()
  }
}

// Closes the menu that slides over the page on a phone, if it is open.
const closeAppDrawer = () => {
  const toggle = document.getElementById("app-drawer-toggle")

  if (!toggle?.checked) {
    return false
  }

  toggle.checked = false
  return true
}

// Android's back button closes the topmost open dialog, then the menu. A
// listener turns off Capacitor's own handling, so going back is done here
// too; with nowhere to go back to, the app goes to the background like other
// Android apps, and comes back on the same page.
const registerCapacitorBackButton = () => {
  if (Capacitor.getPlatform() !== "android") {
    return
  }

  void App.addListener("backButton", ({canGoBack}) => {
    const dialogs = document.querySelectorAll("dialog[open]")
    const dialog = dialogs[dialogs.length - 1]

    if (dialog) {
      closeDialogAsEscape(dialog)
    } else if (closeAppDrawer()) {
      return
    } else if (canGoBack) {
      window.history.back()
    } else {
      void App.minimizeApp()
    }
  })
}

// Going back through the history (the swipe from the edge on iOS, a browser's
// back button) leaves the page that dialogs and the menu were open over, so
// they close too; otherwise a dialog whose `open` LiveView keeps would stay
// over the page it went back to. LiveView sends `phx:navigate` with `pop`
// only when the page changed (not for an anchor of the same page), before it
// patches, while the old page is still connected.
const closeOverlaysOnPop = () => {
  Array.from(document.querySelectorAll("dialog[open]")).reverse().forEach(closeDialogAsEscape)
  closeAppDrawer()
}

const registerHistoryClosesOverlays = () => {
  window.addEventListener("phx:navigate", ({detail}) => {
    if (detail?.pop) closeOverlaysOnPop()
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

// Saving takes the device to the signed-in account and keeps the session's
// language for its notifications. The settings page and the start of a page
// may both save one device: it goes to the server once per page load.
const savedPushDevices = new Map()

function savePushDevice(subscription, identifier) {
  if (!savedPushDevices.has(identifier)) {
    const saving = postPushSubscription(subscription)
      .then(payload => {
        writePushStore(POTOK_PUSH_DEVICE_KEY, identifier)
        return payload
      })
      .catch(error => {
        savedPushDevices.delete(identifier)
        throw error
      })

    savedPushDevices.set(identifier, saving)
  }

  return savedPushDevices.get(identifier)
}

async function postPushSubscription(subscription) {
  const response = await fetch("/accounts/push-subscriptions", {
    method: "POST",
    credentials: "same-origin",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
      "x-csrf-token": csrfToken,
    },
    body: JSON.stringify({subscription}),
  })

  const payload = await response.json().catch(() => ({}))
  if (!response.ok) throw new Error(payload.error || "")

  return payload
}

function saveNativeDeviceToken(token) {
  writePushStore(POTOK_PUSH_TOKEN_KEY, token)
  return savePushDevice({type: "fcm", token, platform: Capacitor.getPlatform()}, token)
}

function saveWebPushSubscription(subscription) {
  const json = subscription.toJSON()
  return savePushDevice(json, json.endpoint)
}

function forgetPushDevice() {
  writePushStore(POTOK_PUSH_DEVICE_KEY, null)
  savedPushDevices.clear()
}

// The app asks for notifications by itself once, the first time someone is
// signed in in it, and saves the device on every start while they are
// allowed, so a fresh install needs no visit to the settings. A refusal is
// left alone, and so is "Disable" in the settings.
async function autoEnableNativePush() {
  if (!NativePushManager.isSupported() || !signedIn()) return

  await NativePushManager.initialize()
  if (readPushStore(POTOK_PUSH_OFF_KEY)) return

  let {receive} = await NativePushManager.checkPermissions()
  const ask = receive === "prompt" && !readPushStore(POTOK_PUSH_ASKED_KEY)

  if (ask) {
    writePushStore(POTOK_PUSH_ASKED_KEY, "1")
    receive = (await NativePushManager.requestPermissions()).receive
  }

  // iOS registered already while setting up, if notifications were allowed.
  if (receive === "granted" && (ask || Capacitor.getPlatform() !== "ios")) {
    await NativePushManager.register()
  }
}

// Before the switch existed, "Disable" only dropped the token. Every save
// left the language it was saved in, so a device with that and no token had
// turned notifications off, and they stay off. Read once, first thing on a
// start (`NativePushManager.setUp`), before anything registers.
function keepOldPushSwitch() {
  const oldLocaleKey = "potok:push-locale"
  if (!readPushStore(oldLocaleKey)) return

  if (!readPushStore(POTOK_PUSH_TOKEN_KEY)) writePushStore(POTOK_PUSH_OFF_KEY, "1")
  writePushStore(oldLocaleKey, null)
}

// A browser asks only after a click, in the settings. A permission given
// there is saved again on every page load: after a new sign-in, the account
// signed in gets this browser's notifications.
async function syncWebPushSubscription() {
  if (NativePushManager.isSupported() || !signedIn()) return
  if (!("serviceWorker" in navigator && "PushManager" in window && "Notification" in window)) return
  if (Notification.permission !== "granted") return

  const registration = await navigator.serviceWorker.getRegistration()
  const existing = await registration?.pushManager.getSubscription()
  if (existing) await saveWebPushSubscription(existing)
}

// Logging out takes this device off the account: the log-out form carries
// what the device saved, and the server deletes it with the session. Without
// it phoenix_html sends the form as always.
function logOutWithPushDevice(event, link) {
  const identifier = readPushStore(POTOK_PUSH_DEVICE_KEY)
  if (!identifier || event.defaultPrevented || !link.dataset.to) return

  event.preventDefault()

  const form = document.createElement("form")
  form.method = "post"
  form.action = link.dataset.to
  form.hidden = true

  for (const [name, value] of [
    ["_method", "delete"],
    ["_csrf_token", link.dataset.csrf || csrfToken],
    ["push_device", identifier],
  ]) {
    const input = document.createElement("input")
    input.type = "hidden"
    input.name = name
    input.value = value
    form.appendChild(input)
  }

  document.body.appendChild(form)
  form.submit()
}

// The sub-groups tab hides thread sub-groups until the viewer shows them, and
// keeps that choice in this browser. The server says when it changes.
const SUB_GROUPS_THREADS_KEY = "potok:sub-groups-threads"

function storedShowThreads() {
  try {
    return window.localStorage.getItem(SUB_GROUPS_THREADS_KEY) === "shown"
  } catch (_error) {
    return false
  }
}

window.addEventListener("phx:sub_groups_threads", ({detail}) => {
  try {
    window.localStorage.setItem(SUB_GROUPS_THREADS_KEY, detail.shown ? "shown" : "hidden")
  } catch (_error) {}
})

// The root group hides the public groups the viewer is not in until they are
// shown, and this browser keeps that choice too.
const ROOT_PUBLIC_GROUPS_KEY = "potok:root-public-groups"

function storedShowPublicGroups() {
  try {
    return window.localStorage.getItem(ROOT_PUBLIC_GROUPS_KEY) === "shown"
  } catch (_error) {
    return false
  }
}

window.addEventListener("phx:sub_groups_public", ({detail}) => {
  try {
    window.localStorage.setItem(ROOT_PUBLIC_GROUPS_KEY, detail.shown ? "shown" : "hidden")
  } catch (_error) {}
})

// The root calendar's filters (its groups' events, public events), kept in
// this browser; both are on until the viewer turns one off.
const CALENDAR_FILTERS_KEY = "potok:calendar-filters"

function storedCalendarFilters() {
  try {
    const stored = JSON.parse(window.localStorage.getItem(CALENDAR_FILTERS_KEY) || "{}")
    return {groups: stored?.groups !== false, public: stored?.public !== false}
  } catch (_error) {
    return {groups: true, public: true}
  }
}

// The same for the root overview of polls.
const POLLS_FILTERS_KEY = "potok:polls-filters"

function storedPollsFilters() {
  try {
    const stored = JSON.parse(window.localStorage.getItem(POLLS_FILTERS_KEY) || "{}")
    return {groups: stored?.groups !== false, public: stored?.public !== false}
  } catch (_error) {
    return {groups: true, public: true}
  }
}

window.addEventListener("phx:polls_filters", ({detail}) => {
  try {
    window.localStorage.setItem(
      POLLS_FILTERS_KEY,
      JSON.stringify({groups: detail.groups === true, public: detail.public === true})
    )
  } catch (_error) {}
})

window.addEventListener("phx:calendar_filters", ({detail}) => {
  try {
    window.localStorage.setItem(
      CALENDAR_FILTERS_KEY,
      JSON.stringify({groups: detail.groups === true, public: detail.public === true})
    )
  } catch (_error) {}
})

// The files tab's view, a list or folders, kept in this browser for every
// group; the server says when it changes.
const FILES_VIEW_KEY = "potok:files-view"

function storedFilesView() {
  try {
    return window.localStorage.getItem(FILES_VIEW_KEY) === "tree" ? "tree" : "list"
  } catch (_error) {
    return "list"
  }
}

window.addEventListener("phx:files_view", ({detail}) => {
  try {
    window.localStorage.setItem(FILES_VIEW_KEY, detail.view === "tree" ? "tree" : "list")
  } catch (_error) {}
})

// After a deploy every page reconnects at once. Phoenix retries after 10,
// 50, 100 ms...; a random part spreads those retries over a few seconds, and
// pages fall back to long polling (a request per poll, heavier for the
// server) only when the websocket has not connected for 10 s, not 2.5 s.
const reconnectAfterMs = (tries) => {
  const base = [100, 500, 1000, 2000, 5000][tries - 1] ?? 10000
  return base + Math.floor(Math.random() * Math.min(base, 3000))
}

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 10000,
  reconnectAfterMs,
  // Read on every join, so a page opened by live navigation gets the latest
  // choices. The calendar shows times in the viewer's zone.
  params: () => ({
    _csrf_token: csrfToken,
    time_zone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    show_threads: storedShowThreads(),
    show_public_groups: storedShowPublicGroups(),
    calendar_filters: storedCalendarFilters(),
    polls_filters: storedPollsFilters(),
    files_view: storedFilesView(),
  }),
  hooks: {
    HeaderDrawer,
    ValueSheet,
    DropdownMenu,
    AutoDismissFlash,
    PushNotifications,
    GroupAppFrame,
    ReactionPicker,
    LocationPicker,
    ProcessCanvas,
    RootMap,
    KeyboardMedia,
    ShareComposer,
    SharePreview,
    ComposerDraft,
    DraftMark,
    DescriptionArchive,
    ...colocatedHooks,
  },
  uploaders: Uploaders,
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())
// The drop in the top bar, while topbar.js marks the page as loading.
installPageLoader()

installPasswordToggleButtons()
installGalleries()
// A conversation's notifications leave this device once it is read.
installNotificationTray()

// Drafts stay in this browser, which may be a shared one: logging out drops them.
document.addEventListener("click", event => {
  if (event.target.closest?.("[data-clear-drafts]")) clearAllDrafts()

  // Before phoenix_html, which listens on the window.
  const logOut = event.target.closest?.("[data-log-out]")
  if (logOut) logOutWithPushDevice(event, logOut)
})

// Inside a LiveView the attribute is set through a JS command: those are
// sticky, while plain DOM changes would be undone by the next patch.
const setNavLinkCurrent = (link, isActive) => {
  if (link.closest("[data-phx-session]")) {
    const command = isActive
      ? [["set_attr", {attr: ["aria-current", "page"]}]]
      : [["remove_attr", {attr: "aria-current"}]]

    liveSocket.execJS(link, JSON.stringify(command))
  } else if (isActive) {
    link.setAttribute("aria-current", "page")
  } else {
    link.removeAttribute("aria-current")
  }
}

const updateDrawerActiveLinks = () => {
  const pathname = window.location.pathname

  document.querySelectorAll("[data-nav-link]").forEach(link => {
    const target = link.dataset.navTarget || ""
    const match = link.dataset.navMatch || "exact"
    const isActive = match === "prefix"
      ? pathname === target || pathname.startsWith(`${target}/`)
      : pathname === target

    setNavLinkCurrent(link, isActive)
  })
}

window.addEventListener("DOMContentLoaded", installDomainMap)
window.addEventListener("DOMContentLoaded", installHelpAccess)
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
  syncWebPushSubscription().catch(error => console.warn("Unable to save this browser for notifications", error))
  autoEnableNativePush().catch(error => console.warn("Unable to turn on notifications", error))
})

window.addEventListener("phx:current_profile_updated", ({detail}) => {
  const brandTitle = document.getElementById("nav-brand-title")
  const brandAvatar = document.getElementById("nav-brand-profile-avatar")
  const brandInitials = document.getElementById("nav-brand-profile-initials")
  const brandLogo = document.getElementById("nav-brand-logo")
  const invitationsLink = document.getElementById("nav-invitations-link")
  const invitationsBadge = document.getElementById("nav-invitations-count-badge")
  const rootGroupBadge = document.getElementById("nav-root-group-unread-badge")
  const noticesLink = document.getElementById("nav-notices-link")
  const noticesBadge = document.getElementById("nav-notices-count-badge")
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

  if (noticesLink) {
    noticesLink.hidden = !hasProfile
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

    if (noticesBadge) {
      noticesBadge.hidden = true
      noticesBadge.textContent = ""
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
  // No group counts past 100 unread messages (`Social.unread_cap/0`).
  rootGroupBadge.textContent = count > 99 ? "99+" : String(count)
})

// Unread notices of the groups the profile follows, kept apart from messages.
window.addEventListener("phx:unread_notices_count_updated", ({detail}) => {
  const noticesBadge = document.getElementById("nav-notices-count-badge")

  if (!noticesBadge) {
    return
  }

  const count = Number(detail.count || 0)

  noticesBadge.hidden = count <= 0
  noticesBadge.textContent = count > 999 ? "999+" : String(count)
})

// The last page of this tab outside Profiles, where choosing a profile there
// goes back to (the `.CloseProfiles` hook reads the same key). Only a signed-in
// page counts; any other one forgets it, so the next account to sign in here
// does not land in the last one's group.
const PROFILES_RETURN_KEY = "potok:profiles-return"

const rememberProfilesReturn = () => {
  const {pathname, search, hash} = window.location

  if (pathname === "/profiles" || pathname.startsWith("/profiles/")) {
    return
  }

  try {
    if (document.getElementById("app-sidebar-account")) {
      window.sessionStorage.setItem(PROFILES_RETURN_KEY, `${pathname}${search}${hash}`)
    } else {
      window.sessionStorage.removeItem(PROFILES_RETURN_KEY)
    }
  } catch (_error) {
    // Ignore storage failures (private mode/quota/etc.).
  }
}

rememberProfilesReturn()
window.addEventListener("phx:page-loading-stop", rememberProfilesReturn)

registerCapacitorMagicLinks()
registerCapacitorBackButton()
registerHistoryClosesOverlays()
registerAppHistory()
registerCapacitorPushNotifications()
registerCapacitorRoutePersistence()
registerSystemBarsStyle()
registerKeyboardWatcher()

window.addEventListener("DOMContentLoaded", () => {
  installLongPressLinkMenu()
})

// connect if there are any LiveViews on the page
installUploadStripping()
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

