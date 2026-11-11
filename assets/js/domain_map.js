// The map of the domain at `/domain`. The server renders the words around it
// and hands over the data in `data-map`; this draws the diagram from that data
// and keeps what the visitor picks. Nothing goes back to the server.

const SVG = "http://www.w3.org/2000/svg"
const HUBS = ["Profile", "Group"]
const LINE = {cascade: "c", nilify: "n-del", restrict: "r", soft: "s"}

// The core: a sentence per arrow, read from subject to object.
const CORE = {
  width: 1040,
  height: 484,
  nodeWidth: 172,
  nodeHeight: 60,
  nodes: {
    Account: [24, 70],
    Profile: [297, 70],
    Value: [570, 70],
    ValueAttachment: [844, 70],
    GroupRole: [24, 230],
    GroupMembership: [297, 230],
    Group: [570, 230],
    GroupAltDescription: [844, 230],
    GroupManifest: [297, 390],
    Event: [570, 390],
    Tag: [844, 390],
  },
  tagged: ["Group", "Profile", "Event", "Value", "ValueAttachment"],
  // label: [x, anchor, y, word, y of the line under it, that line]
  edges: [
    {from: "Account", to: "Profile", d: "M196 100H297", label: [246.5, "middle", 92, "uses", 114, "n : m"]},
    {from: "Profile", to: "Value", d: "M469 100H570", label: [519.5, "middle", 92, "writes", 114, "1 : n"]},
    {from: "Value", to: "ValueAttachment", d: "M742 86H844", label: [793, "middle", 78, "carries", 101, "1 : n"]},
    {from: "Profile", to: "GroupMembership", d: "M383 130V230", label: [391, "start", 176, "is_member", 190, "1 : n"]},
    {from: "GroupMembership", to: "Group", d: "M469 246H570", label: [519.5, "middle", 238, "in_group", 262, "n : 1"]},
    {from: "GroupMembership", to: "GroupRole", d: "M297 260H196", soft: true, label: [246.5, "middle", 252, "holds_roles", 274, "by_key"]},
    {from: "Group", to: "Value", d: "M626 230V130", loop: true, label: [618, "end", 176, "contains", 190, "1 : n"]},
    {from: "Value", to: "Group", d: "M686 130V230", loop: true, label: [694, "start", 176, "opens_thread", 190, "1 : 0..1"]},
    {from: "Group", to: "GroupAltDescription", d: "M742 276H844", label: [793, "middle", 268, "descriptions", 292, "1 : n"]},
    {from: "Value", to: "GroupAltDescription", points: [[742, 114], [793, 114], [793, 246], [844, 246]], label: [801, "start", 172, "app_data", 186, "0..1 : n"]},
    {from: "Group", to: "Event", d: "M656 290V390", label: [664, "start", 336, "calendar", 350, "1 : n"]},
    {from: "Group", to: "GroupManifest", points: [[570, 278], [520, 278], [520, 420], [469, 420]], label: [512, "end", 340, "has_manifest", 354, "1 : 0..1"]},
    {from: "GroupManifest", to: "GroupRole", points: [[297, 420], [110, 420], [110, 290]], label: [203, "middle", 412, "defines", 436, "1 : n"]},
    {from: "Group", to: "Group", d: "M590 290C590 334 636 334 636 290", label: [613, "middle", 350, "sub_group", 364, "sub_group_of"]},
    {from: "Value", to: "Value", d: "M626 70C626 26 686 26 686 70", label: [656, "middle", 14, "reply", 28, "reply_to"]},
  ],
}

