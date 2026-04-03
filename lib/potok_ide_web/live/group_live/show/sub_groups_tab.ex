defmodule PotokIdeWeb.GroupLive.Show.SubGroupsTab do
  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.Components

  attr :group, :map, required: true
  attr :current_profile, :map, default: nil
  attr :children, :any, required: true
  attr :pagination, :map, required: true
  attr :unread_counts, :map, required: true

  def panel(assigns) do
    ~H"""
    <div id="group-panel-sub-groups" class="card">
      <Components.group_path
        :if={!@group.is_root}
        group={@group}
        current_profile={@current_profile}
        class="shadow-md"
      />

      <div class="card-body h-[calc(100dvh-8rem)] overflow-y-auto">
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
              avatar_size="size-10"
              text_class="text-sm"
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
    </div>
    """
  end
end
