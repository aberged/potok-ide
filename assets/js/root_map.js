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
//
// Areas (`GroupAreas`) lie under the pins: the view's answer names the areas
// wide enough to draw at its zoom, and their borders come once per level of
// detail (`root_map_shapes`) and stay in a cache here, so moving the map sends
// no border twice. An area that covers the whole view is drawn as its outline
// only. A drawn area keeps its pin, the same one it shows far out, on its own
// rather than in the clusters, and a tap on it opens the area's sheet like any
// pin. A tap on the map, off the pins, asks
// which areas stand there (`root_map_here`) and the server shows their card.
// While an area filter holds areas, everything outside them is dimmed. The
// layers (places, areas) are switched on the page and remembered here.

// Leaflet 1.9's package names only its UMD build; the ESM one has named exports.
let leafletModule = null
const loadLeaflet = () =>
  leafletModule || (leafletModule = import("leaflet/dist/leaflet-src.esm.js"))

const VIEW_KEY = "potok:root-map-view"
const LAYERS_KEY = "potok:root-map-layers"
const MOVE_DELAY_MS = 250
// A tap waits this long, so that a double tap zooms instead.
const TAP_DELAY_MS = 250
// The levels of detail borders come at (`GroupAreas.level/1`).
const LEVELS = [6, 8, 10, 12, 14, 16]
const SHAPES_PER_REQUEST = 100
const SHAPE_CACHE_LIMIT = 800
// A drawn area's pin stands over the other pins and clusters.
const AREA_PIN_Z = 500
// The whole world, around the holes of the chosen areas.
const WORLD_RING = [
  [-89.9, -540],
  [-89.9, 540],
  [89.9, 540],
  [89.9, -540],
]
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

const readLayers = () => {
  try {
    const layers = JSON.parse(window.localStorage.getItem(LAYERS_KEY) || "null")

    if (layers && typeof layers.places === "boolean" && typeof layers.areas === "boolean") {
      return {places: layers.places, areas: layers.areas}
    }
  } catch (_error) {}

  return {places: true, areas: true}
}

const saveLayers = layers => {
  try {
    window.localStorage.setItem(LAYERS_KEY, JSON.stringify(layers))
  } catch (_error) {}
}

const levelFor = zoom => LEVELS.find(level => level >= zoom) ?? LEVELS[LEVELS.length - 1]

const shapeKey = (id, version, level) => `${id}:${version}:${level}`

