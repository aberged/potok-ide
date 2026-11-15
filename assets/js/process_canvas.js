// The canvas of the process editor (GroupLive.Show.ProcessEditorState). The
// server holds the graph and every text on it; the canvas draws what it gets
// in `data-state` and in `process_canvas:state`, and tells the server what
// the pointer did. It writes no text of its own.
//
// - On a phone (narrower than 1024px) dagre lays the graph out top to bottom,
//   ignoring saved places. A step or a flow is tapped to edit it, and the
//   "+" on a flow puts a step into it.
// - From 1024px it is a free canvas: steps stand where they were dragged
//   (`layout`), a step without a place gets one from dagre next to what
//   comes before it, a flow is drawn from a step's handle to another step,
//   and the canvas pans (drag the background, the wheel) and zooms (pinch,
//   ctrl + wheel, the buttons).
//
// Events to the server: process_editor_select {node} | {flow} | {},
// process_editor_insert_menu {flow}, process_editor_move {positions},
// process_editor_connect {from, to}, process_editor_delete {}.

let dagreModule = null
const loadDagre = () => dagreModule || (dagreModule = import("@dagrejs/dagre"))

const WIDE = "(min-width: 1024px)"
const SNAP = 8
const DRAG_START = 4
const MIN_ZOOM = 0.3
const MAX_ZOOM = 1.6
const PHONE_MIN_SCALE = 0.8
const PAD = 24

const SIZES = {
  start: [168, 42],
  end: [120, 42],
  gateway: [176, 46],
  step: [224, 64],
}

// Narrower on a phone, so a decision's branches stand side by side.
const PHONE_SIZES = {
  start: [150, 38],
  end: [104, 38],
  gateway: [150, 42],
  step: [172, 58],
}

let sizes = SIZES

const TONES = {
  start: "border-success/40 bg-success/10 text-success",
  end: "border-base-300 bg-base-200 text-base-content/70",
  gateway: "border-amber-500/40 bg-amber-500/10 text-amber-700 dark:text-amber-300",
  message: "bg-sky-500/10 text-sky-600 dark:text-sky-300",
  subgroup: "bg-violet-500/10 text-violet-600 dark:text-violet-300",
  push: "bg-rose-500/10 text-rose-600 dark:text-rose-300",
  task: "bg-amber-500/15 text-amber-700 dark:text-amber-300",
  timer: "bg-teal-500/10 text-teal-600 dark:text-teal-300",
}

const PILLS = new Set(["start", "end", "gateway"])

const sizeOf = node => sizes[PILLS.has(node.kind) ? node.kind : "step"]

const el = (tag, attrs = {}, children = []) => {
  const node = document.createElement(tag)
  for (const [key, value] of Object.entries(attrs)) {
    if (value === undefined || value === null || value === false) continue
    if (key === "class") node.className = value
    else if (key === "text") node.textContent = value
    else if (key === "style") Object.assign(node.style, value)
    else node.setAttribute(key, value === true ? "" : value)
  }
  for (const child of children) if (child) node.appendChild(child)
  return node
}

const svg = (tag, attrs = {}) => {
  const node = document.createElementNS("http://www.w3.org/2000/svg", tag)
  for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, value)
  return node
}

const snap = value => Math.round(value / SNAP) * SNAP

// A point at `t` (0..1) along a polyline.
const along = (points, t) => {
  const lengths = []
  let total = 0
  for (let i = 1; i < points.length; i++) {
    const length = Math.hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
    lengths.push(length)
    total += length
  }
  let target = total * t
  for (let i = 1; i < points.length; i++) {
    if (target <= lengths[i - 1] || i === points.length - 1) {
      const f = lengths[i - 1] === 0 ? 0 : Math.min(1, target / lengths[i - 1])
      return {
        x: points[i - 1].x + (points[i].x - points[i - 1].x) * f,
        y: points[i - 1].y + (points[i].y - points[i - 1].y) * f,
      }
    }
    target -= lengths[i - 1]
  }
  return points[0]
}

// A smooth path through dagre's points.
const throughPoints = points => {
  if (points.length < 3) return `M${points[0].x},${points[0].y} L${points[points.length - 1].x},${points[points.length - 1].y}`
  let d = `M${points[0].x},${points[0].y}`
  for (let i = 1; i < points.length - 1; i++) {
    const mid = {x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2}
    d += ` Q${points[i].x},${points[i].y} ${mid.x},${mid.y}`
  }
  const last = points[points.length - 1]
  return d + ` L${last.x},${last.y}`
}

