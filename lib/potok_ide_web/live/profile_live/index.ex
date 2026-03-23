defmodule PotokIdeWeb.ProfileLive.Index do
  use PotokIdeWeb, :live_view

  alias PotokIde.Accounts
  alias PotokIde.Social
  alias PotokIde.Social.Profile
  alias PotokIdeWeb.ProfileAuth

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6 px-4 pt-4 flex h-[calc(100dvh-4rem)] overflow-y-auto flex-col">
        <.header>
          {gettext("Profiles")}
          <:subtitle>{gettext("Pick the profile you want to use, or create a new one.")}</:subtitle>
        </.header>

        <div :if={@current_profile} class="alert">
          <.profile_identity profile={@current_profile} title={gettext("Current profile:")} />
        </div>

        <div :if={@profile_invitations != []} id="shared-profile-invitations" class="space-y-3">
          <.header>
            {gettext("Shared profile invitations")}
            <:subtitle>
              {gettext("Pending invitations for your current profile.")}
            </:subtitle>
          </.header>

          <div :for={invitation <- @profile_invitations} class="card bg-base-200">
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

        <div class="card bg-base-200">
          <div class="card-body">
            <h3 class="card-title">{gettext("Your profiles")}</h3>

            <div :if={@profiles == []} class="text-base-content/70">
              {gettext("No profiles yet.")}
            </div>

            <ul :if={@profiles != []} class="space-y-2">
              <li :for={profile <- @profiles} class="flex items-center justify-between gap-3">
                <.profile_identity profile={profile} subtitle={Atom.to_string(profile.sharing)} />

                <div class="flex shrink-0 items-center gap-2">
                  <.button
                    :if={is_nil(@current_profile) or @current_profile.id != profile.id}
                    phx-click="use"
                    phx-value-id={profile.id}
                    variant="primary"
                  >
                    {gettext("Use")}
                  </.button>
                  <span
                    :if={!is_nil(@current_profile) and @current_profile.id == profile.id}
                    class="badge badge-outline badge-success"
                  >
                    {gettext("Active")}
                  </span>
                  <.button phx-click="edit" phx-value-id={profile.id}>{gettext("Edit")}</.button>
                </div>
              </li>
            </ul>

            <div class="mt-4">
              <.button navigate={~p"/groups"} variant="primary">
                {gettext("Go to /")}
              </.button>
            </div>
          </div>
        </div>

        <div :if={@edit_form} class="card bg-base-200">
          <div class="card-body gap-0">
            <button
              id="toggle-edit-profile"
              type="button"
              phx-click="cancel_edit"
              class="flex w-full items-center justify-between gap-3 rounded-2xl text-left transition-opacity hover:opacity-85"
              aria-expanded="true"
            >
              <div>
                <h3 class="card-title">{gettext("Edit profile")}</h3>
                <p class="mt-1 text-sm text-base-content/60">
                  {gettext("Update the selected profile details.")}
                </p>
              </div>
              <.icon name="hero-chevron-down" class="size-5 shrink-0 rotate-180 transition-transform" />
            </button>

            <div class="mt-5 border-t border-base-300/70 pt-5">
              <.form
                for={@edit_form}
                id="edit-profile-form"
                phx-change="validate_edit"
                phx-submit="save_edit"
              >
                <.input
                  field={@edit_form[:username]}
                  id="edit-profile-username"
                  label={gettext("Username")}
                  required
                />
                <.input
                  field={@edit_form[:profile_picture_url]}
                  id="edit-profile-picture-url"
                  label={gettext("Profile picture URL")}
                  type="url"
                />
                <.input
                  field={@edit_form[:description_format]}
                  id="edit-profile-description-format"
                  label={gettext("Description format")}
                  type="select"
                  options={@description_format_options}
                />
                <.input
                  field={@edit_form[:description]}
                  id="edit-profile-description"
                  label={gettext("Description")}
                  type="textarea"
                />
                <.input
                  field={@edit_form[:sharing]}
                  id="edit-profile-sharing"
                  label={gettext("Sharing")}
                  type="select"
                  options={@sharing_options}
                />
                <div class="mt-3 flex flex-wrap gap-2">
                  <.button phx-disable-with={gettext("Saving...")} variant="primary">
                    {gettext("Save changes")}
                  </.button>
                  <.button type="button" phx-click="cancel_edit">{gettext("Cancel")}</.button>
                </div>
              </.form>

              <div
                :if={@edit_profile && @edit_profile.sharing == :shared}
                class="mt-6 border-t border-base-300/70 pt-5"
              >
                <h4 class="text-base font-semibold text-base-content">
                  {gettext("Invite profile to shared profile")}
                </h4>
                <p class="mt-1 text-sm text-base-content/60">
                  {gettext("Send an invitation by profile username.")}
                </p>

                <.form
                  for={@profile_invitation_form}
                  id="shared-profile-invitation-form"
                  phx-submit="invite_profile_to_profile"
                >
                  <.input
                    field={@profile_invitation_form[:username]}
                    id="shared-profile-invitation-username"
                    label={gettext("Profile username")}
                    required
                  />
                  <div class="mt-3">
                    <.button phx-disable-with={gettext("Sending...")} variant="primary">
                      {gettext("Send invitation")}
                    </.button>
                  </div>
                </.form>
              </div>
            </div>
          </div>
        </div>

        <div class="card bg-base-200">
          <div class="card-body gap-0">
            <button
              id="toggle-create-profile"
              type="button"
              phx-click="toggle_create_profile"
              class="flex w-full items-center justify-between gap-3 rounded-2xl text-left transition-opacity hover:opacity-85"
              aria-expanded={to_string(@create_profile_expanded)}
            >
              <div>
                <h3 class="card-title">{gettext("Create profile")}</h3>
                <p class="mt-1 text-sm text-base-content/60">
                  {gettext("Expand to create a new profile.")}
                </p>
              </div>
              <.icon
                name="hero-chevron-down"
                class={[
                  "size-5 shrink-0 transition-transform",
                  @create_profile_expanded && "rotate-180"
                ]}
              />
            </button>

            <div :if={@create_profile_expanded} class="mt-5 border-t border-base-300/70 pt-5">
              <.form for={@form} id="create-profile-form" phx-change="validate" phx-submit="create">
                <.input
                  field={@form[:username]}
                  id="create-profile-username"
                  label={gettext("Username")}
                  required
                />
                <.input
                  field={@form[:profile_picture_url]}
                  id="create-profile-picture-url"
                  label={gettext("Profile picture URL")}
                  type="url"
                />
                <.input
                  field={@form[:description_format]}
                  id="create-profile-description-format"
                  label={gettext("Description format")}
                  type="select"
                  options={@description_format_options}
                />
                <.input
                  field={@form[:description]}
                  id="create-profile-description"
                  label={gettext("Description")}
                  type="textarea"
                />
                <.input
                  field={@form[:sharing]}
                  id="create-profile-sharing"
                  label={gettext("Sharing")}
                  type="select"
                  options={@sharing_options}
                />
                <.button phx-disable-with={gettext("Creating...")} variant="primary">
                  {gettext("Create")}
                </.button>
              </.form>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :profile, :map, required: true
  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil

  def profile_identity(assigns) do
    ~H"""
    <div class="flex min-w-0 items-center gap-3">
      <%= if avatar_url = profile_picture_url(@profile) do %>
        <img
          src={avatar_url}
          alt={@profile.username}
          class="size-11 shrink-0 rounded-full border border-base-300 object-cover shadow-sm"
        />
      <% else %>
        <div class="flex size-11 shrink-0 items-center justify-center rounded-full border border-base-300 bg-base-300 text-sm font-semibold uppercase text-base-content/75 shadow-sm">
          {profile_initials(@profile.username)}
        </div>
      <% end %>

      <div class="min-w-0">
        <div
          :if={@title}
          class="text-xs font-semibold uppercase tracking-[0.16em] text-base-content/45"
        >
          {@title}
        </div>
        <div class="truncate font-semibold text-base-content">{@profile.username}</div>
        <div :if={@subtitle} class="truncate text-xs text-base-content/60">{@subtitle}</div>
      </div>
    </div>
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
     |> assign(:profile_invitations, pending_profile_invitations(socket.assigns.current_profile))
     |> assign(:form, new_profile_form())
     |> assign(:create_profile_expanded, false)
     |> assign(:edit_form, nil)
     |> assign(:edit_profile, nil)
     |> assign(:edit_profile_id, nil)
     |> assign(:profile_invitation_form, new_profile_invitation_form())
     |> assign(:description_format_options, [
       {gettext("Markdown"), :markdown},
       {gettext("HTML"), :html}
     ])
     |> assign(:sharing_options, [{gettext("Unique"), :unique}, {gettext("Shared"), :shared}])}
  end

  @impl true
  def handle_event("validate", %{"profile" => attrs}, socket) do
    changeset =
      %Profile{}
      |> Profile.changeset(attrs)
      |> Map.put(:action, :validate)

    {:noreply,
     socket
     |> assign(:create_profile_expanded, true)
     |> assign(:form, to_form(changeset))}
  end

  def handle_event("toggle_create_profile", _params, socket) do
    {:noreply, update(socket, :create_profile_expanded, &(!&1))}
  end

  def handle_event("validate_edit", %{"profile" => attrs}, socket) do
    account = socket.assigns.current_scope.account

    case current_editable_profile(socket, account) do
      nil ->
        {:noreply, clear_edit_state(socket)}

      profile ->
        changeset =
          profile
          |> Profile.changeset(attrs)
          |> Map.put(:action, :validate)

        {:noreply, assign(socket, :edit_form, to_form(changeset))}
    end
  end

  def handle_event("create", %{"profile" => attrs}, socket) do
    account = socket.assigns.current_scope.account

    case Social.create_profile_for_account(account, attrs) do
      {:ok, profile} ->
        {:ok, account} = Accounts.set_current_profile(account, profile)

        {:noreply,
         socket
         |> assign(:current_scope, %{socket.assigns.current_scope | account: account})
         |> assign(:current_profile, profile)
         |> assign(:profiles, Social.list_profiles_for_account(account))
         |> assign(:form, new_profile_form())
         |> assign(:create_profile_expanded, false)
         |> assign(:profile_invitations, pending_profile_invitations(profile))
         |> push_current_profile_updated(profile)
         |> put_flash(:info, gettext("Profile created."))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:create_profile_expanded, true)
         |> assign(:form, to_form(changeset))}
    end
  end

  def handle_event("edit", %{"id" => id}, socket) do
    account = socket.assigns.current_scope.account

    case Social.get_profile_for_account(account, String.to_integer(id)) do
      nil ->
        {:noreply,
         put_flash(socket, :error, gettext("That profile is not available for this account."))}

      profile ->
        {:noreply,
         socket
         |> assign(:edit_profile, profile)
         |> assign(:edit_profile_id, profile.id)
         |> assign(:edit_form, to_form(Profile.changeset(profile, %{})))}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, clear_edit_state(socket)}
  end

  def handle_event("save_edit", %{"profile" => attrs}, socket) do
    account = socket.assigns.current_scope.account

    case socket.assigns.edit_profile_id do
      nil ->
        {:noreply, clear_edit_state(socket)}

      profile_id ->
        case Social.update_profile_for_account(account, profile_id, attrs) do
          {:ok, profile} ->
            {:noreply,
             socket
             |> assign(:profiles, Social.list_profiles_for_account(account))
             |> assign(
               :profile_invitations,
               pending_profile_invitations(socket.assigns.current_profile)
             )
             |> maybe_assign_current_profile(profile)
             |> clear_edit_state()
             |> put_flash(:info, gettext("Profile updated."))}

          {:error, :not_found} ->
            {:noreply,
             socket
             |> clear_edit_state()
             |> put_flash(:error, gettext("That profile is not available for this account."))}

          {:error, changeset} ->
            {:noreply,
             assign(socket, :edit_form, to_form(Map.put(changeset, :action, :validate)))}
        end
    end
  end

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
         |> assign(:profile_invitations, pending_profile_invitations(profile))
         |> put_private(:previous_current_profile, profile)
         |> ProfileAuth.sync_profile_subscription(previous_profile)
         |> push_current_profile_updated(profile)
         |> put_flash(:info, gettext("Profile selected."))}
    end
  end

  def handle_event(
        "invite_profile_to_profile",
        %{"profile_invitation" => %{"username" => raw_username}},
        socket
      ) do
    inviter_account = socket.assigns.current_scope.account
    inviter = socket.assigns.current_profile
    username = String.trim(raw_username)

    case {socket.assigns.edit_profile, inviter} do
      {_, nil} ->
        {:noreply,
         put_flash(socket, :error, gettext("Select a current profile before sending invitations."))}

      {%{sharing: :shared} = profile, inviter} ->
        case Social.get_profile_by_username(username) do
          nil ->
            {:noreply,
             put_flash(socket, :error, gettext("No profile exists for that username."))}

          invitee ->
            case Social.invite_profile_to_profile(inviter_account, inviter, profile, invitee) do
              {:ok, _invitation} ->
                {:noreply,
                 socket
                 |> assign(:profile_invitation_form, new_profile_invitation_form())
                 |> put_flash(:info, gettext("Shared profile invitation sent."))}

              {:error, :profile_not_shared} ->
                {:noreply,
                 put_flash(socket, :error, gettext("Only shared profiles can be invited."))}

              {:error, :inviter_not_linked} ->
                {:noreply,
                 put_flash(
                   socket,
                   :error,
                   gettext("That profile is not available for this account.")
                 )}

              {:error, :cannot_invite_self} ->
                {:noreply,
                 put_flash(socket, :error, gettext("You cannot invite your own profile."))}

              {:error, %Ecto.Changeset{}} ->
                {:noreply,
                 put_flash(socket, :error, gettext("A shared profile invitation is already pending."))}

              {:error, _reason} ->
                {:noreply,
                 put_flash(socket, :error, gettext("Could not send shared profile invitation."))}
            end
        end

      _ ->
        {:noreply,
         put_flash(socket, :error, gettext("Select a shared profile before inviting another profile."))}
    end
  end

  def handle_event("accept_profile_invitation", %{"id" => id}, socket) do
    account = socket.assigns.current_scope.account
    invitee = socket.assigns.current_profile
    invitation_id = String.to_integer(id)

    with %{} <- invitee,
         %{} = invitation <- Social.get_pending_profile_invitation_for_invitee(invitee, invitation_id),
         {:ok, _accepted_invitation} <- Social.accept_profile_invitation(invitation, invitee, account) do
      refreshed_account = Accounts.get_account!(account.id)

      {:noreply,
       socket
       |> assign(:current_scope, %{socket.assigns.current_scope | account: refreshed_account})
       |> assign(:current_profile, Social.get_account_current_profile(refreshed_account))
       |> assign(:profiles, Social.list_profiles_for_account(refreshed_account))
       |> assign(
         :profile_invitations,
         pending_profile_invitations(Social.get_account_current_profile(refreshed_account))
       )
       |> put_flash(:info, gettext("Shared profile invitation accepted."))}
    else
      nil ->
        {:noreply,
         put_flash(socket, :error, gettext("Shared profile invitation not found."))}

      {:error, _reason} ->
        {:noreply,
         put_flash(socket, :error, gettext("Could not accept shared profile invitation."))}
    end
  end

  @impl true
  def handle_info({:account_profiles_updated, account_id}, socket)
      when socket.assigns.current_scope.account.id == account_id do
    previous_profile = socket.private[:previous_current_profile]

    current_profile = Social.get_account_current_profile(socket.assigns.current_scope.account)

    {:noreply,
     socket
     |> assign(:profiles, Social.list_profiles_for_account(socket.assigns.current_scope.account))
     |> assign(:current_profile, current_profile)
     |> assign(:profile_invitations, pending_profile_invitations(current_profile))
     |> put_private(:previous_current_profile, current_profile)
     |> ProfileAuth.sync_profile_subscription(previous_profile)}
  end

  def handle_info({:account_profiles_updated, _account_id}, socket), do: {:noreply, socket}

  def handle_info({:profile_share_invitations_updated, profile_id}, socket)
      when not is_nil(socket.assigns.current_profile) and socket.assigns.current_profile.id == profile_id do
    {:noreply,
     assign(
       socket,
       :profile_invitations,
       pending_profile_invitations(socket.assigns.current_profile)
     )}
  end

  def handle_info({:profile_share_invitations_updated, _profile_id}, socket),
    do: {:noreply, socket}

  defp profile_picture_url(%{profile_picture_url: url}) when is_binary(url) do
    case String.trim(url) do
      "" -> nil
      trimmed_url -> trimmed_url
    end
  end

  defp profile_picture_url(_), do: nil

  defp profile_initials(username) when is_binary(username) do
    username
    |> String.split(~r/[\s_-]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(fn part ->
      part
      |> String.first()
      |> to_string()
    end)
    |> case do
      "" -> "?"
      initials -> String.upcase(initials)
    end
  end

  defp profile_initials(_), do: "?"

  defp new_profile_form do
    %Profile{}
    |> Profile.changeset(%{})
    |> to_form()
  end

  defp new_profile_invitation_form do
    to_form(%{"username" => ""}, as: :profile_invitation)
  end

  defp pending_profile_invitations(nil), do: []
  defp pending_profile_invitations(profile), do: Social.list_pending_profile_invitations(profile)

  defp clear_edit_state(socket) do
    socket
    |> assign(:edit_profile, nil)
    |> assign(:edit_profile_id, nil)
    |> assign(:edit_form, nil)
    |> assign(:profile_invitation_form, new_profile_invitation_form())
  end

  defp current_editable_profile(socket, account) do
    case socket.assigns.edit_profile_id do
      nil -> nil
      profile_id -> Social.get_profile_for_account(account, profile_id)
    end
  end

  defp maybe_assign_current_profile(socket, profile) do
    case socket.assigns.current_profile do
      %{id: id} when id == profile.id ->
        socket
        |> assign(:current_profile, profile)
        |> push_current_profile_updated(profile)

      _ ->
        socket
    end
  end

  defp push_current_profile_updated(socket, profile) do
    push_event(socket, "current_profile_updated", %{
      username: profile.username,
      profile_picture_url: profile_picture_url(profile)
    })
  end
end
