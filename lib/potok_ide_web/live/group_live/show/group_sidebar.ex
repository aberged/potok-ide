defmodule PotokIdeWeb.GroupLive.Show.GroupSidebar do
  @moduledoc """
  The column of the viewer's groups beside a group's page on a wide screen
  (from 80rem, `xl`), so another conversation is a click away without the
  root's list. The root has none: its page is that list.

  It loads only once the browser says it shows (`.GroupSidebar` asks with
  `group_sidebar_load`), so a phone never pays for it. Then it follows the
  counts the page keeps (`counted/2`, from the page's unread overview) and
  the newest values the page hears of (`noted/4`). Each row carries its own
  counts and is keyed, so a new value re-sends only the rows it changed.

  Its button hides it on this device: `data-group-sidebar="hidden"` on
  <html>, kept in `potok:group-sidebar` by the script in root.html.heex,
  which also reads it before the first paint.
  """

  use PotokIdeWeb, :html

  alias PotokIde.Social
  alias PotokIdeWeb.GroupLive.Show.Components

  def init(socket), do: assign(socket, :sidebar, nil)

  @doc """
  Loads the column, once, from the page's unread overview: the groups with
  something unread of their own come first.
  """
  def load(
        %{assigns: %{sidebar: nil, current_profile: %{} = profile, group: %{is_root: false}}} =
          socket,
        overview
      ) do
    unread_ids = for {id, %{own: own}} when own > 0 <- overview.groups, do: id
    groups = Social.list_sidebar_groups(profile, unread_ids)

    socket
    |> assign(:sidebar, %{groups: groups, rows: []})
    |> counted(overview)
  end

  def load(socket, _overview), do: socket

  @doc """
  The rows again, from what the page counts now: a group's own unread
  values, a silenced group's apart, unread ones first, then the newest.
  """
  def counted(%{assigns: %{sidebar: %{groups: groups} = sidebar}} = socket, %{} = overview) do
    muted = socket.assigns[:muted_group_ids] || MapSet.new()
    current_id = socket.assigns.group.id

    rows =
      groups
      |> Enum.map(fn group ->
        counts = Map.get(overview.groups, group.id, %{})

        %{
          id: group.id,
          group: group,
          unread: Map.get(counts, :own, 0),
          muted_unread: Map.get(counts, :muted, 0),
          muted?: MapSet.member?(muted, group.id),
          current?: group.id == current_id
        }
      end)
      |> Enum.sort_by(&{&1.unread > 0, newest(&1.group), &1.id}, :desc)

    assign(socket, :sidebar, %{sidebar | rows: rows})
  end

  def counted(socket, _overview), do: socket

  @doc "A group of the column got a newest value (or lost it): its row says so."
  def noted(%{assigns: %{sidebar: %{groups: groups} = sidebar}} = socket, group_id, preview, at) do
    if Enum.any?(groups, &(&1.id == group_id)) do
      groups =
        Enum.map(groups, fn
          %{id: ^group_id} = group -> %{group | last_value: preview, last_value_at: at}
          group -> group
        end)

      socket
      |> assign(:sidebar, %{sidebar | groups: groups})
      |> counted(socket.assigns[:unread_overview])
    else
      socket
    end
  end

  def noted(socket, _group_id, _preview, _at), do: socket

  defp newest(%{last_value_at: %DateTime{} = at}), do: DateTime.to_unix(at)
  defp newest(_group), do: 0

  attr :sidebar, :map, required: true, doc: "nil until it loads"
  attr :current_profile, :map, required: true

  def panel(assigns) do
    ~H"""
    <aside
      id="group-sidebar"
      phx-hook=".GroupSidebar"
      aria-label={gettext("Your groups")}
      class="hidden w-72 shrink-0 flex-col overflow-hidden border-r border-base-300/70 pt-1 xl:group-sidebar-shown:flex"
    >
      <div class="flex shrink-0 items-center justify-between gap-2 py-2 pr-1 pl-3">
        <h2 class="text-xs font-semibold uppercase tracking-[0.14em] text-base-content/60">
          {gettext("Your groups")}
        </h2>
        <.icon_button
          id="group-sidebar-hide"
          type="button"
          phx-click={JS.dispatch("phx:toggle-group-sidebar")}
          icon="hero-chevron-double-left"
          label={gettext("Hide your groups")}
        />
      </div>

      <div
        id="group-sidebar-scroll"
        class="min-h-0 flex-1 overflow-y-auto overscroll-contain pr-2 pb-3"
      >
        <div
          :if={is_nil(@sidebar)}
          id="group-sidebar-loading"
          class="space-y-2 px-1"
          aria-hidden="true"
        >
          <div :for={_row <- 1..6} class="h-14 animate-pulse rounded-2xl bg-base-200/70" />
        </div>

        <ul :if={@sidebar} id="group-sidebar-list" class="space-y-0.5">
          <li
            :for={row <- @sidebar.rows}
            :key={row.id}
            id={"group-sidebar-row-#{row.id}"}
            aria-current={row.current? && "page"}
            class={[
              "group/child relative rounded-2xl px-2 py-2 transition-colors duration-150",
              if(row.current?, do: "bg-primary/10", else: "hover:bg-base-200/70")
            ]}
          >
            <Components.group_identity
              group={row.group}
              current_profile={@current_profile}
              id_prefix="sidebar-group"
              avatar_size="size-9"
              text_class="text-sm"
              muted?={row.muted?}
            >
              <:subtitle>
                <div class="flex w-full min-w-0 flex-col">
                  <Components.draft_mark
                    id={"sidebar-group-draft-#{row.id}"}
                    current_profile={@current_profile}
                    group={row.group}
                  />
                  <.last_value
                    group={row.group}
                    current_profile={@current_profile}
                    unread={row.unread > 0}
                  />
                </div>
              </:subtitle>
            </Components.group_identity>
            <%!-- The counts keep their place when they are 0, so a row that moves
                 keeps its shape: they stand over the avatar's corner. --%>
            <.count_badge
              id={"sidebar-group-unread-badge-#{row.id}"}
              count={row.unread}
              hidden={row.unread == 0}
              class="absolute top-0.5 left-8"
            />
            <.count_badge
              id={"sidebar-group-muted-unread-badge-#{row.id}"}
              count={row.muted_unread}
              tone={:muted}
              hidden={row.unread > 0 or row.muted_unread == 0}
              class="absolute top-0.5 left-8"
            />
          </li>
          <li
            :if={@sidebar.rows == []}
            id="group-sidebar-empty"
            class="px-3 py-6 text-sm text-base-content/60"
          >
            {gettext("You are not in any group yet.")}
          </li>
        </ul>
      </div>
    </aside>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".GroupSidebar">
      // Where the list stood, for the next group's page: the column loads again there.
      const SCROLL_KEY = "potok:group-sidebar-scroll"

      export default {
        mounted() {
          this.wide = window.matchMedia("(min-width: 80rem)")
          this.scroller = this.el.querySelector("#group-sidebar-scroll")

          this.maybeLoad = () => {
            const hidden = document.documentElement.dataset.groupSidebar === "hidden"
            if (this.loaded || hidden || !this.wide.matches) return

            this.loaded = true
            this.pushEvent("group_sidebar_load", {})
          }

          this.keepScroll = () => {
            try {
              sessionStorage.setItem(SCROLL_KEY, String(this.scroller.scrollTop))
            } catch (_error) {}
          }

          this.wide.addEventListener("change", this.maybeLoad)
          window.addEventListener("potok:group-sidebar-shown", this.maybeLoad)
          this.scroller.addEventListener("scroll", this.keepScroll, {passive: true})
          this.maybeLoad()
        },

        updated() {
          if (this.restored || !this.el.querySelector("#group-sidebar-list")) return

          this.restored = true

          try {
            const top = Number(sessionStorage.getItem(SCROLL_KEY))
            if (top > 0) this.scroller.scrollTop = top
          } catch (_error) {}
        },

        // A new socket starts with no column.
        reconnected() {
          this.loaded = false
          this.restored = false
          this.maybeLoad()
        },

        destroyed() {
          this.wide.removeEventListener("change", this.maybeLoad)
          window.removeEventListener("potok:group-sidebar-shown", this.maybeLoad)
        },
      }
    </script>
    """
  end

  attr :group, :map, required: true
  attr :current_profile, :map, required: true
  attr :unread, :boolean, required: true

  # The newest value under the name, "You:" for the viewer's own and no name
  # in a direct conversation, as in the sub-groups list. A draft takes its
  # place while there is one. An empty line stands for a group without one.
  defp last_value(assigns) do
    %{group: group, current_profile: profile} = assigns

    {author, text} =
      case group.last_value do
        %{text: text, creator_id: creator_id} = last when is_binary(text) ->
          author =
            cond do
              match?(%{id: ^creator_id}, profile) -> gettext("You:")
              group.is_direct -> nil
              true -> last.author <> ":"
            end

          {author, text}

        _none ->
          {nil, ""}
      end

    assigns = assign(assigns, author: author, text: text)

    ~H"""
    <p
      id={"sidebar-group-last-value-#{@group.id}"}
      class={[
        "truncate text-xs leading-4 group-has-[[data-draft-text]]/child:hidden",
        if(@unread, do: "text-base-content/85", else: "text-base-content/60")
      ]}
    >
      <span class="font-semibold">{@author}</span>
      {@text}
    </p>
    """
  end
end
