defmodule PotokIdeWeb.GroupLive.GuestSheet do
  @moduledoc """
  A sub-group over a guest's app, such as a map's pin (`AppApi` `show_group`
  for a guest): the guest's `GroupSheet`. A guest has no sheet of its own to
  run apps in, so it shows text only: the description the sub-group opens on
  when it opened that to guests too, otherwise its card (name, picture, a
  piece of its description). Both link to the sub-group's own page, where an
  app of it runs. Closing it tells the app (`group_sheet_closed`), as the
  member's sheet does.
  """
  use PotokIdeWeb, :html

  alias PotokIde.Social.{Group, GroupPins}
  alias PotokIdeWeb.Avatars
  alias PotokIdeWeb.GroupLive.Show.{AppHost, Components, GroupDescriptionTab}
  alias PotokIdeWeb.{GuestDescriptions, PinIcons, PublicPreview}

  def init(socket), do: assign(socket, :guest_sheet, nil)

  @doc "Opens the sheet of `group`, a public sub-group, over the app."
  def open(socket, %Group{} = group) do
    entries = GuestDescriptions.entries(group)
    entry = GuestDescriptions.pick(entries, group, nil)

    source =
      case entry do
        %{uses_api: false} -> GuestDescriptions.source(group, entry)
        _app_or_none -> nil
      end

    socket
    |> close()
    |> assign(:guest_sheet, %{
      group: group,
      source: source,
      card_text: PublicPreview.card_text(group),
      key: System.unique_integer([:positive])
    })
  end

  @doc "Closes the sheet and tells the app which group it showed."
  def close(%{assigns: %{guest_sheet: %{group: group}}} = socket) do
    socket
    |> assign(:guest_sheet, nil)
    |> AppHost.push("group_sheet_closed", %{id: group.id})
  end

  def close(socket), do: socket

  attr :sheet, :map, default: nil, doc: "the `@guest_sheet` assign"

  def dialog(assigns) do
    ~H"""
    <dialog
      :if={@sheet}
      id="guest-sheet"
      phx-hook=".GuestSheet"
      phx-mounted={JS.ignore_attributes(["open"])}
      aria-labelledby="guest-sheet-title"
      class="fixed inset-0 m-0 size-full max-h-none max-w-none overflow-hidden bg-transparent p-0 backdrop:bg-transparent"
    >
      <div class="flex size-full items-end justify-center sm:items-center sm:p-6">
        <div
          id="guest-sheet-backdrop"
          class="absolute inset-0 bg-black/30 backdrop-blur-[2px] dark:bg-black/60"
          phx-click="guest_sheet_close"
          aria-hidden="true"
        >
        </div>
        <section
          tabindex="-1"
          autofocus
          class={[
            "relative flex w-full flex-col overflow-hidden rounded-t-3xl border border-b-0 border-base-300/70 bg-base-100 text-base-content shadow-2xl shadow-base-content/10 outline-none sm:max-w-3xl sm:rounded-3xl sm:border-b",
            if(@sheet.source, do: "h-[88dvh] sm:h-[85dvh]", else: "max-h-[88dvh]")
          ]}
        >
          <div
            class="mx-auto mt-2 h-1 w-10 shrink-0 rounded-full bg-base-300 sm:hidden"
            aria-hidden="true"
          >
          </div>
          <header class="flex shrink-0 items-center gap-3 border-b border-base-300/70 px-4 py-3">
            <PinIcons.pin
              id="guest-sheet-pin"
              color={look(@sheet.group).color}
              paths={look(@sheet.group).paths}
              picture_url={look(@sheet.group).picture && Avatars.group_avatar_url(@sheet.group)}
              mark={look(@sheet.group).mark}
              class="h-10 w-8 shrink-0 drop-shadow-sm"
            />
            <div class="min-w-0 flex-1">
              <h2 id="guest-sheet-title" class="truncate text-base font-semibold leading-tight">
                {@sheet.group.name}
              </h2>
              <p class="mt-0.5 flex items-center gap-1 text-xs text-base-content/60">
                <.icon name="hero-globe-alt-micro" class="size-3.5" />
                <span class="truncate">{PinIcons.kind_label(GroupPins.kind(@sheet.group))}</span>
              </p>
            </div>
            <.button
              id="guest-sheet-open"
              href={~p"/groups/#{@sheet.group.id}"}
              aria-label={gettext("Open group")}
              variant="soft"
              size="sm"
              class="shrink-0"
            >
              <span class="hidden min-[400px]:inline">{gettext("Open group")}</span>
              <.icon name="hero-arrow-top-right-on-square" class="size-4" />
            </.button>
            <.icon_button
              id="guest-sheet-close"
              type="button"
              phx-click="guest_sheet_close"
              icon="hero-x-mark"
              label={gettext("Close")}
            />
          </header>
          <div
            :if={@sheet.source}
            id="guest-sheet-description"
            class="min-h-0 flex-1 overflow-y-auto overscroll-contain px-4 pt-3 pb-[calc(var(--app-safe-area-bottom)+1rem)]"
          >
            <Components.formatted_content
              content={@sheet.source.description}
              content_format={@sheet.source.description_format}
              class={GroupDescriptionTab.description_column(@sheet.source)}
            />
          </div>
          <div
            :if={!@sheet.source}
            id="guest-sheet-card"
            class="flex items-start gap-4 px-4 pt-4 pb-[calc(var(--app-safe-area-bottom)+1.25rem)]"
          >
            <img
              src={Avatars.group_avatar_url(@sheet.group)}
              alt=""
              class="size-16 shrink-0 rounded-full border border-base-300 bg-base-100 object-cover"
            />
            <p class="min-w-0 text-sm leading-6 text-pretty wrap-break-word text-base-content/75">
              {@sheet.card_text}
            </p>
          </div>
        </section>
      </div>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".GuestSheet">
      export default {
        mounted() {
          // Escape and Android's back button close it through the server.
          this.el.addEventListener("cancel", event => {
            event.preventDefault()
            this.pushEvent("guest_sheet_close", {})
          })

          this.el.showModal()
        },

        updated() {
          if (!this.el.open) this.el.showModal()
        },
      }
    </script>
    """
  end

  defp look(group), do: PinIcons.look(group)
end
