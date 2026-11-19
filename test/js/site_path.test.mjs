// `node --test test/js/site_path.test.mjs`: which pages of a site in an app's
// frame Potok remembers and puts in a link (assets/js/site_path.js).
import assert from "node:assert/strict"
import { test } from "node:test"

import { MAX_PAGE, homePath, sitePath } from "../../assets/js/site_path.js"

const HOME = "https://ustav.pages.dev/"

test("a path of the same site is kept with its query and fragment", () => {
  assert.equal(sitePath("/poglavlja/03-prava.html#clan-12", HOME), "/poglavlja/03-prava.html#clan-12")
  assert.equal(sitePath("/pretraga?q=sloboda", HOME), "/pretraga?q=sloboda")
  assert.equal(sitePath("/a/../b.html", HOME), "/b.html")
})

test("another site, a scheme or tricks are refused", () => {
  for (const page of [
    "https://evil.example/",
    "//evil.example/x",
    "javascript:alert(1)",
    "/\\evil.example",
    "/x\nSet-Cookie: a",
    "relative.html",
    "",
    "/" + "a".repeat(MAX_PAGE),
    42,
    null,
  ]) {
    assert.equal(sitePath(page, HOME), null, String(page))
  }
})

test("a frame with no web address of its own remembers nothing", () => {
  assert.equal(sitePath("/x", "about:blank"), null)
  assert.equal(sitePath("/x", "not a url"), null)
  assert.equal(sitePath("/x", "data:text/html,hi"), null)
})

test("the home path is the frame's own address", () => {
  assert.equal(homePath("https://obuka.pages.dev/index.html"), "/index.html")
  assert.equal(homePath(HOME), "/")
})
