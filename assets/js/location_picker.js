// The map of the "Location" card in a group's settings. A group stands on the
// map as a point, as an area or as a route.
//
// A point: a tap or a drag puts the group's pin, the two number fields
// follow, and typing in them moves the pin. The pin looks like the one chosen
// below the map.
//
// An area: the border is drawn on the map (`AreaEditor`) or comes from a
// GeoJSON file. It does not go through the form, which sends every field with
// each key typed: the card sends it on its own (`edit_group_area`), the
// server checks it and answers with the area's pin, a point inside it, which
// this writes into the number fields.
//
// A route: the line is drawn on the map (`RouteEditor`) or comes from a GPX,
// KML or GeoJSON file (`route_files.js`), and goes on its own as well
// (`edit_group_route`); the server answers with its start, where the pin
// goes, and its length.
//
// Which mode shows is the server's (`location_mode`); `location_reset` puts
// back what is saved.
//
// Leaflet loads the first time the card shows (a hidden card has no size to
// draw in). Tiles come from Potok (`/tiles`, `PotokIde.MapTiles`).
//
// The fields belong to the group's form: writing them fires one `input`, so
// the form's `phx-change` sends them as if typed. They have no `phx-debounce`,
// which would lose a value written here during its wait.

import {
  AreaEditor,
  MAX_POINTS,
  areasInGeoJSON,
  isGeographic,
  pointCount,
  polygonsOf,
  simplifyPolygons,
} from "./area_editor"
import {RouteEditor} from "./route_editor"
import {cleanLines, isGeographicLines, linePointCount, linesOf, routesInFile, simplifyLines} from "./route_files"

// Leaflet 1.9's package names only its UMD build; the ESM one has named exports.
let leafletModule = null
const loadLeaflet = () =>
  leafletModule || (leafletModule = import("leaflet/dist/leaflet-src.esm.js"))

const PLACE_ZOOM = 15
const PIN_SIZE = [32, 40]
const PIN_ANCHOR = [16, 39]
const SEND_DELAY_MS = 300
// A border file stays small; a track from a watch is bigger before it is simplified.
const MAX_FILE_BYTES = {area: 5_000_000, route: 20_000_000}
const FIT_PADDING = [24, 24]
const MODES = ["point", "area", "route"]

// Android often names a GPX or KML file "application/octet-stream", so the
// picker offers files by their names too.
const FILE_TYPES = {
  area: ".geojson,.json,application/geo+json,application/json",
  route:
    ".gpx,.kml,.geojson,.json,application/gpx+xml,application/vnd.google-earth.kml+xml,application/geo+json,application/json",
}

const coordinate = (input, bound) => {
  const value = Number.parseFloat(input?.value ?? "")
  return Number.isFinite(value) && Math.abs(value) <= bound ? value : null
}

const fill = (text, values) =>
  Object.entries(values).reduce((result, [key, value]) => result.replaceAll(`%{${key}}`, value), text || "")

