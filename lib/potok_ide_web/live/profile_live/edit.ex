defmodule PotokIdeWeb.ProfileLive.Edit do
  use PotokIdeWeb, :live_view

  alias PotokIde.Social
  alias PotokIde.Social.Profile
  alias PotokIdeWeb.ProfileLive.Components, as: ProfileComponents

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex h-[calc(100dvh-4rem)] flex-col overflow-y-auto px-4 pt-4">
        <div class="mx-auto flex w-full max-w-3xl flex-1 flex-col gap-6 pb-8">
          <div class="card">
            <div class="card-body gap-5">
              <div>
                <ProfileComponents.profile_identity
                  profile={@profile}
                  subtitle={Atom.to_string(@profile.sharing)}
                />
                <p class="mt-3 text-sm text-base-content/60">
                  {gettext("Update the selected profile details.")}
                </p>
              </div>

              <.form
                for={@form}
                id="edit-profile-form"
                phx-change="validate"
                phx-submit="save"
              >
                <ProfileComponents.profile_form_fields
                  form={@form}
                  description_format_options={@description_format_options}
                  sharing_options={@sharing_options}
                />
                <div class="mt-4 flex flex-wrap gap-2">
                  <.button phx-disable-with={gettext("Saving...")} variant="primary">
                    {gettext("Save changes")}
                  </.button>
                  <.button navigate={~p"/profiles"} type="button">{gettext("Cancel")}</.button>
                </div>
              </.form>

              <div :if={@profile.sharing == :shared} class="border-t border-base-300/70 pt-5">
                <h3 class="text-base font-semibold text-base-content">
                  {gettext("Invite profile to shared profile")}
                </h3>

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
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => raw_id}, _session, socket) do
    account = socket.assigns.current_scope.account

    case parse_profile_id(raw_id) do
      {:ok, profile_id} ->
        case Social.get_profile_for_account(account, profile_id) do
          nil ->
            {:ok,
             socket
             |> put_flash(:error, gettext("That profile is not available for this account."))
             |> push_navigate(to: ~p"/profiles")}

          profile ->
            {:ok,
             socket
             |> assign(:profile, profile)
             |> assign(:form, to_form(Profile.changeset(profile, %{})))
             |> assign(:profile_invitation_form, new_profile_invitation_form())
             |> assign(
               :description_format_options,
               ProfileComponents.description_format_options()
             )
             |> assign(:sharing_options, ProfileComponents.sharing_options())}
        end

      :error ->
        {:ok,
         socket
         |> put_flash(:error, gettext("That profile is not available for this account."))
         |> push_navigate(to: ~p"/profiles")}
    end
  end

  @impl true
  def handle_event("validate", %{"profile" => attrs}, socket) do
    changeset =
      socket.assigns.profile
      |> Profile.changeset(attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("save", %{"profile" => attrs}, socket) do
    account = socket.assigns.current_scope.account

    case Social.update_profile_for_account(account, socket.assigns.profile.id, attrs) do
      {:ok, profile} ->
        {:noreply,
         socket
         |> assign(:profile, profile)
         |> maybe_assign_current_profile(profile)
         |> put_flash(:info, gettext("Profile updated."))
         |> push_navigate(to: ~p"/profiles")}

      {:error, :not_found} ->
        {:noreply,
         socket
         |> put_flash(:error, gettext("That profile is not available for this account."))
         |> push_navigate(to: ~p"/profiles")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(Map.put(changeset, :action, :validate)))}
    end
  end

  def handle_event(
        "invite_profile_to_profile",
        %{"profile_invitation" => %{"username" => raw_username}},
        socket
      ) do
    inviter_account = socket.assigns.current_scope.account
    inviter = socket.assigns.current_profile
    profile = socket.assigns.profile
    username = String.trim(raw_username)

    case inviter do
      nil ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Select a current profile before sending invitations.")
         )}

      _inviter when profile.sharing != :shared ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Select a shared profile before inviting another profile.")
         )}

      inviter ->
        case Social.get_profile_by_username(username) do
          nil ->
            {:noreply, put_flash(socket, :error, gettext("No profile exists for that username."))}

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
                 put_flash(
                   socket,
                   :error,
                   gettext("A shared profile invitation is already pending.")
                 )}

              {:error, _reason} ->
                {:noreply,
                 put_flash(socket, :error, gettext("Could not send shared profile invitation."))}
            end
        end
    end
  end

  defp parse_profile_id(raw_id) do
    case Integer.parse(raw_id) do
      {profile_id, ""} -> {:ok, profile_id}
      _ -> :error
    end
  end

  defp new_profile_invitation_form do
    to_form(%{"username" => ""}, as: :profile_invitation)
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
      profile_picture_url: ProfileComponents.profile_picture_url(profile)
    })
  end
end
