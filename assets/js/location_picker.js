// The map of the "Location" card in a group's settings. A group stands on the
// map as a point or as an area.
//
// A point: a tap or a drag puts the group's pin, the two number fields
// follow, and typing in them moves the pin. The pin looks like the one chosen
// below the map.
//
// An area: the border is drawn on the map (`AreaEditor`) or comes from a
// GeoJSON file. It does not go through the form, which sends every field with
// each key typed: the card sends it on its own (`edit_group_area`), the
// server checks it and answers with the area's pin, a point inside it, which
// this writes into the number fields. Which mode shows is the server's
// (`location_mode`); `location_reset` puts back what is saved.
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

// Leaflet 1.9's package names only its UMD build; the ESM one has named exports.
let leafletModule = null
const loadLeaflet = () =>
  leafletModule || (leafletModule = import("leaflet/dist/leaflet-src.esm.js"))

const PLACE_ZOOM = 15
const PIN_SIZE = [32, 40]
const PIN_ANCHOR = [16, 39]
const SEND_DELAY_MS = 300
const MAX_FILE_BYTES = 5_000_000
const FIT_PADDING = [24, 24]

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
    this.editor = null
    this.writing = false
    this.mode = this.el.dataset.mode === "area" ? "area" : "point"
    this.startArea = JSON.parse(this.el.dataset.area || "null")

    this.handleInput = () => {
      if (!this.writing) this.syncFromInputs()
    }

    this.handleChange = event => {
      if (event.target.name === this.el.dataset.pinName) this.refreshIcon()
    }

    this.handleClear = () => {
      this.writeInputs(null)
      this.removeMarker()
      this.editor?.setShape(null, {silent: true})
      this.showChoices([])

      if (this.mode === "area") {
        this.sendArea(null)
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

    // The tools of an area, rendered by the server next to the map.
    this.tools = {}
    const actions = {
      areaUndo: () => this.editor?.undo(),
      areaRemoveCorner: () => this.editor?.removeSelected(),
      areaRestart: () => {
        this.showChoices([])
        this.editor?.restart()
      },
      areaImport: () => this.pickFile(),
    }

    for (const [key, action] of Object.entries(actions)) {
      const button = document.getElementById(this.el.dataset[key])
      if (!button) continue

      button.addEventListener("click", action)
      this.tools[key] = {button, action}
    }

    this.handleEvent("location_mode", ({mode}) => this.setMode(mode))

    this.handleEvent("location_reset", ({area, mode}) => {
      this.startArea = area
      this.editor?.setShape(area, {silent: true})
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

    this.editor = new AreaEditor(L, this.map, {
      onChange: (geometry, state) => {
        this.showState(state)
        this.updateTools(state)
        if (this.mode === "area") this.scheduleArea(geometry)
      },
    })

    this.editor.setShape(this.startArea, {silent: true})
    this.setMode(this.mode, {quiet: true})

    const point = this.inputPoint()
    const areaBounds = this.mode === "area" ? this.editor.bounds() : null

    if (areaBounds) {
      this.map.fitBounds(areaBounds, {padding: FIT_PADDING})
    } else if (point) {
      this.map.setView(point, PLACE_ZOOM)
    } else {
      this.map.fitBounds(JSON.parse(this.el.dataset.defaultBounds))
    }

    if (point) this.placeMarker(point)

    this.map.on("click", event => {
      if (this.mode === "area") {
        this.editor.addCorner(event.latlng.wrap())
      } else {
        this.put(event.latlng)
      }
    })
  },

  // Point or area. `quiet` leaves the server alone: it said so itself, or
  // the card is just starting.
  setMode(mode, {quiet = false} = {}) {
    this.mode = mode === "area" ? "area" : "point"

    if (this.locateButton) this.locateButton.hidden = !(this.canLocate && this.mode === "point")
    if (!this.editor) return

    this.editor.setActive(this.mode === "area")
    this.marker?.dragging?.[this.mode === "area" ? "disable" : "enable"]()
    this.showState(this.mode === "area" ? this.editor.state() : null)
    this.updateTools(this.editor.state())

    if (this.mode === "area") {
      this.showChoices([])
      // The server forgot the border when the card went to a point.
      if (!quiet && this.editor.toGeoJSON()) this.sendArea(this.editor.toGeoJSON())
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

  // The pin of the choice that is ticked, drawn by the server next to it.
  icon() {
    const checked = this.form?.querySelector(`input[name="${this.el.dataset.pinName}"]:checked`)
    const svg = checked?.closest("label")?.querySelector("[data-pin-svg]")

    return this.L.divIcon({
      html: svg ? svg.innerHTML : "",
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

  showState(state) {
    if (!this.status) return

    let text = ""
    let warning = false

    if (state?.fixed) {
      text = fill(this.el.dataset.msgFixed, {points: state.points, parts: state.parts})
    } else if (state?.crosses) {
      text = this.el.dataset.msgCrosses
      warning = true
    } else if (state && state.corners > 0 && state.corners < 3) {
      text = this.el.dataset.msgCorners
    }

    if (this.notice) {
      text = text ? `${this.notice} ${text}` : this.notice
    }

    this.status.textContent = text || ""
    this.status.hidden = !text
    this.status.classList.toggle("text-error", warning)
    this.status.classList.toggle("text-base-content/65", !warning)
  },

  updateTools(state = this.editor?.state()) {
    const set = (key, enabled) => {
      const tool = this.tools[key]
      if (tool) tool.button.disabled = !enabled
    }

    set("areaUndo", Boolean(state?.canUndo))
    set("areaRemoveCorner", Boolean(state?.selected))
    set("areaRestart", Boolean(state && (state.fixed || state.corners > 0)))
  },

  // A GeoJSON file, read here: its areas never reach the server as a file.
  pickFile() {
    const input = document.createElement("input")
    input.type = "file"
    input.accept = ".geojson,.json,application/geo+json,application/json"

    input.addEventListener("change", () => {
      const file = input.files?.[0]
      if (!file) return

      if (file.size > MAX_FILE_BYTES) {
        this.showError(this.el.dataset.msgTooBig)
        return
      }

      file
        .text()
        .then(text => this.readGeoJSON(text))
        .catch(() => this.showError(this.el.dataset.msgFile))
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
      this.showChoices(areas)
    }
  },

  // Several areas in one file, as a city's open data holds every quarter:
  // the viewer picks one by its name.
  showChoices(areas) {
    if (!this.choices) return

    this.choices.replaceChildren()
    this.choices.hidden = areas.length === 0
    if (areas.length === 0) return

    const title = document.createElement("p")
    title.className = "mb-1.5 text-xs font-semibold text-base-content/70"
    title.textContent = fill(this.el.dataset.msgPick, {count: areas.length})

    const list = document.createElement("div")
    list.className =
      "flex max-h-48 flex-col gap-1 overflow-y-auto rounded-2xl border border-base-300 bg-base-100 p-1.5"

    areas.forEach((area, index) => {
      const button = document.createElement("button")
      button.type = "button"
      button.className =
        "cursor-pointer truncate rounded-xl px-2.5 py-1.5 text-left text-sm font-medium text-base-content/80 transition-colors duration-150 hover:bg-base-200 hover:text-base-content"
      button.textContent = area.name || fill(this.el.dataset.msgUnnamed, {number: index + 1})
      button.addEventListener("click", () => {
        this.showChoices([])
        this.useImported(area.geometry)
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

    this.editor.setShape({type: "MultiPolygon", coordinates: polygons})
    this.notice = null

    const bounds = this.editor.bounds()
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
