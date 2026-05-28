defmodule PotokIdeWeb.GroupLive.Show.InviteProfileTab do
  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.Components

  attr :invite_form, :any, required: true
  attr :invite_form_version, :integer, required: true
  attr :invite_profile_suggestions, :list, default: []
  attr :group, :map, required: true
  attr :current_profile, :map, default: nil

  def panel(assigns) do
    ~H"""
    <div id="group-panel-invite-profile" class="card max-w-dvw lg:max-w-6xl px-2">
      <Components.group_path
        group={@group}
        current_profile={@current_profile}
        class="shadow-md"
      />
      <div class="card-body h-[calc(100dvh-12rem-var(--app-safe-area-bottom)-var(--app-safe-area-top))] max-w-lg overflow-y-auto">
        <h3 class="card-title">{gettext("Invite to group")}</h3>
        <.form
          for={@invite_form}
          id={"group-invite-form-#{@invite_form_version}"}
          phx-change="suggest_invite_profiles"
          phx-submit="invite"
          autocomplete="off"
        >
          <div class="relative">
            <.input
              field={@invite_form[:identifier]}
              id={"group-invite-identifier-#{@invite_form_version}"}
              label={gettext("Invitee username or email")}
              autocomplete="off"
              phx-debounce="200"
              required
            />

            <div
              :if={@invite_profile_suggestions != []}
              id="group-invite-suggestions"
              phx-click-away="clear_invite_profile_suggestions"
              class="absolute inset-x-0 top-full z-20 -mt-2 overflow-hidden rounded-2xl border border-base-300/70 bg-base-100 shadow-xl"
            >
              <button
                :for={profile <- @invite_profile_suggestions}
                id={"group-invite-suggestion-#{profile.id}"}
                type="button"
                phx-click="select_invite_profile"
                phx-value-username={profile.username}
                class="flex w-full items-center gap-3 border-b border-base-200/80 px-3 py-2 text-left transition-colors last:border-b-0 hover:bg-base-200/70 focus-visible:bg-base-200/70 focus-visible:outline-none"
              >
                <img
                  src={profile_avatar_url(profile)}
                  alt={profile.username}
                  class="size-10 shrink-0 rounded-full border border-base-300 bg-base-100 object-cover shadow-sm"
                />
                <span class="min-w-0 truncate text-sm font-semibold text-base-content">
                  {profile.username}
                </span>
              </button>
            </div>
          </div>

          <.button phx-disable-with={gettext("Inviting...")} variant="primary">
            {gettext("Invite")}
          </.button>
        </.form>

        <div class="mt-2 text-xs text-base-content/60">
          {gettext(
            "Enter a username to invite an existing profile, or an email to invite an account."
          )}
        </div>

        <div class="mt-2 text-xs text-base-content/60">
          {gettext("Invitees accept invitations at")} <.link navigate={~p"/invitations"} class="link">/invitations</.link>.
        </div>
      </div>
    </div>
    """
  end

  defp profile_avatar_url(%{profile_picture_url: url}) when is_binary(url) and url != "", do: url
  defp profile_avatar_url(%{id: id}), do: "/avatar/profile/#{id}"
end
