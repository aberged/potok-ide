defmodule PotokIdeWeb.GroupLive.Show.MembersTab do
  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.Components

  attr :members, :any, required: true
  attr :pagination, :map, required: true
  attr :current_profile, :map, required: true
  attr :online_profile_ids, :any, required: true
  attr :group, :map, required: true

  def panel(assigns) do
    ~H"""
    <div id="group-panel-members" class="card max-w-dvw md:max-w-6xl px-2">
      <Components.group_path
        group={@group}
        current_profile={@current_profile}
        class="shadow-md"
      />
      <div class="card-body h-[calc(100dvh-12rem)] overflow-y-auto">
        <h3 class="card-title mb-2">{gettext("Members")}</h3>

        <ul id="group-members-list" class="space-y-2" phx-update="stream">
          <li
            :if={@pagination.loaded_count == 0}
            id="group-members-empty"
            class="text-base-content/70"
          >
            {gettext("No members.")}
          </li>

          <li :for={{dom_id, member} <- @members} id={dom_id}>
            <div class="flex items-start justify-between gap-3 rounded-2xl border border-base-300/60 bg-base-100/70 px-4 py-3 shadow-sm">
              <Components.profile_identity
                profile={member}
                me={member.id == @current_profile.id}
                online?={MapSet.member?(@online_profile_ids, member.id)}
                presence_badge_id={"group-member-presence-#{member.id}"}
              />

              <button
                :if={@group.creator_id == @current_profile.id and member.id != @group.creator_id}
                id={"group-remove-member-#{member.id}"}
                type="button"
                phx-click="remove_member"
                phx-value-id={member.id}
                data-confirm={
                  gettext("Remove %{username} from this group?", username: member.username)
                }
                aria-label={gettext("Remove %{username}", username: member.username)}
                class="btn btn-ghost btn-xs rounded-full border border-error/30 bg-error/5 text-error transition-colors hover:border-error/50 hover:bg-error/10"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>
          </li>
        </ul>

        <div :if={@pagination.has_more?} class="mt-4 flex justify-center">
          <button
            id="group-members-load-more"
            type="button"
            phx-click="load_more_members"
            class="btn btn-ghost btn-sm rounded-full border border-base-300 bg-base-100/80 px-4"
          >
            {gettext("Load more members")}
          </button>
        </div>
      </div>
    </div>
    """
  end
end
