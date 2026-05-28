defmodule PotokIdeWeb.ProfileLive.New do
  use PotokIdeWeb, :live_view

  alias PotokIde.Social
  alias PotokIde.Social.Profile
  alias PotokIdeWeb.ProfileLive.Components, as: ProfileComponents

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_profile={@current_profile}
      current_locale={@current_locale}
      available_locales={@available_locales}
      pending_invitations_count={@pending_invitations_count}
      pending_group_join_requests_count={@pending_group_join_requests_count}
      root_group_unread_count={@root_group_unread_count}
    >
      <div class="flex h-[calc(100dvh-4rem)] flex-col overflow-y-auto px-4 pt-4">
        <div class="mx-auto flex w-full max-w-3xl flex-1 flex-col gap-6 pb-8">
          <div class="card">
            <div class="card-body gap-5">
              <div>
                <h2 class="card-title text-xl">{gettext("New profile details")}</h2>

                <p class="mt-1 text-sm text-base-content/60">
                  {gettext("Choose how this profile appears and whether it can be shared.")}
                </p>
              </div>

              <.form for={@form} id="create-profile-form" phx-change="validate" phx-submit="create">
                <ProfileComponents.profile_form_fields
                  form={@form}
                  description_format_options={@description_format_options}
                  sharing_options={@sharing_options}
                />
                <div class="mt-4 flex flex-wrap gap-2">
                  <.button phx-disable-with={gettext("Creating...")} variant="primary">
                    {gettext("Create profile")}
                  </.button>
                  <.button navigate={~p"/profiles"} type="button">{gettext("Cancel")}</.button>
                </div>
              </.form>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:form, new_profile_form())
     |> assign(:description_format_options, ProfileComponents.description_format_options())
     |> assign(:sharing_options, ProfileComponents.sharing_options())}
  end

  @impl true
  def handle_event("validate", %{"profile" => attrs}, socket) do
    changeset =
      %Profile{}
      |> Profile.changeset(attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :form, to_form(changeset))}
  end

  def handle_event("create", %{"profile" => attrs}, socket) do
    account = socket.assigns.current_scope.account

    case Social.create_profile_for_account(account, attrs) do
      {:ok, _profile} ->
        {:noreply,
         socket
         |> assign(:current_scope, %{socket.assigns.current_scope | account: account})
         |> put_flash(:info, gettext("Profile created."))
         |> push_navigate(to: ~p"/profiles")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
    end
  end

  defp new_profile_form do
    %Profile{}
    |> Profile.changeset(%{})
    |> to_form()
  end
end