// All tables: a fixed grid by domain, keys point away from the table holding them.
const COLUMN = [26, 228, 430, 632, 834]
const TABLES = {
  width: 1032,
  height: 690,
  nodeWidth: 172,
  nodeHeight: 46,
  nodes: {
    AccountToken: [COLUMN[0], 44],
    Account: [COLUMN[0], 116],
    PushSubscription: [COLUMN[0], 188],
    GmailRefreshToken: [COLUMN[0], 260],
    // Under the legend, which stands at the left from y 338 to 432.
    GroupFollow: [COLUMN[0], 476],
    GroupNotice: [COLUMN[0], 548],
    GroupNoticeReceipt: [COLUMN[0], 620],
    Profile: [COLUMN[1], 44],
    AccountProfile: [COLUMN[1], 116],
    ProfileInvitation: [COLUMN[2], 44],
    GroupAccountInvitation: [COLUMN[2], 116],
    GroupInvitation: [COLUMN[3], 44],
    GroupJoinRequest: [COLUMN[3], 116],
    GroupJoinRequestApproval: [COLUMN[4], 116],
    GroupMembership: [COLUMN[1], 212],
    Group: [COLUMN[2], 212],
    GroupMemberRole: [COLUMN[1], 284],
    GroupAltDescription: [COLUMN[2], 284],
    GroupRole: [COLUMN[1], 356],
    GroupManifest: [COLUMN[2], 356],
    Value: [COLUMN[3], 212],
    ValueAttachment: [COLUMN[4], 212],
    ValueReaction: [COLUMN[3], 284],
    GroupValueRead: [COLUMN[4], 284],
    Event: [COLUMN[3], 380],
    Response: [COLUMN[4], 380],
    MemberSetting: [COLUMN[4], 452],
    Poll: [COLUMN[3], 548],
    PollOption: [COLUMN[4], 548],
    PollBallot: [COLUMN[4], 620],
    GroupReaction: [COLUMN[1], 428],
    GroupBlock: [COLUMN[2], 428],
    Tag: [COLUMN[1], 524],
    Tagging: [COLUMN[2], 524],
  },
  clusters: {
    account: [16, 14, 192, 302],
    profiles: [218, 14, 192, 158],
    joining: [420, 14, 596, 158],
    group: [218, 182, 394, 302],
    content: [622, 182, 394, 158],
    calendar: [622, 350, 394, 158],
    polls: [622, 518, 394, 158],
    notices: [16, 446, 192, 230],
    tags: [218, 494, 394, 86],
  },
}

// Lines that would run behind a node on the shortest way.
const ROUTES = {
  "GroupAccountInvitation>Account": {from: "l", to: "r", control: [0, 64]},
  "GroupInvitation>Profile": {from: "l", to: "r", control: [0, 63]},
  "GroupManifest>Group": {from: "r", to: "r", bulge: 26},
  "Event>Value": {from: "l", to: "l", bulge: 24},
  "Tagging>Value": {from: "r", to: "l"},
  "Tagging>Group": {from: "r", to: "r", bulge: 22},
  "Tag>Profile": {from: "l", to: "l", bulge: 24},
  "GroupMembership>Profile": {from: "l", to: "l", bulge: 24},
  "GroupReaction>Profile": {from: "l", to: "l", bulge: 24},
  "GroupReaction>Group": {from: "r", to: "l"},
  "GroupBlock>Group": {from: "r", to: "r", bulge: 34},
  "GroupBlock>Profile": {from: "l", to: "l", bulge: 40},
  "Tagging>ValueAttachment": {d: "M602 534C618 512 612 345 652 345H790C812 345 818 330 818 300V262C818 252 824 248 834 247"},
}

const element = (tag, attributes, parent, text) => {
  const node = document.createElementNS(SVG, tag)
  for (const name in attributes || {}) {
    if (attributes[name] != null) node.setAttribute(name, attributes[name])
  }
  if (text != null) node.textContent = text
  if (parent) parent.appendChild(node)
  return node
}

