defmodule PotokIdeWeb.GroupLive.Show.MembersTab do
  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.Components

  attr :members, :any, required: true
  attr :pagination, :map, required: true
  attr :current_profile, :map, required: true

  def panel(assigns) do
    ~H"""
    <div id="group-panel-members" class="card">
      <div class="card-body h-[calc(100dvh-8rem)] overflow-y-auto">
        <h3 class="card-title mb-2">{gettext("Members")}</h3>

        <ul id="group-members-list" class="space-y-2" phx-update="stream">
          <li :if={@pagination.loaded_count == 0} id="group-members-empty" class="text-base-content/70">
            {gettext("No members.")}
          </li>
          <li :for={{dom_id, member} <- @members} id={dom_id}>
            <Components.profile_identity profile={member} me={member.id == @current_profile.id} />
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
