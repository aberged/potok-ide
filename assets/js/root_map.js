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
// An area (`GroupAreas`) is only the shape of a group the filters keep: its
// pin is one of the pins, in the clusters like any other, and the view's
// answer also names the areas wide enough at its zoom (two pins wide) to show
// their borders under the pins. Borders come once per level of detail
// (`root_map_shapes`) and stay in a cache here, so moving the map sends no
// border twice. An area that covers the whole view is drawn as its outline
// only. A tap on the map, off the pins, asks which areas stand there
// (`root_map_here`) and the server shows their card. The chosen areas of the
// area filter come marked `ctx`: an outline at any zoom and whatever the
// filters, with everything outside them dimmed.
//
// A route (`GroupRoutes`) is the same: its pin, at its start, is one of the
// pins, and once it is wide enough its line is drawn over the areas, in the
// tone of its pin over a casing, with a ring at its end. Lines come and stay
// like borders. A wider line nobody sees takes a tap on the route, which
// opens its sheet as its pin does. The route of a `?route=` link comes
// marked `ctx`, drawn whatever the filters.
//
// A link to one group's place (`?place=`) or to a calendar event's
// (`?event=`) comes as `focus` in every answer, nil when there is none: its
// pin is drawn whatever the filters, over the others, with a ring at its tip;
// a focused group's area or route also comes marked `ctx`. An event's own
// area or route comes as a key; its shape is asked for once
// (`root_map_focus_shape`), kept here, and drawn like a chosen area (an
// outline over the dimmed world) or a chosen route. A tap on the pin, or on
// the event's route, brings back the event's card (`root_map_focus_show`); on
// a group's pin it opens the group.
//
// The layers (places, areas, routes) are switched on the page and remembered
// here.
//
// Markers and borders are kept by what they show, so a new answer only adds
// what is new and takes away what is gone.

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
// Markers closer than their half sizes and this much more become one, so
// that none stands against another.
const MERGE_GAP = 8
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
const DEFAULT_MARK = "translate(22.75 2.75) scale(0.46875)"

