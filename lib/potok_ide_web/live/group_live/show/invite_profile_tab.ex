defmodule PotokIdeWeb.GroupLive.Show.InviteProfileTab do
  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.Components

  attr :invite_form, :any, required: true
  attr :invite_form_version, :integer, required: true
  attr :group, :map, required: true
  attr :current_profile, :map, default: nil

  def panel(assigns) do
    ~H"""
    <div id="group-panel-invite-profile" class="card max-w-dvw md:max-w-6xl px-2">
      <Components.group_path
        group={@group}
        current_profile={@current_profile}
        class="shadow-md"
      />
      <div class="card-body h-[calc(100dvh-12rem)] max-w-[32rem] overflow-y-auto">
        <h3 class="card-title">{gettext("Invite profile")} u 👆 grupu</h3>
        <.form for={@invite_form} id={"group-invite-form-#{@invite_form_version}"} phx-submit="invite">
          <.input
            field={@invite_form[:username]}
            id={"group-invite-username-#{@invite_form_version}"}
            label={gettext("Invitee username")}
            required
          />
          <.button phx-disable-with={gettext("Inviting...")} variant="primary">
            {gettext("Invite")}
          </.button>
        </.form>

        <div class="mt-2 text-xs text-base-content/60">
          {gettext("Invitees accept invitations at")} <.link navigate={~p"/invitations"} class="link">/invitations</.link>.
        </div>
      </div>
    </div>
    """
  end
end