const escapeHTML = text =>
  String(text).replace(/[&<>"]/g, char => ({"&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;"}[char]))

const rich = text => escapeHTML(text).replace(/`([^`]+)`/g, "<code>$1</code>")

// A path through `points` with rounded corners.
const elbow = (points, radius = 10) => {
  let d = `M${points[0][0]} ${points[0][1]}`
  for (let i = 1; i < points.length - 1; i++) {
    const [x0, y0] = points[i - 1]
    const [x1, y1] = points[i]
    const [x2, y2] = points[i + 1]
    const before = Math.hypot(x1 - x0, y1 - y0)
    const after = Math.hypot(x2 - x1, y2 - y1)
    const cut = Math.min(radius, before / 2, after / 2)
    d += `L${x1 - (x1 - x0) / before * cut} ${y1 - (y1 - y0) / before * cut}`
    d += `Q${x1} ${y1} ${x1 + (x2 - x1) / after * cut} ${y1 + (y2 - y1) / after * cut}`
  }
  const [lastX, lastY] = points[points.length - 1]
  return `${d}L${lastX} ${lastY}`
}

const sidesBetween = (a, b) => {
  const dx = b.x + b.width / 2 - (a.x + a.width / 2)
  const dy = b.y + b.height / 2 - (a.y + a.height / 2)
  if (Math.abs(dx) >= Math.abs(dy) * 1.6) return dx > 0 ? ["r", "l"] : ["l", "r"]
  return dy > 0 ? ["b", "t"] : ["t", "b"]
}

const pointOn = (box, side, position) => {
  if (side === "l") return [box.x, box.y + position * box.height]
  if (side === "r") return [box.x + box.width, box.y + position * box.height]
  if (side === "t") return [box.x + position * box.width, box.y]
  return [box.x + position * box.width, box.y + box.height]
}

const curve = (route, from, to, sideFrom) => {
  const [px, py] = from
  const [qx, qy] = to
  if (route.control) {
    const cx = (px + qx) / 2 + route.control[0]
    const cy = (py + qy) / 2 + route.control[1]
    return `M${px} ${py}Q${cx} ${cy} ${qx} ${qy}`
  }
  if (route.bulge) {
    const out = sideFrom === "r" ? route.bulge : -route.bulge
    return `M${px} ${py}C${px + out} ${py} ${qx + out} ${qy} ${qx} ${qy}`
  }
  if (sideFrom === "l" || sideFrom === "r") {
    const way = sideFrom === "r" ? 1 : -1
    const reach = Math.max(Math.abs(qx - px) / 2, 22)
    return `M${px} ${py}C${px + way * reach} ${py} ${qx - way * reach} ${qy} ${qx} ${qy}`
  }
  const way = sideFrom === "b" ? 1 : -1
  const reach = Math.max(Math.abs(qy - py) / 2, 12)
  return `M${px} ${py}C${px} ${py + way * reach} ${qx} ${qy - way * reach} ${qx} ${qy}`
}

export function installDomainMap() {
  const root = document.getElementById("domain-map")
  if (!root) return

  const {entities, edges, domains, labels} = JSON.parse(root.dataset.map)
  const map = root.querySelector("#domain-diagram")
  const scroller = root.querySelector(".dm-scroll")
  const figure = root.querySelector(".dm-figure")
  const detailBox = root.querySelector("#domain-detail")
  const softButton = root.querySelector("#domain-soft-only")
  const allCheckbox = root.querySelector("#domain-all-links")
  const domainChips = [...root.querySelectorAll("[data-domain]")]

  const state = {view: "core", selected: null, hover: null, domain: null, all: false, soft: false}
  let nodes = {}
  let lines = []
  let wordings = []

  const markers = () => {
    const defs = element("defs", {}, map)
    const marker = (id, width, height, refX, refY, draw) => {
      const node = element("marker", {
        id,
        markerUnits: "userSpaceOnUse",
        markerWidth: width,
        markerHeight: height,
        refX,
        refY,
        orient: "auto",
      }, defs)
      draw(node)
    }
    marker("dm-cascade", 9, 9, 8.5, 4.5, node => element("path", {d: "M0 .8L8.5 4.5L0 8.2z", class: "f-c"}, node))
    marker("dm-nilify", 10, 10, 9, 5, node => element("circle", {cx: 5, cy: 5, r: 3.4, class: "f-n"}, node))
    marker("dm-restrict", 11, 13, 10.5, 6.5, node => {
      element("path", {d: "M0 2.5L7.5 6.5L0 10.5z", class: "f-r"}, node)
      element("path", {d: "M9.5 .5V12.5", class: "b-r"}, node)
    })
    marker("dm-soft", 9, 9, 8, 4.5, node => element("path", {d: "M.5 .8L8 4.5L.5 8.2", class: "o-s"}, node))
    marker("dm-loop", 12, 12, 11, 6, node => element("path", {d: "M0 .8L11 6L0 11.2z", class: "f-a"}, node))
  }

  const drawNode = (layer, id, x, y, width, height) => {
    const entity = entities[id]
    const group = element("g", {
      class: `n${HUBS.includes(id) ? " hubn" : ""}`,
      transform: `translate(${x} ${y})`,
      tabindex: 0,
      role: "button",
      "aria-label": `${entity.name}, ${id}`,
      "data-id": id,
      style: `--dc:var(--dm-${entity.domain})`,
    }, layer)
    element("rect", {width, height, rx: 9, class: "nb"}, group)
    element("text", {x: 11, y: height / 2 - 3, class: "nt"}, group, entity.name)
    const code = element("text", {x: 11, y: height / 2 + 12, class: "ns"}, group, id)
    nodes[id] = {group, code}
    return group
  }

  const drawCore = () => {
    map.setAttribute("viewBox", `0 0 ${CORE.width} ${CORE.height}`)
    map.setAttribute("aria-label", labels.core_description)
    markers()
    const lineLayer = element("g", {}, map)
    const nodeLayer = element("g", {}, map)
    const wordLayer = element("g", {}, map)

    CORE.edges.forEach(edge => {
      const line = element("path", {
        d: edge.d || elbow(edge.points),
        class: `e core${edge.loop ? " loop-a" : ""}${edge.soft ? " s" : ""}`,
        "marker-end": `url(#dm-${edge.loop ? "loop" : edge.soft ? "soft" : "cascade"})`,
      }, lineLayer)
      lines.push({line, from: edge.from, to: edge.to})

      const [x, anchor, y, word, underY, under] = edge.label
      const top = element("text", {x, y, "text-anchor": anchor, class: `l${edge.loop ? " a" : ""}`}, wordLayer, labels.core[word])
      const bottom = element("text", {x, y: underY, "text-anchor": anchor, class: "ls"}, wordLayer, labels.core[under] || under)
      wordings.push({text: top, from: edge.from, to: edge.to}, {text: bottom, from: edge.from, to: edge.to})
    })

    for (const id in CORE.nodes) {
      const [x, y] = CORE.nodes[id]
      const group = drawNode(nodeLayer, id, x, y, CORE.nodeWidth, CORE.nodeHeight)
      if (CORE.tagged.includes(id)) element("text", {x: CORE.nodeWidth - 10, y: 18, class: "tagm"}, group, "#")
    }
    element("text", {x: 930, y: 470, "text-anchor": "middle", class: "note"}, wordLayer, labels.tag_note)
  }

  const drawLegend = () => {
    const group = element("g", {transform: "translate(28 338)"}, map)
    const rows = [
      ["cascade", labels.legend_cascade],
      ["nilify", labels.legend_nilify],
      ["restrict", labels.legend_restrict],
      ["soft", labels.legend_soft],
    ]
    rows.forEach(([kind, text], index) => {
      const y = index * 21
      element("path", {
        d: `M0 ${y}H34`,
        class: `e lge ${LINE[kind]}`,
        style: "opacity:1",
        "marker-end": `url(#dm-${kind})`,
      }, group)
      element("text", {x: 44, y: y + 4, class: "lg"}, group, text)
    })

    const y = rows.length * 21 + 3
    const stamps = element("g", {class: "lgst"}, group)
    ;[["P", "profiles"], ["G", "group"]].forEach(([letter, domain], index) => {
      const cx = 7 + index * 20
      element("circle", {cx, cy: y, r: 7, class: "st", style: `--dc:var(--dm-${domain})`}, stamps)
      element("text", {x: cx, y: y + 3.2, class: "stt"}, stamps, letter)
    })
    element("text", {x: 44, y: y + 4, class: "lg"}, stamps, labels.legend_hubs)
  }

  const drawTables = () => {
    const {nodeWidth: width, nodeHeight: height} = TABLES
    map.setAttribute("viewBox", `0 0 ${TABLES.width} ${TABLES.height}`)
    map.setAttribute("aria-label", labels.tables_description)
    markers()
    const box = id => ({x: TABLES.nodes[id][0], y: TABLES.nodes[id][1], width, height})
    const clusterLayer = element("g", {}, map)
    const lineLayer = element("g", {}, map)
    const nodeLayer = element("g", {}, map)

    domains.forEach(domain => {
      const [x, y, w, h] = TABLES.clusters[domain.id]
      const style = `--dc:var(--dm-${domain.id})`
      element("rect", {x, y, width: w, height: h, rx: 12, class: "cl", "data-area": domain.id, style}, clusterLayer)
      element("text", {x: x + 11, y: y + 18, class: "clt", "data-area": domain.id, style}, clusterLayer, domain.name)
    })

    const items = edges.map(edge => {
      if (edge.from === edge.to) return {edge, loop: true}
      const route = ROUTES[`${edge.from}>${edge.to}`] || {}
      const a = box(edge.from)
      const b = box(edge.to)
      const [sideFrom, sideTo] = route.from ? [route.from, route.to] : sidesBetween(a, b)
      return {edge, route, a, b, sideFrom, sideTo}
    })

    // Lines on one side of a node spread out, in the order of where they go.
    const sides = {}
    const onSide = (key, item, end, other, side) => {
      sides[key] = sides[key] || {side, list: []}
      sides[key].list.push({item, end, other})
    }
    items.forEach(item => {
      if (item.loop || item.route.d) return
      onSide(item.edge.from + item.sideFrom, item, "fromAt", item.b, item.sideFrom)
      onSide(item.edge.to + item.sideTo, item, "toAt", item.a, item.sideTo)
    })
    Object.values(sides).forEach(({side, list}) => {
      const upright = side === "l" || side === "r"
      list.sort((m, n) => (upright ? m.other.y - n.other.y : m.other.x - n.other.x))
      const margin = upright ? 0.16 : 0.07
      list.forEach((entry, index) => {
        entry.item[entry.end] = list.length === 1 ? 0.5 : margin + (1 - 2 * margin) * index / (list.length - 1)
      })
    })

    items.forEach(item => {
      const {edge} = item
      let d
      if (item.loop) {
        const [x, y] = TABLES.nodes[edge.from]
        const left = x + width - 44
        const right = x + width - 14
        d = `M${left} ${y}C${left} ${y - 24} ${right} ${y - 24} ${right} ${y}`
      } else if (item.route.d) {
        d = item.route.d
      } else {
        d = curve(item.route, pointOn(item.a, item.sideFrom, item.fromAt), pointOn(item.b, item.sideTo, item.toAt), item.sideFrom)
      }
      const kind = edge.kind === "soft" ? "soft" : edge.rule
      const hub = HUBS.includes(edge.to) && edge.from !== edge.to
      const line = element("path", {
        d,
        class: `e ${LINE[kind]}${hub ? " hub" : ""}`,
        "marker-end": `url(#dm-${kind})`,
      }, lineLayer)
      lines.push({line, from: edge.from, to: edge.to})
    })

    for (const id in TABLES.nodes) {
      const [x, y] = TABLES.nodes[id]
      const group = drawNode(nodeLayer, id, x, y, width, height)
      const stamps = HUBS.filter(hub => hub !== id && edges.some(e => e.kind === "key" && e.from === id && e.to === hub))
      stamps.forEach((hub, index) => {
        const cx = width - 12 - (stamps.length - 1 - index) * 17
        element("circle", {cx, cy: 13, r: 7, class: "st", style: `--dc:var(--dm-${entities[hub].domain})`}, group)
        element("text", {x: cx, y: 16.2, class: "stt"}, group, hub[0])
      })
    }
    drawLegend()
  }

  const neighbours = id => {
    const near = {}
    const add = (other, columns) => { (near[other] = near[other] || []).push(columns) }
    edges.forEach(edge => {
      if (edge.from === id && edge.to !== id) add(edge.to, edge.columns)
      else if (edge.to === id && edge.from !== id) add(edge.from, edge.columns)
    })
    return near
  }

  // Both ends of each soft link: a table shows the column it holds, or else
  // the one pointed at.
  const softEnds = () => {
    const near = {}
    const softLinks = edges.filter(edge => edge.kind === "soft")
    softLinks.forEach(edge => { (near[edge.from] = near[edge.from] || []).push(edge.columns) })
    softLinks.forEach(edge => { near[edge.to] = near[edge.to] || [[edge.target]] })
    return near
  }

  const columnLabel = columns => {
    const text = columns.map(column => column.join(" + ")).join(" · ")
    return text.length > 27 && columns.length > 1 ? labels.keys[columns.length] : text
  }

  const apply = () => {
    const active = [state.soft ? null : state.hover, state.selected].find(id => id && nodes[id]) || null
    const core = state.view === "core"
    map.classList.toggle("alle", !core && state.all)
    map.classList.toggle("focus", !!active)
    map.classList.toggle("dom", !active && !!state.domain)
    map.classList.toggle("softonly", !active && state.soft)

    let near = {}
    if (active && core) {
      CORE.edges.forEach(edge => {
        if (edge.from === active && edge.to !== active) near[edge.to] = true
        if (edge.to === active && edge.from !== active) near[edge.from] = true
      })
      if (active === "Tag") CORE.tagged.forEach(id => { near[id] = true })
      if (CORE.tagged.includes(active)) near.Tag = true
    } else if (active) {
      near = neighbours(active)
    } else if (state.soft) {
      near = softEnds()
    }

    for (const id in nodes) {
      const {group, code} = nodes[id]
      const selected = id === active
      const inDomain = !active && state.domain && entities[id].domain === state.domain
      group.classList.toggle("sel", selected)
      group.classList.toggle("hit", selected || !!near[id] || !!inDomain)
      code.textContent = !core && near[id] ? columnLabel(near[id]) : id
    }
    lines.forEach(({line, from, to}) => {
      const on = active
        ? from === active || to === active
        : state.domain && (entities[from].domain === state.domain || entities[to].domain === state.domain)
      line.classList.toggle("on", !!on)
    })
    wordings.forEach(({text, from, to}) => {
      text.classList.toggle("on", !!active && (from === active || to === active))
    })
    map.querySelectorAll(".cl,.clt").forEach(cluster => {
      cluster.classList.toggle("hit", cluster.dataset.area === state.domain)
    })
  }

  const offsetTo = id => {
    if (!nodes[id] || scroller.scrollWidth <= scroller.clientWidth) return 0
    const node = nodes[id].group.getBoundingClientRect()
    const view = scroller.getBoundingClientRect()
    return node.left + node.width / 2 - view.left - view.width / 2
  }

  const render = () => {
    map.textContent = ""
    nodes = {}
    lines = []
    wordings = []
    if (state.view === "core") drawCore()
    else drawTables()

    for (const id in nodes) {
      const {group} = nodes[id]
      group.addEventListener("click", event => {
        event.stopPropagation()
        select(id)
      })
      group.addEventListener("keydown", event => {
        if (event.key !== "Enter" && event.key !== " ") return
        event.preventDefault()
        select(id)
      })
      group.addEventListener("pointerenter", event => {
        if (event.pointerType !== "mouse") return
        state.hover = id
        apply()
      })
      group.addEventListener("pointerleave", event => {
        if (event.pointerType !== "mouse") return
        state.hover = null
        apply()
      })
      group.addEventListener("focus", () => {
        if (!group.matches(":focus-visible")) return
        state.hover = id
        apply()
      })
      group.addEventListener("blur", () => {
        state.hover = null
        apply()
      })
    }
    apply()
    // Narrow screens open on the loop between Group and Value.
    scroller.scrollLeft = 0
    scroller.scrollLeft = offsetTo(state.selected && nodes[state.selected] ? state.selected : "Group")
  }

  const setView = (view, remember) => {
    if (view === "core" && state.soft) {
      state.soft = false
      softButton.setAttribute("aria-pressed", "false")
    }
    state.view = view
    state.hover = null
    root.querySelector("#domain-view-core").setAttribute("aria-pressed", view === "core")
    root.querySelector("#domain-view-tables").setAttribute("aria-pressed", view === "tables")
    root.querySelector("#domain-all-links-wrap").hidden = view !== "tables"
    const caption = state.soft ? "soft" : view
    root.querySelectorAll("[data-caption]").forEach(text => { text.hidden = text.dataset.caption !== caption })
    render()
    if (remember) history.replaceState(null, "", `#${view === "core" ? "core" : "tables"}`)
  }

  const deletionHTML = ({blocked_by: blockedBy, cascades, clears}) => {
    const parts = []
    if (blockedBy.length) {
      parts.push(`<p><b>${escapeHTML(labels.blocked_by)}</b> ${blockedBy
        .map(edge => `${entityButton(edge.from)} (${escapeHTML(edge.columns[0])})`)
        .join(", ")}</p>`)
    }
    if (cascades.length) {
      parts.push(`<p><b>${escapeHTML(labels.cascades)}</b> ${cascades.map(id => entityButton(id)).join(", ")}</p>`)
    }
    if (clears.length) {
      parts.push(`<p><b>${escapeHTML(labels.clears)}</b> ${clears
        .map(edge => `${escapeHTML(entities[edge.from].name)} (${escapeHTML(edge.columns[0])})`)
        .join(", ")}</p>`)
    }
    return parts.length ? parts.join("") : `<p class="dm-empty">${escapeHTML(labels.nothing_else)}</p>`
  }

  const entityButton = id =>
    `<button type="button" class="dm-ent" data-entity="${id}">${escapeHTML(entities[id].name)}</button>`

  const pill = edge => {
    if (edge.kind === "soft") return `<span class="dm-pill s">${escapeHTML(labels.soft)}</span>`
    return `<span class="dm-pill ${edge.rule}">${escapeHTML(labels[edge.rule])}</span>`
  }

  const showDetail = id => {
    const entity = entities[id]
    const outgoing = edges.filter(edge => edge.from === id)
    const incoming = edges.filter(edge => edge.to === id && edge.from !== id)
    const area = domains.find(domain => domain.id === entity.domain).name
    const heading = text => `<h3>${escapeHTML(text)}</h3>`
    const columns = edge => `<span class="dm-field">${escapeHTML(edge.columns.join(" + "))}</span>`
    const fieldRow = (field, tag) =>
      `<li class="dm-row"><span class="dm-field">${escapeHTML(field.name)}</span><span class="dm-type">${escapeHTML(field.type)}</span>${tag}</li>`

    let html = `<div class="dm-head"><div><h2>${escapeHTML(entity.name)}</h2>`
    html += `<p class="dm-where"><span class="mono">${id}</span><span>${escapeHTML(area)}</span></p></div>`
    html += `<button type="button" class="dm-close" id="domain-close">${escapeHTML(labels.close)}</button></div>`
    html += `<p>${rich(entity.description)}</p>`

    html += heading(labels.keys_here)
    html += outgoing.length
      ? `<ul class="dm-rows">${outgoing.map(edge => `<li class="dm-row">${columns(edge)}<span>→ ${entityButton(edge.to)}</span>${pill(edge)}</li>`).join("")}</ul>`
      : `<p class="dm-empty">${escapeHTML(labels.no_keys)}</p>`

    html += heading(`${labels.pointing_here} (${incoming.length})`)
    html += incoming.length
      ? `<ul class="dm-rows">${incoming.map(edge => `<li class="dm-row"><span>${entityButton(edge.from)}</span>${columns(edge)}${pill(edge)}</li>`).join("")}</ul>`
      : `<p class="dm-empty">${escapeHTML(labels.nobody)}</p>`

    html += heading(labels.deleting)
    html += `<div class="dm-deletion">${deletionHTML(entity.deletion)}</div>`

    html += heading(labels.fields)
    html += `<ul class="dm-rows">${entity.fields.map(field => {
      const tag = field["primary?"]
        ? `<span class="dm-pill">${escapeHTML(labels.primary)}</span>`
        : field["key?"] ? `<span class="dm-pill">${escapeHTML(labels.key)}</span>` : ""
      return fieldRow(field, tag)
    }).join("")}</ul>`

    if (entity.virtual.length) {
      html += heading(labels.virtual)
      html += `<ul class="dm-rows">${entity.virtual.map(field => fieldRow(field, "")).join("")}</ul>`
    }

    if (entity.unique.length || entity.checks.length) {
      html += heading(labels.rules)
      entity.checks.forEach(check => {
        html += `<div class="dm-rule">${rich(check.text)}</div>`
      })
      entity.unique.forEach(index => {
        const condition = index.condition ? `<span>${escapeHTML(index.condition)}</span>` : ""
        html += `<div class="dm-rule">${escapeHTML(labels.unique)}: ${escapeHTML(index.columns)}${condition}</div>`
      })
    }

    html += heading(labels.source)
    html += `<p class="mono">${escapeHTML(entity.file)}</p>`
    html += `<p class="mono">${escapeHTML(labels.table)} ${escapeHTML(entity.table)}</p>`

    detailBox.innerHTML = html
    detailBox.hidden = false
    detailBox.scrollTop = 0
    root.querySelector(".dm-side").scrollTop = 0
    root.classList.add("has-sel")
  }

  const smooth = () => (window.matchMedia("(prefers-reduced-motion: reduce)").matches ? "auto" : "smooth")

  // The sheet covers the lower half on narrow screens: keep the node in sight.
  const reveal = id => {
    if (window.matchMedia("(min-width: 1280px)").matches) return
    scroller.scrollBy({left: offsetTo(id), behavior: smooth()})
    figure.scrollIntoView({block: "start", behavior: smooth()})
  }

  function select(id) {
    state.selected = id
    state.hover = null
    if (id && state.view === "core" && !CORE.nodes[id]) setView("tables", true)
    if (id) {
      showDetail(id)
    } else {
      detailBox.hidden = true
      root.classList.remove("has-sel")
    }
    apply()
    if (id) reveal(id)
  }

  const setSoft = on => {
    state.soft = on
    softButton.setAttribute("aria-pressed", on)
    if (on) {
      if (state.selected) select(null)
      state.domain = null
      domainChips.forEach(chip => chip.setAttribute("aria-pressed", "false"))
      state.all = false
      allCheckbox.checked = false
    }
    setView(on ? "tables" : state.view, on)
  }

  root.querySelector("#domain-view-core").addEventListener("click", () => setView("core", true))
  root.querySelector("#domain-view-tables").addEventListener("click", () => setView("tables", true))
  softButton.addEventListener("click", () => setSoft(!state.soft))
  allCheckbox.addEventListener("change", event => {
    state.all = event.target.checked
    if (state.all && state.soft) setSoft(false)
    else apply()
  })
  domainChips.forEach(chip => chip.addEventListener("click", () => {
    state.domain = state.domain === chip.dataset.domain ? null : chip.dataset.domain
    if (state.soft) setSoft(false)
    domainChips.forEach(other => other.setAttribute("aria-pressed", other.dataset.domain === state.domain))
    if (state.domain && state.selected) select(null)
    else apply()
  }))
  root.addEventListener("click", event => {
    if (event.target.closest("#domain-close")) return select(null)
    const button = event.target.closest("[data-entity]")
    if (button) select(button.dataset.entity)
  })
  map.addEventListener("click", () => { if (state.selected) select(null) })
  document.addEventListener("keydown", event => { if (event.key === "Escape" && state.selected) select(null) })
  window.addEventListener("hashchange", () => {
    const view = location.hash.slice(1)
    if (view === "core" || view === "tables") setView(view, false)
  })

  setView(location.hash === "#tables" ? "tables" : "core", false)
}
