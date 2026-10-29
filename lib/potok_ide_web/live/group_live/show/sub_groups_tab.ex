defmodule PotokIdeWeb.GroupLive.Show.SubGroupsTab do
  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.Components

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
  attr :show_thread_sub_groups, :boolean, default: true
  attr :thread_sub_groups_count, :integer, default: 0
  attr :sub_groups_view, :string, default: "list", doc: "\"list\" or \"tree\""
  attr :tree, :map, default: nil, doc: "`Social.sub_group_tree/3` of the group"

  def panel(assigns) do
    assigns =
      assign(
        assigns,
        :children_search_form,
        to_form(%{"q" => assigns.children_search_query}, as: :children_search)
      )

    ~H"""
    <div
      id="group-panel-sub-groups"
      class="card relative flex min-h-0 flex-1 flex-col px-2"
    >
      <div class="group/filters absolute right-4 -top-[.06rem] z-45 mb-3 flex items-start gap-2">
        <%!-- List or folder tree; direct conversations are always a list.
             Phones get one button that flips to the other view, so the
             group path keeps its room. --%>
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
              else: "border-gray-500/50 bg-base-100 text-base-content/55 hover:text-base-content"
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

        <.form
          for={@children_search_form}
          id="group-children-search-form"
          phx-change="search_children"
        >
          <div class="relative w-fit">
            <button
              :if={@children_search_query != ""}
              id="group-children-search-reset"
              type="button"
              phx-click="clear_children_search"
              aria-label={gettext("Clear search")}
              class="absolute left-2 pt-[0.7rem] text-base-content/60 hover:text-base-content"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
            <.input
              field={@children_search_form[:q]}
              id="group-children-search-input"
              type="text"
              phx-debounce="300"
              autocomplete="off"
              class="bg-base-100/85 h-10 px-6 pr-10 rounded-full text-sm focus:outline-none border border-gray-500/50 transition-all duration-300 ease-in-out w-12 focus:w-64"
              placeholder={gettext("Search by name")}
            />
            <div class="absolute right-0 top-0 mt-4 mr-4">
              <svg class="h-4 w-4 fill-current" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20">
                <path d="M12.9 14.32a8 8 0 1 1 1.41-1.41l5.35 5.33-1.42 1.42-5.33-5.34zM8 14A6 6 0 1 0 8 2a6 6 0 0 0 0 12z">
                </path>
              </svg>
            </div>
          </div>
        </.form>
      </div>

      <Components.group_path
        :if={!@group.is_root}
        group={@group}
        current_profile={@current_profile}
        class="shadow-md"
      />
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
            <% true -> %>
              {gettext("No sub-groups yet.")}
          <% end %>
        </p>

        <%= if @sub_groups_view == "tree" do %>
          <div
            :if={@tree && @tree.nodes != []}
            id="group-children-tree"
            class="mt-2 rounded-3xl border border-base-300/70 bg-base-100/70 p-2 shadow-sm"
          >
            <.tree_node
              :for={node <- @tree.nodes}
              :key={node.group.id}
              node={node}
              search_query={@children_search_query}
            />
          </div>
          <p
            :if={@tree && @tree.truncated?}
            id="group-children-tree-truncated"
            class="mt-3 flex items-center gap-2 px-1 text-xs text-base-content/60"
          >
            <.icon name="hero-information-circle" class="size-4 shrink-0" />
            {gettext("Only part of the tree is shown. Open a sub-group to see what is below it.")}
          </p>
        <% else %>
          <ul id="group-children-list" class="space-y-4" phx-update="stream">
            <li :for={{dom_id, group} <- @children} id={dom_id}>
              <Components.group_identity
                group={group}
                current_profile={@current_profile}
                avatar_size="size-10"
                text_class="text-sm"
                highlight_query={@children_search_query}
                pending_join_requests_count={Map.get(@pending_join_request_counts, group.id, 0)}
                unread_count={Map.get(@unread_counts, group.id, 0)}
              />
            </li>
          </ul>

          <div :if={@pagination.has_more?} class="mt-4 flex justify-center">
            <button
              id="group-children-load-more"
              type="button"
              phx-click="load_more_children"
              class="btn btn-ghost btn-sm rounded-full border border-base-300 bg-base-100/80 px-4"
            >
              {gettext("Load more sub-groups")}
            </button>
          </div>
        <% end %>
      </div>

      <button
        :if={@can_create_subgroups}
        id="group-sub-groups-create-fab"
        type="button"
        phx-click="switch_tab"
        phx-value-tab="create_group"
        aria-label={gettext("Create sub-group")}
        class="absolute bottom-[1.5rem] right-0 ml-auto mr-6 inline-flex size-14 items-center justify-center rounded-full bg-primary text-primary-content shadow-lg shadow-primary/30 transition-transform duration-200 hover:scale-105 hover:shadow-xl focus:outline-none focus:ring-2 focus:ring-primary/40"
      >
        <.icon name="hero-plus" class="size-6" />
      </button>
    </div>
    """
  end

  attr :node, :map,
    required: true,
    doc: "a `Social.sub_group_tree/3` node with its `unread_count`"

  attr :search_query, :string, default: ""

  # The chevron opens and closes a folder; the name opens the group. `open`
  # is left to the browser after mount, so refreshes keep folders as they
  # were. Searching renders the folders under other ids, so they mount again
  # opened on the way to the matches, and again closed once the search ends.
  defp tree_node(assigns) do
    assigns =
      assign(
        assigns,
        :dom_id,
        if(String.trim(assigns.search_query) == "",
          do: "sub-group-folder-#{assigns.node.group.id}",
          else: "sub-group-search-folder-#{assigns.node.group.id}"
        )
      )

    ~H"""
    <%= if @node.children == [] do %>
      <div
        id={@dom_id}
        class="flex items-center rounded-xl pr-2 transition-colors hover:bg-base-200"
      >
        <span class="size-8 shrink-0" aria-hidden="true"></span>
        <.tree_node_link node={@node} search_query={@search_query} />
      </div>
    <% else %>
      <details id={@dom_id} open={@node.open?} phx-mounted={JS.ignore_attributes(["open"])}>
        <summary class="flex cursor-pointer list-none items-center rounded-xl pr-2 transition-colors hover:bg-base-200 [&::-webkit-details-marker]:hidden">
          <span class="inline-flex size-8 shrink-0 items-center justify-center rounded-lg text-base-content/45 transition-colors hover:text-base-content">
            <.icon
              name="hero-chevron-right"
              class="size-3.5 transition-transform duration-150 [details[open]>summary_&]:rotate-90"
            />
          </span>
          <.tree_node_link node={@node} search_query={@search_query} />
        </summary>
        <div class="ml-4 space-y-0.5 border-l border-base-300/70 pl-1">
          <.tree_node
            :for={child <- @node.children}
            :key={child.group.id}
            node={child}
            search_query={@search_query}
          />
        </div>
      </details>
    <% end %>
    """
  end

  attr :node, :map, required: true
  attr :search_query, :string, required: true

  defp tree_node_link(assigns) do
    assigns =
      assigns
      |> assign(:group, assigns.node.group)
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
            name="hero-folder"
            class={["size-5 [details[open]>summary_&]:hidden", node_icon_color(@group)]}
          />
          <.icon
            name="hero-folder-open"
            class={["hidden size-5 [details[open]>summary_&]:block", node_icon_color(@group)]}
          />
        <% end %>
        <span class="absolute -bottom-1 -left-1 text-[0.6rem] leading-none" aria-hidden="true">
          {if @group.public?, do: "📢", else: "🔐"}
        </span>
      </span>
      <Components.highlighted_text
        text={@group.name}
        query={@search_query}
        class={[
          "min-w-0 flex-1 truncate text-sm transition-colors group-hover/node:text-base-content",
          if(@group.member?, do: "font-medium text-base-content", else: "text-base-content/60")
        ]}
      />
      <span
        :if={@node.descendant_count > 0}
        class="shrink-0 text-xs tabular-nums text-base-content/50"
      >
        {ngettext("1 sub-group", "%{count} sub-groups", @node.descendant_count)}
      </span>
      <span
        :if={@unread_count > 0}
        id={"sub-group-folder-unread-#{@group.id}"}
        class="inline-flex min-w-5 shrink-0 items-center justify-center rounded-full bg-red-600 px-1.5 py-0.5 text-[11px] font-semibold leading-none text-white shadow-sm"
      >
        {if @unread_count > 999, do: "999+", else: @unread_count}
      </span>
    </.link>
    """
  end

  defp node_icon_color(%{member?: true}), do: "text-amber-500"
  defp node_icon_color(_group), do: "text-base-content/40"
end
