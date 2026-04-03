defmodule PotokIdeWeb.GroupLive.Show.GroupDescriptionTab do
  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.Components

  attr :group, :map, required: true
  attr :current_profile, :map, default: nil

  def panel(assigns) do
    ~H"""
    <div id="group-panel-description">
      <Components.group_path
        group={@group}
        current_profile={@current_profile}
        class="shadow-md"
      />
      <div class="h-[calc(100dvh-12rem)] overflow-y-auto">
        <div
          :if={blank_description?(@group.description)}
          id="group-description-empty"
          class="flex min-h-48 items-center justify-center rounded-3xl border border-dashed border-base-300 bg-base-100/70 px-6 text-center text-sm text-base-content/60"
        >
          {gettext("This group has no description yet.")}
        </div>

        <div
          :if={!blank_description?(@group.description)}
          id="group-description-content"
          class="p-4"
        >
          <Components.formatted_content
            content={@group.description}
            content_format={@group.description_format}
          />
        </div>
      </div>
    </div>
    """
  end

  defp blank_description?(description), do: is_nil(description) or String.trim(description) == ""
end
