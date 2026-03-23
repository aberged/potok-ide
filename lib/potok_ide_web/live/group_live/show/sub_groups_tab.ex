defmodule PotokIdeWeb.GroupLive.Show.SubGroupsTab do
  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.Components

  attr :children, :list, required: true

  def panel(assigns) do
    ~H"""
    <div id="group-panel-sub-groups" class="card bg-base-200 pt-4">
      <div class="card-body">

        <div :if={@children == []} class="text-base-content/70">
          {gettext("No sub-groups yet.")}
        </div>

        <ul :if={@children != []} class="space-y-4">
          <li :for={group <- @children}>
            <Components.group_identity
              group={group}
              avatar_size="size-10"
              text_class="text-sm"
            />
          </li>
        </ul>
      </div>
    </div>
    """
  end
end
