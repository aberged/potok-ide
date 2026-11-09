// The root's map (`RootMapTab`): every group with a place the viewer sees.
//
// The server does the counting. As the map moves, this asks for what lies in
// its view (`root_map_view`) and gets back single groups and clusters, a few
// hundred at most however many groups there are, gathered on a grid of cells
// about 64 pixels wide (`Social.list_map_cells/4`). A new filter sends the
// view again by itself (`root_map_data`).
//
// The server's grid is fixed, so markers of neighbouring cells that would
// cover each other on screen are joined here before they are drawn.
//
// A tap on a pin opens the group's sheet over the map (`root_map_open`); a
// tap on a cluster zooms in until it spreads, or lists its groups when they
// stand in one place (`root_map_spot`). The view is kept in the browser for
// the next visit.

// Leaflet 1.9's package names only its UMD build; the ESM one has named exports.
let leafletModule = null
const loadLeaflet = () =>
  leafletModule || (leafletModule = import("leaflet/dist/leaflet-src.esm.js"))

const VIEW_KEY = "potok:root-map-view"
const MOVE_DELAY_MS = 250
const PIN_SIZE = [32, 40]
const PIN_ANCHOR = [16, 39]
const FIT_PADDING = [48, 48]
const FIT_MAX_ZOOM = 16
const FALLBACK_COLOR = "#0a5bc4"
const DEFAULT_DROP = "M16 38.5C11 33 2 24 2 15a14 14 0 1 1 28 0c0 9-9 18-14 23.5Z"
const DEFAULT_GLYPH = "translate(7 6) scale(0.75)"

const escapeAttribute = value =>
  String(value)
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")

// A place's own icon while the catalogue has it, its kind's otherwise.
const lookOf = (place, pins) => {
  const kind =
    pins.kinds.find(row => row.key === place.kind) || pins.kinds.find(row => row.key === "none")
  const icon =
    place.pin && place.pin !== "picture" ? pins.icons.find(row => row.key === place.pin) : null
  const base = icon || kind
  const tone = base?.tone || "kind"

  return {
    color: pins.tones[tone] || FALLBACK_COLOR,
    paths: base?.paths || [],
    picture: place.pin === "picture" ? place.picture_url : null,
  }
}

let clipCounter = 0

// The drop in its tone with a white glyph, or the group's picture; a lock
// for a closed group. The same drawing as `PinIcons.pin/1`.
const pinSvg = (look, pins, locked) => {
  const drop = escapeAttribute(pins.drop || DEFAULT_DROP)
  const transform = escapeAttribute(pins.glyph_transform || DEFAULT_GLYPH)
  let inner

  if (look.picture) {
    const clip = `root-map-clip-${++clipCounter}`
    inner =
      `<defs><clipPath id="${clip}"><circle cx="16" cy="15" r="12"/></clipPath></defs>` +
      `<image href="${escapeAttribute(look.picture)}" x="4" y="3" width="24" height="24" ` +
      `preserveAspectRatio="xMidYMid slice" clip-path="url(#${clip})"/>`
  } else {
    const paths = look.paths
      .map(path => {
        const rule = path.evenodd ? ' fill-rule="evenodd" clip-rule="evenodd"' : ""
        return `<path d="${escapeAttribute(path.d)}"${rule}/>`
      })
      .join("")
    inner = `<g transform="${transform}" fill="#ffffff">${paths}</g>`
  }

  const lock = locked
    ? '<g><circle cx="26.5" cy="6.5" r="5.5" fill="#ffffff"/>' +
      '<rect x="23.9" y="6.3" width="5.2" height="3.9" rx="0.8" fill="#1f2937"/>' +
      '<path d="M24.9 6.4v-0.9a1.6 1.6 0 0 1 3.2 0v0.9" fill="none" stroke="#1f2937" stroke-width="1"/></g>'
    : ""

  return (
    `<svg viewBox="0 0 32 40" width="32" height="40" aria-hidden="true" focusable="false">` +
    `<path d="${drop}" fill="${escapeAttribute(look.color)}" stroke="#ffffff" stroke-width="1.75" stroke-linejoin="round"/>` +
    inner +
    lock +
    "</svg>"
  )
}

// A step of size for each order of magnitude.
const clusterSize = count => (count < 10 ? 36 : count < 100 ? 44 : count < 1000 ? 52 : 60)

