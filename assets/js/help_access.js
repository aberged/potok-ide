// The calculator of access rights on the help's page `/pomoc/prava-pristupa`.
// The server draws the example's manifest and hands over, in `data-calc`, the
// names, the texts and the outcome of every case, which
// `PotokIde.Social.Access` worked out (`PotokIdeWeb.HelpGuides.calc/0`). This
// keeps what the visitor picks and looks the outcomes up: it holds no rule of
// its own, so it cannot say other than the app does. Nothing goes back to the
// server.

// What a field of the table says of a permission, in the order a click goes
// through them, as `@cells` in `HelpGuides`.
const CELLS = ["none", "allow", "deny"]
const MARKS = {none: "·", allow: "✓", deny: "✕"}

const element = (tag, className, text) => {
  const node = document.createElement(tag)
  if (className) node.className = className
  if (text !== undefined) node.textContent = text
  return node
}

export function installHelpAccess() {
  const root = document.getElementById("help-access-calc")
  if (!root) return

  const calc = JSON.parse(root.dataset.calc)
  const {texts, outcomes} = calc
  const byId = id => document.getElementById(`hg-calc-${id}`)

  const admin = calc.roles.find(role => role.locked)
  const everyone = calc.roles.find(role => role.allow_only)
  // The two roles of the example's own, in the order `HelpGuides` counts them.
  const [first, second] = calc.roles.filter(role => role !== admin && role !== everyone)
  const assignable = [admin, first, second]

  // What every role says of every permission: the manifest the visitor edits.
  const fields = {}

  const resetManifest = () => {
    calc.roles.forEach(role => {
      fields[role.key] = {}
      calc.permissions.forEach(({key}) => {
        fields[role.key][key] = role.allowed.includes(key)
          ? "allow"
          : role.denied.includes(key)
            ? "deny"
            : "none"
      })
    })
  }

  const state = {account: true, member: true, held: new Set(), public: true, openChat: true, blocked: false, preset: null}

  const usePreset = key => {
    const preset = calc.presets.find(one => one.key === key)
    state.account = preset.account
    state.member = preset.member
    state.held = new Set(preset.held)
    state.blocked = false
    state.preset = preset.key

    // A profile that is not a member shows the most in a public group with an open chat.
    if (preset.account && !preset.member) {
      state.public = true
      state.openChat = true
    }
  }

  const isMember = () => state.account && state.member
  const heldRoles = () => (isMember() ? calc.roles.filter(role => role === everyone || state.held.has(role.key)) : [])
  const names = roles => roles.map(role => role.name).join(", ")

  // `HelpGuides.member_index/4`.
  const memberIndex = permission => {
    const roles = (state.held.has(admin.key) ? 4 : 0) + (state.held.has(first.key) ? 2 : 0) + (state.held.has(second.key) ? 1 : 0)
    const cell = role => CELLS.indexOf(fields[role.key][permission])

    return ((roles * 3 + cell(first)) * 3 + cell(second)) * 2 + cell(everyone)
  }

  const memberHas = permission => outcomes.member[permission][memberIndex(permission)] === "1"

  // `HelpGuides.outsider_index/5`: three marks from there on.
  const outsiderMarks = () => {
    const on = [state.public, state.openChat, state.blocked, fields[everyone.key].react === "allow", fields[everyone.key].post_values === "allow"]
    const index = 3 * on.reduce((sum, one) => sum * 2 + (one ? 1 : 0), 0)

    return [0, 1, 2].map(offset => outcomes.outsider[index + offset] === "1")
  }

  const permissionRows = () =>
    calc.permissions.map(({key}) => {
      if (!state.account) return {key, ok: false, why: texts.why.guest}
      if (!state.member) return {key, ok: false, why: texts.why.outsider}

      const ok = memberHas(key)
      if (state.held.has(admin.key)) return {key, ok, why: texts.why.admin}

      const held = heldRoles()
      const allowedBy = held.filter(role => fields[role.key][key] === "allow")
      const deniedBy = held.filter(role => role !== everyone && fields[role.key][key] === "deny")

      if (ok) return {key, ok, why: `${texts.why.allowed} ${names(allowedBy)}`}

      if (deniedBy.length > 0) {
        const over = allowedBy.length > 0 ? `; ${texts.why.denied_over} (${names(allowedBy)})` : ""
        return {key, ok, denied: true, why: `${texts.why.denied} ${names(deniedBy)}${over}`}
      }

      return {key, ok, why: texts.why.none}
    })

  // What reaches past the permissions: the group's reactions and its chat.
  const extras = rows => {
    const why = texts.extra_why

    if (!state.account) {
      return [
        [texts.extra.react, false, why.guest_react],
        [texts.extra.read, false, why.guest_read],
        [texts.extra.write, false, why.guest_write],
      ]
    }

    if (state.member) {
      const has = key => rows.find(row => row.key === key).ok

      return [
        [texts.extra.react, has("react"), why.member_react],
        [texts.extra.read, true, why.member_read],
        [texts.extra.write, has("post_values"), why.member_write],
      ]
    }

    const [reacts, reads, writes] = outsiderMarks()
    const blocked = state.public && state.blocked
    const open = state.public && state.openChat

    return [
      [texts.extra.react, reacts, !state.public ? why.not_public : blocked ? why.blocked : reacts ? why.react_yes : why.react_no],
      [texts.extra.read, reads, open ? why.read_yes : state.public ? why.not_open : why.not_public],
      [texts.extra.write, writes, !open ? why.not_open : blocked ? why.blocked : writes ? why.write_yes : why.write_no],
    ]
  }

  const cellButton = (role, permission, held) => {
    const says = fields[role.key][permission.key]
    const cell = element("td", held ? "hg-cellc hg-held" : "hg-cellc")
    const shown = role.locked ? "allow" : says
    const button = element("button", `hg-cell ${shown === "none" ? "" : `hg-${shown}`} ${role.locked ? "hg-locked" : ""}`.trim(), MARKS[shown])
    const note = role.locked ? ` ${texts.cell_locked}` : role.allow_only ? ` ${texts.cell_allow_only}` : ""
    const title = `${role.name} · ${permission.label}: ${role.locked ? texts.cell.locked : texts.cell[says]}${note}`

    button.type = "button"
    button.dataset.role = role.key
    button.dataset.perm = permission.key
    button.title = title
    button.setAttribute("aria-label", title)
    if (role.locked) button.setAttribute("aria-disabled", "true")

    cell.append(button)
    return cell
  }

  const render = () => {
    const active = document.activeElement
    const focused = active && root.contains(active) && active.dataset.role ? {role: active.dataset.role, perm: active.dataset.perm} : null
    const member = isMember()

    byId("account").checked = state.account
    byId("member").checked = member
    byId("member").disabled = !state.account

    assignable.forEach(role => {
      const box = byId(`role-${role.key}`)
      box.checked = member && state.held.has(role.key)
      box.disabled = !member
    })

    byId(`role-${everyone.key}`).checked = member
    byId("public").checked = state.public
    byId("openchat").checked = state.public && state.openChat
    byId("openchat").disabled = !state.public
    byId("blocked").checked = state.blocked
    byId("blocked").disabled = !state.account || !state.public

    calc.presets.forEach(preset => byId(`preset-${preset.key}`).setAttribute("aria-pressed", String(preset.key === state.preset)))

    const held = heldRoles()
    calc.roles.forEach(role => byId(`th-${role.key}`).classList.toggle("hg-held", held.includes(role)))

    const rows = permissionRows()

    byId("body").replaceChildren(
      ...calc.permissions.map((permission, index) => {
        const row = rows[index]
        const line = element("tr")
        const name = element("td", "hg-perm")
        name.append(element("b", null, permission.label), element("code", null, permission.key))

        const result = element("td", "hg-res")
        const mark = element("span", row.ok ? "hg-yes" : "hg-nope", row.ok ? "✓" : "✕")
        mark.setAttribute("aria-label", row.ok ? texts.has : texts.has_not)
        result.append(mark)

        line.dataset.permission = permission.key
        line.append(name, ...calc.roles.map(role => cellButton(role, permission, held.includes(role))), result, element("td", row.denied ? "hg-why hg-deny" : "hg-why", row.why))
        return line
      }),
    )

    const preset = calc.presets.find(one => one.key === state.preset)
    const who = element("div")
    who.append(
      element("div", "hg-summary-who", preset ? preset.label : texts.summary.custom),
      element("div", "hg-summary-roles", !state.account ? texts.summary.guest : !state.member ? texts.summary.outsider : `${texts.summary.roles} ${names(held)}`),
    )

    const list = element("ul")
    extras(rows).forEach(([label, ok, why]) => {
      const item = element("li")
      const text = element("span", null, label)
      text.append(element("small", null, why))
      item.append(element("span", ok ? "hg-yes" : "hg-nope", ok ? "✓" : "✕"), text)
      list.append(item)
    })

    const count = element("div", "hg-summary-count", `${rows.filter(row => row.ok).length} ${texts.summary.of}`)
    count.id = "hg-calc-count"

    byId("summary").replaceChildren(who, count, list)

    if (focused) root.querySelector(`button[data-role="${focused.role}"][data-perm="${focused.perm}"]`)?.focus()
  }

  // A click on a field takes it to its next state; "everyone" has no "denies".
  const cycle = (role, permission) => {
    if (role.locked) return

    const says = fields[role.key][permission]
    const states = role.allow_only ? ["none", "allow"] : CELLS
    fields[role.key][permission] = states[(states.indexOf(says) + 1) % states.length]
  }

  const changed = () => {
    state.preset = null
    render()
  }

  byId("presets").addEventListener("click", event => {
    const button = event.target.closest("button[data-preset]")
    if (!button) return

    usePreset(button.dataset.preset)
    render()
  })

  byId("account").addEventListener("change", event => {
    state.account = event.target.checked
    if (!state.account) state.blocked = false
    changed()
  })

  byId("member").addEventListener("change", event => {
    state.member = event.target.checked
    if (state.member) state.blocked = false
    changed()
  })

  assignable.forEach(role =>
    byId(`role-${role.key}`).addEventListener("change", event => {
      if (event.target.checked) state.held.add(role.key)
      else state.held.delete(role.key)
      changed()
    }),
  )

  byId("public").addEventListener("change", event => {
    state.public = event.target.checked
    if (!state.public) state.blocked = false
    changed()
  })

  byId("openchat").addEventListener("change", event => {
    state.openChat = event.target.checked
    changed()
  })

  // A member answers to their roles, so a block also takes them out of the group.
  byId("blocked").addEventListener("change", event => {
    state.blocked = event.target.checked
    if (state.blocked) state.member = false
    changed()
  })

  byId("body").addEventListener("click", event => {
    const button = event.target.closest("button[data-role]")
    if (!button) return

    cycle(calc.roles.find(role => role.key === button.dataset.role), button.dataset.perm)
    render()
  })

  byId("reset").addEventListener("click", () => {
    resetManifest()
    render()
  })

  resetManifest()
  usePreset(calc.start)
  render()
}
