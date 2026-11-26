// Clears a conversation's notifications from this device once it is read,
// as messaging apps do. The server sends `push:clear` with the group and the
// kinds of notification to clear (`PotokIdeWeb.PushClear`).
//
// In the browser, the service worker's notifications carry `data.group_id`
// and `data.kind` (see `priv/static/sw.js`). In the app, Android's are
// matched by their tag, which always starts with `group-<id>-`, and iOS's by
// the FCM data the notification keeps.
import {Capacitor} from "@capacitor/core"
import {PushNotifications} from "@capacitor/push-notifications"

// The tags of each kind (`PotokIde.Social.Notifications`, `Notices`). A chat
// tag of an older release was one per value (`group-<id>-value-<v>-created`).
const tagPrefixes = (groupId, kinds) =>
  kinds.flatMap(kind => {
    switch (kind) {
      case "message":
      case "mention":
      case "reply":
        return [`group-${groupId}-chat`, `group-${groupId}-value-`]
      case "reaction":
        return [`group-${groupId}-value-`]
      case "notice":
        return [`group-${groupId}-notice-`]
      default:
        return []
    }
  })

const matchesTag = (tag, prefixes) =>
  typeof tag === "string" && prefixes.some(prefix => tag.startsWith(prefix))

const matchesData = (data, groupId, kinds) =>
  data && String(data.group_id) === String(groupId) && kinds.includes(data.kind)

const clearInBrowser = async (groupId, kinds, prefixes) => {
  if (!("serviceWorker" in navigator)) return

  const registration = await navigator.serviceWorker.getRegistration()
  if (!registration?.getNotifications) return

  const notifications = await registration.getNotifications()

  notifications
    .filter(notification =>
      matchesData(notification.data, groupId, kinds) || matchesTag(notification.tag, prefixes))
    .forEach(notification => notification.close())
}

const clearInApp = async (groupId, kinds, prefixes) => {
  const {notifications} = await PushNotifications.getDeliveredNotifications()

  const matching = (notifications || []).filter(notification =>
    matchesTag(notification.tag, prefixes) || matchesData(notification.data, groupId, kinds))

  if (matching.length > 0) {
    await PushNotifications.removeDeliveredNotifications({notifications: matching})
  }
}

export const clearConversationNotifications = async ({group_id: groupId, kinds} = {}) => {
  if (!groupId || !Array.isArray(kinds) || kinds.length === 0) return

  const prefixes = tagPrefixes(groupId, kinds)

  try {
    if (Capacitor.isNativePlatform()) {
      await clearInApp(groupId, kinds, prefixes)
    } else {
      await clearInBrowser(groupId, kinds, prefixes)
    }
  } catch (_error) {
    // iOS refuses until push is registered in this session; nothing to clear
    // is no reason to bother anyone.
  }
}

export const installNotificationTray = () => {
  window.addEventListener("phx:push:clear", event => clearConversationNotifications(event.detail))
}
