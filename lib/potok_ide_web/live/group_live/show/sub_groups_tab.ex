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
  attr :sub_groups_kind, :string, required: true
  attr :direct_sub_groups_unread_count, :integer, required: true
  attr :other_sub_groups_unread_count, :integer, required: true
  attr :children_search_query, :string, default: ""

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
      class="card relative h-[calc(100dvh-8rem-var(--app-safe-area-bottom)-var(--app-safe-area-top))] max-w-dvw px-2 lg:max-w-6xl"
    >
      <.form
        for={@children_search_form}
        id="group-children-search-form"
        phx-change="search_children"
        class="mb-3 absolute right-4 -top-[.06rem] z-45"
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
            placeholder={gettext("Search by name")}
            phx-debounce="300"
            autocomplete="off"
            class="bg-base-100/85 h-10 px-6 pr-10 rounded-full text-sm focus:outline-none border border-gray-500/50 transition-all duration-300 ease-in-out w-12 focus:w-64"
            placeholder="Search..."
          />
          <div class="absolute right-0 top-0 mt-4 mr-4">
            <svg class="h-4 w-4 fill-current" xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20">
                <path d="M12.9 14.32a8 8 0 1 1 1.41-1.41l5.35 5.33-1.42 1.42-5.33-5.34zM8 14A6 6 0 1 0 8 2a6 6 0 0 0 0 12z">
                </path>
            </svg>
          </div>
        </div>
      </.form>

      <Components.group_path
        :if={!@group.is_root}
        group={@group}
        current_profile={@current_profile}
        class="shadow-md"
      />

      <div class="min-h-0 flex-1 overflow-y-auto p-2 pb-4">

        <p
          :if={@pagination.loaded_count == 0}
          id="group-children-empty"
          class="text-base-content/70"
        >
          {if String.trim(@children_search_query) == "",
            do: gettext("No sub-groups yet."),
            else: gettext("No sub-groups match your search.")}
        </p>

        <ul id="group-children-list" class="space-y-4" phx-update="stream">
          <li :for={{dom_id, group} <- @children} id={dom_id}>
            <Components.group_identity
              group={group}
              current_profile={@current_profile}
              avatar_size="size-10"
              text_class="text-sm"
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
      </div>

      <button
        :if={@is_member}
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
end
