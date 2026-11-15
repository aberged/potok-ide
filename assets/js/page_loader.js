// The drop in the top bar (`Layouts.page_loader/1`) falls while <html> has
// `data-page-loading`, which `vendor/topbar.js` sets and takes away. The
// motion is in app.css. Two things keep it one drop that falls:
//
// - Each load starts the fall over, so the drop first shows at the top,
//   instead of going on from wherever the last load froze it.
// - Going to another LiveView renders a new top bar, and with it a new drop,
//   whose fall would start over from the top while the bar still fades out.
//   LiveView renders the new page and only then sends
//   `phx:page-loading-stop` (kind "initial"), before the browser paints it,
//   so the new drop is set to the time the old one had reached.
//
// The time goes through the drop's animations, not a style on the element:
// LiveView would take that style away at its next patch.

const LOADING_ATTRIBUTE = "data-page-loading"

let startedAt = null

const dropAnimations = () => {
  const loader = document.getElementById("nav-page-loader")
  if (!loader) return []

  return loader
    .getAnimations({subtree: true})
    .filter(animation =>
      animation instanceof CSSAnimation && animation.animationName.startsWith("page-loader")
    )
}

// The same time for all three keeps the second ripple 160 ms behind, since
// that is its `animation-delay`. Setting the time leaves the play state to
// the CSS, which still pauses the fall between loads.
const setDropTime = time => {
  dropAnimations().forEach(animation => {
    animation.currentTime = time
  })
}

export const installPageLoader = () => {
  if (typeof CSSAnimation === "undefined" || !document.timeline) return

  const root = document.documentElement

  new MutationObserver(() => {
    if (!root.hasAttribute(LOADING_ATTRIBUTE)) {
      startedAt = null
    } else if (startedAt === null) {
      startedAt = document.timeline.currentTime
      setDropTime(0)
    }
  }).observe(root, {attributes: true, attributeFilter: [LOADING_ATTRIBUTE]})

  window.addEventListener("phx:page-loading-stop", () => {
    if (startedAt !== null) setDropTime(document.timeline.currentTime - startedAt)
  })
}
