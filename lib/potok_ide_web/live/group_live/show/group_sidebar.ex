defmodule PotokIdeWeb.GroupLive.Show.GroupSidebar do
  @moduledoc """
  The column of the viewer's groups beside a group's page on a wide screen
  (from 80rem, `xl`), to move between groups and sub-groups without the
  root's list. The root has none: its page is that list.

  It holds, top down: a search, the groups the viewer pinned
  (`Social.list_pinned_groups/1`), the tree of its groups and a list of its
  direct conversations. The tree is the root's folder view without the
  public groups the viewer is not in (`SubGroupTree` with `public?: false`):
  its memberships, the public groups it follows and the folders on the way
  to them, threads left out. The folders on the way to the page's group come
  open, and so do those this browser remembers (`potok:group-sidebar-open`).

  A row counts what is unread where the reader cannot see it otherwise: a
  closed folder all of its sub-tree, an open one what its shown sub-groups
  do not show (its own values and its threads). So every number of the
  home badge can be followed down to its group. What waits for the viewer
  counts the same way.

  It loads only once the browser says it shows (`.GroupSidebar` asks with
  `group_sidebar_load`), so a phone never pays for it. Then it follows the
  counts the page keeps (`counted/2`) and the newest values of the direct
  conversations (`noted/4`).

  Its button hides it on this device: `data-group-sidebar="hidden"` on
  <html>, kept in `potok:group-sidebar` by the script in root.html.heex,
  which also reads it before the first paint.
  """

  use PotokIdeWeb, :html

  import Phoenix.LiveView, only: [push_event: 3]

  alias PotokIde.{Social, TextFold}
  alias PotokIdeWeb.GroupLive.Show.{Components, SubGroupTree}

  @directs_limit 20
  @open_limit 300

  def init(socket), do: assign(socket, :sidebar, nil)

  @doc """
  Loads the column, once. `params` may carry the `open` folders this browser
  remembers.
  """
  def load(socket, overview, params \\ %{})

  def load(
        %{assigns: %{sidebar: nil, current_profile: %{} = profile, group: %{is_root: false}}} =
          socket,
        overview,
        params
      ) do
    root = Social.get_root_group!()
    open = remembered_ids(params) ++ path_ids(socket, root)

    sidebar = %{
      root: root,
      search: "",
      open: open,
      tree: load_tree(root, profile, open, ""),
      directs: load_directs(root, profile, overview, ""),
      direct_rows: [],
      pins: Social.list_pinned_groups(profile),
      pin_rows: []
    }

    socket
    |> assign(:sidebar, sidebar)
    |> counted(overview)
  end

  def load(socket, _overview, _params), do: socket

  @doc "The profile pinned or unpinned a group: the pinned rows again."
  def pins_changed(%{assigns: %{sidebar: %{} = sidebar}} = socket) do
    pins = Social.list_pinned_groups(socket.assigns.current_profile)

    socket
    |> assign(:sidebar, %{sidebar | pins: pins})
    |> recount()
  end

  def pins_changed(socket), do: socket

  @doc "Opens or closes a folder of the tree; the browser remembers the open ones."
  def toggle(%{assigns: %{sidebar: %{tree: tree} = sidebar}} = socket, group_id) do
    tree = SubGroupTree.toggle(tree, group_id, socket.assigns.current_profile)

    socket
    |> assign(:sidebar, %{sidebar | tree: tree})
    |> recount()
    |> remember_open()
  end

  def toggle(socket, _group_id), do: socket

  @doc "The next page of the top level (nil) or of a folder."
  def more(%{assigns: %{sidebar: %{tree: tree} = sidebar}} = socket, group_id) do
    tree = SubGroupTree.load_more(tree, group_id, socket.assigns.current_profile)

    socket
    |> assign(:sidebar, %{sidebar | tree: tree})
    |> recount()
  end

  def more(socket, _group_id), do: socket

  @doc """
  Searches the viewer's groups by name: the tree shows the matches and the
  folders on the way to them, and the direct conversations narrow too. An
  empty search brings back the tree as it was.
  """
  def search(%{assigns: %{sidebar: %{} = sidebar}} = socket, query) do
    query = normalize_search(query)

    if query == sidebar.search do
      socket
    else
      profile = socket.assigns.current_profile
      root = sidebar.root

      # The folders open before the search come back after it.
      open = if sidebar.search == "", do: SubGroupTree.open_ids(sidebar.tree), else: sidebar.open

      sidebar = %{
        sidebar
        | search: query,
          open: open,
          tree: load_tree(root, profile, open, query),
          directs: load_directs(root, profile, current_overview(socket), query)
      }

      socket
      |> assign(:sidebar, sidebar)
      |> recount()
    end
  end

  def search(socket, _query), do: socket

  @doc """
  The rows' counts again, from the page's unread overview and what waits
  for the viewer (`group_waiting_counts`).
  """
  def counted(%{assigns: %{sidebar: %{} = sidebar}} = socket, %{} = overview) do
    counts = %{
      unread: subtree_counts(overview),
      muted: muted_counts(overview),
      waiting: socket.assigns[:group_waiting_counts] || %{},
      muted_ids: socket.assigns[:muted_group_ids] || MapSet.new()
    }

    tree = %{sidebar.tree | nodes: put_counts(sidebar.tree.nodes, counts)}

    assign(socket, :sidebar, %{
      sidebar
      | tree: tree,
        direct_rows: direct_rows(sidebar.directs, overview, counts.muted_ids),
        pin_rows: pin_rows(sidebar.pins, sidebar.search, counts)
    })
  end

  def counted(socket, _overview), do: socket

  @doc "A direct conversation of the column got a newest value (or lost it): its row says so."
  def noted(%{assigns: %{sidebar: %{directs: directs} = sidebar}} = socket, group_id, preview, at) do
    if Enum.any?(directs, &(&1.id == group_id)) do
      directs =
        Enum.map(directs, fn
          %{id: ^group_id} = group -> %{group | last_value: preview, last_value_at: at}
          group -> group
        end)

      socket
      |> assign(:sidebar, %{sidebar | directs: directs})
      |> recount()
    else
      socket
    end
  end

  def noted(socket, _group_id, _preview, _at), do: socket

  defp recount(socket), do: counted(socket, current_overview(socket))

  defp current_overview(socket),
    do: socket.assigns[:unread_overview] || Social.unread_overview(socket.assigns.current_profile)

  defp remember_open(%{assigns: %{sidebar: %{search: "", tree: tree}}} = socket) do
    ids = tree |> SubGroupTree.open_ids() |> Enum.take(@open_limit)
    push_event(socket, "group_sidebar_open", %{ids: ids})
  end

  defp remember_open(socket), do: socket

  defp load_tree(root, profile, open, search) do
    SubGroupTree.load(root, profile, nil,
      public?: false,
      threads?: false,
      open: open,
      search: search
    )
  end

  defp load_directs(root, profile, overview, search) do
    Social.list_child_groups_for_profile(root, profile,
      is_direct: true,
      search: if(search == "", do: nil, else: search),
      limit: @directs_limit,
      unread_overview: overview
    )
  end

  # The ids the browser sent, whole numbers only and not too many.
  defp remembered_ids(%{"open" => ids}) when is_list(ids) do
    ids
    |> Enum.flat_map(fn
      id when is_integer(id) and id > 0 ->
        [id]

      id when is_binary(id) ->
        case Integer.parse(id) do
          {id, ""} when id > 0 -> [id]
          _other -> []
        end

      _other ->
        []
    end)
    |> Enum.take(@open_limit)
  end

  defp remembered_ids(_params), do: []

  # The groups above the page's group, so its row is in sight.
  defp path_ids(socket, root) do
    current_id = socket.assigns.group.id

    for %{id: id} <- socket.assigns[:group_path] || [], id not in [root.id, current_id], do: id
  end

  defp normalize_search(query) when is_binary(query),
    do: query |> String.trim() |> String.slice(0, 120)

  defp normalize_search(_query), do: ""

  defp subtree_counts(%{groups: groups}),
    do: Map.new(groups, fn {id, info} -> {id, Map.get(info, :subtree, 0)} end)

  defp muted_counts(%{groups: groups}),
    do: Map.new(groups, fn {id, info} -> {id, Map.get(info, :muted, 0)} end)

  # A closed folder counts its whole sub-tree; an open one only what its
  # shown sub-groups leave out. A shortcut's leaf counts its target, which
  # is not below the folder it stands in, so it takes nothing from it.
  defp put_counts(nil, _counts), do: nil

  defp put_counts(nodes, counts) do
    Enum.map(nodes, fn node ->
      children = put_counts(node.children, counts)
      id = node.group.id
      shown = if node.open?, do: Enum.reject(children || [], &shortcut?/1), else: []

      node
      |> Map.put(:children, children)
      |> Map.put(:unread_count, visible(counts.unread, id, shown))
      |> Map.put(:waiting_count, visible(counts.waiting, id, shown))
      |> Map.put(:muted_unread, Map.get(counts.muted, id, 0))
      |> Map.put(:muted?, MapSet.member?(counts.muted_ids, id))
    end)
  end

  defp visible(counts, id, shown) do
    below = Enum.sum_by(shown, &Map.get(counts, &1.group.id, 0))
    max(Map.get(counts, id, 0) - below, 0)
  end

  defp shortcut?(node), do: is_integer(Map.get(node.group, :shortcut_id))

  # A pinned group stands out of its place in the tree, so it counts all
  # that is below it, as a closed folder does. A search keeps those whose
  # name holds it.
  defp pin_rows(pins, search, counts) do
    term = TextFold.fold(search)

    for %{group: group, path: path} <- pins,
        term == "" or String.contains?(TextFold.fold(group.name), term) do
      %{
        id: group.id,
        group: group,
        path: path,
        unread: Map.get(counts.unread, group.id, 0),
        muted_unread: Map.get(counts.muted, group.id, 0),
        waiting: Map.get(counts.waiting, group.id, 0),
        muted?: MapSet.member?(counts.muted_ids, group.id)
      }
    end
  end

  # A conversation's own unread values, a silenced one's apart, unread ones
  # first, then the newest.
  defp direct_rows(directs, overview, muted_ids) do
    directs
    |> Enum.map(fn group ->
      counts = Map.get(overview.groups, group.id, %{})

      %{
        id: group.id,
        group: group,
        unread: Map.get(counts, :own, 0),
        muted_unread: Map.get(counts, :muted, 0),
        muted?: MapSet.member?(muted_ids, group.id)
      }
    end)
    |> Enum.sort_by(&{&1.unread > 0, newest(&1.group), &1.id}, :desc)
  end

  defp newest(%{last_value_at: %DateTime{} = at}), do: DateTime.to_unix(at)
  defp newest(_group), do: 0

  attr :sidebar, :map, required: true, doc: "nil until it loads"
  attr :current_profile, :map, required: true
  attr :group_id, :integer, required: true, doc: "the page's group, whose row stands out"

  def panel(assigns) do
    assigns =
      assign(
        assigns,
        :search_form,
        to_form(%{"q" => (assigns.sidebar && assigns.sidebar.search) || ""},
          as: :group_sidebar_search
        )
      )

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

      <.form
        :if={@sidebar}
        for={@search_form}
        id="group-sidebar-search-form"
        phx-change="group_sidebar_search"
        phx-submit="group_sidebar_search"
        class="shrink-0 pr-2 pb-2 pl-1"
      >
        <div class="relative">
          <.icon
            name="hero-magnifying-glass"
            class="pointer-events-none absolute top-1/2 left-3 size-4 -translate-y-1/2 text-base-content/50"
          />
          <input
            type="text"
            id="group-sidebar-search-input"
            name={@search_form[:q].name}
            value={@search_form[:q].value}
            phx-debounce="300"
            autocomplete="off"
            placeholder={gettext("Search your groups")}
            aria-label={gettext("Search your groups")}
            class="h-9 w-full rounded-full border border-base-300 bg-base-100/85 pr-9 pl-9 text-sm transition-colors duration-150 placeholder:text-base-content/45 hover:border-base-content/30 focus:border-primary/60 focus:outline-none focus:ring-2 focus:ring-primary/20"
          />
          <button
            :if={@sidebar.search != ""}
            id="group-sidebar-search-reset"
            type="button"
            phx-click="clear_group_sidebar_search"
            aria-label={gettext("Clear search")}
            class="absolute top-1/2 right-2 inline-flex size-6 -translate-y-1/2 items-center justify-center rounded-full text-base-content/60 transition-colors hover:bg-base-200 hover:text-base-content"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
      </.form>

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
          <div :for={_row <- 1..6} class="h-9 animate-pulse rounded-xl bg-base-200/70" />
        </div>

        <%= if @sidebar do %>
          <section
            :if={@sidebar.pin_rows != []}
            id="group-sidebar-pinned"
            aria-labelledby="group-sidebar-pinned-title"
            class="mb-3"
          >
            <h3
              id="group-sidebar-pinned-title"
              class="py-1 pl-3 text-xs font-semibold uppercase tracking-[0.14em] text-base-content/60"
            >
              {gettext("Pinned")}
            </h3>
            <ul id="group-sidebar-pin-list" class="space-y-px">
              <.pin_row
                :for={row <- @sidebar.pin_rows}
                :key={row.id}
                row={row}
                group_id={@group_id}
                search={@sidebar.search}
              />
            </ul>
          </section>
          <div id="group-sidebar-tree" role="tree" aria-label={gettext("Your groups")}>
            <.sidebar_node
              :for={node <- @sidebar.tree.nodes}
              :key={node_key(node)}
              node={node}
              group_id={@group_id}
              search={@sidebar.search}
            />
            <.more_button :if={@sidebar.tree.more?} id="group-sidebar-more" />
          </div>
          <p
            :if={@sidebar.tree.nodes == [] and @sidebar.search == ""}
            id="group-sidebar-empty"
            class="px-3 py-4 text-sm text-base-content/60"
          >
            {gettext("You are not in any group yet.")}
          </p>
          <p
            :if={
              @sidebar.search != "" and @sidebar.tree.nodes == [] and @sidebar.direct_rows == [] and
                @sidebar.pin_rows == []
            }
            id="group-sidebar-no-match"
            class="px-3 py-4 text-sm text-base-content/60"
          >
            {gettext("None of your groups matches the search.")}
          </p>
          <p
            :if={@sidebar.tree.truncated?}
            id="group-sidebar-truncated"
            class="flex items-center gap-1.5 px-3 pt-2 text-xs text-base-content/60"
          >
            <.icon name="hero-information-circle" class="size-4 shrink-0" />
            {gettext("Only part of the results is shown. Narrow the search.")}
          </p>

          <section
            :if={@sidebar.direct_rows != []}
            id="group-sidebar-directs"
            aria-labelledby="group-sidebar-directs-title"
            class="mt-4"
          >
            <div class="flex items-center justify-between gap-2 py-1 pr-1 pl-3">
              <h3
                id="group-sidebar-directs-title"
                class="text-xs font-semibold uppercase tracking-[0.14em] text-base-content/60"
              >
                {gettext("Direct conversations")}
              </h3>
              <.link
                id="group-sidebar-directs-all"
                navigate={~p"/groups/#{@sidebar.root.id}/sub_groups?#{[sub_groups_kind: "direct"]}"}
                class="rounded-full px-2 py-0.5 text-xs font-medium text-primary transition-colors hover:bg-primary/10"
              >
                {gettext("All conversations")}
              </.link>
            </div>
            <ul id="group-sidebar-direct-list" class="space-y-0.5">
              <li
                :for={row <- @sidebar.direct_rows}
                :key={row.id}
                id={"group-sidebar-direct-#{row.id}"}
                aria-current={row.id == @group_id && "page"}
                class={[
                  "group/child relative rounded-2xl px-2 py-2 transition-colors duration-150",
                  if(row.id == @group_id, do: "bg-primary/10", else: "hover:bg-base-200/70")
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
                <%!-- The counts keep their place when they are 0, so a row that
                     moves keeps its shape: they stand over the avatar's corner. --%>
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
            </ul>
          </section>
        <% end %>
      </div>
    </aside>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".GroupSidebar">
      // Where the list stood, for the next group's page: the column loads again there.
      const SCROLL_KEY = "potok:group-sidebar-scroll"
      // The folders open in the tree, for every page of this browser.
      const OPEN_KEY = "potok:group-sidebar-open"

      const storedOpen = () => {
        try {
          const ids = JSON.parse(localStorage.getItem(OPEN_KEY) || "[]")
          return Array.isArray(ids) ? ids.filter(Number.isInteger).slice(0, 300) : []
        } catch (_error) {
          return []
        }
      }

      export default {
        mounted() {
          this.wide = window.matchMedia("(min-width: 80rem)")
          this.scroller = this.el.querySelector("#group-sidebar-scroll")

          this.maybeLoad = () => {
            const hidden = document.documentElement.dataset.groupSidebar === "hidden"
            if (this.loaded || hidden || !this.wide.matches) return

            this.loaded = true
            this.pushEvent("group_sidebar_load", {open: storedOpen()})
          }

          this.keepScroll = () => {
            try {
              sessionStorage.setItem(SCROLL_KEY, String(this.scroller.scrollTop))
            } catch (_error) {}
          }

          this.handleEvent("group_sidebar_open", ({ids}) => {
            try {
              localStorage.setItem(OPEN_KEY, JSON.stringify(ids))
            } catch (_error) {}
          })

          this.wide.addEventListener("change", this.maybeLoad)
          window.addEventListener("potok:group-sidebar-shown", this.maybeLoad)
          this.scroller.addEventListener("scroll", this.keepScroll, {passive: true})
          this.maybeLoad()
        },

        updated() {
          if (this.restored || !this.el.querySelector("#group-sidebar-tree")) return

          this.restored = true

          try {
            const top = Number(sessionStorage.getItem(SCROLL_KEY))
            if (top > 0) this.scroller.scrollTop = top
          } catch (_error) {}

          // The page's own row in sight, if the list starts somewhere else.
          const current = this.el.querySelector("#group-sidebar-tree [aria-current=page]")
          if (current) current.scrollIntoView({block: "nearest"})
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

  attr :node, :map, required: true, doc: "a `SubGroupTree` node with its counts"
  attr :group_id, :integer, required: true
  attr :search, :string, required: true

  # The chevron opens and closes a folder; the name opens the group.
  defp sidebar_node(assigns) do
    node = assigns.node

    assigns =
      assigns
      |> assign(:key, node_key(node))
      |> assign(:folder?, node.child_count > 0 or node.children not in [nil, []])
      |> assign(:current?, node.group.id == assigns.group_id and not shortcut?(node))
      |> assign(:unread, Map.get(node, :unread_count, 0))
      |> assign(:muted_unread, Map.get(node, :muted_unread, 0))
      |> assign(:waiting, Map.get(node, :waiting_count, 0))

    ~H"""
    <div
      id={"group-sidebar-node-#{@key}"}
      role="treeitem"
      aria-expanded={@folder? && to_string(@node.open?)}
    >
      <div class={[
        "group/node flex items-center gap-0.5 rounded-xl pr-1.5 transition-colors duration-150",
        if(@current?, do: "bg-primary/10", else: "hover:bg-base-200/70")
      ]}>
        <%= if @folder? do %>
          <button
            id={"group-sidebar-toggle-#{@key}"}
            type="button"
            phx-click="group_sidebar_toggle"
            phx-value-id={@node.group.id}
            aria-label={gettext("Sub-groups of %{name}", name: @node.group.name)}
            class="inline-flex size-7 shrink-0 items-center justify-center rounded-lg text-base-content/60 transition-colors hover:text-base-content"
          >
            <.icon
              name="hero-chevron-right"
              class={[
                "size-3.5 transition-transform duration-150 phx-click-loading:hidden",
                @node.open? && "rotate-90"
              ]}
            />
            <span class="hidden size-3.5 animate-spin rounded-full border-2 border-current border-t-transparent phx-click-loading:block">
            </span>
          </button>
        <% else %>
          <span class="size-7 shrink-0" aria-hidden="true"></span>
        <% end %>
        <.link
          id={"group-sidebar-link-#{@key}"}
          navigate={~p"/groups/#{@node.group.id}"}
          aria-current={@current? && "page"}
          title={
            if(@node.group.member?,
              do: @node.group.name,
              else: gettext("You are not a member of %{name}", name: @node.group.name)
            )
          }
          class="flex min-w-0 flex-1 items-center gap-2 py-1.5"
        >
          <span class="relative shrink-0">
            <.icon
              name={node_icon(@node)}
              class={[
                "size-5",
                if(@node.group.member?, do: "text-amber-500", else: "text-base-content/40")
              ]}
            />
            <Components.avatar_mark
              icon={
                if(@node.group.public?, do: "hero-globe-alt-micro", else: "hero-lock-closed-micro")
              }
              class="-bottom-1 -left-1 size-3.5 [&>span]:size-2.5"
            />
            <Components.avatar_mark
              :if={shortcut?(@node)}
              icon="hero-arrow-turn-up-right-micro"
              title={gettext("Shortcut")}
              class="-bottom-1 -right-1 size-3.5 text-primary [&>span]:size-2.5"
            />
          </span>
          <Components.highlighted_text
            text={@node.group.name}
            query={@search}
            class={[
              "min-w-0 flex-1 truncate text-sm",
              cond do
                @current? -> "font-semibold text-base-content"
                @node.group.member? -> "font-medium text-base-content/90"
                true -> "text-base-content/65"
              end
            ]}
          />
          <.icon
            :if={Map.get(@node, :muted?, false)}
            id={"group-sidebar-muted-#{@key}"}
            name="hero-bell-slash-micro"
            class="size-3.5 shrink-0 text-base-content/45"
          />
        </.link>
        <span
          id={"group-sidebar-waiting-#{@key}"}
          hidden={@waiting == 0}
          title={gettext("Waiting for you: %{count}", count: @waiting)}
          aria-label={gettext("Waiting for you: %{count}", count: @waiting)}
          class="inline-flex h-5 shrink-0 items-center gap-1 rounded-full bg-amber-500/15 px-1.5 text-[11px] font-semibold tabular-nums text-amber-900 dark:text-amber-100"
        >
          <span class="size-1.5 rounded-full bg-amber-500" aria-hidden="true"></span>
          {@waiting}
        </span>
        <.count_badge
          id={"group-sidebar-unread-#{@key}"}
          count={@unread}
          hidden={@unread == 0}
          class="shrink-0"
        />
        <.count_badge
          id={"group-sidebar-muted-unread-#{@key}"}
          count={@muted_unread}
          tone={:muted}
          hidden={@unread > 0 or @muted_unread == 0}
          class="shrink-0"
        />
      </div>
      <div
        :if={@node.open? and @node.children not in [nil, []]}
        role="group"
        class="ml-3.5 space-y-px border-l border-base-300/70 pl-1"
      >
        <.sidebar_node
          :for={child <- @node.children}
          :key={node_key(child)}
          node={child}
          group_id={@group_id}
          search={@search}
        />
        <.more_button
          :if={@node.more?}
          id={"group-sidebar-more-#{@node.group.id}"}
          parent_id={@node.group.id}
        />
      </div>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :group_id, :integer, required: true
  attr :search, :string, required: true

  # A pinned group with the way to it under its name, and its pin to take off.
  defp pin_row(assigns) do
    assigns = assign(assigns, :current?, assigns.row.id == assigns.group_id)

    ~H"""
    <li
      id={"group-sidebar-pin-#{@row.id}"}
      class={[
        "group/pin flex items-center gap-1 rounded-xl pr-1 pl-1.5 transition-colors duration-150",
        if(@current?, do: "bg-primary/10", else: "hover:bg-base-200/70")
      ]}
    >
      <.link
        id={"group-sidebar-pin-link-#{@row.id}"}
        navigate={~p"/groups/#{@row.id}"}
        aria-current={@current? && "page"}
        title={Enum.join(@row.path ++ [@row.group.name], " › ")}
        class="flex min-w-0 flex-1 items-center gap-2 py-1.5"
      >
        <span class="relative shrink-0">
          <.icon
            name={
              if(@row.group.parent_value_id, do: "hero-chat-bubble-left-right", else: "hero-folder")
            }
            class="size-5 text-amber-500"
          />
          <Components.avatar_mark
            icon="hero-bookmark-solid"
            class="-bottom-1 -left-1 size-3.5 text-primary [&>span]:size-2.5"
          />
        </span>
        <span class="min-w-0 flex-1">
          <Components.highlighted_text
            text={@row.group.name}
            query={@search}
            class={[
              "block truncate text-sm",
              if(@current?, do: "font-semibold text-base-content", else: "font-medium")
            ]}
          />
          <span
            :if={@row.path != []}
            id={"group-sidebar-pin-path-#{@row.id}"}
            class="block truncate text-[11px] leading-4 text-base-content/55"
          >
            {Enum.join(@row.path, " › ")}
          </span>
        </span>
        <.icon
          :if={@row.muted?}
          name="hero-bell-slash-micro"
          class="size-3.5 shrink-0 text-base-content/45"
        />
      </.link>
      <span
        id={"group-sidebar-pin-waiting-#{@row.id}"}
        hidden={@row.waiting == 0}
        title={gettext("Waiting for you: %{count}", count: @row.waiting)}
        aria-label={gettext("Waiting for you: %{count}", count: @row.waiting)}
        class="inline-flex h-5 shrink-0 items-center gap-1 rounded-full bg-amber-500/15 px-1.5 text-[11px] font-semibold tabular-nums text-amber-900 dark:text-amber-100"
      >
        <span class="size-1.5 rounded-full bg-amber-500" aria-hidden="true"></span>
        {@row.waiting}
      </span>
      <.count_badge
        id={"group-sidebar-pin-unread-#{@row.id}"}
        count={@row.unread}
        hidden={@row.unread == 0}
        class="shrink-0"
      />
      <.count_badge
        id={"group-sidebar-pin-muted-unread-#{@row.id}"}
        count={@row.muted_unread}
        tone={:muted}
        hidden={@row.unread > 0 or @row.muted_unread == 0}
        class="shrink-0"
      />
      <button
        id={"group-sidebar-unpin-#{@row.id}"}
        type="button"
        phx-click={JS.push("group_pin", value: %{id: @row.id, pin: false})}
        aria-label={gettext("Unpin %{name}", name: @row.group.name)}
        title={gettext("Unpin")}
        class="inline-flex size-6 shrink-0 items-center justify-center rounded-full text-base-content/50 opacity-0 transition duration-150 hover:bg-base-300 hover:text-base-content focus-visible:opacity-100 group-hover/pin:opacity-100 phx-click-loading:animate-pulse"
      >
        <.icon name="hero-x-mark-micro" class="size-4" />
      </button>
    </li>
    """
  end

  attr :id, :string, required: true
  attr :parent_id, :integer, default: nil, doc: "the folder to page, nil for the top level"

  defp more_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click="group_sidebar_more"
      phx-value-id={@parent_id}
      class="ml-7 inline-flex items-center gap-1.5 rounded-full px-2 py-1 text-xs font-medium text-base-content/65 transition-colors hover:bg-base-200 hover:text-base-content phx-click-loading:animate-pulse"
    >
      <.icon name="hero-ellipsis-horizontal" class="size-4" />
      {gettext("Load more sub-groups")}
    </button>
    """
  end

  defp node_icon(%{group: %{thread?: true}}), do: "hero-chat-bubble-left-right"
  defp node_icon(%{open?: true}), do: "hero-folder-open"
  defp node_icon(_node), do: "hero-folder"

  # A shortcut's leaf has its own id, as its target may stand in the tree too.
  defp node_key(%{group: %{shortcut_id: id}}) when is_integer(id), do: "shortcut-#{id}"
  defp node_key(%{group: %{id: id}}), do: Integer.to_string(id)

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
