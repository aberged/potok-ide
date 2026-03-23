defmodule PotokIdeWeb.GroupLive.Show.SubGroupsTab do
  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.Components

  attr :children, :list, required: true

  def panel(assigns) do
    ~H"""
    <div id="group-panel-sub-groups" class="card bg-base-200">
      <div class="card-body">
        <h3 class="card-title">{gettext("Sub-groups")}</h3>

        <div :if={@children == []} class="text-base-content/70">
          {gettext("No sub-groups yet.")}
        </div>

        <ul :if={@children != []} class="space-y-2">
          <li :for={group <- @children}>
            <.link
              navigate={~p"/groups/#{group.id}"}
              class="block rounded-2xl px-2 py-2 transition-colors hover:bg-base-300/50"
            >
              <div class="flex items-center justify-between gap-3">
                <Components.group_identity
                  group={group}
                  avatar_size="size-10"
                  text_class="text-sm"
                />
                <span class="text-xs text-base-content/60">
                  ({if group.is_public, do: gettext("public"), else: gettext("private")})
                </span>
              </div>
            </.link>
          </li>
        </ul>
      </div>
    </div>
    """
  end
end
