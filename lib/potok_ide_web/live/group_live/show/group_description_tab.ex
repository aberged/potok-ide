defmodule PotokIdeWeb.GroupLive.Show.GroupDescriptionTab do
  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.Components

  attr :group, :map, required: true
  attr :current_profile, :map, default: nil
  attr :is_member, :boolean, default: false
  attr :pending_join_request, :map, default: nil

  def panel(assigns) do
    assigns = assign(assigns, :empty_description_image_src, empty_description_image_src())

    ~H"""
    <div class="h-[calc(100dvh-8rem)] max-w-dvw px-2 pb-[calc(var(--app-safe-area-bottom)+var(--app-safe-area-top)+4rem)] lg:max-w-6xl">
      <Components.group_path
        group={@group}
        current_profile={@current_profile}
        class="shadow-md sticky"
      />
      <div class="h-[calc(100dvh-12rem)] max-w-dvw overflow-y-auto pb-[calc(var(--app-safe-area-bottom)+var(--app-safe-area-top)+4rem)] lg:max-w-6xl">
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

  defp empty_description_image_src do
    random_number = :rand.uniform()

    cond do
      random_number < 1 / 3 ->
        ~p"/images/social-media.gif"

      random_number < 2 / 3 ->
        "https://img.daisyui.com/images/daisyui/mark-rotating.svg"

      true ->
        ~p"/images/idea.gif"
    end
  end

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