// A curve between two boxes on the free canvas: downwards from the bottom to
// the top, otherwise around the right side, as a flow back up does.
const between = (a, b) => {
  const [aw, ah] = a.size
  const [bw, bh] = b.size
  if (b.y - bh / 2 > a.y + ah / 2 + 12) {
    const s = {x: a.x, y: a.y + ah / 2}
    const t = {x: b.x, y: b.y - bh / 2}
    const dy = Math.max(30, (t.y - s.y) / 2)
    return {
      d: `M${s.x},${s.y} C${s.x},${s.y + dy} ${t.x},${t.y - dy} ${t.x},${t.y}`,
      mid: bezier(s, {x: s.x, y: s.y + dy}, {x: t.x, y: t.y - dy}, t, 0.5),
      plus: bezier(s, {x: s.x, y: s.y + dy}, {x: t.x, y: t.y - dy}, t, 0.78),
    }
  }
  // Back up, round the side the source stands on, so it passes no step.
  const left = a.x < b.x
  const side = left ? -1 : 1
  const s = {x: a.x + (side * aw) / 2, y: a.y}
  const t = {x: b.x + (side * bw) / 2, y: b.y}
  const dx = Math.max(60, Math.abs(t.y - s.y) / 3)
  const edge = left ? Math.min(s.x, t.x) - dx : Math.max(s.x, t.x) + dx
  const c1 = {x: edge, y: s.y}
  const c2 = {x: edge, y: t.y}
  return {
    d: `M${s.x},${s.y} C${c1.x},${c1.y} ${c2.x},${c2.y} ${t.x},${t.y}`,
    mid: bezier(s, c1, c2, t, 0.5),
    plus: bezier(s, c1, c2, t, 0.78),
  }
}

const bezier = (p0, p1, p2, p3, t) => {
  const u = 1 - t
  return {
    x: u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x,
    y: u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y,
  }
}

