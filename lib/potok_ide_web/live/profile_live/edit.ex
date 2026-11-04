defmodule PotokIdeWeb.ProfileLive.Edit do
  use PotokIdeWeb, :live_view

  alias PotokIde.Social
  alias PotokIde.Social.Profile
  alias PotokIde.Tags
  alias PotokIde.Tags.Tag
  alias PotokIdeWeb.GroupLive.Show.Components, as: GroupComponents
  alias PotokIdeWeb.ProfileLive.Components, as: ProfileComponents
  alias PotokIdeWeb.{TagComponents, TagEditor}

  # `ProfileComponents.form_sections/1` and the tags, see `sections/0`.
  @sections ~w(basics description sharing tags)

  # Laid out like a group's edit tab: cards picked one at a time, the other
  # ones only hidden, so an edit made in one survives a switch to another. The
  # invitation and the tags work on their own, outside the profile form. The
  # save bar shows while the form has unsaved changes, whichever card is on
  # screen. The form is `novalidate`, as a required field in a hidden card
  # would silently stop the browser from submitting; the server opens the card
  # with the error instead.
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
      <.page_container id="profile-edit-page">
        <.page_header id="profile-edit-header" icon="hero-user-circle">
          {gettext("Edit profile")}
          <:subtitle>{@profile.username}</:subtitle>
          <:actions>
            <.icon_button
              id="profile-edit-back"
              navigate={~p"/profiles"}
              icon="hero-arrow-left"
              label={gettext("Profiles")}
              variant="secondary"
              size="md"
            />
          </:actions>
        </.page_header>

        <GroupComponents.settings_tabs
          id="profile-edit-sections"
          tabs={sections()}
          current={@section}
          event="set_section"
          tab_id_prefix="profile-edit-tab"
        />

        <.form
          for={@form}
          id="edit-profile-form"
          phx-change="validate"
          phx-submit="save"
          novalidate
        >
          <ProfileComponents.profile_form_cards
            form={@form}
            section={@section}
            id_prefix="profile-edit"
            description_format_options={@description_format_options}
            sharing_options={@sharing_options}
          />
        </.form>

        <GroupComponents.settings_card
          :if={@profile.sharing == :shared}
          id="profile-edit-invite"
          tab_id="profile-edit-tab-sharing"
          active={@section == "sharing"}
          icon="hero-paper-airplane"
          title={gettext("Invite profile to shared profile")}
          subtitle={gettext("Send an invitation by profile username.")}
          class="mt-4"
        >
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
        </GroupComponents.settings_card>

        <GroupComponents.settings_card
          id="profile-tags-section"
          tab_id="profile-edit-tab-tags"
          active={@section == "tags"}
          icon="hero-hashtag"
          title={gettext("Public tags")}
          subtitle={gettext("Everyone sees these tags on the profile, say its interests or skills.")}
        >
          <TagComponents.tag_chips id="profile-tag-list" tags={@profile_tags} />
          <p
            :if={@profile_tags == []}
            id="profile-tags-empty"
            class="text-sm text-base-content/65"
          >
            {gettext("No public tags yet.")}
          </p>
          <.button
            id="profile-tags-edit"
            type="button"
            phx-click="edit_profile_tags"
            variant="soft"
            class="mt-4"
          >
            <.icon name="hero-hashtag" class="size-4" />
            <span>{gettext("Edit tags")}</span>
          </.button>
        </GroupComponents.settings_card>

        <%!-- Outside the form, which it submits through `form`, so it can
             stick to the bottom over every card. --%>
        <div
          :if={dirty?(@form)}
          id="profile-edit-save-bar"
          class="sticky bottom-0 z-10 mt-4 flex flex-wrap items-center justify-between gap-3 rounded-3xl border border-primary/30 bg-base-100/95 px-4 py-3 shadow-xl shadow-primary/10 backdrop-blur"
        >
          <p class="flex items-center gap-2 text-sm font-medium">
            <span class="size-2 shrink-0 rounded-full bg-primary"></span>
            {gettext("You have unsaved changes.")}
          </p>
          <div class="ml-auto flex items-center gap-2">
            <.button id="profile-edit-discard" type="button" phx-click="discard" variant="ghost">
              {gettext("Discard")}
            </.button>
            <.button
              id="profile-edit-save"
              type="submit"
              form="edit-profile-form"
              phx-disable-with={gettext("Saving...")}
              variant="primary"
            >
              {gettext("Save changes")}
            </.button>
          </div>
        </div>
      </.page_container>
      <TagComponents.tag_editor editor={@tag_editor} />
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => raw_id}, _session, socket) do
    account = socket.assigns.current_scope.account

    case parse_profile_id(raw_id) do
      {:ok, profile_id} ->
        case Social.load_picture(Social.get_profile_for_account(account, profile_id)) do
          nil ->
            {:ok,
             socket
             |> put_flash(:error, gettext("That profile is not available for this account."))
             |> push_navigate(to: ~p"/profiles")}

          profile ->
            {:ok,
             socket
             |> assign(:profile, profile)
             |> assign(:profile_tags, public_tags(profile))
             |> TagEditor.init()
             |> assign(:form, to_form(Profile.changeset(profile, %{})))
             |> assign(:section, "basics")
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

  def handle_event("set_section", %{"section" => section}, socket) when section in @sections,
    do: {:noreply, assign(socket, :section, section)}

  def handle_event("set_section", _params, socket), do: {:noreply, socket}

  def handle_event("discard", _params, socket),
    do: {:noreply, assign(socket, :form, to_form(Profile.changeset(socket.assigns.profile, %{})))}

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
        {:noreply,
         socket
         |> assign(:form, to_form(Map.put(changeset, :action, :validate)))
         |> assign(:section, ProfileComponents.error_section(changeset) || socket.assigns.section)}
    end
  end

  # The profile puts public tags on itself; the account is linked to it.
  def handle_event("edit_profile_tags", _params, socket) do
    profile = socket.assigns.profile
    {:noreply, TagEditor.open(socket, profile, :profile, profile.id, public_only?: true)}
  end

  def handle_event("tag_editor_" <> _ = event, params, socket),
    do: TagEditor.handle_event(event, params, socket)

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

  @impl true
  def handle_info({:tags_changed, :profile, profile_id}, socket)
      when profile_id == socket.assigns.profile.id do
    {:noreply,
     socket
     |> assign(:profile_tags, public_tags(socket.assigns.profile))
     |> TagEditor.refresh(:profile, profile_id)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # The tabs: the form's cards and the tags. The keys are those of `@sections`.
  defp sections do
    ProfileComponents.form_sections("profile-edit") ++
      [{"tags", "profile-tags-section", gettext("Tags"), false}]
  end

  # Whether the form holds something not saved yet (its save bar shows). A
  # field that fails validation, like a cleared name, is dropped from the
  # changes, so errors count too: the bar's save then shows what is wrong.
  defp dirty?(%Phoenix.HTML.Form{source: %Ecto.Changeset{changes: changes, errors: errors}}),
    do: changes != %{} or errors != []

  defp public_tags(%Profile{id: id} = profile) do
    profile
    |> Tags.tags_for(:profile, [id])
    |> Map.get(id, [])
    |> Enum.filter(&Tag.public?/1)
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
      id: profile.id,
      username: profile.username,
      profile_picture_url: ProfileComponents.profile_picture_url(profile)
    })
  end
end
