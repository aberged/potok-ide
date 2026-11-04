defmodule PotokIdeWeb.GroupLive.Show.SubGroupsTab do
  use PotokIdeWeb, :html

  alias PotokIde.Events.Format
  alias PotokIdeWeb.GroupLive.Show.Components
  alias PotokIdeWeb.TagComponents

  attr :group, :map, required: true
  attr :current_profile, :map, default: nil
  attr :children, :any, required: true
  attr :pagination, :map, required: true
  attr :pending_join_request_counts, :map, required: true
  attr :unread_counts, :map, required: true
  attr :is_member, :boolean, required: true
  attr :can_create_subgroups, :boolean, default: false
  attr :sub_groups_kind, :string, required: true
  attr :direct_sub_groups_unread_count, :integer, required: true
  attr :other_sub_groups_unread_count, :integer, required: true
  attr :children_search_query, :string, default: ""
  attr :show_thread_sub_groups, :boolean, default: false
  attr :thread_sub_groups_count, :integer, default: 0

  attr :show_public_sub_groups, :boolean,
    default: false,
    doc: "whether the root shows the public groups the viewer is not in"

  attr :sub_groups_view, :string, default: "list", doc: "\"list\" or \"tree\""
  attr :tree, :map, default: nil, doc: "the `SubGroupTree` of the group"
  attr :time_zone, :string, required: true, doc: "the viewer's, for when sub-groups were active"

  def panel(assigns) do
    assigns =
      assigns
      |> assign(
        :children_search_form,
        to_form(%{"q" => assigns.children_search_query}, as: :children_search)
      )
      # Only a search narrows the list: hidden threads and public groups are
      # the default and the view shows the same sub-groups either way.
      |> assign(:filters_active?, String.trim(assigns.children_search_query) != "")
      |> assign(
        :public_hidden?,
        assigns.group.is_root and assigns.sub_groups_kind != "direct" and
          not assigns.show_public_sub_groups
      )

    ~H"""
    <div
      id="group-panel-sub-groups"
      class="card relative flex min-h-0 flex-1 flex-col px-2"
    >
      <%!-- The controls fold into one button when they cover the list. The
           browser remembers the choice (`.CollapsibleFilters`) and patches
           keep what the hook set. --%>
      <div
        id="group-children-filters"
        phx-hook=".CollapsibleFilters"
        phx-mounted={JS.ignore_attributes(["data-collapsed"])}
        class="group/filters relative z-45 flex shrink-0 items-start justify-end gap-2 px-2 pb-1"
      >
        <div
          id="group-children-filters-body"
          class="flex items-start gap-2 group-data-collapsed/filters:hidden"
        >
          <%!-- List or folder tree; direct conversations are always a list.
             Phones get one button that flips to the other view, so the
             row keeps its room. --%>
          <button
            :if={@sub_groups_kind != "direct"}
            id="group-children-view-flip"
            type="button"
            phx-click="set_sub_groups_view"
            phx-value-view={if(@sub_groups_view == "tree", do: "list", else: "tree")}
            aria-label={if(@sub_groups_view == "tree", do: gettext("List"), else: gettext("Folders"))}
            class="mt-1 inline-flex size-10 shrink-0 items-center justify-center rounded-full border border-gray-500/50 bg-base-100 text-base-content/70 shadow-xs transition duration-150 ease-out hover:text-base-content active:scale-95 phx-click-loading:opacity-60 sm:hidden max-sm:group-has-[input:focus]/filters:hidden"
          >
            <.icon
              name={if(@sub_groups_view == "tree", do: "hero-list-bullet", else: "hero-folder")}
              class="size-4"
            />
          </button>
          <div
            :if={@sub_groups_kind != "direct"}
            id="group-children-view"
            role="group"
            aria-label={gettext("Show sub-groups as")}
            class="mt-1 hidden h-10 shrink-0 items-center rounded-full border border-gray-500/50 bg-base-100 p-0.5 shadow-xs sm:inline-flex"
          >
            <Components.view_toggle_button
              id="group-children-view-list"
              event="set_sub_groups_view"
              view="list"
              active={@sub_groups_view == "list"}
              icon="hero-list-bullet"
              label={gettext("List")}
              label_class="sr-only"
            />
            <Components.view_toggle_button
              id="group-children-view-tree"
              event="set_sub_groups_view"
              view="tree"
              active={@sub_groups_view == "tree"}
              icon="hero-folder"
              label={gettext("Folders")}
              label_class="sr-only"
            />
          </div>

          <%!-- Shown or hidden thread sub-groups (groups started from a chat value).
             Phones give the expanded search the whole row while it has focus. --%>
          <button
            :if={@thread_sub_groups_count > 0}
            id="group-children-threads-toggle"
            type="button"
            phx-click="toggle_thread_sub_groups"
            aria-pressed={to_string(@show_thread_sub_groups)}
            title={
              if(@show_thread_sub_groups, do: gettext("Hide threads"), else: gettext("Show threads"))
            }
            class={[
              "mt-1 inline-flex h-10 items-center gap-1.5 rounded-full border px-3 text-sm font-semibold shadow-xs transition duration-150 ease-out hover:-translate-y-px active:scale-95 phx-click-loading:opacity-60 max-sm:group-has-[input:focus]/filters:hidden",
              if(@show_thread_sub_groups,
                do: "border-primary/50 bg-base-100 text-primary hover:bg-base-200",
                else: "border-gray-500/50 bg-base-100 text-base-content/65 hover:text-base-content"
              )
            ]}
          >
            <.icon
              name={
                if(@show_thread_sub_groups, do: "hero-chat-bubble-left-right", else: "hero-eye-slash")
              }
              class="size-4"
            />
            <span class="hidden sm:inline">{gettext("Threads")}</span>
            <span class={[
              "inline-flex min-w-5 items-center justify-center rounded-full px-1.5 py-0.5 text-[11px] leading-none tabular-nums",
              if(@show_thread_sub_groups,
                do: "bg-primary text-primary-content",
                else: "bg-base-300 text-base-content/70"
              )
            ]}>
              {@thread_sub_groups_count}
            </span>
          </button>

          <%!-- The root's public groups the viewer is not in, hidden until shown;
             those on the way to one of the viewer's groups stay. --%>
          <button
            :if={@group.is_root and @sub_groups_kind != "direct"}
            id="group-children-public-toggle"
            type="button"
            phx-click="toggle_public_sub_groups"
            aria-pressed={to_string(@show_public_sub_groups)}
            title={
              if(@show_public_sub_groups,
                do: gettext("Hide public groups you are not in"),
                else: gettext("Show public groups you are not in")
              )
            }
            class={[
              "mt-1 inline-flex h-10 items-center gap-1.5 rounded-full border px-3 text-sm font-semibold shadow-xs transition duration-150 ease-out hover:-translate-y-px active:scale-95 phx-click-loading:opacity-60 max-sm:group-has-[input:focus]/filters:hidden",
              if(@show_public_sub_groups,
                do: "border-primary/50 bg-base-100 text-primary hover:bg-base-200",
                else: "border-gray-500/50 bg-base-100 text-base-content/65 hover:text-base-content"
              )
            ]}
          >
            <.icon
              name={if(@show_public_sub_groups, do: "hero-megaphone", else: "hero-eye-slash")}
              class="size-4"
            />
            <span class="hidden sm:inline">{gettext("Public groups")}</span>
          </button>

          <.form
            for={@children_search_form}
            id="group-children-search-form"
            phx-change="search_children"
          >
            <.search_field
              id="group-children-search-input"
              field={@children_search_form[:q]}
              reset_id="group-children-search-reset"
              reset_event="clear_children_search"
              placeholder={gettext("Search by name")}
            />
          </.form>
        </div>

        <%!-- Last, so a folded bar leaves only this button at the edge. The dot
             tells a folded bar that the list is filtered. --%>
        <button
          id="group-children-filters-toggle"
          type="button"
          aria-controls="group-children-filters-body"
          aria-expanded="true"
          aria-label={gettext("Filters")}
          title={gettext("Filters")}
          phx-mounted={JS.ignore_attributes(["aria-expanded"])}
          class="relative mt-1 inline-flex size-10 shrink-0 items-center justify-center rounded-full border border-gray-500/50 bg-base-100 text-base-content/70 shadow-xs transition duration-150 ease-out hover:-translate-y-px hover:text-base-content active:scale-95"
        >
          <.icon name="hero-chevron-right" class="size-4 group-data-collapsed/filters:hidden" />
          <.icon
            name="hero-adjustments-horizontal"
            class="hidden size-4 group-data-collapsed/filters:block"
          />
          <span
            :if={@filters_active?}
            id="group-children-filters-active"
            class="absolute -right-0.5 -top-0.5 hidden size-2.5 rounded-full bg-primary ring-2 ring-base-100 group-data-collapsed/filters:block"
          >
          </span>
        </button>
        <script :type={Phoenix.LiveView.ColocatedHook} name=".CollapsibleFilters">
          const STORAGE_KEY = "potok:sub-groups-filters"

          export default {
            mounted() {
              const toggle = () => this.el.querySelector("#group-children-filters-toggle")

              const apply = collapsed => {
                this.el.toggleAttribute("data-collapsed", collapsed)
                toggle()?.setAttribute("aria-expanded", String(!collapsed))
              }

              let stored = null
              try {
                stored = window.localStorage.getItem(STORAGE_KEY)
              } catch (_error) {}
              apply(stored === "collapsed")

              this.el.addEventListener("click", event => {
                if (!event.target.closest("#group-children-filters-toggle")) return

                const collapsed = !this.el.hasAttribute("data-collapsed")
                apply(collapsed)

                try {
                  window.localStorage.setItem(STORAGE_KEY, collapsed ? "collapsed" : "expanded")
                } catch (_error) {}
              })
            },
          }
        </script>
      </div>

      <div class="min-h-0 flex-1 overflow-y-auto overscroll-contain p-2 pb-24">
        <p
          :if={@pagination.loaded_count == 0}
          id="group-children-empty"
          class="text-base-content/70"
        >
          <%= cond do %>
            <% String.trim(@children_search_query) != "" -> %>
              {gettext("No sub-groups match your search.")}
            <% !@show_thread_sub_groups and @thread_sub_groups_count > 0 -> %>
              {gettext("Only threads here, and they are hidden.")}
            <% @public_hidden? -> %>
              {gettext("You are not in any group yet.")}
            <% true -> %>
              {gettext("No sub-groups yet.")}
          <% end %>
        </p>
        <%!-- Lets a new profile find groups to join. --%>
        <div
          :if={@pagination.loaded_count == 0 and @public_hidden?}
          id="group-children-public-hidden"
          class="mt-3 flex flex-wrap items-center gap-3 text-sm text-base-content/65"
        >
          <span>{gettext("Public groups you are not in are hidden.")}</span>
          <.button
            id="group-children-show-public"
            type="button"
            phx-click="toggle_public_sub_groups"
            size="sm"
          >
            <.icon name="hero-megaphone" class="size-4" />
            {gettext("Show public groups")}
          </.button>
        </div>

        <%= if @sub_groups_view == "tree" do %>
          <div
            :if={@tree && @tree.nodes != []}
            id="group-children-tree"
            role="tree"
            class="mt-2 rounded-3xl border border-base-300/70 bg-base-100/70 p-2 shadow-sm"
          >
            <.tree_node
              :for={node <- @tree.nodes}
              :key={node.group.id}
              node={node}
              search_query={@children_search_query}
            />
            <.tree_more_button :if={@tree.more?} id="group-children-tree-more" />
          </div>
          <p
            :if={@tree && @tree.truncated?}
            id="group-children-tree-truncated"
            class="mt-3 flex items-center gap-2 px-1 text-xs text-base-content/65"
          >
            <.icon name="hero-information-circle" class="size-4 shrink-0" />
            {gettext(
              "Only part of the results is shown. Narrow the search, or open a sub-group to search inside it."
            )}
          </p>
        <% else %>
          <ul id="group-children-list" class="space-y-4" phx-update="stream">
            <li :for={{dom_id, group} <- @children} id={dom_id} class="group/child">
              <div class="flex items-center gap-1">
                <div class="min-w-0 flex-1">
                  <Components.group_identity
                    group={group}
                    current_profile={@current_profile}
                    avatar_size="size-10"
                    text_class="text-sm"
                    highlight_query={@children_search_query}
                    pending_join_requests_count={Map.get(@pending_join_request_counts, group.id, 0)}
                    unread_count={Map.get(@unread_counts, group.id, 0)}
                  >
                    <:subtitle :if={child_details?(group)}>
                      <.child_details group={group} time_zone={@time_zone} />
                    </:subtitle>
                  </Components.group_identity>
                </div>
                <TagComponents.tag_button
                  id={"child-group-tags-#{group.id}"}
                  kind={:group}
                  item_id={group.id}
                  class="shrink-0 opacity-60 transition-opacity group-hover/child:opacity-100 focus-visible:opacity-100"
                />
              </div>
            </li>
          </ul>

          <div :if={@pagination.has_more?} class="mt-4 flex justify-center">
            <.button
              id="group-children-load-more"
              type="button"
              phx-click="load_more_children"
              size="sm"
            >
              {gettext("Load more sub-groups")}
            </.button>
          </div>
        <% end %>
      </div>

      <.icon_button
        :if={@can_create_subgroups}
        id="group-sub-groups-create-fab"
        type="button"
        phx-click="switch_tab"
        phx-value-tab="create_group"
        icon="hero-plus"
        label={gettext("Create sub-group")}
        variant="primary"
        size="lg"
        class="absolute bottom-[1.5rem] right-0 mr-6"
      />
    </div>
    """
  end

  # Direct conversations load no counts, so they show the time alone.
  defp child_details?(group),
    do: group.last_value_at != nil or group.member_count != nil or group.tags != []

  attr :group, :map, required: true
  attr :time_zone, :string, required: true

  # The line below a sub-group's name: when it last had a value, its members
  # and sub-groups, whether the viewer is in it (only public groups list
  # without), and its tags, which give way when space runs out.
  defp child_details(assigns) do
    ~H"""
    <div
      id={"child-group-details-#{@group.id}"}
      class="flex min-w-0 items-center gap-2 text-[11px] leading-4 text-base-content/65"
    >
      <time
        :if={@group.last_value_at}
        id={"child-group-last-value-#{@group.id}"}
        datetime={DateTime.to_iso8601(@group.last_value_at)}
        class="shrink-0 tabular-nums"
      >
        {Format.recent(@group.last_value_at, @time_zone, DateTime.utc_now())}
      </time>
      <span
        :if={@group.member_count}
        id={"child-group-members-#{@group.id}"}
        class="inline-flex shrink-0 items-center gap-0.5 tabular-nums"
      >
        <.icon name="hero-users" class="size-3 opacity-70" />
        <span aria-hidden="true">{@group.member_count}</span>
        <span class="sr-only">
          {ngettext("1 member", "%{count} members", @group.member_count)}
        </span>
      </span>
      <span
        :if={(@group.sub_group_count || 0) > 0}
        id={"child-group-sub-groups-#{@group.id}"}
        class="inline-flex shrink-0 items-center gap-0.5 tabular-nums"
      >
        <.icon name="hero-folder" class="size-3 opacity-70" />
        <span aria-hidden="true">{@group.sub_group_count}</span>
        <span class="sr-only">
          {ngettext("1 sub-group", "%{count} sub-groups", @group.sub_group_count)}
        </span>
      </span>
      <span
        :if={@group.viewer_is_member == false}
        id={"child-group-not-member-#{@group.id}"}
        class="shrink-0"
      >
        {gettext("Not a member")}
      </span>
      <TagComponents.tag_chips
        id={"child-group-tag-list-#{@group.id}"}
        tags={@group.tags}
        size={:sm}
        max={3}
      />
    </div>
    """
  end

  attr :node, :map, required: true, doc: "a `SubGroupTree` node"
  attr :search_query, :string, default: ""

  # The chevron opens and closes a folder; the name opens the group. The
  # server keeps which folders are open, so a reload keeps them as they were,
  # and the first opening of a folder loads its sub-groups.
  defp tree_node(assigns) do
    assigns =
      assign(
        assigns,
        :folder?,
        assigns.node.child_count > 0 or assigns.node.children not in [nil, []]
      )

    ~H"""
    <div
      id={"sub-group-folder-#{@node.group.id}"}
      role="treeitem"
      aria-expanded={@folder? && to_string(@node.open?)}
    >
      <div class="flex items-center rounded-xl pr-2 transition-colors hover:bg-base-200">
        <%= if @folder? do %>
          <button
            id={"sub-group-folder-toggle-#{@node.group.id}"}
            type="button"
            phx-click="toggle_sub_group_folder"
            phx-value-id={@node.group.id}
            aria-label={gettext("Sub-groups of %{name}", name: @node.group.name)}
            class="inline-flex size-8 shrink-0 items-center justify-center rounded-lg text-base-content/65 transition-colors hover:text-base-content"
          >
            <.icon
              name="hero-chevron-right"
              class={[
                "size-3.5 transition-transform duration-150 phx-click-loading:hidden",
                @node.open? && "rotate-90"
              ]}
            />
            <%!-- Shown while the sub-groups of a folder opened for the first time load. --%>
            <span class="hidden size-3.5 animate-spin rounded-full border-2 border-current border-t-transparent phx-click-loading:block">
            </span>
          </button>
        <% else %>
          <span class="size-8 shrink-0" aria-hidden="true"></span>
        <% end %>
        <.tree_node_link node={@node} search_query={@search_query} />
      </div>
      <div
        :if={@node.open? and @node.children not in [nil, []]}
        role="group"
        class="ml-4 space-y-0.5 border-l border-base-300/70 pl-1"
      >
        <.tree_node
          :for={child <- @node.children}
          :key={child.group.id}
          node={child}
          search_query={@search_query}
        />
        <.tree_more_button
          :if={@node.more?}
          id={"sub-group-folder-more-#{@node.group.id}"}
          parent_id={@node.group.id}
        />
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :parent_id, :integer, default: nil, doc: "the folder to page, nil for the top level"

  defp tree_more_button(assigns) do
    ~H"""
    <.button
      id={@id}
      type="button"
      phx-click="load_more_sub_group_folders"
      phx-value-id={@parent_id}
      size="sm"
      class="ml-8 mt-0.5"
    >
      <.icon name="hero-ellipsis-horizontal" class="size-4" />
      {gettext("Load more sub-groups")}
    </.button>
    """
  end

  attr :node, :map, required: true
  attr :search_query, :string, required: true

  defp tree_node_link(assigns) do
    assigns =
      assigns
      |> assign(:group, assigns.node.group)
      |> assign(:open?, assigns.node.open?)
      |> assign(:unread_count, assigns.node.unread_count)

    ~H"""
    <.link
      id={"sub-group-folder-link-#{@group.id}"}
      navigate={~p"/groups/#{@group.id}"}
      title={
        if(@group.member?,
          do: @group.name,
          else: gettext("You are not a member of %{name}", name: @group.name)
        )
      }
      class="group/node flex min-w-0 flex-1 items-center gap-2 py-1.5"
    >
      <span class="relative shrink-0">
        <%= if @group.thread? do %>
          <.icon name="hero-chat-bubble-left-right" class={["size-5", node_icon_color(@group)]} />
        <% else %>
          <.icon
            name={if(@open?, do: "hero-folder-open", else: "hero-folder")}
            class={["size-5", node_icon_color(@group)]}
          />
        <% end %>
        <Components.avatar_mark
          icon={if(@group.public?, do: "hero-megaphone-micro", else: "hero-lock-closed-micro")}
          class="-bottom-1 -left-1 size-3.5 [&>span]:size-2.5"
        />
      </span>
      <Components.highlighted_text
        text={@group.name}
        query={@search_query}
        class={[
          "min-w-0 flex-1 truncate text-sm transition-colors group-hover/node:text-base-content",
          if(@group.member?, do: "font-medium text-base-content", else: "text-base-content/65")
        ]}
      />
      <span
        :if={@node.child_count > 0}
        class="shrink-0 text-xs tabular-nums text-base-content/65"
      >
        {ngettext("1 sub-group", "%{count} sub-groups", @node.child_count)}
      </span>
      <.count_badge
        :if={@unread_count > 0}
        id={"sub-group-folder-unread-#{@group.id}"}
        count={@unread_count}
        class="shrink-0"
      />
    </.link>
    """
  end

  defp node_icon_color(%{member?: true}), do: "text-amber-500"
  defp node_icon_color(_group), do: "text-base-content/40"
end
