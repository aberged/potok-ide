// The line of a route on the "Location" card (`LocationPicker`): the border
// editor (`AreaEditor`) with an open line. A tap on the map adds a point at
// the end, a point drags, the dot between two points adds one there, a picked
// point can go, and the whole line can be turned around, as its start is
// where the route's pin stands. A route from a file with more than one part,
// or too many points to drag by hand, is shown as it is and replaced as a
// whole. A route may cross itself or end where it starts, as a loop does.
//
// The card sends the line to the server (`edit_group_route`), which checks it
// and puts the pin at its start.

import {AreaEditor, MAX_EDIT_CORNERS, round} from "./area_editor"
import {linePointCount, linesOf} from "./route_files"

export class RouteEditor extends AreaEditor {
  // A route to start from (GeoJSON, or null for none). `silent` keeps it from
  // counting as a change.
  setShape(geometry, {silent = false} = {}) {
    const lines = linesOf(geometry)
    this.history = []
    this.selected = null

    if (lines.length === 1 && lines[0].length <= MAX_EDIT_CORNERS) {
      this.corners = lines[0].map(([lng, lat]) => [lat, lng])
      this.fixed = null
    } else if (lines.length > 0) {
      this.corners = []
      this.fixed = lines
    } else {
      this.corners = []
      this.fixed = null
    }

    this.render()
    if (!silent) this.emit()
  }

  // A drawn route, or one from a file, or none.
  toGeoJSON() {
    if (this.fixed) return {type: "MultiLineString", coordinates: this.fixed}
    if (this.corners.length < 2) return null

    return {type: "MultiLineString", coordinates: [this.corners.map(([lat, lng]) => [round(lng), round(lat)])]}
  }

  bounds() {
    const points = this.fixed ? this.fixed.flatMap(line => line.map(([lng, lat]) => [lat, lng])) : this.corners
    return points.length > 0 ? this.L.latLngBounds(points) : null
  }

  state() {
    return {
      corners: this.corners.length,
      fixed: this.fixed !== null,
      points: this.fixed ? linePointCount(this.fixed) : this.corners.length,
      parts: this.fixed ? this.fixed.length : 1,
      crosses: false,
      canUndo: this.history.length > 0,
      selected: this.selected !== null,
    }
  }

  crosses() {
    return false
  }

  // The same line the other way: its end becomes its start.
  reverse() {
    if (this.fixed) {
      this.remember()
      this.fixed = [...this.fixed].reverse().map(line => [...line].reverse())
    } else if (this.corners.length >= 2) {
      this.remember()
      this.corners.reverse()
      if (this.selected !== null) this.selected = this.corners.length - 1 - this.selected
    } else {
      return
    }

    this.changed()
  }

  renderFixed() {
    const latlngs = this.fixed.map(line => line.map(([lng, lat]) => [lat, lng]))

    this.L.polyline(latlngs, {
      className: "potok-route-edit is-fixed",
      interactive: false,
      weight: 3.5,
      lineCap: "round",
      lineJoin: "round",
    }).addTo(this.layer)

    // Where it starts and where it ends, as on a drawn one.
    const first = latlngs[0][0]
    const lastLine = latlngs[latlngs.length - 1]
    this.endMarker(first, "is-start")
    this.endMarker(lastLine[lastLine.length - 1], "is-end")
  }

  endMarker(latlng, className) {
    this.L.marker(latlng, {
      interactive: false,
      keyboard: false,
      icon: this.L.divIcon({
        html: `<span class="potok-corner ${className}"></span>`,
        className: "potok-corner-icon",
        iconSize: [30, 30],
      }),
    }).addTo(this.layer)
  }

  makeShape() {
    if (this.corners.length < 2) return null

    return this.L.polyline(this.corners, {
      className: "potok-route-edit",
      interactive: false,
      weight: 3.5,
      lineCap: "round",
      lineJoin: "round",
    })
  }

  // The first point is the start, where the pin goes; the last the end.
  cornerHtml(index) {
    const classes = ["potok-corner"]
    if (index === 0) classes.push("is-start")
    if (index > 0 && index === this.corners.length - 1) classes.push("is-end")
    if (index === this.selected) classes.push("is-selected")
    return `<span class="${classes.join(" ")}"></span>`
  }

  // A dot in the middle of each stretch; none from the end back to the start.
  midpointsOf() {
    return this.corners.slice(1).map(([lat2, lng2], index) => {
      const [lat1, lng1] = this.corners[index]
      return {index: index + 1, latlng: [(lat1 + lat2) / 2, (lng1 + lng2) / 2]}
    })
  }
}