const escapeAttribute = value =>
  String(value)
    .replace(/&/g, "&amp;")
    .replace(/"/g, "&quot;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")

// A place's own icon while the catalogue has it, its kind's otherwise. A pin
// of its own keeps the kind's mark, as `PinIcons.look/1` does.
const lookOf = (place, pins) => {
  const kind =
    pins.kinds.find(row => row.key === place.kind) || pins.kinds.find(row => row.key === "none")
  const icon =
    place.pin && place.pin !== "picture" ? pins.icons.find(row => row.key === place.pin) : null
  const base = icon || kind
  const tone = base?.tone || "kind"
  const own = Boolean(icon) || place.pin === "picture"

  return {
    tone,
    color: pins.tones[tone] || FALLBACK_COLOR,
    paths: base?.paths || [],
    picture: place.pin === "picture" ? place.picture_url : null,
    mark: own ? kind?.mark || null : null,
  }
}

const glyphPaths = paths =>
  paths
    .map(path => {
      const rule = path.evenodd ? ' fill-rule="evenodd" clip-rule="evenodd"' : ""
      return `<path d="${escapeAttribute(path.d)}"${rule}/>`
    })
    .join("")

// The cluster's ring: one arc per tone, as long as its share of the groups,
// in the order of the catalogue's tones. The same drawing as the Map app's
// (potok-mapa `src/places.ts`, `ringGradient`).
const ringGradient = (counts, tones) => {
  const total = Object.values(counts).reduce((sum, count) => sum + count, 0)
  if (total === 0) return FALLBACK_COLOR

  const order = [...Object.keys(tones), ...Object.keys(counts).filter(tone => !(tone in tones))]
  const stops = []
  let start = 0

  for (const tone of order) {
    const count = counts[tone] || 0
    if (count === 0) continue

    const end = start + (count / total) * 360
    stops.push(`${tones[tone] || FALLBACK_COLOR} ${start.toFixed(2)}deg ${end.toFixed(2)}deg`)
    start = end
  }

  return stops.length === 1 ? stops[0].split(" ")[0] : `conic-gradient(${stops.join(", ")})`
}

const addTones = (into, tones) => {
  for (const [tone, count] of Object.entries(tones || {})) into[tone] = (into[tone] || 0) + count
  return into
}

let clipCounter = 0

// The drop in its tone with a white glyph, or the group's picture; a lock
// at the top left for a closed group and the kind's mark at the top right for
// a picked pin, as the avatar has them. The same drawing as `PinIcons.pin/1`.
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
    inner = `<g transform="${transform}" fill="#ffffff">${glyphPaths(look.paths)}</g>`
  }

  const lock = locked
    ? '<g data-pin-lock><circle cx="5.5" cy="6.5" r="5.5" fill="#ffffff"/>' +
      '<rect x="2.9" y="6.3" width="5.2" height="3.9" rx="0.8" fill="#1f2937"/>' +
      '<path d="M3.9 6.4v-0.9a1.6 1.6 0 0 1 3.2 0v0.9" fill="none" stroke="#1f2937" stroke-width="1"/></g>'
    : ""

  const mark = look.mark
    ? '<g data-pin-mark><circle cx="26.5" cy="6.5" r="5.5" fill="#ffffff"/>' +
      `<g transform="${escapeAttribute(pins.mark_transform || DEFAULT_MARK)}" ` +
      `fill="${escapeAttribute(pins.tones.kind || FALLBACK_COLOR)}">${glyphPaths(look.mark)}</g></g>`
    : ""

  return (
    `<svg viewBox="0 0 32 40" width="32" height="40" aria-hidden="true" focusable="false">` +
    `<path d="${drop}" fill="${escapeAttribute(look.color)}" stroke="#ffffff" stroke-width="1.75" stroke-linejoin="round"/>` +
    inner +
    lock +
    mark +
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
      // Remembered before routes were a layer: routes shown.
      const routes = typeof layers.routes === "boolean" ? layers.routes : true
      return {places: layers.places, areas: layers.areas, routes}
    }
  } catch (_error) {}

  return {places: true, areas: true, routes: true}
}

const layersOf = layers => ({
  places: layers.places === true,
  areas: layers.areas === true,
  routes: layers.routes === true,
})

const saveLayers = layers => {
  try {
    window.localStorage.setItem(LAYERS_KEY, JSON.stringify(layers))
  } catch (_error) {}
}

const levelFor = zoom => LEVELS.find(level => level >= zoom) ?? LEVELS[LEVELS.length - 1]

// What a pin shows, so that one showing the same stays on the map.
const placeKey = (prefix, place) =>
  [prefix, place.id, place.lat, place.lng, place.pin, place.kind, place.is_public, place.picture_url].join(":")

// Keeps the layers of `drawn` (key => layer) whose key `next` (key => make)
// still has, takes the others off `group` and adds the new ones. Returns the
// markers by the place id they carry.
const sync = (drawn, next, group) => {
  for (const [key, layer] of drawn) {
    if (!next.has(key)) {
      group.removeLayer(layer)
      drawn.delete(key)
    }
  }

  for (const [key, make] of next) {
    if (!drawn.has(key)) drawn.set(key, make().addTo(group))
  }

  const byId = new Map()

  for (const layer of drawn.values()) {
    if (layer.options?.placeId !== undefined) byId.set(layer.options.placeId, layer)
  }

  return byId
}

const shapeKey = (id, version, level) => `${id}:${version}:${level}`

// A GeoJSON (Multi)Polygon as Leaflet's nested [lat, lng] lists.
const toLatLngs = geojson => {
  const polygons = geojson.type === "Polygon" ? [geojson.coordinates] : geojson.coordinates || []
  return polygons.map(rings => rings.map(ring => ring.map(([lng, lat]) => [lat, lng])))
}

