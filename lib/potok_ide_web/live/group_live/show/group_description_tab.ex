defmodule PotokIdeWeb.GroupLive.Show.GroupDescriptionTab do
  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.Components

  attr :group, :map, required: true
  attr :current_profile, :map, default: nil
  attr :is_member, :boolean, default: false
  attr :pending_join_request, :map, default: nil

  def panel(assigns) do
    ~H"""
    <div class="h-[calc(100dvh-8rem)] pb-[calc(env(safe-area-inset-bottom,0px)+env(safe-area-inset-top,0px)+4rem)] max-w-dvw lg:max-w-6xl px-2">
      <Components.group_path
        group={@group}
        current_profile={@current_profile}
        class="shadow-md sticky"
      />
      <div class="h-[calc(100dvh-12rem)] pb-[calc(env(safe-area-inset-bottom,0px)+env(safe-area-inset-top,0px)+4rem)] max-w-dvw lg:max-w-6xl overflow-y-auto">
        <div
          :if={blank_description?(@group.description)}
          id="group-description-empty"
          class="flex min-h-48 items-center justify-center rounded-3xl border border-dashed border-base-300 bg-base-100/70 px-6 text-center text-sm text-base-content/60"
        >
          {gettext("This group has no description yet.")}
        </div>

        <div
          :if={!blank_description?(@group.description)}
          class=""
          id="group-panel-description"
          phx-hook="GroupDescriptionActions"
          data-group-id={@group.id}
          data-current-profile-id={@current_profile && @current_profile.id}
          data-current-profile={current_profile_payload(@current_profile)}
          data-description={@group.description || ""}
          data-description-format={@group.description_format}
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

  defp current_profile_payload(nil), do: ""

  defp current_profile_payload(current_profile) do
    Jason.encode!(%{
      id: current_profile.id,
      username: current_profile.username,
      profile_picture_url: current_profile.profile_picture_url,
      description: current_profile.description,
      description_format: current_profile.description_format,
      sharing: current_profile.sharing,
      inserted_at: current_profile.inserted_at,
      updated_at: current_profile.updated_at
    })
  end
end