// A GeoJSON (Multi)Polygon as Leaflet's nested [lat, lng] lists.
const toLatLngs = geojson => {
  const polygons = geojson.type === "Polygon" ? [geojson.coordinates] : geojson.coordinates || []
  return polygons.map(rings => rings.map(ring => ring.map(([lng, lat]) => [lat, lng])))
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
    this.layers = readLayers()
    this.areas = []
    this.chosen = []
    this.shapes = new Map()
    this.pendingShapes = new Set()
    this.areaPaths = new Map()
    this.areaMarkers = new Map()
    this.selectedAreaId = null

    this.handleEvent("root_map_data", data => this.draw(data))
    this.handleEvent("root_map_fit", ({bounds}) => this.fit(bounds))
    this.handleEvent("group_sheet_closed", () => this.select(null))
    this.handleEvent("root_map_select_area", ({id}) => this.selectArea(id))
    this.handleEvent("root_map_layers", layers => {
      this.layers = {places: layers.places === true, areas: layers.areas === true}
      saveLayers(this.layers)
    })

    this.resizer = new ResizeObserver(() => {
      if (this.el.offsetWidth === 0) return

      if (this.map) {
        this.map.invalidateSize()
      } else {
        void this.start()
      }
    })

    this.resizer.observe(this.el)

    // The page renders a card over the map's bottom (`#root-map-here`, the
    // groups of a spot): Leaflet's zoom buttons and the attribution move up
    // above it rather than hide under it.
    this.box = this.el.closest("#root-map-wrap")?.parentElement
    this.coverWatch = new MutationObserver(() => this.liftControls())
    if (this.box) this.coverWatch.observe(this.box, {childList: true, subtree: true})
    this.liftControls()
  },

  liftControls() {
    const cover = this.box?.querySelector(":scope > #root-map-here, :scope > #root-map-spot")
    const lift = cover ? `${cover.offsetHeight + 8}px` : "0px"
    if (this.el.style.getPropertyValue("--map-cover") !== lift) this.el.style.setProperty("--map-cover", lift)
  },

  // The server forgot the view with the old socket.
  reconnected() {
    this.schedule(0)
  },

  destroyed() {
    clearTimeout(this.timer)
    clearTimeout(this.tapTimer)
    this.coverWatch?.disconnect()
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

    // Areas under the pins, the dimming around the chosen ones above them,
    // and the chosen borders above that.
    for (const [name, zIndex] of [
      ["potokAreas", 350],
      ["potokAreaMask", 360],
      ["potokAreaChosen", 370],
    ]) {
      this.map.createPane(name).style.zIndex = String(zIndex)
    }

    this.areaRenderer = L.svg({pane: "potokAreas", padding: 0.5})
    this.maskRenderer = L.svg({pane: "potokAreaMask", padding: 0.5})
    this.chosenRenderer = L.svg({pane: "potokAreaChosen", padding: 0.5})
    this.areaLayer = L.layerGroup().addTo(this.map)
    this.maskLayer = L.layerGroup().addTo(this.map)
    this.chosenLayer = L.layerGroup().addTo(this.map)
    this.areaPinLayer = L.layerGroup().addTo(this.map)
    this.layer = L.layerGroup().addTo(this.map)

    // A tap off the pins: the areas there. Pins keep their taps.
    this.map.on("click", event => {
      clearTimeout(this.tapTimer)
      this.tapTimer = setTimeout(() => this.tapAt(event.latlng), TAP_DELAY_MS)
    })
    this.map.on("dblclick zoomstart", () => clearTimeout(this.tapTimer))

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

    this.pushEvent(
      "root_map_view",
      {bbox, zoom: Math.round(this.map.getZoom()), layers: this.layers},
      reply => {
        if (seq === this.seq && reply?.ok) this.draw(reply)
      }
    )
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

    if (data.layers) {
      this.layers = {places: data.layers.places === true, areas: data.layers.areas === true}
      saveLayers(this.layers)
    }

    this.areas = data.areas || []
    this.chosen = data.chosen || []
    this.drawAreas()
    this.fetchShapes()

    if (Array.isArray(data.fit)) this.fit(data.fit)

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
    for (const markers of [this.markers, this.areaMarkers]) {
      for (const [id, marker] of markers) {
        marker.getElement()?.classList.toggle("is-selected", id === this.selectedId)
        marker.setZIndexOffset(id === this.selectedId ? 1000 : marker.options.baseZ || 0)
      }
    }
  },

  fit(bounds) {
    if (!this.map || !Array.isArray(bounds)) return

    this.map.flyToBounds(bounds, {padding: FIT_PADDING, maxZoom: FIT_MAX_ZOOM, duration: 0.6})
  },

  // The areas there, smallest first; the server shows their card.
  tapAt(latlng) {
    if (!this.layers.areas) return

    const zoom = Math.round(this.map.getZoom())

    this.pushEvent("root_map_here", {lat: latlng.lat, lng: latlng.lng, zoom}, reply =>
      this.selectArea(reply?.ids?.[0] ?? null)
    )
  },

  // The border of an area at this zoom's level of detail, or at another
  // level of the same version while that one is on its way.
  shapeOf(area) {
    const level = levelFor(Math.round(this.map.getZoom()))
    const exact = this.shapes.get(shapeKey(area.id, area.v, level))
    if (exact) return exact

    const nearest = [...LEVELS].sort((a, b) => Math.abs(a - level) - Math.abs(b - level))

    for (const other of nearest) {
      const shape = this.shapes.get(shapeKey(area.id, area.v, other))
      if (shape) return shape
    }

    return null
  },

  // Asks for the borders this zoom lacks, a hundred at a time.
  fetchShapes() {
    if (!this.map) return

    const zoom = Math.round(this.map.getZoom())
    const level = levelFor(zoom)
    const missing = this.areas.filter(area => {
      const key = shapeKey(area.id, area.v, level)
      return !this.shapes.has(key) && !this.pendingShapes.has(key)
    })

    for (let start = 0; start < missing.length; start += SHAPES_PER_REQUEST) {
      const batch = missing.slice(start, start + SHAPES_PER_REQUEST)
      const keys = batch.map(area => shapeKey(area.id, area.v, level))
      keys.forEach(key => this.pendingShapes.add(key))

      this.pushEvent("root_map_shapes", {ids: batch.map(area => area.id), zoom}, reply => {
        keys.forEach(key => this.pendingShapes.delete(key))
        if (!reply?.ok) return

        for (const shape of reply.shapes || []) {
          this.shapes.set(shapeKey(shape.id, shape.v, reply.level), shape.geojson)
        }

        while (this.shapes.size > SHAPE_CACHE_LIMIT) {
          this.shapes.delete(this.shapes.keys().next().value)
        }

        this.drawAreas()
      })
    }
  },

  drawAreas() {
    if (!this.areaLayer) return

    const L = this.L
    this.areaLayer.clearLayers()
    this.maskLayer.clearLayers()
    this.chosenLayer.clearLayers()
    this.areaPaths = new Map()

    const view = this.map.getBounds()
    const holes = []

    // Biggest first, as they come, so that smaller areas lie on top.
    for (const area of this.areas) {
      const shape = this.shapeOf(area)
      if (!shape) continue

      const latlngs = toLatLngs(shape)
      const [west, south, east, north] = area.bbox
      const covers =
        west <= view.getWest() &&
        east >= view.getEast() &&
        south <= view.getSouth() &&
        north >= view.getNorth()
      const color = lookOf(area, this.pins).color
      const chosen = this.chosen.includes(area.id)

      const path = L.polygon(latlngs, {
        pane: "potokAreas",
        renderer: this.areaRenderer,
        color,
        fillColor: color,
        weight: 2,
        className: covers ? "potok-area is-outline" : "potok-area",
      }).addTo(this.areaLayer)

      this.areaPaths.set(area.id, path)

      if (chosen) {
        holes.push(...latlngs.map(rings => rings[0]))

        L.polygon(latlngs, {
          pane: "potokAreaChosen",
          renderer: this.chosenRenderer,
          color,
          weight: 3,
          fill: false,
          interactive: false,
          className: "potok-area-chosen",
        }).addTo(this.chosenLayer)
      }
    }

    if (holes.length > 0) {
      L.polygon([WORLD_RING, ...holes], {
        pane: "potokAreaMask",
        renderer: this.maskRenderer,
        stroke: false,
        interactive: false,
        className: "potok-area-mask",
      }).addTo(this.maskLayer)
    }

    this.drawAreaPins()
    this.markAreaSelected()
  },

  // The pins of the areas drawn as borders: the server leaves them out of the
  // clusters, and they stand here even before a border arrives, over the
  // other pins.
  drawAreaPins() {
    const L = this.L
    this.areaPinLayer.clearLayers()
    this.areaMarkers = new Map()

    for (const area of this.areas) {
      const marker = L.marker([area.lat, area.lng], {
        icon: L.divIcon({
          html: pinSvg(lookOf(area, this.pins), this.pins, !area.is_public),
          className: "potok-pin potok-map-pin",
          iconSize: PIN_SIZE,
          iconAnchor: PIN_ANCHOR,
        }),
        title: area.name,
        alt: area.name,
        riseOnHover: true,
        zIndexOffset: AREA_PIN_Z,
        baseZ: AREA_PIN_Z,
      })
        .on("click", () => this.select(area.id, true))
        .addTo(this.areaPinLayer)

      this.areaMarkers.set(area.id, marker)
    }

    this.markSelected()
  },

  selectArea(id) {
    this.selectedAreaId = id
    this.markAreaSelected()
  },

  markAreaSelected() {
    for (const [id, path] of this.areaPaths) {
      path.getElement()?.classList.toggle("is-selected", id === this.selectedAreaId)
      if (id === this.selectedAreaId) path.bringToFront()
    }
  },
}
