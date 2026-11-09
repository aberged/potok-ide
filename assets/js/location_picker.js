// The map of the "Location" card in a group's settings: a tap or a drag puts
// the group's pin, the two number fields follow, and typing in them moves the
// pin. The pin looks like the one chosen below the map.
//
// Leaflet loads the first time the card shows (a hidden card has no size to
// draw in). Tiles come from Potok (`/tiles`, `PotokIde.MapTiles`).
//
// The fields belong to the group's form: writing them fires one `input`, so
// the form's `phx-change` sends them as if typed. They have no `phx-debounce`,
// which would lose a value written here during its wait.

// Leaflet 1.9's package names only its UMD build; the ESM one has named exports.
let leafletModule = null
const loadLeaflet = () =>
  leafletModule || (leafletModule = import("leaflet/dist/leaflet-src.esm.js"))

const PLACE_ZOOM = 15
const PIN_SIZE = [32, 40]
const PIN_ANCHOR = [16, 39]

const coordinate = (input, bound) => {
  const value = Number.parseFloat(input?.value ?? "")
  return Number.isFinite(value) && Math.abs(value) <= bound ? value : null
}

export const LocationPicker = {
  mounted() {
    this.form = this.el.closest("form")
    this.lat = document.getElementById(this.el.dataset.latInput)
    this.lng = document.getElementById(this.el.dataset.lngInput)
    this.error = document.getElementById(this.el.dataset.errorTarget)
    this.map = null
    this.marker = null
    this.L = null
    this.writing = false

    this.handleInput = () => {
      if (!this.writing) this.syncFromInputs()
    }

    this.handleChange = event => {
      if (event.target.name === this.el.dataset.pinName) this.refreshIcon()
    }

    this.handleClear = () => {
      this.writeInputs(null)
      this.removeMarker()
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

    if (this.locateButton && "geolocation" in navigator && !native) {
      this.locateButton.hidden = false
      this.locateButton.addEventListener("click", this.handleLocate)
    }

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
    this.resizer?.disconnect()
    this.lat?.removeEventListener("input", this.handleInput)
    this.lng?.removeEventListener("input", this.handleInput)
    this.form?.removeEventListener("change", this.handleChange)
    this.clearButton?.removeEventListener("click", this.handleClear)
    this.locateButton?.removeEventListener("click", this.handleLocate)
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

    const point = this.inputPoint()

    if (point) {
      this.map.setView(point, PLACE_ZOOM)
      this.placeMarker(point)
    } else {
      this.map.fitBounds(JSON.parse(this.el.dataset.defaultBounds))
    }

    this.map.on("click", event => this.put(event.latlng))
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
      this.map.panTo(point)
    } else if (!this.lat?.value && !this.lng?.value) {
      this.removeMarker()
    }
  },

  put(latlng) {
    const point = this.L.latLng(latlng.lat, latlng.lng).wrap()
    this.placeMarker(point)
    this.writeInputs(point)
    this.showError(null)
  },

  placeMarker(point) {
    if (this.marker) {
      this.marker.setLatLng(point)
      return
    }

    this.marker = this.L.marker(point, {
      draggable: true,
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
