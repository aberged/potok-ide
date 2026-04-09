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

  def panel(assigns) do
    ~H"""
    <div id="group-panel-sub-groups" class="card relative h-[calc(100dvh-8rem)] pb-[calc(env(safe-area-inset-bottom,0px)+env(safe-area-inset-top,0px))] max-w-dvw md:max-w-6xl px-2 ">
      <Components.group_path
        :if={!@group.is_root}
        group={@group}
        current_profile={@current_profile}
        class="shadow-md"
      />

      <div class="card-body h-[calc(100dvh-12rem)] pb-[calc(env(safe-area-inset-bottom,0px)+env(safe-area-inset-top,0px))] overflow-y-auto">
        <ul id="group-children-list" class="space-y-4" phx-update="stream">
          <li
            :if={@pagination.loaded_count == 0}
            id="group-children-empty"
            class="text-base-content/70"
          >
            {gettext("No sub-groups yet.")}
          </li>

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
        class="sticky bottom-6 ml-auto mr-6 inline-flex size-14 items-center justify-center rounded-full bg-primary text-primary-content shadow-lg shadow-primary/30 transition-transform duration-200 hover:scale-105 hover:shadow-xl focus:outline-none focus:ring-2 focus:ring-primary/40"
      >
        <.icon name="hero-plus" class="size-6" />
      </button>
    </div>
    """
  end
end
