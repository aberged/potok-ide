// The border of an area on the "Location" card (`LocationPicker`): a tap on
// the map adds a corner, a corner drags, the dot between two corners adds one
// there, and a picked corner can go. Every change can be undone. A border from
// a GeoJSON file that is more than one ring, or has too many corners to drag
// by hand, is shown as it is and replaced as a whole.
//
// The editor only draws and keeps the border; the card sends it to the server
// (`edit_group_area`), which checks it and puts the area's pin inside it.

export const MAX_EDIT_CORNERS = 500
// What the server keeps at most (`GroupAreas.normalize/1`).
export const MAX_POINTS = 10_000
const MAX_HISTORY = 100
const CORNER_SIZE = [30, 30]
const MIDPOINT_SIZE = [24, 24]

const orient = (a, b, c) => (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])

// Whether two segments cross each other inside both (touching at an end
// does not count).
const segmentsCross = (p1, p2, p3, p4) => {
  const d1 = orient(p3, p4, p1)
  const d2 = orient(p3, p4, p2)
  const d3 = orient(p1, p2, p3)
  const d4 = orient(p1, p2, p4)

  return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
}

// Whether a closed ring of [lng, lat] corners crosses itself.
export const ringCrosses = corners => {
  const n = corners.length
  if (n < 4) return false

  for (let i = 0; i < n; i++) {
    const a1 = corners[i]
    const a2 = corners[(i + 1) % n]

    for (let j = i + 2; j < n; j++) {
      // The first and the last segment share a corner.
      if (i === 0 && j === n - 1) continue
      if (segmentsCross(a1, a2, corners[j], corners[(j + 1) % n])) return true
    }
  }

  return false
}

// A GeoJSON Polygon or MultiPolygon as the polygons of a MultiPolygon.
export const polygonsOf = geometry => {
  if (!geometry) return []
  if (geometry.type === "Polygon") return [geometry.coordinates]
  if (geometry.type === "MultiPolygon") return geometry.coordinates
  return []
}

export const pointCount = polygons =>
  polygons.reduce((sum, rings) => sum + rings.reduce((ringSum, ring) => ringSum + ring.length, 0), 0)

// Whether every coordinate looks like longitude and latitude.
export const isGeographic = polygons =>
  polygons.every(rings =>
    rings.every(ring =>
      ring.every(
        point =>
          Array.isArray(point) &&
          Number.isFinite(point[0]) &&
          Number.isFinite(point[1]) &&
          Math.abs(point[0]) <= 180 &&
          Math.abs(point[1]) <= 90
      )
    )
  )

// The areas a GeoJSON file holds: every Polygon and MultiPolygon, with a name
// from its feature's properties when there is one.
export const areasInGeoJSON = json => {
  const found = []

  const visit = (node, properties) => {
    if (!node || typeof node !== "object") return

    switch (node.type) {
      case "FeatureCollection":
        ;(node.features || []).forEach(feature => visit(feature, null))
        break
      case "Feature":
        visit(node.geometry, node.properties || {})
        break
      case "GeometryCollection":
        ;(node.geometries || []).forEach(geometry => visit(geometry, properties))
        break
      case "Polygon":
      case "MultiPolygon":
        found.push({name: nameOf(properties), geometry: node})
        break
      default:
        break
    }
  }

  visit(json, null)
  return found
}

const nameOf = properties => {
  if (!properties) return null

  for (const key of ["name", "naziv", "NAZIV", "Name", "NAME", "ime", "title"]) {
    if (typeof properties[key] === "string" && properties[key].trim() !== "") {
      return properties[key].trim()
    }
  }

  const text = Object.values(properties).find(value => typeof value === "string" && value.trim())
  return text ? text.trim() : null
}

