defmodule PotokIdeWeb.GroupLive.Show.MediaViewer do
  @moduledoc """
  The full-screen preview of images, videos and audio attached to values.
  The page renders one `viewer/1`; it opens for any link that carries
  `media_data/2`. The links keep their `href` and `target`, so a modified
  click (or a page without JS) still opens the file in a new tab.
  """

  use PotokIdeWeb, :html

  alias PotokIde.Social.ValueAttachment

  @doc """
  Data attributes that open the attachment's link in the viewer, or none for
  a file that is only downloaded. The arrows step through the links of the
  same `gallery`, in page order.
  """
  def media_data(%ValueAttachment{} = attachment, gallery) when is_binary(gallery) do
    case ValueAttachment.media_kind(attachment) do
      nil ->
        %{}

      kind ->
        %{
          "data-media" => kind,
          "data-media-gallery" => gallery,
          "data-media-name" => attachment.filename,
          "data-media-download" => download_path(attachment)
        }
    end
  end

  @doc "A link that downloads the file, even one that is shown in place."
  def download_path(%ValueAttachment{id: id}), do: ~p"/files/#{id}?download=1"

  def viewer(assigns) do
    ~H"""
    <dialog
      id="media-viewer"
      phx-hook=".MediaViewer"
      phx-update="ignore"
      aria-label={gettext("File preview")}
      class="fixed inset-0 m-0 size-full max-h-none max-w-none overflow-hidden overscroll-contain border-0 bg-black/90 p-0 text-white opacity-0 backdrop-blur-md transition-[opacity,display,overlay] transition-discrete duration-200 ease-out [color-scheme:dark] backdrop:bg-transparent open:opacity-100 starting:open:opacity-0"
    >
      <div class="flex size-full flex-col">
        <div class="flex shrink-0 items-center gap-1 px-3 pt-[max(0.75rem,var(--app-safe-area-top))] pb-2 sm:px-5">
          <div class="min-w-0 flex-1 pl-1">
            <p id="media-viewer-name" class="truncate text-sm font-semibold"></p>
            <p id="media-viewer-counter" class="h-4 text-xs tabular-nums text-white/60"></p>
          </div>
          <a
            id="media-viewer-download"
            href="#"
            title={gettext("Download")}
            aria-label={gettext("Download")}
            class="inline-flex size-10 shrink-0 items-center justify-center rounded-full text-white/80 transition duration-150 ease-out hover:bg-white/15 hover:text-white active:scale-95"
          >
            <.icon name="hero-arrow-down-tray" class="size-5" />
          </a>
          <button
            id="media-viewer-close"
            type="button"
            autofocus
            title={gettext("Close")}
            aria-label={gettext("Close")}
            class="inline-flex size-10 shrink-0 items-center justify-center rounded-full text-white/80 transition duration-150 ease-out hover:bg-white/15 hover:text-white active:scale-95"
          >
            <.icon name="hero-x-mark" class="size-6" />
          </button>
        </div>

        <div
          id="media-viewer-stage"
          class="relative flex min-h-0 flex-1 touch-pan-y touch-pinch-zoom items-center justify-center px-3 pb-[max(1rem,var(--app-safe-area-bottom))] sm:px-20"
        >
          <div id="media-viewer-media" class="flex size-full items-center justify-center"></div>
          <div
            id="media-viewer-spinner"
            hidden
            class="pointer-events-none absolute size-9 animate-spin rounded-full border-2 border-white/20 border-t-white"
          >
          </div>
          <div
            id="media-viewer-error"
            hidden
            class="absolute inset-x-6 top-1/2 mx-auto flex max-w-sm -translate-y-1/2 flex-col items-center gap-3 text-center"
          >
            <.icon name="hero-exclamation-triangle" class="size-8 text-white/60" />
            <p class="text-sm text-white/80">
              {gettext("This file cannot be previewed in the browser.")}
            </p>
            <a
              id="media-viewer-error-download"
              href="#"
              class="inline-flex items-center gap-2 rounded-full bg-white px-4 py-2 text-sm font-semibold text-black transition duration-150 ease-out hover:bg-white/90 active:scale-95"
            >
              <.icon name="hero-arrow-down-tray" class="size-4" />
              {gettext("Download")}
            </a>
          </div>
          <button
            id="media-viewer-prev"
            type="button"
            hidden
            title={gettext("Previous")}
            aria-label={gettext("Previous")}
            class="absolute top-1/2 left-2 inline-flex size-11 -translate-y-1/2 items-center justify-center rounded-full bg-white/10 text-white shadow-lg backdrop-blur transition duration-150 ease-out hover:bg-white/20 active:scale-95 sm:left-5"
          >
            <.icon name="hero-chevron-left" class="size-6" />
          </button>
          <button
            id="media-viewer-next"
            type="button"
            hidden
            title={gettext("Next")}
            aria-label={gettext("Next")}
            class="absolute top-1/2 right-2 inline-flex size-11 -translate-y-1/2 items-center justify-center rounded-full bg-white/10 text-white shadow-lg backdrop-blur transition duration-150 ease-out hover:bg-white/20 active:scale-95 sm:right-5"
          >
            <.icon name="hero-chevron-right" class="size-6" />
          </button>
        </div>
      </div>

      <template id="media-viewer-audio-template">
        <div class="flex w-full max-w-md flex-col items-center gap-5 rounded-3xl border border-white/10 bg-white/5 px-6 py-8 shadow-2xl">
          <span class="inline-flex size-20 items-center justify-center rounded-full bg-white/10">
            <.icon name="hero-musical-note" class="size-10 text-white/80" />
          </span>
          <p data-audio-name class="max-w-full truncate text-sm font-medium"></p>
          <audio controls class="w-full"></audio>
        </div>
      </template>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".MediaViewer">
      const SWIPE_DISTANCE = 50

      export default {
        mounted() {
          const el = this.el
          const find = name => el.querySelector(`#media-viewer-${name}`)

          this.ui = {
            name: find("name"),
            counter: find("counter"),
            download: find("download"),
            close: find("close"),
            stage: find("stage"),
            media: find("media"),
            spinner: find("spinner"),
            error: find("error"),
            errorDownload: find("error-download"),
            prev: find("prev"),
            next: find("next"),
            audioTemplate: find("audio-template"),
          }

          this.onDocumentClick = event => {
            if (event.defaultPrevented || event.button !== 0) return
            if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return

            const link = event.target.closest?.("a[data-media]")
            if (!link || el.contains(link)) return

            event.preventDefault()
            this.open(link)
          }

          // One sound at a time: starting any audio or video pauses the others.
          this.onPlay = event => {
            document.querySelectorAll("audio, video").forEach(media => {
              if (media !== event.target && !media.paused) media.pause()
            })
          }

          document.addEventListener("click", this.onDocumentClick)
          document.addEventListener("play", this.onPlay, true)

          this.ui.close.addEventListener("click", () => el.close())
          this.ui.prev.addEventListener("click", () => this.step(-1))
          this.ui.next.addEventListener("click", () => this.step(1))
          el.addEventListener("close", () => this.reset())

          // The empty space around the file closes the viewer, like a backdrop.
          el.addEventListener("click", event => {
            if (this.swiped) {
              this.swiped = false
              return
            }

            if ([el, this.ui.stage, this.ui.media].includes(event.target)) el.close()
          })

          el.addEventListener("keydown", event => {
            if (event.target.closest("video, audio")) return

            if (event.key === "ArrowLeft") this.step(-1)
            else if (event.key === "ArrowRight") this.step(1)
            else return

            event.preventDefault()
          })

          this.ui.stage.addEventListener("pointerdown", event => {
            this.swipeStart =
              event.pointerType === "touch" ? {x: event.clientX, y: event.clientY} : null
          })

          this.ui.stage.addEventListener("pointerup", event => {
            const start = this.swipeStart
            this.swipeStart = null
            if (!start || this.current?.dataset.media !== "image") return

            const dx = event.clientX - start.x
            const dy = event.clientY - start.y

            if (Math.abs(dx) > SWIPE_DISTANCE && Math.abs(dx) > Math.abs(dy) * 1.5) {
              this.swiped = true
              this.step(dx < 0 ? 1 : -1)
            }
          })
        },

        destroyed() {
          document.removeEventListener("click", this.onDocumentClick)
          document.removeEventListener("play", this.onPlay, true)
          document.documentElement.classList.remove("overflow-hidden")
        },

        // Links are looked up on every step, so values that arrived or left
        // while the viewer was open are taken into account.
        gallery() {
          const gallery = this.current?.dataset.mediaGallery

          return Array.from(document.querySelectorAll("a[data-media]")).filter(
            link => link.dataset.mediaGallery === gallery && !this.el.contains(link)
          )
        },

        open(link) {
          this.opener = link
          this.show(link)

          if (!this.el.open) {
            document.documentElement.classList.add("overflow-hidden")
            this.el.showModal()
          }
        },

        step(delta) {
          const links = this.gallery()
          if (links.length < 2) return

          const index = Math.max(links.indexOf(this.current), 0)
          this.show(links[(index + delta + links.length) % links.length])
        },

        show(link) {
          const ui = this.ui
          this.current = link
          this.clearMedia()

          const links = this.gallery()
          const index = links.indexOf(link)
          const kind = link.dataset.media
          const name = link.dataset.mediaName || ""

          ui.name.textContent = name
          ui.counter.textContent = links.length > 1 ? `${index + 1} / ${links.length}` : ""
          ui.download.href = link.dataset.mediaDownload
          ui.errorDownload.href = link.dataset.mediaDownload
          ui.prev.hidden = links.length < 2
          ui.next.hidden = links.length < 2
          ui.error.hidden = true
          ui.media.hidden = false
          // Video and audio show their own loading state in the controls.
          ui.spinner.hidden = kind !== "image"

          const {node, media} = this.createMedia(kind, name)

          media.addEventListener("error", () => {
            if (!node.isConnected) return
            ui.spinner.hidden = true
            ui.media.hidden = true
            ui.error.hidden = false
          })

          if (kind === "image") {
            media.addEventListener("load", () => {
              if (!node.isConnected) return
              ui.spinner.hidden = true
              media.classList.remove("opacity-0")
            })
          }

          media.src = link.getAttribute("href")
          ui.media.append(node)

          // Still inside the click or key press, so browsers allow sound.
          if (kind !== "image") media.play()?.catch(() => {})

          if (links.length > 1 && index >= 0) {
            const neighbours = [
              links[(index + 1) % links.length],
              links[(index - 1 + links.length) % links.length],
            ]

            neighbours
              .filter(neighbour => neighbour.dataset.media === "image")
              .forEach(neighbour => {
                new Image().src = neighbour.getAttribute("href")
              })
          }
        },

        createMedia(kind, name) {
          if (kind === "image") {
            const image = document.createElement("img")
            image.alt = name
            image.decoding = "async"
            image.draggable = false
            image.className =
              "max-h-full max-w-full select-none rounded-xl object-contain opacity-0 shadow-2xl transition-opacity duration-200"

            return {node: image, media: image}
          }

          if (kind === "video") {
            const video = document.createElement("video")
            video.controls = true
            video.autoplay = true
            video.playsInline = true
            video.className = "max-h-full max-w-full rounded-xl bg-black shadow-2xl"

            return {node: video, media: video}
          }

          const card = this.ui.audioTemplate.content.firstElementChild.cloneNode(true)
          const audio = card.querySelector("audio")
          card.querySelector("[data-audio-name]").textContent = name
          audio.autoplay = true

          return {node: card, media: audio}
        },

        // Pausing alone keeps a video downloading; dropping the source stops it.
        clearMedia() {
          this.ui.media.querySelectorAll("video, audio").forEach(media => {
            media.pause()
            media.removeAttribute("src")
            media.load()
          })

          this.ui.media.replaceChildren()
        },

        reset() {
          this.clearMedia()
          document.documentElement.classList.remove("overflow-hidden")
          if (this.opener?.isConnected) this.opener.focus({preventScroll: true})
          this.current = null
          this.opener = null
        },
      }
    </script>
    """
  end
end
