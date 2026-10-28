defmodule PotokIdeWeb.GroupLive.Show.GroupDescriptionTab do
  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.Components

  attr :group, :map, required: true
  attr :current_profile, :map, default: nil
  attr :is_member, :boolean, default: false
  attr :pending_join_request, :map, default: nil

  def panel(assigns) do
    assigns =
      assign(assigns, :empty_description_image_src, empty_description_image_src(assigns.group))

    ~H"""
    <div class="flex min-h-0 flex-1 flex-col px-2">
      <Components.group_path
        group={@group}
        current_profile={@current_profile}
        class="shadow-md sticky"
      />
      <div class="flex min-h-0 flex-1 overflow-y-auto overscroll-contain flex-col pb-4">
        <div
          :if={blank_description?(@group.description)}
          id="group-description-empty"
          class="flex flex-col min-h-48 items-center justify-center rounded-3xl border border-dashed border-base-300 bg-base-100/70 px-6 text-center text-sm text-base-content/60"
        >
          <p class="p-2">{gettext("This group has no description yet.")}</p>

          <div class="text-center opacity-85 overflow-hidden rounded-4xl">
            <img
              class="pointer-events-none inline-block align-bottom"
              src={@empty_description_image_src}
              alt={gettext("Group description illustration")}
              width="400"
              height="400"
              loading="lazy"
            />
          </div>
        </div>

        <div
          :if={!blank_description?(@group.description) and @group.uses_api}
          id="group-panel-description"
          class="flex min-h-0 flex-1 flex-col"
        >
          <Components.app_frame
            id="group-app-frame"
            html={@group.description}
            storage_key={"potok-app:#{@group.id}"}
            viewer_key={"#{@current_profile && @current_profile.id}:#{@is_member}"}
          />
        </div>

        <div
          :if={!blank_description?(@group.description) and !@group.uses_api}
          id="group-panel-description"
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

  # Picked per group instead of at random, so re-renders never swap the image.
  defp empty_description_image_src(group) do
    case rem(group.id || 0, 4) do
      0 -> ~p"/images/social-media.gif"
      1 -> ~p"/images/mark-rotating.svg"
      2 -> ~p"/images/pencil.gif"
      _ -> ~p"/images/idea.gif"
    end
  end
end