// Fewer points, each ring simplified on the screen at one zoom with a
// tolerance that grows until the border fits; rings keep three corners.
export const simplifyPolygons = (L, map, polygons, maxPoints) => {
  const zoom = 18
  const projected = polygons.map(rings =>
    rings.map(ring => ring.map(([lng, lat]) => map.project([lat, lng], zoom)))
  )

  let tolerance = 0.5
  let result = polygons

  while (pointCount(result) > maxPoints && tolerance < 1_000_000) {
    tolerance *= 2

    result = projected.map(rings =>
      rings
        .map(points => {
          const open = points.slice(0, -1)
          const simple = L.LineUtil.simplify(open, tolerance)
          if (simple.length < 3) return null

          const ring = simple.map(point => {
            const latlng = map.unproject(point, zoom)
            return [Number(latlng.lng.toFixed(6)), Number(latlng.lat.toFixed(6))]
          })

          return [...ring, ring[0]]
        })
        .filter(Boolean)
    )

    result = result.filter(rings => rings.length > 0)
  }

  return result
}

export class AreaEditor {
  constructor(L, map, {onChange}) {
    this.L = L
    this.map = map
    this.onChange = onChange
    this.layer = L.layerGroup()
    this.active = false
    // Corners of a drawn border as [lat, lng], the ring left open.
    this.corners = []
    // A border shown as it is: MultiPolygon coordinates.
    this.fixed = null
    this.history = []
    this.selected = null
  }

  setActive(active) {
    this.active = active

    if (active) {
      this.layer.addTo(this.map)
    } else {
      this.layer.remove()
    }

    this.render()
  }

  // A border to start from (GeoJSON, or null for none). `silent` keeps it
  // from counting as a change.
  setShape(geometry, {silent = false} = {}) {
    const polygons = polygonsOf(geometry)
    this.history = []
    this.selected = null

    if (polygons.length === 1 && polygons[0].length === 1 && polygons[0][0].length - 1 <= MAX_EDIT_CORNERS) {
      const ring = polygons[0][0]
      const open = ring.length > 1 && sameCorner(ring[0], ring[ring.length - 1]) ? ring.slice(0, -1) : ring
      this.corners = open.map(([lng, lat]) => [lat, lng])
      this.fixed = null
    } else if (polygons.length > 0) {
      this.corners = []
      this.fixed = polygons
    } else {
      this.corners = []
      this.fixed = null
    }

    this.render()
    if (!silent) this.emit()
  }

  // A drawn border, or one from a file, or none.
  toGeoJSON() {
    if (this.fixed) return {type: "MultiPolygon", coordinates: this.fixed}
    if (this.corners.length < 3) return null

    const ring = this.corners.map(([lat, lng]) => [round(lng), round(lat)])
    return {type: "MultiPolygon", coordinates: [[[...ring, ring[0]]]]}
  }

  bounds() {
    const points = this.fixed
      ? this.fixed.flatMap(rings => rings[0].map(([lng, lat]) => [lat, lng]))
      : this.corners

    return points.length > 0 ? this.L.latLngBounds(points) : null
  }

  state() {
    return {
      corners: this.corners.length,
      fixed: this.fixed !== null,
      points: this.fixed ? pointCount(this.fixed) : this.corners.length,
      parts: this.fixed ? this.fixed.length : 1,
      crosses: this.crosses(),
      canUndo: this.history.length > 0,
      selected: this.selected !== null,
    }
  }

  crosses() {
    return ringCrosses(this.corners.map(([lat, lng]) => [lng, lat]))
  }

  remember() {
    this.history.push({corners: this.corners.map(corner => [...corner]), fixed: this.fixed})
    if (this.history.length > MAX_HISTORY) this.history.shift()
  }

  addCorner(latlng) {
    if (this.fixed || this.corners.length >= MAX_EDIT_CORNERS) return

    this.remember()
    this.corners.push([latlng.lat, latlng.lng])
    this.selected = null
    this.changed()
  }

  insertCorner(index, latlng) {
    this.remember()
    this.corners.splice(index, 0, [latlng.lat, latlng.lng])
    this.selected = index
    this.changed()
  }

