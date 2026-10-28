const CACHE_VERSION = "potok-static-v3"
const STATIC_CACHE = CACHE_VERSION
const STATIC_CACHE_MAX_ENTRIES = 80
const STATIC_ASSETS = [
  "/offline.html",
  "/manifest.webmanifest",
  "/favicon.ico",
  "/images/logo.svg",
  "/images/pwa/icon.svg",
  "/images/pwa/icon-192.png",
]

// `phx.digest` file names (`app-<32 hex>.js`) never change content, so they
// are served from the cache without revalidation.
const DIGESTED_ASSET = /-[0-9a-f]{32}\.[a-z0-9]+$/

// A new worker waits until the page asks it to take over (see the update
// toast in app.js), so an update never reloads a page mid-typing.
self.addEventListener("install", event => {
  event.waitUntil(caches.open(STATIC_CACHE).then(cache => cache.addAll(STATIC_ASSETS)))
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

// Keys come back in insertion order, so the oldest entries go first.
const trimCache = async cache => {
  const keys = await cache.keys()
  const excess = keys.length - STATIC_CACHE_MAX_ENTRIES

  if (excess > 0) {
    await Promise.all(keys.slice(0, excess).map(key => cache.delete(key)))
  }
}

const putInCache = async (request, response) => {
  const cache = await caches.open(STATIC_CACHE)
  await cache.put(request, response)
  await trimCache(cache)
}

const cacheFirst = async (event, request) => {
  const cachedResponse = await caches.match(request)

  if (cachedResponse) {
    return cachedResponse
  }

  const response = await fetch(request)

  if (response.ok) {
    event.waitUntil(putInCache(request, response.clone()))
  }

  return response
}

const staleWhileRevalidate = async (event, request) => {
  const cachedResponse = await caches.match(request)

  const networkResponse = fetch(request)
    .then(response => {
      if (response.ok) {
        event.waitUntil(putInCache(request, response.clone()))
      }

      return response
    })
    .catch(() => cachedResponse)

  return cachedResponse || networkResponse
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
    DIGESTED_ASSET.test(url.pathname)
      ? cacheFirst(event, request)
      : staleWhileRevalidate(event, request)
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
