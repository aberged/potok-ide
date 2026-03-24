defmodule PotokIdeWeb.GroupLive.Show.InviteProfileTab do
  use PotokIdeWeb, :html

  attr :invite_form, :any, required: true

  def panel(assigns) do
    ~H"""
    <div id="group-panel-invite-profile" class="card bg-base-200 pt-4">
      <div class="card-body">
        <h3 class="card-title">{gettext("Invite profile")}</h3>
        
        <.form for={@invite_form} phx-submit="invite">
          <.input field={@invite_form[:username]} label={gettext("Invitee username")} required />
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