  removeSelected() {
    if (this.selected === null) return

    this.remember()
    this.corners.splice(this.selected, 1)
    this.selected = null
    this.changed()
  }

  undo() {
    const last = this.history.pop()
    if (!last) return

    this.corners = last.corners
    this.fixed = last.fixed
    this.selected = null
    this.changed()
  }

  restart() {
    if (!this.fixed && this.corners.length === 0) return

    this.remember()
    this.corners = []
    this.fixed = null
    this.selected = null
    this.changed()
  }

  changed() {
    this.render()
    this.emit()
  }

  emit() {
    this.onChange?.(this.toGeoJSON(), this.state())
  }

  render() {
    const L = this.L
    this.layer.clearLayers()
    this.shape = null
    this.midpoints = []
    if (!this.active) return

    if (this.fixed) {
      L.polygon(
        this.fixed.map(rings => rings.map(ring => ring.map(([lng, lat]) => [lat, lng]))),
        {className: "potok-area-edit is-fixed", interactive: false, weight: 2}
      ).addTo(this.layer)

      return
    }

    const crossing = this.crosses()
    const className = crossing ? "potok-area-edit is-crossing" : "potok-area-edit"

    if (this.corners.length >= 3) {
      this.shape = L.polygon(this.corners, {className, interactive: false, weight: 2.5})
    } else if (this.corners.length === 2) {
      this.shape = L.polyline(this.corners, {className, interactive: false, weight: 2.5})
    }

    this.shape?.addTo(this.layer)
    this.drawMidpoints()

    this.corners.forEach((corner, index) => {
      const marker = L.marker(corner, {
        draggable: true,
        keyboard: false,
        autoPan: true,
        zIndexOffset: 1000,
        icon: L.divIcon({
          html: `<span class="potok-corner${index === this.selected ? " is-selected" : ""}"></span>`,
          className: "potok-corner-icon",
          iconSize: CORNER_SIZE,
        }),
      }).addTo(this.layer)

      marker.on("click", () => {
        this.selected = this.selected === index ? null : index
        this.render()
        this.emit()
      })

      marker.on("dragstart", () => this.remember())

      marker.on("drag", () => {
        const latlng = marker.getLatLng()
        this.corners[index] = [latlng.lat, latlng.lng]
        this.shape?.setLatLngs(this.corners)
        this.placeMidpoints()
      })

      marker.on("dragend", () => {
        const latlng = marker.getLatLng()
        this.corners[index] = [latlng.lat, latlng.lng]
        this.changed()
      })
    })
  }

  // A dot in the middle of each side; a tap or a drag adds a corner there.
  midpointsOf() {
    const n = this.corners.length
    if (n < 2) return []

    const sides = n === 2 ? 1 : n
    return Array.from({length: sides}, (_, index) => {
      const [lat1, lng1] = this.corners[index]
      const [lat2, lng2] = this.corners[(index + 1) % n]
      return {index: index + 1, latlng: [(lat1 + lat2) / 2, (lng1 + lng2) / 2]}
    })
  }

  drawMidpoints() {
    const L = this.L

    this.midpoints = this.midpointsOf().map(({index, latlng}) => {
      const marker = L.marker(latlng, {
        draggable: true,
        keyboard: false,
        icon: L.divIcon({
          html: '<span class="potok-midpoint"></span>',
          className: "potok-corner-icon",
          iconSize: MIDPOINT_SIZE,
        }),
      }).addTo(this.layer)

      marker.on("click", () => this.insertCorner(index, marker.getLatLng()))
      marker.on("dragend", () => this.insertCorner(index, marker.getLatLng()))
      return marker
    })
  }

  placeMidpoints() {
    this.midpointsOf().forEach(({latlng}, i) => this.midpoints[i]?.setLatLng(latlng))
  }
}

const round = value => Number(value.toFixed(6))

const sameCorner = (a, b) => a[0] === b[0] && a[1] === b[1]
