// The routes a file holds, read in the browser for the "Location" card
// (`LocationPicker`): the file never reaches the server, only the line picked
// from it. Three kinds of file carry routes:
//
// * GPX, from a watch or an app (Strava, Garmin, Komoot, Wikiloc): a route per
//   track (`trk`, each `trkseg` a part) and per planned route (`rte`);
// * KML, from Google My Maps or Google Earth: a route per placemark with a
//   `LineString` (also inside `MultiGeometry`) or a `gx:Track`. A KMZ is a
//   zipped KML, which this does not open;
// * GeoJSON: every `LineString` and `MultiLineString`, as for areas.
//
// A route is `{name, geometry}`, the geometry a GeoJSON MultiLineString of
// [lng, lat] points (heights dropped).

import {nameOf, round} from "./area_editor"

// A GeoJSON LineString or MultiLineString as the parts of a MultiLineString.
export const linesOf = geometry => {
  if (!geometry) return []
  if (geometry.type === "LineString") return [geometry.coordinates]
  if (geometry.type === "MultiLineString") return geometry.coordinates
  return []
}

export const linePointCount = lines => lines.reduce((sum, line) => sum + line.length, 0)

// Whether every point looks like longitude and latitude.
export const isGeographicLines = lines =>
  lines.every(line =>
    line.every(
      point =>
        Array.isArray(point) &&
        Number.isFinite(point[0]) &&
        Number.isFinite(point[1]) &&
        Math.abs(point[0]) <= 180 &&
        Math.abs(point[1]) <= 90
    )
  )

// Points as the server keeps them: [lng, lat] to six decimals, none twice in
// a row, and only parts that still go somewhere.
export const cleanLines = lines =>
  lines
    .map(line =>
      line
        .map(([lng, lat]) => [round(lng), round(lat)])
        .filter((point, index, all) => index === 0 || point[0] !== all[index - 1][0] || point[1] !== all[index - 1][1])
    )
    .filter(line => line.length >= 2)

// Fewer points, each part simplified on the screen at one zoom with a
// tolerance that grows until the route fits; a part keeps both ends.
export const simplifyLines = (L, map, lines, maxPoints) => {
  const zoom = 18
  const projected = lines.map(line => line.map(([lng, lat]) => map.project([lat, lng], zoom)))

  let tolerance = 0.5
  let result = lines

  while (linePointCount(result) > maxPoints && tolerance < 1_000_000) {
    tolerance *= 2

    result = projected
      .map(points =>
        L.LineUtil.simplify(points, tolerance).map(point => {
          const latlng = map.unproject(point, zoom)
          return [round(latlng.lng), round(latlng.lat)]
        })
      )
      .filter(line => line.length >= 2)
  }

  return result
}

// The routes of a file's text: `{routes}`, or `{error}` with "kmz" for a
// zipped KML and "file" for anything unreadable.
export const routesInFile = (text, fileName = "") => {
  const name = fileName.toLowerCase()
  if (name.endsWith(".kmz") || text.startsWith("PK")) return {error: "kmz"}

  const xml = name.endsWith(".gpx") || name.endsWith(".kml") || text.trimStart().startsWith("<")

  if (xml) {
    const doc = new DOMParser().parseFromString(text, "application/xml")
    if (doc.getElementsByTagName("parsererror").length > 0) return {error: "file"}

    switch (doc.documentElement.localName) {
      case "gpx":
        return {routes: routesInGPX(doc)}
      case "kml":
        return {routes: routesInKML(doc)}
      default:
        return {error: "file"}
    }
  }

  try {
    return {routes: routesInGeoJSON(JSON.parse(text))}
  } catch (_error) {
    return {error: "file"}
  }
}

// Every LineString and MultiLineString, with its feature's name.
export const routesInGeoJSON = json => {
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
      case "LineString":
      case "MultiLineString":
        found.push({
          name: nameOf(properties),
          geometry: {type: "MultiLineString", coordinates: linesOf(node)},
        })
        break
      default:
        break
    }
  }

  visit(json, null)
  return found
}

// Elements by their local name, whatever namespace the file uses.
const byTag = (node, tag) => Array.from(node.getElementsByTagNameNS("*", tag))

const childText = (node, tag) => {
  for (const child of node.children) {
    if (child.localName === tag) return child.textContent.trim() || null
  }

  return null
}

const gpxPoint = element => [
  Number.parseFloat(element.getAttribute("lon")),
  Number.parseFloat(element.getAttribute("lat")),
]

const route = (name, parts) =>
  parts.length > 0 ? [{name, geometry: {type: "MultiLineString", coordinates: parts}}] : []

export const routesInGPX = doc => [
  ...byTag(doc, "trk").flatMap(track =>
    route(
      childText(track, "name"),
      byTag(track, "trkseg")
        .map(segment => byTag(segment, "trkpt").map(gpxPoint))
        .filter(points => points.length > 0)
    )
  ),
  ...byTag(doc, "rte").flatMap(planned => {
    const points = byTag(planned, "rtept").map(gpxPoint)
    return route(childText(planned, "name"), points.length > 0 ? [points] : [])
  }),
]

// "lng,lat[,height]" tuples apart by white space.
const kmlCoordinates = text =>
  text
    .trim()
    .split(/\s+/)
    .filter(Boolean)
    .map(tuple => tuple.split(",").slice(0, 2).map(Number.parseFloat))

export const routesInKML = doc =>
  byTag(doc, "Placemark").flatMap(placemark => {
    const lines = byTag(placemark, "LineString").map(line => {
      const coordinates = byTag(line, "coordinates")[0]
      return coordinates ? kmlCoordinates(coordinates.textContent) : []
    })

    // Google Earth's tracks: "lng lat height" in each `gx:coord`.
    const tracks = byTag(placemark, "Track").map(track =>
      byTag(track, "coord").map(coord => coord.textContent.trim().split(/\s+/).slice(0, 2).map(Number.parseFloat))
    )

    return route(
      childText(placemark, "name"),
      [...lines, ...tracks].filter(points => points.length > 0)
    )
  })
