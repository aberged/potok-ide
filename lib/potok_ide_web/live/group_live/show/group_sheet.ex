defmodule PotokIdeWeb.GroupLive.Show.GroupSheet do
  @moduledoc """
  A sub-group's description over the app that asked for it, such as a map's
  pin (`AppApi` `show_group`): a top-layer dialog of the page, as the poll's,
  with `GroupLive.Sheet` inside.

  The sheet is a LiveView of its own, bound to the sub-group, so the apps in
  its description run with that group's rights; an app can never run another
  app's code itself. It shows the description and a link to the whole group.
  Closing it tells the app (`group_sheet_closed`), so a map can let go of its
  pin.
  """
  use PotokIdeWeb, :html

  alias PotokIde.Social.{Group, GroupPins}
  alias PotokIdeWeb.Avatars
  alias PotokIdeWeb.GroupLive.Show.AppHost
  alias PotokIdeWeb.PinIcons

  def init(socket), do: assign(socket, :group_sheet, nil)

  @doc "Opens the sheet of `group`, a sub-group the viewer sees, over the app."
  def open(socket, %Group{} = group) do
    socket
    |> close()
    |> assign(:group_sheet, %{group: group, key: System.unique_integer([:positive])})
  end

  @doc "Closes the sheet and tells the app which group it showed."
  def close(%{assigns: %{group_sheet: %{group: group}}} = socket) do
    socket
    |> assign(:group_sheet, nil)
    |> AppHost.push("group_sheet_closed", %{id: group.id})
  end

  def close(socket), do: socket

  @doc "Closes the sheet when it shows `group_id`: the group went away under it."
  def gone(%{assigns: %{group_sheet: %{group: %{id: group_id}}}} = socket, group_id),
    do: close(socket)

  def gone(socket, _group_id), do: socket

  attr :sheet, :map, default: nil, doc: "the `@group_sheet` assign"
  attr :socket, :any, required: true, doc: "the page's socket, for the sheet's LiveView"
  attr :session, :map, required: true, doc: "what the sheet needs to know who is looking"

  def dialog(assigns) do
    ~H"""
    <dialog
      :if={@sheet}
      id="group-sheet"
      phx-hook=".GroupSheet"
      phx-mounted={JS.ignore_attributes(["open"])}
      aria-labelledby="group-sheet-title"
      class="fixed inset-0 m-0 size-full max-h-none max-w-none overflow-hidden bg-transparent p-0 backdrop:bg-transparent"
    >
      <div class="flex size-full items-end justify-center sm:items-center sm:p-6">
        <div
          id="group-sheet-backdrop"
          class="absolute inset-0 bg-black/30 backdrop-blur-[2px] dark:bg-black/60"
          phx-click="group_sheet_close"
          aria-hidden="true"
        >
        </div>
        <section
          tabindex="-1"
          autofocus
          class="relative flex h-[88dvh] w-full flex-col overflow-hidden rounded-t-3xl border border-b-0 border-base-300/70 bg-base-100 text-base-content shadow-2xl shadow-base-content/10 outline-none sm:h-[85dvh] sm:max-w-3xl sm:rounded-3xl sm:border-b"
        >
          <div
            class="mx-auto mt-2 h-1 w-10 shrink-0 rounded-full bg-base-300 sm:hidden"
            aria-hidden="true"
          >
          </div>
          <header class="flex shrink-0 items-center gap-3 border-b border-base-300/70 px-4 py-3">
            <PinIcons.pin
              id="group-sheet-pin"
              color={look(@sheet.group).color}
              paths={look(@sheet.group).paths}
              picture_url={look(@sheet.group).picture && Avatars.group_avatar_url(@sheet.group)}
              class="h-10 w-8 shrink-0 drop-shadow-sm"
            />
            <div class="min-w-0 flex-1">
              <h2 id="group-sheet-title" class="truncate text-base font-semibold leading-tight">
                {@sheet.group.name}
              </h2>
              <p class="mt-0.5 flex items-center gap-1 text-xs text-base-content/60">
                <.icon
                  name={
                    if(@sheet.group.is_public,
                      do: "hero-globe-alt-micro",
                      else: "hero-lock-closed-micro"
                    )
                  }
                  class="size-3.5"
                />
                <span class="truncate">{PinIcons.kind_label(GroupPins.kind(@sheet.group))}</span>
              </p>
            </div>
            <.button
              id="group-sheet-open"
              navigate={~p"/groups/#{@sheet.group.id}"}
              aria-label={gettext("Open group")}
              variant="soft"
              size="sm"
              class="shrink-0"
            >
              <span class="hidden min-[400px]:inline">{gettext("Open group")}</span>
              <.icon name="hero-arrow-top-right-on-square" class="size-4" />
            </.button>
            <.icon_button
              id="group-sheet-close"
              type="button"
              phx-click="group_sheet_close"
              icon="hero-x-mark"
              label={gettext("Close")}
            />
          </header>
          <div class="flex min-h-0 flex-1 flex-col pt-2 pb-[var(--app-safe-area-bottom)] sm:pb-0">
            {live_render(@socket, PotokIdeWeb.GroupLive.Sheet,
              id: "group-sheet-lv-#{@sheet.key}",
              session: Map.merge(@session, %{"group_id" => @sheet.group.id}),
              container: {:div, class: "flex min-h-0 flex-1 flex-col"}
            )}
          </div>
        </section>
      </div>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".GroupSheet">
      export default {
        mounted() {
          // Escape and Android's back button close it through the server.
          this.el.addEventListener("cancel", event => {
            event.preventDefault()
            this.pushEvent("group_sheet_close", {})
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
