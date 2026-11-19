// Galleries in rich content (`PotokIdeWeb.Galleries`). The strip scrolls on
// its own (a swipe, a trackpad, the arrow keys once it has the focus) and
// snaps to each picture through CSS; the server adds two buttons, and this
// moves the strip one picture when one is clicked. Nothing is added to the
// page, so a LiveView patch has nothing to undo. Feed holds the same lines,
// as an app's frame does not run this file.

// The picture whose middle is nearest the middle of the strip.
const currentIndex = (strip, slides) => {
  const box = strip.getBoundingClientRect()
  const middle = box.left + box.width / 2
  let best = 0
  let bestDistance = Infinity

  slides.forEach((slide, index) => {
    const rect = slide.getBoundingClientRect()
    const distance = Math.abs(rect.left + rect.width / 2 - middle)

    if (distance < bestDistance) {
      best = index
      bestDistance = distance
    }
  })

  return best
}

// One picture on, or back; past the last one the first comes again.
export const stepGallery = (strip, direction) => {
  const slides = Array.from(strip.children)
  if (slides.length < 2) return

  const index = (currentIndex(strip, slides) + direction + slides.length) % slides.length
  const target = slides[index]
  const stripBox = strip.getBoundingClientRect()
  const targetBox = target.getBoundingClientRect()
  const left =
    strip.scrollLeft + (targetBox.left - stripBox.left) - (stripBox.width - targetBox.width) / 2
  const still = window.matchMedia("(prefers-reduced-motion: reduce)").matches

  strip.scrollTo({left, behavior: still ? "auto" : "smooth"})
}

export const installGalleries = (root = document) => {
  root.documentElement.setAttribute("data-potok-galleries", "")

  root.addEventListener("click", event => {
    const button = event.target.closest?.("[data-gallery-step]")
    const strip = button?.closest("[data-potok-gallery]")?.querySelector("[data-gallery-strip]")
    if (!strip) return

    event.preventDefault()
    stepGallery(strip, Number(button.dataset.galleryStep) || 1)
  })
}