export const ProcessCanvas = {
  mounted() {
    this.state = JSON.parse(this.el.dataset.state || "{}")
    this.view = {x: PAD, y: PAD, zoom: 1, fitted: false}
    this.places = {}
    this.wide = window.matchMedia(WIDE)
    this.onMode = () => {
      this.view.fitted = false
      this.draw()
    }
    this.wide.addEventListener("change", this.onMode)

    this.onKey = event => this.key(event)
    this.el.addEventListener("keydown", this.onKey)

    this.onUnload = event => {
      if (this.state.dirty) {
        event.preventDefault()
        event.returnValue = ""
      }
    }
    window.addEventListener("beforeunload", this.onUnload)

    this.handleEvent("process_canvas:state", state => {
      if (state.id && state.id !== this.el.id) return
      const reset = state.reset
      this.state = state
      if (reset) this.view.fitted = false
      this.draw()
    })

    this.handleEvent("process_canvas:fit", () => {
      this.view.fitted = false
      this.draw()
    })

    this.draw()
  },

  destroyed() {
    this.wide.removeEventListener("change", this.onMode)
    window.removeEventListener("beforeunload", this.onUnload)
    this.el.removeEventListener("keydown", this.onKey)
  },

  // ---------
  // Layout
  // ---------

  async draw() {
    const {graphlib, layout} = await loadDagre()
    const state = this.state
    if (!state.nodes) return

    sizes = this.wide.matches ? SIZES : PHONE_SIZES
    const g = new graphlib.Graph({multigraph: true})
    g.setGraph(
      this.wide.matches
        ? {rankdir: "TB", nodesep: 28, ranksep: 48, edgesep: 18, marginx: 0, marginy: 0}
        : {rankdir: "TB", nodesep: 16, ranksep: 40, edgesep: 12, marginx: 0, marginy: 0},
    )
    g.setDefaultEdgeLabel(() => ({}))
    for (const node of state.nodes) {
      const [width, height] = sizeOf(node)
      g.setNode(node.id, {width, height})
    }
    for (const flow of state.flows) {
      const label = flow.label ? {width: Math.min(160, 14 + flow.label.length * 6.5), height: 22, labelpos: "c"} : {}
      g.setEdge(flow.from, flow.to, label, flow.key)
    }
    layout(g)

    const auto = {}
    for (const node of state.nodes) {
      const {x, y} = g.node(node.id)
      auto[node.id] = {x, y}
    }

    const wide = this.wide.matches
    this.places = wide ? this.freePlaces(auto) : auto

    const routes = {}
    for (const flow of state.flows) {
      const a = {...this.places[flow.from], size: sizeOf(this.node(flow.from))}
      const b = {...this.places[flow.to], size: sizeOf(this.node(flow.to))}
      if (wide) {
        routes[flow.key] = between(a, b)
      } else {
        const points = g.edge({v: flow.from, w: flow.to, name: flow.key}).points
        routes[flow.key] = {
          d: throughPoints(points),
          mid: along(points, 0.5),
          plus: along(points, flow.label ? 0.8 : 0.5),
        }
      }
    }

    this.render(routes, wide)
  },

  node(id) {
    return this.state.nodes.find(node => node.id === id)
  },

  // Saved places where there are any; elsewhere dagre's, moved along with
  // the nearest step before it that has a saved place.
  freePlaces(auto) {
    const saved = this.state.layout || {}
    const places = {}
    for (const [id, [x, y]] of Object.entries(saved)) if (auto[id]) places[id] = {x, y}

    let changed = true
    while (changed) {
      changed = false
      for (const node of this.state.nodes) {
        if (places[node.id]) continue
        const before = this.state.flows.find(flow => flow.to === node.id && places[flow.from])
        if (before) {
          const from = places[before.from]
          places[node.id] = {
            x: from.x + (auto[node.id].x - auto[before.from].x),
            y: from.y + (auto[node.id].y - auto[before.from].y),
          }
          changed = true
        }
      }
    }
    for (const node of this.state.nodes) if (!places[node.id]) places[node.id] = {...auto[node.id]}
    return places
  },

  // ---------
  // Drawing
  // ---------

  render(routes, wide) {
    const state = this.state
    const scrollTop = this.viewport ? this.viewport.scrollTop : 0
    const scrollLeft = this.viewport ? this.viewport.scrollLeft : 0

    const boxes = state.nodes.map(node => {
      const [w, h] = sizeOf(node)
      const {x, y} = this.places[node.id]
      return {minX: x - w / 2, minY: y - h / 2, maxX: x + w / 2, maxY: y + h / 2}
    })
    const minX = Math.min(...boxes.map(b => b.minX)) - PAD
    const minY = Math.min(...boxes.map(b => b.minY)) - PAD
    const maxX = Math.max(...boxes.map(b => b.maxX)) + PAD + 80
    const maxY = Math.max(...boxes.map(b => b.maxY)) + PAD
    this.bounds = {minX, minY, width: maxX - minX, height: maxY - minY}

    this.el.replaceChildren()
    this.viewport = el("div", {
      class: wide
        ? "absolute inset-0 overflow-hidden touch-none select-none cursor-grab"
        : "absolute inset-0 overflow-auto overscroll-contain",
      "data-process-viewport": true,
    })
    this.world = el("div", {class: "absolute left-0 top-0 origin-top-left"})
    this.el.appendChild(this.viewport)

    if (wide) {
      // World coordinates as they are: what is dragged past an edge stays put.
      this.viewport.appendChild(this.world)
      this.world.style.width = "1px"
      this.world.style.height = "1px"
      this.world.style.overflow = "visible"
      if (!this.view.fitted) this.fit()
      this.applyView()
      this.bindPan()
    } else {
      // Scaled to the width of the phone, down to a point, then it scrolls.
      const available = this.el.clientWidth - 16
      const scale = Math.max(PHONE_MIN_SCALE, Math.min(1, available / this.bounds.width))
      const sized = el("div", {
        class: "relative mx-auto",
        style: {width: `${this.bounds.width * scale}px`, height: `${this.bounds.height * scale + 120}px`},
      })
      this.world.style.width = `${this.bounds.width}px`
      this.world.style.height = `${this.bounds.height}px`
      this.world.style.transform = `scale(${scale})`
      sized.appendChild(this.world)
      this.viewport.appendChild(sized)
    }

    this.offset = wide ? {x: 0, y: 0} : {x: -minX, y: -minY}
    this.drawFlows(routes, wide)
    this.drawNodes(wide)
    if (wide) this.drawTools()

    if (!wide) {
      this.viewport.scrollTop = scrollTop
      this.viewport.scrollLeft = scrollLeft
      // A drawing wider than the phone opens with its start in the middle.
      if (!this.view.fitted) {
        const start = state.nodes.find(node => node.kind === "start")
        if (start) {
          const scale = parseFloat(this.world.style.transform.replace(/[^\d.]/g, "")) || 1
          const x = this.at(this.places[start.id]).x * scale
          this.viewport.scrollLeft = Math.max(0, x - this.viewport.clientWidth / 2)
        }
        this.view.fitted = true
      }
      const selected = this.world.querySelector("[aria-pressed=true]")
      if (selected && this.lastSelected !== state.selected) {
        selected.scrollIntoView({block: "center", behavior: "smooth"})
      }
    }
    this.lastSelected = state.selected
  },

  at(point) {
    return {x: point.x + this.offset.x, y: point.y + this.offset.y}
  },

  drawFlows(routes, wide) {
    const state = this.state
    this.flowEls = []
    const layer = svg("svg", {
      class: "absolute left-0 top-0 overflow-visible",
      width: wide ? 1 : this.bounds.width,
      height: wide ? 1 : this.bounds.height,
    })
    const defs = svg("defs")
    for (const [name, cls] of [
      ["plain", "fill-base-content/40"],
      ["selected", "fill-primary"],
      ["invalid", "fill-error"],
    ]) {
      const marker = svg("marker", {
        id: `${this.el.id}-arrow-${name}`,
        viewBox: "0 0 10 10",
        refX: "9",
        refY: "5",
        markerWidth: "7",
        markerHeight: "7",
        orient: "auto-start-reverse",
      })
      marker.appendChild(svg("path", {d: "M0,0 L10,5 L0,10 z", class: cls}))
      defs.appendChild(marker)
    }
    layer.appendChild(defs)

    const group = svg("g", {transform: `translate(${this.offset.x},${this.offset.y})`})
    layer.appendChild(group)

    for (const flow of state.flows) {
      const route = routes[flow.key]
      const selected = state.selected === `flow:${flow.key}`
      const tone = flow.invalid ? "invalid" : selected ? "selected" : "plain"
      const stroke = {
        plain: "stroke-base-content/35",
        selected: "stroke-primary",
        invalid: "stroke-error",
      }[tone]

      group.appendChild(
        svg("path", {
          d: route.d,
          class: `${stroke} fill-none transition-colors`,
          "stroke-width": selected ? "2.5" : "1.75",
          "stroke-dasharray": flow.kind === "deadline" ? "5 4" : "",
          "marker-end": `url(#${this.el.id}-arrow-${tone})`,
        }),
      )

      const hit = svg("path", {
        d: route.d,
        class: "fill-none stroke-transparent cursor-pointer",
        "stroke-width": "16",
        "pointer-events": "stroke",
        "data-flow": flow.key,
      })
      hit.addEventListener("click", event => {
        event.stopPropagation()
        this.push("process_editor_select", {flow: flow.key})
      })
      group.appendChild(hit)

      if (flow.label) {
        const mid = this.at(route.mid)
        const label = el("button", {
          type: "button",
          class: [
            "absolute z-10 max-w-40 -translate-x-1/2 -translate-y-1/2 truncate rounded-full border px-2 py-0.5 text-[11px] font-medium shadow-xs transition hover:shadow-sm",
            selected
              ? "border-primary bg-primary text-primary-content"
              : flow.invalid
                ? "border-error/50 bg-error/10 text-error"
                : "border-base-300 bg-base-100 text-base-content/75",
          ].join(" "),
          style: {left: `${mid.x}px`, top: `${mid.y}px`},
          "data-flow-label": flow.key,
          text: flow.label,
        })
        label.addEventListener("click", event => {
          event.stopPropagation()
          this.push("process_editor_select", {flow: flow.key})
        })
        this.world.appendChild(label)
        this.flowEls.push(label)
      }

      if (state.editable && !wide) {
        const at = this.at(route.plus)
        const plus = el("button", {
          type: "button",
          id: `${this.el.id}-insert-${flow.key}`,
          class:
            "absolute z-20 grid size-7 -translate-x-1/2 -translate-y-1/2 place-items-center rounded-full bg-primary text-primary-content shadow-md ring-4 ring-base-100 transition duration-150 hover:scale-110 active:scale-95",
          style: {left: `${at.x}px`, top: `${at.y}px`},
          "aria-label": state.labels?.add,
          title: state.labels?.add,
        }, [el("span", {class: "hero-plus-mini size-4"})])
        plus.addEventListener("click", event => {
          event.stopPropagation()
          this.push("process_editor_insert_menu", {flow: flow.key})
        })
        this.world.appendChild(plus)
        this.flowEls.push(plus)
      }
    }

    this.world.prepend(layer)
    this.flowEls.push(layer)
    this.layer = layer
  },

  drawNodes(wide) {
    const state = this.state
    for (const node of state.nodes) {
      const [w, h] = sizeOf(node)
      const place = this.at(this.places[node.id])
      const selected = state.selected === `node:${node.id}`
      const pill = PILLS.has(node.kind)

      const ring = node.invalid
        ? "ring-2 ring-error ring-offset-2 ring-offset-base-100"
        : selected
          ? "ring-2 ring-primary ring-offset-2 ring-offset-base-100"
          : ""

      const button = el("button", {
        type: "button",
        id: `${this.el.id}-node-${node.id}`,
        "data-node": node.id,
        "aria-pressed": selected ? "true" : "false",
        "aria-label": [node.title, node.detail].filter(Boolean).join(": "),
        class: [
          "absolute z-10 flex items-center gap-2 text-left transition-shadow duration-150 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary",
          pill
            ? `justify-center rounded-full border px-3 text-sm font-semibold shadow-sm ${TONES[node.kind]}`
            : "rounded-2xl border border-base-300 bg-base-100 px-2.5 shadow-sm hover:shadow-md",
          wide && state.editable ? "cursor-move" : "cursor-pointer",
          ring,
        ].join(" "),
        style: {left: `${place.x - w / 2}px`, top: `${place.y - h / 2}px`, width: `${w}px`, height: `${h}px`},
      })

      if (pill) {
        button.appendChild(el("span", {class: `${node.icon} size-4 shrink-0`}))
        button.appendChild(el("span", {class: "truncate", text: node.title}))
      } else {
        button.appendChild(
          el("span", {class: `grid size-9 shrink-0 place-items-center rounded-xl ${TONES[node.kind] || TONES.message}`}, [
            el("span", {class: `${node.icon} size-5`}),
          ]),
        )
        button.appendChild(
          el("span", {class: "min-w-0 flex-1"}, [
            el("span", {class: "block truncate text-sm font-semibold text-base-content", text: node.title}),
            node.detail ? el("span", {class: "block truncate text-xs text-base-content/60", text: node.detail}) : null,
          ]),
        )
      }

      this.bindNode(button, node, wide)
      this.world.appendChild(button)

      if (wide && state.editable && node.kind !== "end") {
        const handle = el("span", {
          class:
            "absolute z-20 size-3.5 -translate-x-1/2 -translate-y-1/2 cursor-crosshair rounded-full border-2 border-base-100 bg-primary shadow transition hover:scale-125",
          style: {left: `${place.x}px`, top: `${place.y + h / 2}px`},
          "data-handle": node.id,
          title: state.labels?.connect,
        })
        this.bindHandle(handle, node)
        this.world.appendChild(handle)
      }
    }
  },

  drawTools() {
    const labels = this.state.labels || {}
    const tool = (icon, label, action) => {
      const button = el("button", {
        type: "button",
        class:
          "grid size-9 place-items-center rounded-xl text-base-content/70 transition hover:bg-base-200 hover:text-base-content",
        "aria-label": label,
        title: label,
      }, [el("span", {class: `${icon} size-5`})])
      button.addEventListener("click", event => {
        event.stopPropagation()
        action()
      })
      return button
    }
    const bar = el("div", {
      class: "absolute bottom-4 left-4 z-30 flex gap-1 rounded-2xl border border-base-300 bg-base-100/95 p-1 shadow-lg backdrop-blur",
    }, [
      tool("hero-minus", labels.zoom_out, () => this.zoomBy(1 / 1.2)),
      tool("hero-plus", labels.zoom_in, () => this.zoomBy(1.2)),
      tool("hero-arrows-pointing-in", labels.fit, () => {
        this.fit()
        this.applyView()
      }),
    ])
    this.el.appendChild(bar)
  },

  // ---------
  // Pointer
  // ---------

  push(event, payload) {
    this.pushEvent(event, payload)
  },

  bindNode(button, node, wide) {
    if (!(wide && this.state.editable)) {
      button.addEventListener("click", event => {
        event.stopPropagation()
        this.push("process_editor_select", {node: node.id})
      })
      return
    }

    button.addEventListener("pointerdown", event => {
      if (event.button !== 0) return
      event.stopPropagation()
      button.setPointerCapture(event.pointerId)
      const start = {x: event.clientX, y: event.clientY}
      const origin = {...this.places[node.id]}
      let moved = false

      const move = moveEvent => {
        const dx = (moveEvent.clientX - start.x) / this.view.zoom
        const dy = (moveEvent.clientY - start.y) / this.view.zoom
        if (!moved && Math.hypot(dx, dy) < DRAG_START) return
        moved = true
        this.places[node.id] = {x: snap(origin.x + dx), y: snap(origin.y + dy)}
        this.redrawMoved(node.id)
      }

      const up = () => {
        button.removeEventListener("pointermove", move)
        button.removeEventListener("pointerup", up)
        button.removeEventListener("pointercancel", up)
        if (moved) {
          const positions = {}
          for (const [id, {x, y}] of Object.entries(this.places)) positions[id] = [Math.round(x), Math.round(y)]
          this.push("process_editor_move", {positions})
        } else {
          this.push("process_editor_select", {node: node.id})
        }
      }

      button.addEventListener("pointermove", move)
      button.addEventListener("pointerup", up)
      button.addEventListener("pointercancel", up)
    })
  },

  // Moves the dragged step and redraws the flows, without waiting for the
  // server and without touching the step that holds the pointer.
  redrawMoved(id) {
    if (this.frame) return
    this.frame = requestAnimationFrame(() => {
      this.frame = null
      const routes = {}
      for (const flow of this.state.flows) {
        routes[flow.key] = between(
          {...this.places[flow.from], size: sizeOf(this.node(flow.from))},
          {...this.places[flow.to], size: sizeOf(this.node(flow.to))},
        )
      }
      for (const old of this.flowEls) old.remove()
      this.drawFlows(routes, true)

      const [w, h] = sizeOf(this.node(id))
      const place = this.at(this.places[id])
      const button = this.world.querySelector(`[data-node="${CSS.escape(id)}"]`)
      const handle = this.world.querySelector(`[data-handle="${CSS.escape(id)}"]`)
      if (button) Object.assign(button.style, {left: `${place.x - w / 2}px`, top: `${place.y - h / 2}px`})
      if (handle) Object.assign(handle.style, {left: `${place.x}px`, top: `${place.y + h / 2}px`})
    })
  },

  bindHandle(handle, node) {
    handle.addEventListener("pointerdown", event => {
      if (event.button !== 0) return
      event.stopPropagation()
      handle.setPointerCapture(event.pointerId)
      const from = this.at({x: this.places[node.id].x, y: this.places[node.id].y + sizeOf(node)[1] / 2})
      const line = svg("path", {class: "stroke-primary fill-none", "stroke-width": "2", "stroke-dasharray": "6 4"})
      this.layer.appendChild(line)

      const move = moveEvent => {
        const to = this.toWorld(moveEvent.clientX, moveEvent.clientY)
        line.setAttribute("d", `M${from.x},${from.y} L${to.x},${to.y}`)
      }

      const up = upEvent => {
        handle.removeEventListener("pointermove", move)
        handle.removeEventListener("pointerup", up)
        handle.removeEventListener("pointercancel", up)
        line.remove()
        const target = document.elementFromPoint(upEvent.clientX, upEvent.clientY)?.closest("[data-node]")
        if (target && target.dataset.node !== node.id && this.el.contains(target)) {
          this.push("process_editor_connect", {from: node.id, to: target.dataset.node})
        }
      }

      handle.addEventListener("pointermove", move)
      handle.addEventListener("pointerup", up)
      handle.addEventListener("pointercancel", up)
    })
  },

  // World coordinates (with the drawing's offset) of a point on the screen.
  toWorld(clientX, clientY) {
    const rect = this.viewport.getBoundingClientRect()
    return {x: (clientX - rect.left - this.view.x) / this.view.zoom, y: (clientY - rect.top - this.view.y) / this.view.zoom}
  },

  bindPan() {
    const viewport = this.viewport
    const pointers = new Map()
    let pinch = null

    viewport.addEventListener("pointerdown", event => {
      if (event.target.closest("[data-node],[data-handle],[data-flow],[data-flow-label],button")) return
      viewport.setPointerCapture(event.pointerId)
      pointers.set(event.pointerId, {x: event.clientX, y: event.clientY})
      viewport.classList.add("cursor-grabbing")
      this.panned = false
      if (pointers.size === 2) {
        const [a, b] = [...pointers.values()]
        pinch = {distance: Math.hypot(a.x - b.x, a.y - b.y), zoom: this.view.zoom}
      }
    })

    viewport.addEventListener("pointermove", event => {
      const last = pointers.get(event.pointerId)
      if (!last) return
      const now = {x: event.clientX, y: event.clientY}
      pointers.set(event.pointerId, now)
      if (pointers.size === 2 && pinch) {
        const [a, b] = [...pointers.values()]
        const distance = Math.hypot(a.x - b.x, a.y - b.y)
        this.zoomTo(pinch.zoom * (distance / pinch.distance), (a.x + b.x) / 2, (a.y + b.y) / 2)
      } else if (pointers.size === 1) {
        this.view.x += now.x - last.x
        this.view.y += now.y - last.y
        if (Math.abs(now.x - last.x) + Math.abs(now.y - last.y) > 1) this.panned = true
        this.applyView()
      }
    })

    // Only a pointer that went down on the background ends here: one that a
    // step or a flow took bubbles up too, and must not unpick what it picked.
    const end = event => {
      if (!pointers.has(event.pointerId)) return
      pointers.delete(event.pointerId)
      if (pointers.size < 2) pinch = null
      if (pointers.size === 0) {
        viewport.classList.remove("cursor-grabbing")
        if (!this.panned && event.type === "pointerup") this.push("process_editor_select", {})
      }
    }
    viewport.addEventListener("pointerup", end)
    viewport.addEventListener("pointercancel", end)

    viewport.addEventListener(
      "wheel",
      event => {
        event.preventDefault()
        if (event.ctrlKey || event.metaKey) {
          this.zoomTo(this.view.zoom * Math.exp(-event.deltaY / 300), event.clientX, event.clientY)
        } else {
          this.view.x -= event.deltaX
          this.view.y -= event.deltaY
          this.applyView()
        }
      },
      {passive: false},
    )
  },

  zoomBy(factor) {
    const rect = this.viewport.getBoundingClientRect()
    this.zoomTo(this.view.zoom * factor, rect.left + rect.width / 2, rect.top + rect.height / 2)
  },

  zoomTo(zoom, clientX, clientY) {
    zoom = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, zoom))
    const rect = this.viewport.getBoundingClientRect()
    const px = clientX - rect.left
    const py = clientY - rect.top
    this.view.x = px - ((px - this.view.x) / this.view.zoom) * zoom
    this.view.y = py - ((py - this.view.y) / this.view.zoom) * zoom
    this.view.zoom = zoom
    this.applyView()
  },

  fit() {
    const rect = this.el.getBoundingClientRect()
    const {minX, minY, width, height} = this.bounds
    const zoom = Math.min(1, Math.max(MIN_ZOOM, Math.min((rect.width - 2 * PAD) / width, (rect.height - 2 * PAD) / height)))
    this.view.zoom = zoom
    this.view.x = (rect.width - width * zoom) / 2 - minX * zoom
    this.view.y = Math.max(PAD, (rect.height - height * zoom) / 2) - minY * zoom
    this.view.fitted = true
  },

  applyView() {
    if (this.world) this.world.style.transform = `translate(${this.view.x}px, ${this.view.y}px) scale(${this.view.zoom})`
  },

  key(event) {
    if (!this.state.editable) return
    if (event.target.closest("input, textarea, select, [contenteditable]")) return
    if ((event.key === "Delete" || event.key === "Backspace") && this.state.selected) {
      event.preventDefault()
      this.push("process_editor_delete", {})
    }
  },
}