// A GeoJSON (Multi)LineString as Leaflet's [lat, lng] lists, one per part.
const lineLatLngs = geojson => {
  const lines = geojson.type === "LineString" ? [geojson.coordinates] : geojson.coordinates || []
  return lines.filter(line => line.length >= 2).map(line => line.map(([lng, lat]) => [lat, lng]))
}

export const RootMap = {
  mounted() {
    this.map = null
    this.L = null
    this.layer = null
    this.seq = 0
    this.timer = null
    this.markers = new Map()
    this.drawnMarkers = new Map()
    this.drawnPaths = new Map()
    this.selectedId = null
    this.pins = JSON.parse(this.el.dataset.pins || "{}")
    this.maxZoom = Number(this.el.dataset.maxZoom) || 19
    this.layers = readLayers()
    this.areas = []
    this.chosen = []
    this.shapes = new Map()
    this.pendingShapes = new Set()
    this.areaPaths = new Map()
    this.selectedAreaId = null
    this.routes = []
    this.drawnRoutes = new Map()
    this.routePaths = new Map()
    this.focusKey = null
    // The event's own area or route in focus: {key, kind, geojson}.
    this.focusShape = null

    this.handleEvent("root_map_data", data => this.draw(data))
    this.handleEvent("root_map_fit", ({bounds}) => this.fit(bounds))
    this.handleEvent("group_sheet_closed", () => this.select(null))
    this.handleEvent("root_map_select_area", ({id}) => this.selectArea(id))
    this.handleEvent("root_map_layers", layers => {
      this.layers = layersOf(layers)
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
    // groups of a spot, an event in focus): Leaflet's zoom buttons and the
    // attribution move up above it rather than hide under it.
    this.box = this.el.closest("#root-map-wrap")?.parentElement
    this.coverSize = new ResizeObserver(() => this.liftControls())
    this.coverWatch = new MutationObserver(() => this.liftControls())
    if (this.box) this.coverWatch.observe(this.box, {childList: true})
    this.liftControls()
  },

  liftControls() {
    const cover = this.box?.querySelector(
      ":scope > #root-map-here, :scope > #root-map-spot, :scope > #root-map-focus, :scope > #root-map-error"
    )

    if (cover !== this.cover) {
      if (this.cover) this.coverSize.unobserve(this.cover)
      if (cover) this.coverSize.observe(cover)
      this.cover = cover
    }

    const lift = cover ? `${cover.offsetHeight + 8}px` : "0px"
    if (this.el.style.getPropertyValue("--map-cover") !== lift) this.el.style.setProperty("--map-cover", lift)
  },

  // The server forgot the view with the old socket.
  reconnected() {
    this.pendingShapes.clear()
    this.schedule(0)
  },

  destroyed() {
    clearTimeout(this.timer)
    clearTimeout(this.tapTimer)
    this.coverWatch?.disconnect()
    this.coverSize?.disconnect()
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
    // the chosen borders above that, and routes over all of them, still
    // under the pins.
    for (const [name, zIndex] of [
      ["potokAreas", 350],
      ["potokAreaMask", 360],
      ["potokAreaChosen", 370],
      ["potokRoutes", 380],
    ]) {
      this.map.createPane(name).style.zIndex = String(zIndex)
    }

    this.areaRenderer = L.svg({pane: "potokAreas", padding: 0.5})
    this.maskRenderer = L.svg({pane: "potokAreaMask", padding: 0.5})
    this.chosenRenderer = L.svg({pane: "potokAreaChosen", padding: 0.5})
    this.routeRenderer = L.svg({pane: "potokRoutes", padding: 0.5})
    this.areaLayer = L.layerGroup().addTo(this.map)
    this.maskLayer = L.layerGroup().addTo(this.map)
    this.chosenLayer = L.layerGroup().addTo(this.map)
    this.routeLayer = L.layerGroup().addTo(this.map)
    this.layer = L.layerGroup().addTo(this.map)
    this.focusLayer = L.layerGroup().addTo(this.map)

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
  // stand closer than they are wide. Those that would cover or touch each
  // other become one cluster here, the biggest first, as supercluster does in
  // the Map app.
  merge(places, clusters) {
    const items = [
      ...clusters.map(cluster => ({...cluster, tones: cluster.tones || {}, size: clusterSize(cluster.count)})),
      ...places.map(place => ({
        count: 1,
        lat: place.lat,
        lng: place.lng,
        bounds: [
          [place.lat, place.lng],
          [place.lat, place.lng],
        ],
        tones: {[lookOf(place, this.pins).tone]: 1},
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

        if (
          !taken.has(other) &&
          base.point.distanceTo(item.point) < (base.size + item.size) / 2 + MERGE_GAP
        ) {
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
        tones: near.reduce((sum, item) => addTones(sum, item.tones), {}),
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
      this.layers = layersOf(data.layers)
      saveLayers(this.layers)
    }

    this.areas = data.areas || []
    this.routes = data.routes || []
    this.chosen = data.chosen || []
    this.drawAreas()
    this.drawRoutes()
    this.fetchShapes()

    if (Array.isArray(data.fit)) this.fit(data.fit)

    const {places, clusters} = this.merge(data.places || [], data.clusters || [])
    const L = this.L
    const next = new Map()

    for (const cluster of clusters) {
      const ring = ringGradient(cluster.tones || {}, this.pins.tones || {})
      const key = `c:${cluster.lat}:${cluster.lng}:${cluster.count}:${ring}`

      next.set(key, () => {
        const size = clusterSize(cluster.count)
        const label = (this.el.dataset.clusterLabel || "%{count}").replace(
          "%{count}",
          String(cluster.count)
        )

        return L.marker([cluster.lat, cluster.lng], {
          icon: L.divIcon({
            html:
              `<div class="potok-cluster" style="--cluster-size:${size}px;--cluster-ring:${escapeAttribute(ring)}" ` +
              `role="img" aria-label="${escapeAttribute(label)}"><span>${clusterText(cluster.count)}</span></div>`,
            className: "potok-cluster-icon",
            iconSize: [size, size],
          }),
          title: label,
          riseOnHover: true,
        }).on("click", () => this.openCluster(cluster))
      })
    }

    for (const place of places) {
      next.set(placeKey("p", place), () =>
        L.marker([place.lat, place.lng], {
          icon: L.divIcon({
            html: pinSvg(lookOf(place, this.pins), this.pins, !place.is_public),
            className: "potok-pin potok-map-pin",
            iconSize: PIN_SIZE,
            iconAnchor: PIN_ANCHOR,
          }),
          title: place.name,
          alt: place.name,
          riseOnHover: true,
          placeId: place.id,
        }).on("click", () => this.select(place.id, true))
      )
    }

    this.markers = sync(this.drawnMarkers, next, this.layer)
    this.markSelected()
    this.drawFocus(data.focus || null)
  },

  // The place of a link, whatever the filters: its pin over the others, with
  // a ring at its tip, drawn again only when it shows something else.
  drawFocus(focus) {
    this.syncFocusShape(focus?.shape || null)

    const key = focus ? `${placeKey("f", focus)}:${focus.event ? "event" : "group"}` : null
    if (key === this.focusKey) return

    this.focusKey = key
    this.focusLayer.clearLayers()
    if (!focus) return

    const L = this.L

    L.marker([focus.lat, focus.lng], {
      icon: L.divIcon({
        html:
          '<span class="potok-focus-ring" aria-hidden="true"></span>' +
          pinSvg(lookOf(focus, this.pins), this.pins, !focus.is_public),
        className: "potok-pin potok-map-pin is-focus",
        iconSize: PIN_SIZE,
        iconAnchor: PIN_ANCHOR,
      }),
      title: focus.name,
      alt: focus.name,
      zIndexOffset: 2000,
    })
      .on("click", () => {
        if (focus.event) {
          this.pushEvent("root_map_focus_show", {})
        } else {
          this.select(focus.id, true)
        }
      })
      .addTo(this.focusLayer)
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

    for (const [id, route] of this.routePaths) {
      route.line.getElement()?.classList.toggle("is-selected", id === this.selectedId)
      if (id === this.selectedId) route.bringToFront()
    }
  },

  fit(bounds) {
    if (!this.map || !Array.isArray(bounds)) return

    this.map.flyToBounds(bounds, {padding: FIT_PADDING, maxZoom: FIT_MAX_ZOOM, duration: 0.6})
  },

  // The event's own area or route: asked for once, kept by its key, drawn
  // with the areas and the routes once it is here.
  syncFocusShape(shape) {
    if (!shape) {
      if (this.focusShape) {
        this.focusShape = null
        this.drawAreas()
        this.drawRoutes()
      }
      return
    }

    if (this.focusShape?.key === shape.key) return

    this.focusShape = {key: shape.key, kind: shape.kind, geojson: null}

    this.pushEvent("root_map_focus_shape", {}, reply => {
      if (!reply?.ok || this.focusShape?.key !== reply.key) return

      this.focusShape.geojson = reply.geojson
      this.drawAreas()
      this.drawRoutes()
    })
  },

  // The colour of an event's own shape: its pin's.
  eventColor() {
    return lookOf({kind: "none", pin: "event"}, this.pins).color
  },

  // The areas there, smallest first; the server shows their card.
  tapAt(latlng) {
    if (!this.layers.areas) return

    const zoom = Math.round(this.map.getZoom())

    this.pushEvent("root_map_here", {lat: latlng.lat, lng: latlng.lng, zoom}, reply =>
      this.selectArea(reply?.ids?.[0] ?? null)
    )
  },

  // The border of an area, or the line of a route, at this zoom's level of
  // detail, or at another level of the same version while that one is on its
  // way.
  shapeOf(area) {
    const level = levelFor(Math.round(this.map.getZoom()))
    const nearest = [...LEVELS].sort((a, b) => Math.abs(a - level) - Math.abs(b - level))

    for (const other of nearest) {
      const key = shapeKey(area.id, area.v, other)
      const shape = this.shapes.get(key)

      if (shape) {
        this.shapes.delete(key)
        this.shapes.set(key, shape)
        return {shape, key}
      }
    }

    return null
  },

  // Asks for the borders and lines this zoom lacks, a hundred at a time.
  fetchShapes() {
    if (!this.map) return

    const zoom = Math.round(this.map.getZoom())
    const level = levelFor(zoom)
    const missing = [...this.areas, ...this.routes].filter(area => {
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
        this.drawRoutes()
      })
    }
  },

  drawAreas() {
    if (!this.areaLayer) return

    const L = this.L
    const view = this.map.getBounds()
    const next = new Map()
    const chosenNext = new Map()
    const holes = []
    this.areaPaths = new Map()

    // Biggest first, as they come, so that smaller areas lie on top.
    for (const area of this.areas) {
      const found = this.shapeOf(area)
      if (!found) continue

      const latlngs = toLatLngs(found.shape)
      const color = lookOf(area, this.pins).color

      if (area.ctx) {
        holes.push(...latlngs.map(rings => rings[0]))

        chosenNext.set(`${found.key}:${color}`, () =>
          L.polygon(latlngs, {
            pane: "potokAreaChosen",
            renderer: this.chosenRenderer,
            color,
            weight: 3,
            fill: false,
            interactive: false,
            className: "potok-area-chosen",
          })
        )

        continue
      }

      const [west, south, east, north] = area.bbox
      const covers =
        west <= view.getWest() &&
        east >= view.getEast() &&
        south <= view.getSouth() &&
        north >= view.getNorth()

      next.set(`${found.key}:${color}:${covers}`, () =>
        L.polygon(latlngs, {
          pane: "potokAreas",
          renderer: this.areaRenderer,
          color,
          fillColor: color,
          weight: 2,
          className: covers ? "potok-area is-outline" : "potok-area",
          placeId: area.id,
        })
      )
    }

    // The event's own area, outlined like a chosen one.
    if (this.focusShape?.kind === "area" && this.focusShape.geojson) {
      const latlngs = toLatLngs(this.focusShape.geojson)
      holes.push(...latlngs.map(rings => rings[0]))

      chosenNext.set(`focus:${this.focusShape.key}`, () =>
        L.polygon(latlngs, {
          pane: "potokAreaChosen",
          renderer: this.chosenRenderer,
          color: this.eventColor(),
          weight: 3,
          fill: false,
          interactive: false,
          className: "potok-area-chosen",
        })
      )
    }

    this.areaPaths = sync(this.drawnPaths, next, this.areaLayer)
    this.drawnChosen = this.drawnChosen || new Map()
    sync(this.drawnChosen, chosenNext, this.chosenLayer)

    const maskKey = [...chosenNext.keys()].join("|")

    if (maskKey !== this.maskKey) {
      this.maskKey = maskKey
      this.maskLayer.clearLayers()

      if (holes.length > 0) {
        L.polygon([WORLD_RING, ...holes], {
          pane: "potokAreaMask",
          renderer: this.maskRenderer,
          stroke: false,
          interactive: false,
          className: "potok-area-mask",
        }).addTo(this.maskLayer)
      }
    }

    this.markAreaSelected()
  },

  // The lines of the routes, widest first as they come, so shorter ones lie
  // on top. Each is one group of paths: the casing, the line, the line that
  // takes a tap, and the ring at its end (none for a loop).
  drawRoutes() {
    if (!this.routeLayer) return

    const next = new Map()

    for (const route of this.routes) {
      const found = this.shapeOf(route)
      if (!found) continue

      const lines = lineLatLngs(found.shape)
      if (lines.length === 0) continue

      const color = lookOf(route, this.pins).color
      next.set(`${found.key}:${color}:${route.ctx ? "ctx" : ""}`, () => this.routeShape(route, lines, color))
    }

    // The event's own route, drawn like the route of a link.
    if (this.focusShape?.kind === "route" && this.focusShape.geojson) {
      const lines = lineLatLngs(this.focusShape.geojson)
      const color = this.eventColor()

      if (lines.length > 0) {
        next.set(`focus:${this.focusShape.key}:${color}`, () =>
          this.routeShape({ctx: true, event: true}, lines, color)
        )
      }
    }

    this.routePaths = sync(this.drawnRoutes, next, this.routeLayer)
    this.markSelected()
  },

  routeShape(route, lines, color) {
    const L = this.L
    const common = {pane: "potokRoutes", renderer: this.routeRenderer, lineCap: "round", lineJoin: "round"}
    const last = lines[lines.length - 1]
    const start = lines[0][0]
    const end = last[last.length - 1]

    const casing = L.polyline(lines, {
      ...common,
      color: "#ffffff",
      weight: 6.5,
      interactive: false,
      className: "potok-route-casing",
    })

    const line = L.polyline(lines, {
      ...common,
      color,
      weight: 3.5,
      interactive: false,
      className: route.ctx ? "potok-route is-chosen" : "potok-route",
    })

    // Wide enough for a finger; a tap here is not a tap on the map.
    const hit = L.polyline(lines, {
      ...common,
      color,
      opacity: 0,
      weight: 18,
      bubblingMouseEvents: false,
      className: "potok-route-hit",
    }).on("click", () => {
      if (route.event) {
        this.pushEvent("root_map_focus_show", {})
      } else {
        this.select(route.id, true)
      }
    })

    const parts = [casing, line, hit]

    if (start[0] !== end[0] || start[1] !== end[1]) {
      parts.push(
        L.circleMarker(end, {
          ...common,
          radius: 4.5,
          color,
          weight: 2.5,
          fillColor: "#ffffff",
          fillOpacity: 1,
          interactive: false,
          className: "potok-route-end",
        })
      )
    }

    // An event's route is no group's: nothing selects it.
    const group = L.featureGroup(parts, route.event ? {} : {placeId: route.id})
    group.line = line
    return group
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
