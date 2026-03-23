defmodule PotokIdeWeb.GroupLive.Show.MembersTab do
  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.Components

  attr :members, :list, required: true

  def panel(assigns) do
    ~H"""
    <div id="group-panel-members" class="card bg-base-200 pt-4">
      <div class="card-body">
        <h3 class="card-title">{gettext("Members")}</h3>

        <div :if={@members == []} class="text-base-content/70">{gettext("No members.")}</div>

        <ul :if={@members != []} class="space-y-2">
          <li :for={member <- @members}>
            <Components.profile_identity profile={member} />
          </li>
        </ul>
      </div>
    </div>
    """
  end
end
