defmodule PotokIdeWeb.ProfileLive.New do
  use PotokIdeWeb, :live_view

  alias PotokIde.Social
  alias PotokIde.Social.Profile
  alias PotokIdeWeb.GroupLive.Show.Components, as: GroupComponents
  alias PotokIdeWeb.ProfileLive.Components, as: ProfileComponents

  # The keys of `ProfileComponents.form_sections/1`.
  @sections ~w(basics description sharing)

  # Laid out like a group's create tab: cards picked one at a time and the
  # actions in a bar at the bottom. The form is `novalidate`: the browser
  # cannot point at a required field in a hidden card and would silently not
  # submit, so the server checks and opens the card with the error.
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
      full_width
    >
      <.page_container id="profile-new-page">
        <.page_header id="profile-new-header" icon="hero-user-plus">
          {gettext("New profile")}
          <:subtitle>
            {gettext("Choose how this profile appears and whether it can be shared.")}
          </:subtitle>
        </.page_header>

        <GroupComponents.settings_tabs
          id="profile-new-sections"
          tabs={ProfileComponents.form_sections("profile-new")}
          current={@section}
          event="set_section"
          tab_id_prefix="profile-new-tab"
        />

        <.form
          for={@form}
          id="create-profile-form"
          phx-change="validate"
          phx-submit="create"
          novalidate
        >
          <ProfileComponents.profile_form_cards
            form={@form}
            section={@section}
            id_prefix="profile-new"
            description_format_options={@description_format_options}
            sharing_options={@sharing_options}
          />
        </.form>

        <%!-- Outside the form, which it submits through `form`, so it can
             stick to the bottom over every card. --%>
        <div
          id="profile-new-bar"
          class="sticky bottom-0 z-10 mt-4 flex flex-wrap items-center justify-end gap-2 rounded-3xl border border-base-300/70 bg-base-100/95 px-4 py-3 shadow-xl shadow-primary/10 backdrop-blur"
        >
          <.button id="profile-new-cancel" navigate={~p"/profiles"} variant="ghost">
            {gettext("Cancel")}
          </.button>
          <.button
            id="profile-new-submit"
            type="submit"
            form="create-profile-form"
            phx-disable-with={gettext("Creating...")}
            variant="primary"
          >
            {gettext("Create profile")}
          </.button>
        </div>
      </.page_container>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:form, new_profile_form())
     |> assign(:section, "basics")
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

  def handle_event("set_section", %{"section" => section}, socket) when section in @sections,
    do: {:noreply, assign(socket, :section, section)}

  def handle_event("set_section", _params, socket), do: {:noreply, socket}

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
        {:noreply,
         socket
         |> assign(:form, to_form(changeset))
         |> assign(:section, ProfileComponents.error_section(changeset) || socket.assigns.section)}
    end
  end

  defp new_profile_form do
    %Profile{}
    |> Profile.changeset(%{})
    |> to_form()
  end
end
