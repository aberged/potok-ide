defmodule PotokIdeWeb.ProfileLive.Index do
  use PotokIdeWeb, :live_view

  alias PotokIde.Accounts
  alias PotokIde.Social
  alias PotokIdeWeb.ProfileAuth
  alias PotokIdeWeb.ProfileLive.Components, as: ProfileComponents

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-2 px-4 py-4 flex h-[calc(100dvh-4rem)] max-w-3xl mx-auto overflow-y-auto flex-col">
        <div class="flex flex-wrap items-start justify-between gap-3">
          <.header>
            {gettext("Profiles")}
            <:subtitle>
              {gettext(
                "Pick the profile you want to use, or open a dedicated page to create or edit one."
              )}
            </:subtitle>
          </.header>
        </div>

        <div :if={@current_profile} class="alert">
          <ProfileComponents.profile_identity
            profile={@current_profile}
            title={gettext("Current profile:")}
          />
          <.icon name="hero-check-badge" class="size-4 ml-auto" />
        </div>

        <div :if={@default_profile} class="alert">
          <ProfileComponents.profile_identity
            profile={@default_profile}
            title={gettext("Default profile:")}
          />
          <.icon name="hero-globe-alt" class="size-4 ml-auto" />
        </div>

        <div :if={@profile_invitations != []} id="shared-profile-invitations" class="space-y-3">
          <.header>
            {gettext("Shared profile invitations")}
            <:subtitle>{gettext("Pending invitations for your current profile.")}</:subtitle>
          </.header>

          <div :for={invitation <- @profile_invitations} class="card">
            <div class="card-body gap-3">
              <div>
                <h3 class="card-title">{invitation.profile.username}</h3>

                <p class="text-sm text-base-content/70">
                  {gettext("Invited by: ")}<span class="font-semibold">
                    {invitation.inviter.username}
                  </span>
                </p>
              </div>

              <div>
                <.button
                  phx-click="accept_profile_invitation"
                  phx-value-id={invitation.id}
                  id={"accept-profile-invitation-#{invitation.id}"}
                  variant="primary"
                >
                  {gettext("Accept shared profile")}
                </.button>
              </div>
            </div>
          </div>
        </div>

        <h3 class="card-title mb-4">{gettext("Your profiles")}</h3>

        <div :if={@profiles == []} class="text-base-content/70">
          {gettext("No profiles yet.")}
        </div>

        <ul :if={@profiles != []} class="space-y-2">
          <li :for={profile <- @profiles} class="flex items-center justify-between gap-3">
            <ProfileComponents.profile_identity
              profile={profile}
              subtitle={Atom.to_string(profile.sharing)}
            />
            <div class="flex shrink-0 items-center gap-2">
              <.button
                disabled={!(is_nil(@current_profile) or @current_profile.id != profile.id)}
                phx-click="use"
                phx-value-id={profile.id}
              >
                <.icon name="hero-check-badge" class="size-4"></.icon>
              </.button>
              <.button
                disabled={!(is_nil(@default_profile) or @default_profile.id != profile.id)}
                phx-click="set_default"
                phx-value-id={profile.id}
                id={"set-default-profile-#{profile.id}"}
              >
                <.icon name="hero-globe-alt" class="size-4"></.icon>
              </.button>
              <.button navigate={~p"/profiles/#{profile.id}/edit"}><.icon name="hero-pencil" class="size-4"></.icon></.button>
            </div>
          </li>
        </ul>

        <div class="mt-4 flex flex-row justify-between">
          <.button navigate={~p"/groups"} >
            <.icon name="hero-globe-alt" class="size-4" />
          </.button>
          <.button navigate={~p"/profiles/new"} >
            <.icon name="hero-plus" class="size-4" />
            {gettext("Create profile")}
          </.button>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    account = socket.assigns.current_scope.account

    socket =
      socket
      |> put_private(:previous_current_profile, socket.assigns.current_profile)
      |> ProfileAuth.sync_profile_subscription()

    {:ok,
     socket
     |> assign(:profiles, Social.list_profiles_for_account(account))
     |> assign(:default_profile, Social.get_account_default_profile(account))
     |> assign(:profile_invitations, pending_profile_invitations(socket.assigns.current_profile))}
  end

  @impl true
  def handle_event("use", %{"id" => id}, socket) do
    account = socket.assigns.current_scope.account

    case Social.get_profile_for_account(account, String.to_integer(id)) do
      nil ->
        {:noreply,
         put_flash(socket, :error, gettext("That profile is not available for this account."))}

      profile ->
        {:ok, account} = Accounts.set_current_profile(account, profile)
        previous_profile = socket.private[:previous_current_profile]

        {:noreply,
         socket
         |> assign(:current_scope, %{socket.assigns.current_scope | account: account})
         |> assign(:current_profile, profile)
         |> assign(:profiles, Social.list_profiles_for_account(account))
         |> assign(:default_profile, Social.get_account_default_profile(account))
         |> assign(:profile_invitations, pending_profile_invitations(profile))
         |> put_private(:previous_current_profile, profile)
         |> ProfileAuth.sync_profile_subscription(previous_profile)
         |> push_current_profile_updated(profile)
         |> put_flash(:info, gettext("Profile selected."))}
    end
  end

  def handle_event("set_default", %{"id" => id}, socket) do
    account = socket.assigns.current_scope.account

    case Social.get_profile_for_account(account, String.to_integer(id)) do
      nil ->
        {:noreply,
         put_flash(socket, :error, gettext("That profile is not available for this account."))}

      profile ->
        {:ok, account} = Accounts.set_default_profile(account, profile)
        previous_profile = socket.private[:previous_current_profile]
        current_profile = Social.get_account_current_profile(account)

        {:noreply,
         socket
         |> assign(:current_scope, %{socket.assigns.current_scope | account: account})
         |> assign(:current_profile, current_profile)
         |> assign(:profiles, Social.list_profiles_for_account(account))
         |> assign(:default_profile, Social.get_account_default_profile(account))
         |> assign(:profile_invitations, pending_profile_invitations(current_profile))
         |> put_private(:previous_current_profile, current_profile)
         |> ProfileAuth.sync_profile_subscription(previous_profile)
         |> push_current_profile_updated(current_profile)
         |> put_flash(:info, gettext("Default profile updated."))}
    end
  end

  def handle_event("accept_profile_invitation", %{"id" => id}, socket) do
    account = socket.assigns.current_scope.account
    invitee = socket.assigns.current_profile
    invitation_id = String.to_integer(id)

    with %{} <- invitee,
         %{} = invitation <-
           Social.get_pending_profile_invitation_for_invitee(invitee, invitation_id),
         {:ok, _accepted_invitation} <-
           Social.accept_profile_invitation(invitation, invitee, account) do
      refreshed_account = Accounts.get_account!(account.id)

      {:noreply,
       socket
       |> assign(:current_scope, %{socket.assigns.current_scope | account: refreshed_account})
       |> assign(:current_profile, Social.get_account_current_profile(refreshed_account))
       |> assign(:profiles, Social.list_profiles_for_account(refreshed_account))
       |> assign(:default_profile, Social.get_account_default_profile(refreshed_account))
       |> assign(
         :profile_invitations,
         pending_profile_invitations(Social.get_account_current_profile(refreshed_account))
       )
       |> put_flash(:info, gettext("Shared profile invitation accepted."))}
    else
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Shared profile invitation not found."))}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, gettext("Could not accept shared profile invitation."))}
    end
  end

  @impl true
  def handle_info({:account_profiles_updated, account_id}, socket)
      when socket.assigns.current_scope.account.id == account_id do
    previous_profile = socket.private[:previous_current_profile]
    account = Accounts.get_account!(account_id)
    current_profile = Social.get_account_current_profile(account)

    {:noreply,
     socket
     |> assign(:current_scope, %{socket.assigns.current_scope | account: account})
     |> assign(:profiles, Social.list_profiles_for_account(account))
     |> assign(:default_profile, Social.get_account_default_profile(account))
     |> assign(:current_profile, current_profile)
     |> assign(:profile_invitations, pending_profile_invitations(current_profile))
     |> put_private(:previous_current_profile, current_profile)
     |> ProfileAuth.sync_profile_subscription(previous_profile)}
  end

  def handle_info({:account_profiles_updated, _account_id}, socket), do: {:noreply, socket}

  def handle_info({:profile_invitations_updated, _profile_id}, socket), do: {:noreply, socket}

  def handle_info({:profile_share_invitations_updated, profile_id}, socket)
      when not is_nil(socket.assigns.current_profile) and
             socket.assigns.current_profile.id == profile_id do
    {:noreply,
     assign(
       socket,
       :profile_invitations,
       pending_profile_invitations(socket.assigns.current_profile)
     )}
  end

  def handle_info({:profile_share_invitations_updated, _profile_id}, socket),
    do: {:noreply, socket}

  def handle_info({:pending_invitations_count_updated, _profile_id, _count}, socket),
    do: {:noreply, socket}

  defp profile_picture_url(%{profile_picture_url: url}) when is_binary(url) do
    case String.trim(url) do
      "" -> nil
      trimmed_url -> trimmed_url
    end
  end

  defp profile_picture_url(_), do: nil

  defp pending_profile_invitations(nil), do: []
  defp pending_profile_invitations(profile), do: Social.list_pending_profile_invitations(profile)

  defp push_current_profile_updated(socket, profile) do
    push_event(socket, "current_profile_updated", %{
      username: profile.username,
      profile_picture_url: profile_picture_url(profile)
    })
  end
end
