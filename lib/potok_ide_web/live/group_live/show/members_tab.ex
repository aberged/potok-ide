defmodule PotokIdeWeb.GroupLive.Show.MembersTab do
  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.Components

  attr :members, :any, required: true
  attr :pagination, :map, required: true
  attr :current_profile, :map, required: true
  attr :online_profile_ids, :any, required: true
  attr :group, :map, required: true
  attr :join_requests, :list, default: []
  attr :pending_join_requests_count, :integer, default: 0

  def panel(assigns) do
    ~H"""
    <div id="group-panel-members" class="card max-w-dvw lg:max-w-6xl px-2">
      <Components.group_path
        group={@group}
        current_profile={@current_profile}
        class="shadow-md"
      />
      <div class="card-body h-[calc(100dvh-12rem-var(--app-safe-area-bottom)-var(--app-safe-area-top))] overflow-y-auto">
        <h3 :if={!@group.is_direct} class="card-title mb-2">{gettext("Members")}</h3>

        <div class=" flex flex-row">
          <.icon :if={@group.is_direct} name="hero-user" />
          <.icon :if={@group.is_direct} name="hero-user" />
        </div>
        <div
          :if={@group.creator_id == @current_profile.id && !@group.is_direct}
          id="group-join-requests-panel"
          class="mb-5 rounded-3xl border border-base-300/70 bg-base-50/70 p-4 shadow-sm"
        >
          <div class="mb-3 flex items-center justify-between gap-3">
            <div>
              <h4 class="text-sm font-semibold text-base-950">{gettext("Access requests")}</h4>
              <p class="text-xs text-base-900/70">
                {gettext("Profiles waiting for approval to join this public group.")}
              </p>
            </div>

            <span
              id="group-join-requests-count"
              class="inline-flex min-w-8 items-center justify-center rounded-full bg-amber-500 px-2 py-1 text-xs font-semibold text-base-950"
            >
              {@pending_join_requests_count}
            </span>
          </div>

          <div
            :if={@join_requests == []}
            id="group-join-requests-empty"
            class="rounded-2xl border border-dashed border-amber-300/70 bg-base-100/50 px-4 py-3 text-sm text-base-950/70"
          >
            {gettext("No pending access requests.")}
          </div>

          <ul :if={@join_requests != []} id="group-join-requests-list" class="space-y-3">
            <li :for={request <- @join_requests} id={"group-join-request-#{request.id}"}>
              <div class="flex items-start justify-between gap-3 rounded-2xl border border-dashed border-amber-300/70 bg-base-100/50 px-4 py-3">
                <div class="min-w-0 flex-1">
                  <Components.profile_identity
                    profile={request.requester}
                    current_profile={@current_profile}
                    direct_group_link={true}
                  />
                  <div class="mt-2 text-xs text-base-950/65">
                    <Components.local_time
                      id={"group-join-request-inserted-at-#{request.id}"}
                      datetime={request.inserted_at}
                    />
                  </div>
                </div>

                <div class="flex shrink-0 items-center gap-2">
                  <button
                    id={"group-accept-join-request-#{request.id}"}
                    type="button"
                    phx-click="accept_join_request"
                    phx-value-id={request.id}
                    class="btn btn-sm rounded-full border border-emerald-500/40 bg-emerald-500/10 text-emerald-700 hover:border-emerald-500/60 hover:bg-emerald-500/15"
                  >
                    {gettext("Accept")}
                  </button>

                  <button
                    id={"group-reject-join-request-#{request.id}"}
                    type="button"
                    phx-click="reject_join_request"
                    phx-value-id={request.id}
                    class="btn btn-ghost btn-sm rounded-full border border-base-300 bg-base-100/80"
                  >
                    {gettext("Reject")}
                  </button>
                </div>
              </div>
            </li>
          </ul>
        </div>

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
                current_profile={@current_profile}
                direct_group_link={true}
              />

              <button
                :if={
                  @group.creator_id == @current_profile.id && member.id != @group.creator_id &&
                    !@group.is_direct
                }
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