export const LocationPicker = {
  mounted() {
    this.form = this.el.closest("form")
    this.lat = document.getElementById(this.el.dataset.latInput)
    this.lng = document.getElementById(this.el.dataset.lngInput)
    this.error = document.getElementById(this.el.dataset.errorTarget)
    this.status = document.getElementById(this.el.dataset.areaStatus)
    this.choices = document.getElementById(this.el.dataset.areaChoices)
    this.map = null
    this.marker = null
    this.L = null
    this.editors = {}
    this.writing = false
    this.mode = MODES.includes(this.el.dataset.mode) ? this.el.dataset.mode : "point"
    this.startArea = JSON.parse(this.el.dataset.area || "null")
    this.startRoute = JSON.parse(this.el.dataset.route || "null")
    // The route's length as the server wrote it, for the status line.
    this.routeLength = this.el.dataset.routeLength || null

    this.handleInput = () => {
      if (!this.writing) this.syncFromInputs()
    }

    this.handleChange = event => {
      if (event.target.name === this.el.dataset.pinName) this.refreshIcon()
    }

    this.handleClear = () => {
      this.writeInputs(null)
      this.removeMarker()
      this.editors.area?.setShape(null, {silent: true})
      this.editors.route?.setShape(null, {silent: true})
      this.routeLength = null
      this.showChoices([])

      if (this.mode === "area") {
        this.sendArea(null)
      } else if (this.mode === "route") {
        this.sendRoute(null)
      } else {
        this.sendPoint(null)
      }
    }

    this.handleLocate = () => this.locate()

    this.lat?.addEventListener("input", this.handleInput)
    this.lng?.addEventListener("input", this.handleInput)
    this.form?.addEventListener("change", this.handleChange)

    this.clearButton = document.getElementById(this.el.dataset.clearButton)
    this.clearButton?.addEventListener("click", this.handleClear)

    // Native shells have no location permission yet, and some browsers no API.
    this.locateButton = document.getElementById(this.el.dataset.locateButton)
    const native = window.Capacitor?.isNativePlatform?.() === true
    this.canLocate = Boolean(this.locateButton && "geolocation" in navigator && !native)
    this.locateButton?.addEventListener("click", this.handleLocate)

    // The tools of an area and of a route, rendered by the server next to the map.
    this.tools = {}
    const actions = {
      areaUndo: () => this.editors.area?.undo(),
      areaRemoveCorner: () => this.editors.area?.removeSelected(),
      areaRestart: () => {
        this.showChoices([])
        this.editors.area?.restart()
      },
      areaImport: () => this.pickFile("area"),
      routeUndo: () => this.editors.route?.undo(),
      routeRemovePoint: () => this.editors.route?.removeSelected(),
      routeReverse: () => this.editors.route?.reverse(),
      routeRestart: () => {
        this.showChoices([])
        this.editors.route?.restart()
      },
      routeImport: () => this.pickFile("route"),
    }

    for (const [key, action] of Object.entries(actions)) {
      const button = document.getElementById(this.el.dataset[key])
      if (!button) continue

      button.addEventListener("click", action)
      this.tools[key] = {button, action}
    }

    this.handleEvent("location_mode", ({mode}) => this.setMode(mode))

    this.handleEvent("location_reset", ({area, route, route_length, mode}) => {
      this.startArea = area
      this.startRoute = route
      this.routeLength = route_length || null
      this.editors.area?.setShape(area, {silent: true})
      this.editors.route?.setShape(route, {silent: true})
      this.showChoices([])
      this.setMode(mode, {quiet: true})
      this.syncFromInputs()
    })

    this.updateTools()

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

  destroyed() {
    clearTimeout(this.areaTimer)
    clearTimeout(this.routeTimer)
    clearTimeout(this.pointTimer)
    this.resizer?.disconnect()
    this.lat?.removeEventListener("input", this.handleInput)
    this.lng?.removeEventListener("input", this.handleInput)
    this.form?.removeEventListener("change", this.handleChange)
    this.clearButton?.removeEventListener("click", this.handleClear)
    this.locateButton?.removeEventListener("click", this.handleLocate)

    for (const {button, action} of Object.values(this.tools)) {
      button.removeEventListener("click", action)
    }

    this.map?.remove()
  },

  async start() {
    if (this.starting) return
    this.starting = true

    try {
      this.L = await loadLeaflet()
    } catch (_error) {
      this.showError(this.el.dataset.loadError)
      this.starting = false
      return
    }

    const L = this.L
    this.map = L.map(this.el, {zoomControl: true, worldCopyJump: true})
    this.map.attributionControl.setPrefix(
      '<a href="https://leafletjs.com" target="_blank" rel="noopener">Leaflet</a>'
    )

    L.tileLayer(this.el.dataset.tiles, {
      maxZoom: Number(this.el.dataset.maxZoom) || 19,
      attribution: this.el.dataset.attribution,
    }).addTo(this.map)

    this.editors.area = new AreaEditor(L, this.map, {
      onChange: (geometry, state) => {
        if (this.mode !== "area") return
        this.showState(state)
        this.updateTools()
        this.scheduleArea(geometry)
      },
    })

    this.editors.route = new RouteEditor(L, this.map, {
      onChange: (geometry, state) => {
        if (this.mode !== "route") return
        // A notice of an import stays until the next change by hand.
        if (!this.importing) this.notice = null
        this.showState(state)
        this.updateTools()
        this.scheduleRoute(geometry)
      },
    })

    this.editors.area.setShape(this.startArea, {silent: true})
    this.editors.route.setShape(this.startRoute, {silent: true})
    this.setMode(this.mode, {quiet: true})

    const point = this.inputPoint()
    const shapeBounds = this.editor()?.bounds()

    if (shapeBounds) {
      this.map.fitBounds(shapeBounds, {padding: FIT_PADDING})
    } else if (point) {
      this.map.setView(point, PLACE_ZOOM)
    } else {
      this.map.fitBounds(JSON.parse(this.el.dataset.defaultBounds))
    }

    if (point) this.placeMarker(point)

    this.map.on("click", event => {
      if (this.editor()) {
        this.editor().addCorner(event.latlng.wrap())
      } else {
        this.put(event.latlng)
      }
    })
  },

  // The editor of the mode on screen; none for a point.
  editor() {
    return this.mode === "point" ? null : this.editors[this.mode]
  },

  // Point, area or route. `quiet` leaves the server alone: it said so
  // itself, or the card is just starting.
  setMode(mode, {quiet = false} = {}) {
    this.mode = MODES.includes(mode) ? mode : "point"
    this.notice = null

    if (this.locateButton) this.locateButton.hidden = !(this.canLocate && this.mode === "point")
    if (!this.editors.area) return

    this.editors.area.setActive(this.mode === "area")
    this.editors.route.setActive(this.mode === "route")
    this.marker?.dragging?.[this.mode === "point" ? "enable" : "disable"]()
    this.showState(this.editor()?.state() ?? null)
    this.updateTools()

    const editor = this.editor()

    if (editor) {
      this.showChoices([])
      // The server forgot the shape when the card went to another mode.
      const geometry = editor.toGeoJSON()

      if (!quiet && geometry) {
        if (this.mode === "area") this.sendArea(geometry)
        else this.sendRoute(geometry)
      }
    }
  },

  inputPoint() {
    const lat = coordinate(this.lat, 90)
    const lng = coordinate(this.lng, 180)
    return lat === null || lng === null ? null : [lat, lng]
  },

  syncFromInputs() {
    if (!this.map) return

    const point = this.inputPoint()

    if (point) {
      this.placeMarker(point)
      if (this.mode === "point") {
        this.map.panTo(point)
        this.sendPoint(point)
      }
    } else if (!this.lat?.value && !this.lng?.value) {
      this.removeMarker()
      if (this.mode === "point") this.sendPoint(null)
    }
  },

  put(latlng) {
    const point = this.L.latLng(latlng.lat, latlng.lng).wrap()
    this.placeMarker(point)
    this.writeInputs(point)
    this.showError(null)
    this.sendPoint([point.lat, point.lng])
  },

  placeMarker(point) {
    if (this.marker) {
      this.marker.setLatLng(point)
      return
    }

    this.marker = this.L.marker(point, {
      draggable: this.mode === "point",
      icon: this.icon(),
      keyboard: false,
      autoPan: true,
    }).addTo(this.map)

    this.marker.on("dragend", () => this.put(this.marker.getLatLng()))
  },

  removeMarker() {
    this.marker?.remove()
    this.marker = null
  },

  // The pin of the choice that is ticked, drawn by the server next to it: a
  // copy without its id, and with a picture's clip of its own, so no id is
  // on the page twice.
  icon() {
    const checked = this.form?.querySelector(`input[name="${this.el.dataset.pinName}"]:checked`)
    const svg = checked?.closest("label")?.querySelector("[data-pin-svg] svg")
    const id = svg?.id
    const html = !svg
      ? ""
      : id
        ? svg.outerHTML.replaceAll(`${id}-clip`, `${id}-marker-clip`).replace(` id="${id}"`, "")
        : svg.outerHTML

    return this.L.divIcon({
      html,
      className: "potok-pin",
      iconSize: PIN_SIZE,
      iconAnchor: PIN_ANCHOR,
    })
  },

  refreshIcon() {
    if (this.marker) this.marker.setIcon(this.icon())
  },

  writeInputs(point) {
    if (!this.lat || !this.lng) return

    const latlng = point && (Array.isArray(point) ? {lat: point[0], lng: point[1]} : point)
    this.lat.value = latlng ? latlng.lat.toFixed(6) : ""
    this.lng.value = latlng ? latlng.lng.toFixed(6) : ""

    this.writing = true
    this.lng.dispatchEvent(new Event("input", {bubbles: true}))
    this.writing = false
  },

  // Where the pin now stands, for the areas around it (server side).
  sendPoint(point) {
    clearTimeout(this.pointTimer)

    this.pointTimer = setTimeout(() => {
      this.pushEvent(
        "edit_group_point_areas",
        point ? {lat: point[0], lng: point[1]} : {}
      )
    }, SEND_DELAY_MS)
  },

  scheduleArea(geometry) {
    clearTimeout(this.areaTimer)
    this.areaTimer = setTimeout(() => this.sendArea(geometry), SEND_DELAY_MS)
  },

  // The border to the server; its answer is the area's pin.
  sendArea(geometry) {
    clearTimeout(this.areaTimer)
    const seq = (this.areaSeq = (this.areaSeq || 0) + 1)

    this.pushEvent("edit_group_area", {area: geometry}, reply => {
      if (seq !== this.areaSeq || !reply?.ok || !Number.isFinite(reply.lat)) return

      const point = [reply.lat, reply.lng]
      this.placeMarker(point)
      this.writeInputs(point)
    })
  },

  scheduleRoute(geometry) {
    clearTimeout(this.routeTimer)
    this.routeTimer = setTimeout(() => this.sendRoute(geometry), SEND_DELAY_MS)
  },

  // The route to the server; its answer is its start, where the pin goes,
  // and its length.
  sendRoute(geometry) {
    clearTimeout(this.routeTimer)
    const seq = (this.routeSeq = (this.routeSeq || 0) + 1)

    this.pushEvent("edit_group_route", {route: geometry}, reply => {
      if (seq !== this.routeSeq) return

      this.routeLength = reply?.ok ? reply.length_text || null : null
      if (this.mode === "route") this.showState(this.editors.route?.state())
      if (!reply?.ok || !Number.isFinite(reply.lat)) return

      const point = [reply.lat, reply.lng]
      this.placeMarker(point)
      this.writeInputs(point)
    })
  },

  showState(state) {
    if (!this.status) return

    const route = this.mode === "route"
    const data = this.el.dataset
    const parts = []
    let warning = false

    if (route && state && (state.fixed || state.corners >= 2) && this.routeLength) {
      parts.push(fill(data.msgRouteLength, {length: this.routeLength}))
    }

    if (state?.fixed) {
      parts.push(fill(route ? data.msgRouteFixed : data.msgFixed, {points: state.points, parts: state.parts}))
    } else if (state?.crosses) {
      parts.push(data.msgCrosses)
      warning = true
    } else if (route && state?.corners === 1) {
      parts.push(data.msgRoutePoints)
    } else if (!route && state && state.corners > 0 && state.corners < 3) {
      parts.push(data.msgCorners)
    }

    if (this.notice) parts.unshift(this.notice)

    const text = parts.join(" ")
    this.status.textContent = text
    this.status.hidden = !text
    this.status.classList.toggle("text-error", warning)
    this.status.classList.toggle("text-base-content/65", !warning)
  },

  updateTools() {
    const area = this.editors.area?.state()
    const route = this.editors.route?.state()

    const set = (key, enabled) => {
      const tool = this.tools[key]
      if (tool) tool.button.disabled = !enabled
    }

    set("areaUndo", Boolean(area?.canUndo))
    set("areaRemoveCorner", Boolean(area?.selected))
    set("areaRestart", Boolean(area && (area.fixed || area.corners > 0)))
    set("routeUndo", Boolean(route?.canUndo))
    set("routeRemovePoint", Boolean(route?.selected))
    set("routeReverse", Boolean(route && (route.fixed || route.corners >= 2)))
    set("routeRestart", Boolean(route && (route.fixed || route.corners > 0)))
  },

  // A file, read here: its areas or routes never reach the server as a file.
  pickFile(kind) {
    const input = document.createElement("input")
    input.type = "file"
    input.accept = FILE_TYPES[kind]

    input.addEventListener("change", () => {
      const file = input.files?.[0]
      if (!file) return

      if (file.size > MAX_FILE_BYTES[kind]) {
        this.showError(kind === "route" ? this.el.dataset.msgRouteTooBig : this.el.dataset.msgTooBig)
        return
      }

      const message = kind === "route" ? this.el.dataset.msgRouteFile : this.el.dataset.msgFile

      file
        .text()
        .then(text => (kind === "route" ? this.readRoutes(text, file.name) : this.readGeoJSON(text)))
        .catch(() => this.showError(message))
    })

    input.click()
  },

  readGeoJSON(text) {
    let json

    try {
      json = JSON.parse(text)
    } catch (_error) {
      this.showError(this.el.dataset.msgFile)
      return
    }

    const areas = areasInGeoJSON(json)
    this.showError(null)

    if (areas.length === 0) {
      this.showError(this.el.dataset.msgNoArea)
    } else if (areas.length === 1) {
      this.useImported(areas[0].geometry)
    } else {
      this.showChoices(areas, "area")
    }
  },

  readRoutes(text, fileName) {
    const {routes, error} = routesInFile(text, fileName)
    this.showError(null)

    if (error === "kmz") {
      this.showError(this.el.dataset.msgKmz)
    } else if (error) {
      this.showError(this.el.dataset.msgRouteFile)
    } else if (routes.length === 0) {
      this.showError(this.el.dataset.msgNoRoute)
    } else if (routes.length === 1) {
      this.useImportedRoute(routes[0].geometry)
    } else {
      this.showChoices(routes, "route")
    }
  },

  // Several areas or routes in one file, as a city's open data holds every
  // quarter, or a watch every walk: the viewer picks one by its name.
  showChoices(items, kind = "area") {
    if (!this.choices) return

    this.choices.replaceChildren()
    this.choices.hidden = items.length === 0
    if (items.length === 0) return

    const data = this.el.dataset
    const title = document.createElement("p")
    title.className = "mb-1.5 text-xs font-semibold text-base-content/70"
    title.textContent = fill(kind === "route" ? data.msgRoutePick : data.msgPick, {count: items.length})

    const list = document.createElement("div")
    list.className =
      "flex max-h-48 flex-col gap-1 overflow-y-auto rounded-2xl border border-base-300 bg-base-100 p-1.5"

    items.forEach((item, index) => {
      const button = document.createElement("button")
      button.type = "button"
      button.className =
        "cursor-pointer truncate rounded-xl px-2.5 py-1.5 text-left text-sm font-medium text-base-content/80 transition-colors duration-150 hover:bg-base-200 hover:text-base-content"
      button.textContent =
        item.name || fill(kind === "route" ? data.msgRouteUnnamed : data.msgUnnamed, {number: index + 1})
      button.addEventListener("click", () => {
        this.showChoices([])
        if (kind === "route") this.useImportedRoute(item.geometry)
        else this.useImported(item.geometry)
      })
      list.append(button)
    })

    this.choices.append(title, list)
  },

  useImported(geometry) {
    let polygons = polygonsOf(geometry)

    if (!isGeographic(polygons)) {
      this.showError(this.el.dataset.msgNotGeographic)
      return
    }

    const before = pointCount(polygons)
    this.notice = null

    if (before > MAX_POINTS) {
      polygons = simplifyPolygons(this.L, this.map, polygons, MAX_POINTS)
      this.notice = fill(this.el.dataset.msgSimplified, {from: before, to: pointCount(polygons)})
    }

    this.editors.area.setShape({type: "MultiPolygon", coordinates: polygons})
    this.notice = null

    const bounds = this.editors.area.bounds()
    if (bounds) this.map.fitBounds(bounds, {padding: FIT_PADDING})
  },

  useImportedRoute(geometry) {
    let lines = linesOf(geometry)

    if (!isGeographicLines(lines)) {
      this.showError(this.el.dataset.msgNotGeographic)
      return
    }

    lines = cleanLines(lines)

    if (lines.length === 0) {
      this.showError(this.el.dataset.msgNoRoute)
      return
    }

    const before = linePointCount(lines)
    this.notice = null
    this.routeLength = null

    if (before > MAX_POINTS) {
      lines = simplifyLines(this.L, this.map, lines, MAX_POINTS)
      this.notice = fill(this.el.dataset.msgRouteSimplified, {from: before, to: linePointCount(lines)})
    }

    this.importing = true
    this.editors.route.setShape({type: "MultiLineString", coordinates: lines})
    this.importing = false

    const bounds = this.editors.route.bounds()
    if (bounds) this.map.fitBounds(bounds, {padding: FIT_PADDING})
  },

  locate() {
    navigator.geolocation.getCurrentPosition(
      ({coords}) => {
        const point = [coords.latitude, coords.longitude]

        if (this.map) {
          this.put({lat: point[0], lng: point[1]})
          this.map.setView(point, PLACE_ZOOM)
        } else {
          this.writeInputs(point)
        }
      },
      () => this.showError(this.el.dataset.locateError),
      {enableHighAccuracy: true, timeout: 10_000, maximumAge: 60_000}
    )
  },

  showError(message) {
    if (!this.error) return

    this.error.textContent = message || ""
    this.error.hidden = !message
  },
}
