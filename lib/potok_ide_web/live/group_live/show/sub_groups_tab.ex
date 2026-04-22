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

  def panel(assigns) do
    ~H"""
    <div
      id="group-panel-sub-groups"
      class="card relative h-[calc(100dvh-8rem-var(--app-safe-area-bottom)-var(--app-safe-area-top))] max-w-dvw px-2 lg:max-w-6xl"
    >
      <Components.group_path
        :if={!@group.is_root}
        group={@group}
        current_profile={@current_profile}
        class="shadow-md"
      />

      <div
        :if={@group.is_root}
        id="group-sub-groups-kind-tabs"
        class="absolute right-0 top-0 flex items-center gap-2 p-1 border rounded-full bg-base-100 border-base-300"
      >
        <button
          id="group-sub-groups-kind-direct"
          type="button"
          phx-click="switch_sub_groups_kind"
          phx-value-kind="direct"
          class={[
            "btn btn-sm rounded-full",
            if(@sub_groups_kind == "direct",
              do: "btn-primary text-white",
              else: "btn-ghost border border-base-300"
            )
          ]}
        >
          <.icon name="hero-users" class="size-4 mr-1" />
          <span
            :if={@direct_sub_groups_unread_count > 0}
            id="group-sub-groups-kind-direct-unread-badge"
            class="absolute top-[0.1rem] left-8 ml-1 inline-flex min-w-5 items-center justify-center rounded-full bg-red-600 px-1.5 py-0.5 text-[11px] font-semibold leading-none text-white shadow-sm"
          >
            {unread_badge_label(@direct_sub_groups_unread_count)}
          </span>
        </button>

        <button
          id="group-sub-groups-kind-other"
          type="button"
          phx-click="switch_sub_groups_kind"
          phx-value-kind="other"
          class={[
            "btn btn-sm rounded-full",
            if(@sub_groups_kind == "other",
              do: "btn-primary text-white",
              else: "btn-ghost border border-base-300"
            )
          ]}
        >
          <.icon name="hero-user-group" class="size-4 mr-1" />
          <span
            :if={@other_sub_groups_unread_count > 0}
            id="group-sub-groups-kind-other-unread-badge"
            class="absolute top-[0.1rem] right-2 ml-1 inline-flex min-w-5 items-center justify-center rounded-full bg-red-600 px-1.5 py-0.5 text-[11px] font-semibold leading-none text-white shadow-sm"
          >
            {unread_badge_label(@other_sub_groups_unread_count)}
          </span>
        </button>
      </div>

      <div class="min-h-0 flex-1 overflow-y-auto p-2 pb-4">
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
        class="absolute bottom-[1.5rem] right-0 ml-auto mr-6 inline-flex size-14 items-center justify-center rounded-full bg-primary text-primary-content shadow-lg shadow-primary/30 transition-transform duration-200 hover:scale-105 hover:shadow-xl focus:outline-none focus:ring-2 focus:ring-primary/40"
      >
        <.icon name="hero-plus" class="size-6" />
      </button>
    </div>
    """
  end

  defp unread_badge_label(count) when count > 999, do: "999+"
  defp unread_badge_label(count), do: Integer.to_string(count)
end
