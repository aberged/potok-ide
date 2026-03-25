defmodule PotokIdeWeb.GroupLive.Show.MembersTab do
  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.Components

  attr :members, :list, required: true

  def panel(assigns) do
    ~H"""
    <div id="group-panel-members" class="card">
      <div class="card-body h-[calc(100dvh-8rem)] overflow-y-auto">
        <h3 class="card-title mb-2">{gettext("Members")}</h3>

        <div :if={@members == []} class="text-base-content/70">{gettext("No members.")}</div>

        <ul :if={@members != []} class="space-y-2">
          <li :for={member <- @members}><Components.profile_identity profile={member} /></li>
        </ul>
      </div>
    </div>
    """
  end
end
