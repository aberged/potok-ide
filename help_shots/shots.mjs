// Photographs the help world as a phone would. make.exs calls it:
//
//   node shots.mjs <world.json> <folder for PNGs> [--only name,name]
//
// Each entry of shots.json names a picture, who looks (`as`, a person of the
// world, or nobody for a guest), the page (`url`, where `{groups.mz}` and the
// like come from world.json), the steps that bring the screen to the moment
// (`steps`) and, if not the whole screen, the element to cut out (`clip`).
import { chromium } from "playwright-core"
import { mkdirSync, readFileSync } from "node:fs"
import { join } from "node:path"

const [worldPath, outDir, ...rest] = process.argv.slice(2)
const world = JSON.parse(readFileSync(worldPath, "utf8"))
const list = JSON.parse(readFileSync(new URL("./shots.json", import.meta.url), "utf8"))
const onlyAt = rest.indexOf("--only")
const only = onlyAt >= 0 ? rest[onlyAt + 1].split(",") : null
const shots = only ? list.filter(shot => only.includes(shot.name)) : list

if (only) {
  const unknown = only.filter(name => !list.some(shot => shot.name === name))
  if (unknown.length) throw new Error(`Not in shots.json: ${unknown.join(", ")}`)
}

const phone = {
  viewport: { width: 390, height: 844 },
  deviceScaleFactor: 2,
  isMobile: true,
  hasTouch: true,
  locale: "sr-Latn-RS",
  timezoneId: "Europe/Belgrade",
  colorScheme: "light",
  serviceWorkers: "block",
}

// `{groups.mz}` → the id from world.json.
const fill = text =>
  text.replace(/\{([\w.]+)\}/g, (_, path) => {
    const value = path.split(".").reduce((object, key) => object?.[key], world)
    if (value === undefined) throw new Error(`world.json has no ${path}`)
    return value
  })

const browser = await launch()
const contexts = new Map()
let failed = 0

for (const shot of shots) {
  const page = await (await context(shot.as ?? null, shot.worker === true)).newPage()

  try {
    await go(page, fill(shot.url))
    for (const step of shot.steps ?? []) await run(page, step)
    await settle(page)

    const path = join(outDir, `${shot.name}.png`)
    const options = { path, animations: "disabled", caret: "hide" }

    if (shot.clip) await page.locator(fill(shot.clip)).first().screenshot(options)
    else await page.screenshot(options)

    console.log(`  ✓ ${shot.name}`)
  } catch (error) {
    failed++
    console.log(`  ✗ ${shot.name}: ${error.message.split("\n")[0]}`)
    mkdirSync(join(outDir, "..", "failed"), { recursive: true })
    await page.screenshot({ path: join(outDir, "..", "failed", `${shot.name}.png`) }).catch(() => {})
  } finally {
    await page.close()
  }
}

await browser.close()
process.exit(failed ? 1 : 0)

async function launch() {
  for (const channel of ["chrome", "msedge"]) {
    try {
      return await chromium.launch({ channel, args: ["--lang=sr-Latn-RS"] })
    } catch {}
  }

  throw new Error("Neither Chrome nor Edge is installed")
}

// One browser profile per person, logged in by their cookie; a guest has none.
// Service workers stay off, but for a picture that needs one (`worker`).
async function context(name, worker) {
  const key = `${name}:${worker}`
  if (contexts.has(key)) return contexts.get(key)

  const context = await browser.newContext({ ...phone, serviceWorkers: worker ? "allow" : "block" })

  // The app reads the theme from storage, and stays light without it.
  await context.addInitScript(() => {
    try {
      localStorage.setItem("phx:theme", "light")
    } catch {}
  })

  if (name) {
    const person = world.people[name]
    if (!person) throw new Error(`world.json has no person ${name}`)

    await context.addCookies([
      {
        name: "_potok_ide_web_account_remember_me",
        value: person.cookie,
        url: world.base_url,
        httpOnly: true,
        sameSite: "Lax",
      },
    ])
  }

  contexts.set(key, context)
  return context
}

async function go(page, url) {
  await page.goto(world.base_url + url, { waitUntil: "load" })
  await connected(page)
}

// A LiveView page answers clicks only once its socket is up.
async function connected(page) {
  await page.waitForFunction(() => {
    const main = document.querySelector("[data-phx-main]")
    return !main || main.classList.contains("phx-connected")
  })
}

async function run(page, step) {
  const [action, value] = Object.entries(step)[0]

  switch (action) {
    case "click":
      await page.locator(fill(value)).first().click()
      break
    case "tap":
      await page.locator(fill(value)).first().tap()
      break
    // Typed text without the spell checker's red lines, which belong to no
    // one's screen but this browser's.
    case "fill": {
      const field = page.locator(fill(value[0])).first()
      await field.evaluate(el => (el.spellcheck = false))
      await field.fill(value[1])
      break
    }
    case "type": {
      const field = page.locator(fill(value[0])).first()
      await field.evaluate(el => (el.spellcheck = false))
      await field.pressSequentially(value[1], { delay: 60 })
      break
    }
    case "press":
      await page.keyboard.press(value)
      break
    case "wait":
      await page.locator(fill(value)).first().waitFor({ state: "visible" })
      break
    case "gone":
      await page.locator(fill(value)).first().waitFor({ state: "hidden" })
      break
    case "goto":
      await go(page, fill(value))
      break
    case "scroll":
      await page.locator(fill(value)).first().scrollIntoViewIfNeeded()
      break
    case "top":
      await page.locator(fill(value)).first().evaluate(el => el.scrollTo(0, 0))
      break
    case "frameClick": {
      // [the app frame, an element inside it]
      const frame = page.frameLocator(fill(value[0])).first()
      await frame.locator(fill(value[1])).first().click()
      break
    }
    case "longpress":
      await longPress(page, fill(value))
      break
    case "pause":
      await page.waitForTimeout(value)
      break
    case "eval":
      await page.evaluate(fill(value))
      break
    // The element at the top of the screen, as if scrolled there by hand.
    case "show":
      await page.locator(fill(value)).first().evaluate(el => el.scrollIntoView({ block: "start" }))
      break
    default:
      throw new Error(`Unknown step ${action}`)
  }

  await connected(page)
}

// What a finger does: touch, hold, let go (the value sheet opens on hold).
async function longPress(page, selector) {
  const box = await page.locator(selector).first().boundingBox()
  if (!box) throw new Error(`${selector} is not on the screen`)

  const cdp = await page.context().newCDPSession(page)
  const point = { x: box.x + Math.min(40, box.width / 2), y: box.y + box.height / 2 }

  await cdp.send("Input.dispatchTouchEvent", { type: "touchStart", touchPoints: [point] })
  await page.waitForTimeout(800)
  await cdp.send("Input.dispatchTouchEvent", { type: "touchEnd", touchPoints: [] })
  await cdp.detach()
}

// Fonts, pictures, map tiles and app frames all in, and nothing moving.
async function settle(page) {
  await page.evaluate(() => document.fonts.ready)

  await page.waitForFunction(
    () =>
      [...document.images].every(img => img.complete || img.loading === "lazy") &&
      [...document.querySelectorAll(".leaflet-tile")].every(tile => tile.complete),
    null,
    { timeout: 20_000 },
  )

  for (const frame of page.frames()) {
    if (frame === page.mainFrame()) continue
    await frame.evaluate(() => document.fonts?.ready).catch(() => {})
  }

  await page.waitForTimeout(600)
}
