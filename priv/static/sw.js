const CACHE_VERSION = "potok-static-v2"
const STATIC_CACHE = CACHE_VERSION
const STATIC_ASSETS = [
  "/offline.html",
  "/manifest.webmanifest",
  "/favicon.ico",
  "/images/logo.svg",
  "/images/pwa/icon.svg",
  "/images/pwa/apple-touch-icon.svg",
]

self.addEventListener("install", event => {
  event.waitUntil(
    caches.open(STATIC_CACHE).then(cache => cache.addAll(STATIC_ASSETS)).then(() => self.skipWaiting())
  )
})

self.addEventListener("activate", event => {
  event.waitUntil(
    caches.keys().then(cacheNames =>
      Promise.all(
        cacheNames
        .filter(cacheName => cacheName !== STATIC_CACHE)
        .map(cacheName => caches.delete(cacheName))
      )
    ).then(() => self.clients.claim())
  )
})

self.addEventListener("message", event => {
  if (event.data?.type === "SKIP_WAITING") {
    self.skipWaiting()
  }
})

const isStaticAsset = pathname => {
  return pathname.startsWith("/assets/") ||
    pathname.startsWith("/fonts/") ||
    pathname.startsWith("/images/") ||
    pathname === "/favicon.ico" ||
    pathname === "/manifest.webmanifest" ||
    pathname === "/robots.txt"
}

self.addEventListener("fetch", event => {
  const request = event.request

  if (request.method !== "GET") {
    return
  }

  const url = new URL(request.url)

  if (url.origin !== self.location.origin || url.pathname.startsWith("/live/")) {
    return
  }

  if (request.mode === "navigate") {
    event.respondWith(
      fetch(request).catch(() => caches.match("/offline.html"))
    )

    return
  }

  if (!isStaticAsset(url.pathname)) {
    return
  }

  event.respondWith(
    caches.match(request).then(cachedResponse => {
      const networkResponse = fetch(request)
        .then(response => {
          if (response.ok) {
            const responseClone = response.clone()
            caches.open(STATIC_CACHE).then(cache => cache.put(request, responseClone))
          }

          return response
        })
        .catch(() => cachedResponse)

      return cachedResponse || networkResponse
    })
  )
})

const defaultNotification = {
  title: "Potok",
  body: "You have a new update.",
  icon: "/images/pwa/icon-192.png",
  badge: "/images/pwa/icon-192.png",
  url: "/",
}

const parseNotificationPayload = event => {
  if (!event.data) {
    return defaultNotification
  }

  try {
    return {...defaultNotification, ...event.data.json()}
  } catch (_error) {
    return {...defaultNotification, body: event.data.text()}
  }
}

self.addEventListener("push", event => {
  const payload = parseNotificationPayload(event)

  event.waitUntil(
    self.registration.showNotification(payload.title, {
      body: payload.body,
      icon: payload.icon,
      badge: payload.badge,
      tag: payload.tag,
      data: {
        url: payload.url || "/",
      },
    })
  )
})

self.addEventListener("notificationclick", event => {
  event.notification.close()

  const targetUrl = new URL(event.notification.data?.url || "/", self.location.origin).href

  event.waitUntil(
    self.clients.matchAll({type: "window", includeUncontrolled: true}).then(clients => {
      const existingClient = clients.find(client => client.url === targetUrl)

      if (existingClient) {
        return existingClient.focus()
      }

      return self.clients.openWindow(targetUrl)
    })
  )
})