const clusterText = count =>
  count >= 10_000 ? `${Math.floor(count / 1000)}k` : count >= 1000 ? `${(count / 1000).toFixed(1)}k` : String(count)

const readView = () => {
  try {
    const view = JSON.parse(window.localStorage.getItem(VIEW_KEY) || "null")

    if (
      view &&
      Number.isFinite(view.lat) &&
      Number.isFinite(view.lng) &&
      Number.isInteger(view.zoom) &&
      Math.abs(view.lat) <= 90
    ) {
      return view
    }
  } catch (_error) {}

  return null
}

const saveView = view => {
  try {
    window.localStorage.setItem(VIEW_KEY, JSON.stringify(view))
  } catch (_error) {}
}

export const RootMap = {
  mounted() {
    this.map = null
    this.L = null
    this.layer = null
    this.seq = 0
    this.timer = null
    this.markers = new Map()
    this.selectedId = null
    this.pins = JSON.parse(this.el.dataset.pins || "{}")
    this.maxZoom = Number(this.el.dataset.maxZoom) || 19

    this.handleEvent("root_map_data", data => this.draw(data))
    this.handleEvent("root_map_fit", ({bounds}) => this.fit(bounds))
    this.handleEvent("group_sheet_closed", () => this.select(null))

    this.resizer = new ResizeObserver(() => {
      if (this.el.offsetWidth === 0) return

      if (this.map) {
        this.map.invalidateSize()
      } else {
        void this.start()
      }
    })

    this.resizer.observe(this.el)
  },

  // The server forgot the view with the old socket.
  reconnected() {
    this.schedule(0)
  },

  destroyed() {
    clearTimeout(this.timer)
    this.resizer?.disconnect()
    this.map?.remove()
  },

  async start() {
    if (this.starting) return
    this.starting = true

    try {
      this.L = await loadLeaflet()
    } catch (_error) {
      this.el.textContent = this.el.dataset.loadError || ""
      this.starting = false
      return
    }

    const L = this.L
    this.map = L.map(this.el, {
      zoomControl: false,
      worldCopyJump: true,
      minZoom: 2,
      maxZoom: this.maxZoom,
    })
    this.map.attributionControl.setPrefix(
      '<a href="https://leafletjs.com" target="_blank" rel="noopener">Leaflet</a>'
    )
    L.control.zoom({position: "bottomright"}).addTo(this.map)

    L.tileLayer(this.el.dataset.tiles, {
      maxZoom: this.maxZoom,
      attribution: this.el.dataset.attribution,
    }).addTo(this.map)

    this.layer = L.layerGroup().addTo(this.map)

    const view = readView()

    if (view) {
      this.map.setView([view.lat, view.lng], Math.min(view.zoom, this.maxZoom))
    } else {
      this.map.fitBounds(JSON.parse(this.el.dataset.defaultBounds))
    }

    this.map.on("moveend", () => {
      const center = this.map.getCenter().wrap()
      saveView({lat: center.lat, lng: center.lng, zoom: this.map.getZoom()})
      this.schedule(MOVE_DELAY_MS)
    })

    this.schedule(0)
  },

  schedule(delay) {
    if (!this.map) return

    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.request(), delay)
  },

  // Only the newest answer is drawn: an older one may come after it.
  request() {
    const bounds = this.map.getBounds()
    const seq = ++this.seq
    const bbox = [bounds.getWest(), bounds.getSouth(), bounds.getEast(), bounds.getNorth()]

    this.pushEvent("root_map_view", {bbox, zoom: Math.round(this.map.getZoom())}, reply => {
      if (seq === this.seq && reply?.ok) this.draw(reply)
    })
  },

  // The server's cells are a fixed grid, so markers of neighbouring cells can
  // stand closer than they are wide. Those that would cover each other become
  // one cluster here, the biggest first, as supercluster does in the Map app.
  merge(places, clusters) {
    const items = [
      ...clusters.map(cluster => ({...cluster, size: clusterSize(cluster.count)})),
      ...places.map(place => ({
        count: 1,
        lat: place.lat,
        lng: place.lng,
        bounds: [
          [place.lat, place.lng],
          [place.lat, place.lng],
        ],
        size: PIN_SIZE[1],
        place,
      })),
    ]

    // A pin stands on its tip, so its drawing is centred half its height up.
    for (const item of items) {
      const point = this.map.latLngToLayerPoint([item.lat, item.lng])
      item.point = item.place ? point.subtract([0, PIN_ANCHOR[1] / 2]) : point
    }

    items.sort((a, b) => b.count - a.count)

    const taken = new Set()
    const merged = []

    items.forEach((base, index) => {
      if (taken.has(index)) return

      const near = [base]

      for (let other = index + 1; other < items.length; other++) {
        const item = items[other]

        if (!taken.has(other) && base.point.distanceTo(item.point) < (base.size + item.size) / 2) {
          near.push(item)
          taken.add(other)
        }
      }

      if (near.length === 1) {
        merged.push(base)
        return
      }

      const count = near.reduce((sum, item) => sum + item.count, 0)

      merged.push({
        count,
        lat: near.reduce((sum, item) => sum + item.lat * item.count, 0) / count,
        lng: near.reduce((sum, item) => sum + item.lng * item.count, 0) / count,
        bounds: [
          [Math.min(...near.map(i => i.bounds[0][0])), Math.min(...near.map(i => i.bounds[0][1]))],
          [Math.max(...near.map(i => i.bounds[1][0])), Math.max(...near.map(i => i.bounds[1][1]))],
        ],
      })
    })

    return {
      places: merged.filter(item => item.place).map(item => item.place),
      clusters: merged.filter(item => !item.place),
    }
  },

  draw(data) {
    if (!this.layer) return

    const {places, clusters} = this.merge(data.places || [], data.clusters || [])
    const L = this.L
    this.layer.clearLayers()
    this.markers = new Map()

    for (const cluster of clusters) {
      const size = clusterSize(cluster.count)
      const label = (this.el.dataset.clusterLabel || "%{count}").replace(
        "%{count}",
        String(cluster.count)
      )

      L.marker([cluster.lat, cluster.lng], {
        icon: L.divIcon({
          html:
            `<div class="potok-cluster" style="--cluster-size:${size}px" role="img" ` +
            `aria-label="${escapeAttribute(label)}"><span>${clusterText(cluster.count)}</span></div>`,
          className: "potok-cluster-icon",
          iconSize: [size, size],
        }),
        title: label,
        riseOnHover: true,
      })
        .on("click", () => this.openCluster(cluster))
        .addTo(this.layer)
    }

    for (const place of places) {
      const marker = L.marker([place.lat, place.lng], {
        icon: L.divIcon({
          html: pinSvg(lookOf(place, this.pins), this.pins, !place.is_public),
          className: "potok-pin potok-map-pin",
          iconSize: PIN_SIZE,
          iconAnchor: PIN_ANCHOR,
        }),
        title: place.name,
        alt: place.name,
        riseOnHover: true,
      })
        .on("click", () => this.select(place.id, true))
        .addTo(this.layer)

      this.markers.set(place.id, marker)
    }

    this.markSelected()
  },

  // A cluster spreads as the map zooms in; one that stands in one place, or
  // at the last zoom, shows its groups as a list.
  openCluster(cluster) {
    const [[south, west], [north, east]] = cluster.bounds
    const zoom = this.map.getZoom()

    if ((south === north && west === east) || zoom >= this.maxZoom) {
      this.pushEvent("root_map_spot", {bounds: cluster.bounds})
      return
    }

    const box = this.L.latLngBounds(cluster.bounds)
    const target = Math.min(
      this.maxZoom,
      Math.max(this.map.getBoundsZoom(box.pad(0.2)), zoom + 1)
    )

    this.map.flyTo(box.getCenter(), target, {duration: 0.4})
  },

  select(id, open = false) {
    this.selectedId = id
    this.markSelected()

    if (open && id !== null) this.pushEvent("root_map_open", {id})
  },

  markSelected() {
    for (const [id, marker] of this.markers) {
      marker.getElement()?.classList.toggle("is-selected", id === this.selectedId)
      marker.setZIndexOffset(id === this.selectedId ? 1000 : 0)
    }
  },

  fit(bounds) {
    if (!this.map || !Array.isArray(bounds)) return

    this.map.flyToBounds(bounds, {padding: FIT_PADDING, maxZoom: FIT_MAX_ZOOM, duration: 0.6})
  },
}
