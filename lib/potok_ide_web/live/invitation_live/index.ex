defmodule PotokIdeWeb.InvitationLive.Index do
  use PotokIdeWeb, :live_view

  alias PotokIde.Accounts
  alias PotokIde.Social
  alias PotokIde.Social.{EmailInvitations, GroupAccountInvitation, GroupInvitation}
  alias PotokIde.Social.Profile
  alias PotokIdeWeb.ProfileAuth
  alias PotokIdeWeb.GroupLive.Show.Components
  alias PotokIdeWeb.InvitationLive.Components, as: InvitationComponents
  alias PotokIdeWeb.ProfileLive.Components, as: ProfileComponents
  @invitations_per_page 20
  @sent_invitations_per_page 20
  @sections ~w(received sent)

  @impl true
  def render(assigns) do
    assigns =
      assign(
        assigns,
        :invitation_search_form,
        to_form(%{"q" => assigns.invitations_search_query}, as: :invitation_search)
      )

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
      unread_notices_count={@unread_notices_count}
      full_width
    >
      <.page_container id="invitations-page">
        <.page_header id="invitations-header" icon="hero-inbox-arrow-down">
          {gettext("Invitations")}
          <:subtitle>
            {gettext(
              "Group invitations your current profile got and sent, and those that reached your account by email."
            )}
          </:subtitle>
        </.page_header>

        <Components.settings_tabs
          id="invitations-sections"
          tabs={sections()}
          current={@section}
          event="set_section"
          tab_id_prefix="invitations-tab"
          counts={
            %{
              "received" => @invitations_pagination.total_count + length(@account_invitations),
              "sent" => @sent_invitations_pagination.total_count + length(@sent_by_email)
            }
          }
        />

        <%!-- One search for both tabs. --%>
        <.form
          :if={
            @invitations_pagination.total_count > 0 or
              @sent_invitations_pagination.total_count > 0 or @invitations_search_query != "" or
              @account_invitations != [] or @sent_by_email != []
          }
          for={@invitation_search_form}
          id="invitation-search-form"
          phx-change="search_invitations"
          class="mb-3 flex flex-row justify-end"
        >
          <.search_field
            id="invitation-search-input"
            field={@invitation_search_form[:q]}
            reset_id="invitation-search-reset"
            reset_event="clear_invitations_search"
            placeholder={gettext("Search by group or profile")}
          />
        </.form>

        <%!-- A card off screen holds no list: picking its tab loads it. --%>
        <Components.settings_card
          id="invitations-received"
          tab_id="invitations-tab-received"
          active={@section == "received"}
          icon="hero-inbox-arrow-down"
          title={gettext("Invitations for me")}
          subtitle={gettext("To your account by email, or to your current profile.")}
        >
          <div :if={@section == "received"} class="space-y-4">
            <section
              :if={@account_invitations != []}
              id="account-invitations"
              class="space-y-3"
            >
              <h3 class="flex items-center gap-2 text-sm font-semibold text-base-content/80">
                <.icon name="hero-envelope" class="size-4" />
                {gettext("For your account")}
              </h3>
              <p class="text-xs text-base-content/65">
                {gettext(
                  "Invited by email: you choose the profile you join with, and the inviter sees it only then."
                )}
              </p>
              <div
                :for={inv <- @account_invitations}
                id={"account-invitation-#{inv.id}"}
                class="card rounded-2xl border border-primary/25 bg-primary/5"
              >
                <div class="card-body relative mb-0 p-3">
                  <Components.group_identity
                    group={inv.group}
                    current_profile={@current_profile}
                    avatar_size="size-12"
                    text_class="text-sm"
                    highlight_query={@invitations_search_query}
                  />
                  <div class="text-sm text-base-content/70">
                    {gettext("Invited by:")}
                    <.link
                      id={"account-invitation-inviter-#{inv.id}"}
                      navigate={~p"/u/#{inv.inviter.username}"}
                      class="font-semibold underline-offset-2 transition-colors hover:text-primary hover:underline"
                    >
                      {inv.inviter.username}
                    </.link>
                    <Components.local_time
                      id={"account-invitation-inserted-at-#{inv.id}"}
                      datetime={inv.inserted_at}
                      class="text-xs font-thin italic"
                    />
                  </div>
                  <p
                    id={"account-invitation-expires-#{inv.id}"}
                    class="mt-1 text-xs text-base-content/60"
                  >
                    {valid_for(inv)}
                  </p>
                  <div class="mt-2 flex flex-wrap gap-2">
                    <.button
                      id={"account-invitation-accept-#{inv.id}"}
                      phx-click="account_invitation_accept"
                      phx-value-id={inv.id}
                      variant="success"
                      size="sm"
                    >
                      {gettext("Join as @%{username}", username: @current_profile.username)}
                    </.button>
                    <.button
                      id={"account-invitation-accept-as-#{inv.id}"}
                      phx-click="account_invitation_accept_as"
                      phx-value-id={inv.id}
                      variant="secondary"
                      size="sm"
                    >
                      <.icon name="hero-arrows-right-left" class="size-4" />
                      {gettext("Another profile")}
                    </.button>
                  </div>
                  <.icon_button
                    id={"account-invitation-delete-#{inv.id}"}
                    phx-click="account_invitation_delete"
                    phx-value-id={inv.id}
                    data-confirm={gettext("Are you sure you want to delete this invitation?")}
                    icon="hero-trash"
                    label={gettext("Delete")}
                    variant="danger"
                    class="absolute right-0"
                  />
                </div>
              </div>
            </section>

            <div
              :if={@invitations_pagination.total_count == 0 and @account_invitations == []}
              class="rounded-2xl border border-base-300/60 bg-base-100/70 px-4 py-3 text-sm text-base-content/70"
            >
              {if String.trim(@invitations_search_query) == "",
                do: gettext("No pending invitations."),
                else: gettext("No invitations match your search.")}
            </div>

            <div :if={@invitations_pagination.total_count > 0} class="space-y-4">
              <div id="invitations" phx-update="stream" class="space-y-4">
                <div
                  :for={{dom_id, inv} <- @streams.invitations}
                  id={dom_id}
                  class="card rounded-2xl border border-base-300/70 bg-base-100/80"
                >
                  <div class="card-body relative mb-0 p-3">
                    <Components.group_identity
                      group={inv.group}
                      current_profile={@current_profile}
                      avatar_size="size-12"
                      text_class="text-sm"
                      unread_count={Map.get(@group_unread_counts, inv.group.id, 0)}
                      highlight_query={@invitations_search_query}
                    />
                    <div class="text-sm text-base-content/70">
                      {gettext("Invited by:")}
                      <%!-- The invited sees the inviter's card as a member
                           of the group would (`ProfileFacts`). --%>
                      <.link
                        id={"invitation-inviter-#{inv.id}"}
                        navigate={~p"/u/#{inv.inviter.username}"}
                        class="underline-offset-2 transition-colors hover:text-primary hover:underline"
                      >
                        <Components.highlighted_text
                          text={inv.inviter.username}
                          query={@invitations_search_query}
                          class="font-semibold"
                        />
                      </.link>
                      <Components.local_time
                        id={"invitation-inserted-at-#{inv.id}"}
                        datetime={inv.inserted_at}
                        class="text-xs font-thin italic"
                      />
                    </div>

                    <p
                      :if={is_nil(inv.accepted_at)}
                      id={"invitation-expires-#{inv.id}"}
                      class="mt-1 text-xs text-base-content/60"
                    >
                      {valid_for(inv)}
                    </p>

                    <div :if={is_nil(inv.accepted_at)} class="mt-2 flex flex-wrap gap-2">
                      <.button
                        id={"invitation-accept-#{inv.id}"}
                        phx-click="accept"
                        phx-value-id={inv.id}
                        variant="success"
                        size="sm"
                      >
                        {gettext("Accept")}
                      </.button>
                      <%!-- An invitation to a unique profile may be accepted by
                           another unique profile of the account, or a new one. --%>
                      <.button
                        :if={@current_profile.sharing == :unique}
                        id={"invitation-accept-as-#{inv.id}"}
                        phx-click="accept_as_open"
                        phx-value-id={inv.id}
                        variant="secondary"
                        size="sm"
                      >
                        <.icon name="hero-arrows-right-left" class="size-4" />
                        {gettext("Accept with another profile")}
                      </.button>
                    </div>

                    <div
                      :if={!is_nil(inv.accepted_at)}
                      class="mt-1 text-sm text-emerald-700 dark:text-emerald-300"
                    >
                      {gettext("Accepted on")}
                      <Components.local_time
                        id={"invitation-accepted-at-#{inv.id}"}
                        datetime={inv.accepted_at}
                        class="ml-1"
                      />
                    </div>

                    <.icon_button
                      id={"invitation-delete-#{inv.id}"}
                      phx-click="delete_invitation"
                      phx-value-id={inv.id}
                      data-confirm={gettext("Are you sure you want to delete this invitation?")}
                      icon="hero-trash"
                      label={gettext("Delete")}
                      variant="danger"
                      class="absolute right-0"
                    />
                  </div>
                </div>
              </div>

              <.button
                :if={@invitations_pagination.has_more?}
                id="invitations-load-more"
                type="button"
                phx-click="load_more_invitations"
                size="sm"
              >
                {gettext("Load more invitations")}
              </.button>
            </div>
          </div>
        </Components.settings_card>

        <Components.settings_card
          id="invitations-sent"
          tab_id="invitations-tab-sent"
          active={@section == "sent"}
          icon="hero-paper-airplane"
          title={gettext("Invitations sent by me")}
          subtitle={gettext("Invitations your current profile has sent to other profiles.")}
        >
          <div :if={@section == "sent"} class="space-y-4">
            <section :if={@sent_by_email != []} id="sent-by-email" class="space-y-3">
              <h3 class="flex items-center gap-2 text-sm font-semibold text-base-content/80">
                <.icon name="hero-envelope" class="size-4" />
                {gettext("Sent by email")}
              </h3>
              <div
                :for={inv <- @sent_by_email}
                id={"sent-by-email-#{inv.id}"}
                class="card rounded-2xl border border-base-300/70 bg-base-100/80"
              >
                <div class="card-body p-3">
                  <Components.group_identity
                    group={inv.group}
                    current_profile={@current_profile}
                    avatar_size="size-12"
                    text_class="text-sm"
                    highlight_query={@invitations_search_query}
                  />
                  <div class="text-sm text-base-content/70">
                    {gettext("Invited:")}
                    <span class="font-semibold">{inv.email || gettext("an address")}</span>
                  </div>
                  <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-base-content/70">
                    <span class="inline-flex items-center rounded-full bg-amber-500/10 px-2.5 py-1 text-xs font-semibold uppercase tracking-[0.12em] text-amber-800 dark:text-amber-200">
                      {gettext("Pending")}
                    </span>
                    <span>{gettext("Sent on")}</span>
                    <Components.local_time
                      id={"sent-by-email-timestamp-#{inv.id}"}
                      datetime={inv.inserted_at}
                      class="text-xs font-thin italic"
                    />
                  </div>
                  <p class="mt-1 text-xs text-base-content/60">{valid_for(inv)}</p>
                </div>
              </div>
            </section>

            <div
              :if={@sent_invitations_pagination.total_count == 0 and @sent_by_email == []}
              class="rounded-2xl border border-base-300/60 bg-base-100/70 px-4 py-3 text-sm text-base-content/70"
            >
              {if String.trim(@invitations_search_query) == "",
                do: gettext("No invitations sent by this profile."),
                else: gettext("No sent invitations match your search.")}
            </div>

            <div :if={@sent_invitations_pagination.total_count > 0} class="space-y-4">
              <div id="sent-invitations" phx-update="stream" class="space-y-4">
                <div
                  :for={{dom_id, inv} <- @streams.sent_invitations}
                  id={dom_id}
                  class="card rounded-2xl border border-base-300/70 bg-base-100/80"
                >
                  <div class="card-body p-3">
                    <Components.group_identity
                      group={inv.group}
                      current_profile={@current_profile}
                      avatar_size="size-12"
                      text_class="text-sm"
                      unread_count={Map.get(@group_unread_counts, inv.group.id, 0)}
                      highlight_query={@invitations_search_query}
                    />
                    <div class="text-sm text-base-content/70">
                      {gettext("Invited:")}
                      <Components.highlighted_text
                        text={inv.invitee.username}
                        query={@invitations_search_query}
                        class="font-semibold"
                      />
                    </div>

                    <div class="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-base-content/70">
                      <span class={[
                        "inline-flex items-center rounded-full px-2.5 py-1 text-xs font-semibold uppercase tracking-[0.12em]",
                        if(is_nil(inv.accepted_at),
                          do: "bg-amber-500/10 text-amber-800 dark:text-amber-200",
                          else: "bg-emerald-500/10 text-emerald-700 dark:text-emerald-300"
                        )
                      ]}>
                        {if is_nil(inv.accepted_at),
                          do: gettext("Pending"),
                          else: gettext("Accepted")}
                      </span>
                      <span>
                        {if is_nil(inv.accepted_at),
                          do: gettext("Sent on"),
                          else: gettext("Accepted on")}
                      </span>
                      <Components.local_time
                        id={"sent-invitation-timestamp-#{inv.id}"}
                        datetime={
                          if(is_nil(inv.accepted_at),
                            do: inv.inserted_at,
                            else: inv.accepted_at
                          )
                        }
                        class="text-xs font-thin italic"
                      />
                    </div>
                    <p
                      :if={is_nil(inv.accepted_at)}
                      id={"sent-invitation-expires-#{inv.id}"}
                      class="mt-1 text-xs text-base-content/60"
                    >
                      {valid_for(inv)}
                    </p>
                  </div>
                </div>
              </div>

              <.button
                :if={@sent_invitations_pagination.has_more?}
                id="sent-invitations-load-more"
                type="button"
                phx-click="load_more_sent_invitations"
                size="sm"
              >
                {gettext("Load more sent invitations")}
              </.button>
            </div>
          </div>
        </Components.settings_card>

        <%!-- <div><.link navigate={~p"/groups"} class="link">{gettext("Back to /")}</.link></div> --%>
      </.page_container>

      <InvitationComponents.accept_as_dialog
        :if={@accept_as && is_nil(@new_profile_form)}
        invitation={@accept_as.invitation}
        choices={@accept_as.choices}
      />

      <ProfileComponents.welcome_dialog
        :if={@accept_as && @new_profile_form}
        form={@new_profile_form}
        invitation={@accept_as.invitation}
        first={false}
      />
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> put_private(:previous_current_profile, socket.assigns.current_profile)
      |> assign(:section, "received")
      |> assign(:invitations_pagination, default_invitations_pagination())
      |> assign(:sent_invitations_pagination, default_sent_invitations_pagination())
      |> assign(:invitations_search_query, "")
      |> assign(:visible_invitations, [])
      |> assign(:visible_sent_invitations, [])
      |> assign(:accept_as, nil)
      |> assign(:account_invitations, [])
      |> assign(:sent_by_email, [])
      |> assign(:new_profile_form, nil)
      |> stream(:invitations, [], reset: true)
      |> stream(:sent_invitations, [], reset: true)
      |> ProfileAuth.sync_profile_subscription()

    {:ok,
     socket
     |> assign_invitations(socket.assigns.current_profile)}
  end

  @impl true
  def handle_event(
        "load_more_invitations",
        _params,
        %{assigns: %{current_profile: nil}} = socket
      ),
      do: {:noreply, socket}

  def handle_event("load_more_invitations", _params, socket) do
    if socket.assigns.invitations_pagination.has_more? do
      pagination =
        socket.assigns.invitations_pagination
        |> Map.update!(:page, fn page -> page + 1 end)

      invitations_page =
        invitations_page(
          socket.assigns.current_profile,
          pagination,
          socket.assigns.invitations_search_query
        )

      {:noreply,
       socket
       |> assign(:invitations_pagination, pagination_metadata(invitations_page))
       |> assign_visible_invitations(invitations_page.entries)
       |> stream(:invitations, invitations_page.entries, reset: true)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("set_section", %{"section" => section}, socket)
      when section in @sections do
    socket = assign(socket, :section, section)
    profile = socket.assigns.current_profile

    {:noreply,
     cond do
       is_nil(profile) -> socket
       section == "received" -> refresh_invitations(socket, profile)
       true -> refresh_sent_invitations(socket, profile)
     end}
  end

  def handle_event("set_section", _params, socket), do: {:noreply, socket}

  def handle_event(
        "load_more_sent_invitations",
        _params,
        %{assigns: %{current_profile: nil}} = socket
      ),
      do: {:noreply, socket}

  def handle_event("load_more_sent_invitations", _params, socket) do
    if socket.assigns.sent_invitations_pagination.has_more? do
      pagination =
        socket.assigns.sent_invitations_pagination
        |> Map.update!(:page, fn page -> page + 1 end)

      invitations_page =
        sent_invitations_page(
          socket.assigns.current_profile,
          pagination,
          socket.assigns.invitations_search_query
        )

      {:noreply,
       socket
       |> assign(:sent_invitations_pagination, pagination_metadata(invitations_page))
       |> assign_visible_sent_invitations(invitations_page.entries)
       |> stream(:sent_invitations, invitations_page.entries, reset: true)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_event("search_invitations", %{"invitation_search" => %{"q" => query}}, socket) do
    next_query = normalize_invitations_search_query(query)

    if next_query == socket.assigns.invitations_search_query do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:invitations_search_query, next_query)
       |> assign(:invitations_pagination, default_invitations_pagination())
       |> assign_invitations(socket.assigns.current_profile)}
    end
  end

  def handle_event("search_invitations", _params, socket), do: {:noreply, socket}

  @impl true
  def handle_event("clear_invitations_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:invitations_search_query, "")
     |> assign(:invitations_pagination, default_invitations_pagination())
     |> assign_invitations(socket.assigns.current_profile)}
  end

  @impl true
  def handle_event("accept", %{"id" => id}, socket) do
    invitee = socket.assigns.current_profile
    invitation_id = String.to_integer(id)

    with %{} = invitation <- Social.get_pending_invitation_for_invitee(invitee, invitation_id),
         {:ok, _invitation} <- Social.accept_group_invitation(invitation, invitee) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Invitation accepted."))
       |> assign_invitations(invitee)}
    else
      nil ->
        {:noreply,
         put_flash(socket, :error, gettext("This invitation was accepted or has lapsed."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not accept invitation."))}
    end
  end

  # Another unique profile of the account, or a new one, accepts an invitation
  # to the current (unique) profile.
  def handle_event("accept_as_open", %{"id" => id}, socket) do
    account = socket.assigns.current_scope.account

    with %Profile{sharing: :unique} = invitee <- socket.assigns.current_profile,
         {invitation_id, ""} <- Integer.parse(to_string(id)),
         %GroupInvitation{} = invitation <-
           Social.get_pending_invitation_for_invitee(invitee, invitation_id) do
      choices = Social.invitation_profile_choices(account, invitation)

      {:noreply,
       assign(socket,
         accept_as: %{invitation: invitation, choices: choices},
         new_profile_form: nil
       )}
    else
      _gone ->
        {:noreply,
         put_flash(socket, :error, gettext("This invitation was accepted or has lapsed."))}
    end
  end

  # An invitation to the account: the current profile joins, or the person
  # picks another profile, or makes one, in the same window as above.
  def handle_event("account_invitation_accept", %{"id" => id}, socket) do
    account = socket.assigns.current_scope.account
    profile = socket.assigns.current_profile

    with %GroupAccountInvitation{} = invitation <- account_invitation(socket, id),
         {:ok, group} <- EmailInvitations.accept(account, invitation, profile) do
      {:noreply, enter_group_as(socket, profile, group)}
    else
      {:error, reason} -> {:noreply, accept_as_failed(socket, reason)}
      nil -> {:noreply, accept_as_failed(socket, :expired)}
    end
  end

  def handle_event("account_invitation_accept_as", %{"id" => id}, socket) do
    case account_invitation(socket, id) do
      %GroupAccountInvitation{} = invitation ->
        choices = EmailInvitations.choices(socket.assigns.current_scope.account, invitation)

        {:noreply,
         assign(socket,
           accept_as: %{invitation: invitation, choices: choices, account?: true},
           new_profile_form: nil
         )}

      nil ->
        {:noreply, accept_as_failed(socket, :expired)}
    end
  end

  def handle_event("account_invitation_delete", %{"id" => id}, socket) do
    account = socket.assigns.current_scope.account

    with %GroupAccountInvitation{} = invitation <- account_invitation(socket, id),
         :ok <- EmailInvitations.delete(account, invitation) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Invitation deleted."))
       |> assign_account_invitations()}
    else
      _gone -> {:noreply, put_flash(socket, :error, gettext("Invitation not found."))}
    end
  end

  def handle_event("accept_as_close", _params, socket),
    do: {:noreply, assign(socket, accept_as: nil, new_profile_form: nil)}

  def handle_event("welcome_close", _params, socket),
    do: {:noreply, assign(socket, accept_as: nil, new_profile_form: nil)}

  def handle_event("accept_as", _params, %{assigns: %{accept_as: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("accept_as", %{"profile" => profile_id}, socket) do
    account = socket.assigns.current_scope.account
    invitation = socket.assigns.accept_as.invitation

    with {id, ""} <- Integer.parse(to_string(profile_id)),
         %Profile{} = profile <- Social.get_profile_for_account(account, id),
         {:ok, _accepted} <- accept_with(socket.assigns.accept_as, account, profile) do
      {:noreply, enter_group_as(socket, profile, invitation.group)}
    else
      {:error, reason} -> {:noreply, accept_as_failed(socket, reason)}
      _not_held -> {:noreply, accept_as_failed(socket, :not_held)}
    end
  end

  def handle_event("accept_as_new", _params, %{assigns: %{accept_as: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("accept_as_new", _params, socket),
    do: {:noreply, assign(socket, :new_profile_form, ProfileComponents.welcome_form())}

  def handle_event("validate_profile", _params, %{assigns: %{accept_as: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("validate_profile", params, socket) do
    form = ProfileComponents.welcome_form(params["profile"] || %{}, :validate)
    {:noreply, assign(socket, :new_profile_form, form)}
  end

  def handle_event("create_profile", _params, %{assigns: %{accept_as: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("create_profile", params, socket) do
    account = socket.assigns.current_scope.account
    invitation = socket.assigns.accept_as.invitation
    attrs = ProfileComponents.welcome_attrs(params["profile"] || %{})

    create =
      if socket.assigns.accept_as[:account?],
        do: &EmailInvitations.create_profile_and_accept/3,
        else: &Social.create_profile_and_accept_invitation/3

    case create.(account, invitation, attrs) do
      {:ok, profile, %{} = group} ->
        {:noreply, enter_group_as(socket, profile, group)}

      {:ok, profile, nil} ->
        {:noreply,
         socket
         |> assign(accept_as: nil, new_profile_form: nil)
         |> put_flash(
           :error,
           gettext("Profile @%{username} is ready, but the invitation could not be accepted.",
             username: profile.username
           )
         )
         |> assign_invitations(socket.assigns.current_profile)}

      {:error, %Ecto.Changeset{data: %Profile{}} = changeset} ->
        {:noreply, assign(socket, :new_profile_form, to_form(changeset))}

      {:error, reason} ->
        {:noreply, accept_as_failed(socket, reason)}
    end
  end

  @impl true
  def handle_event("delete_invitation", %{"id" => id}, socket) do
    invitee = socket.assigns.current_profile
    invitation_id = String.to_integer(id)

    with %{} = invitation <- Social.get_group_invitation_for_invitee(invitee, invitation_id),
         {:ok, _invitation} <- Social.delete_group_invitation(invitation, invitee) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Invitation deleted."))
       |> assign_invitations(invitee)}
    else
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Invitation not found."))}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, gettext("Could not delete invitation."))}
    end
  end

  @impl true
  def handle_info(
        {:profile_invitations_updated, _profile_id},
        %{assigns: %{current_profile: nil}} = socket
      ),
      do: {:noreply, socket}

  def handle_info({:profile_invitations_updated, profile_id}, socket)
      when socket.assigns.current_profile.id == profile_id do
    {:noreply, assign_invitations(socket, socket.assigns.current_profile)}
  end

  def handle_info({:profile_invitations_updated, _profile_id}, socket), do: {:noreply, socket}

  def handle_info({:profile_share_invitations_updated, _profile_id}, socket),
    do: {:noreply, socket}

  def handle_info({:pending_invitations_count_updated, _profile_id, _count}, socket),
    do: {:noreply, socket}

  def handle_info({:profile_group_join_requests_updated, _profile_id}, socket),
    do: {:noreply, socket}

  def handle_info({:pending_group_join_requests_count_updated, _profile_id, _count}, socket),
    do: {:noreply, socket}

  def handle_info({:group_unread_counts_updated, profile_id, _group_id}, socket)
      when not is_nil(socket.assigns.current_profile) and
             socket.assigns.current_profile.id == profile_id do
    {:noreply, recount_unread(socket)}
  end

  def handle_info({:group_unread_counts_updated, _profile_id, _group_id}, socket),
    do: {:noreply, socket}

  def handle_info({:group_members_unread_changed, _group_id}, socket),
    do: {:noreply, recount_unread(socket)}

  # A deleted value leaves the counts that held it, with no query.
  def handle_info({:group_value_removed, group_id, value_id, creator_id}, socket) do
    with %{} = overview <- socket.assigns.unread_overview,
         false <- match?(%{id: ^creator_id}, socket.assigns.current_profile),
         {:ok, overview} <- Social.remove_unread_value(overview, group_id, value_id) do
      {:noreply,
       socket
       |> put_unread_overview(overview)
       |> maybe_push_root_group_unread_count()
       |> assign_group_unread_counts()}
    else
      _unchanged -> {:noreply, socket}
    end
  end

  # A value someone else posted is added to the counts without a query.
  def handle_info({:group_value_unread, unread}, socket) do
    member_ids = ProfileAuth.unread_groups(socket)

    case Social.add_unread_value(socket.assigns.unread_overview, unread, member_ids) do
      :counted ->
        {:noreply, socket}

      {:ok, overview} ->
        {:noreply,
         socket
         |> put_unread_overview(overview)
         |> maybe_push_root_group_unread_count()
         |> assign_group_unread_counts()}
    end
  end

  @impl true
  def handle_info({:account_profiles_updated, account_id}, socket)
      when socket.assigns.current_scope.account.id == account_id and
             is_nil(socket.assigns.current_profile) do
    {:noreply, push_navigate(socket, to: ~p"/profiles")}
  end

  def handle_info({:account_profiles_updated, account_id}, socket)
      when socket.assigns.current_scope.account.id == account_id do
    previous_profile = socket.private[:previous_current_profile]

    ProfileAuth.handle_current_profile_change(
      socket,
      fn socket, current_profile ->
        socket =
          socket
          |> put_private(:previous_current_profile, current_profile)
          |> ProfileAuth.sync_profile_subscription(previous_profile)

        {:noreply, assign_invitations(socket, current_profile)}
      end,
      fn socket ->
        socket =
          socket
          |> put_private(:previous_current_profile, nil)
          |> ProfileAuth.sync_profile_subscription(previous_profile)

        {:noreply, push_navigate(socket, to: ~p"/profiles")}
      end
    )
  end

  def handle_info({:account_profiles_updated, _account_id}, socket), do: {:noreply, socket}

  def handle_info({:account_invitations_updated, account_id}, socket)
      when socket.assigns.current_scope.account.id == account_id,
      do: {:noreply, assign_account_invitations(socket)}

  # A message no clause above knows (one that ProfileAuth passes on, or one a
  # newer server sends during a deploy) is left alone, not a crash.
  def handle_info(_message, socket), do: {:noreply, socket}

  defp accept_with(%{account?: true, invitation: invitation}, account, profile),
    do: EmailInvitations.accept(account, invitation, profile)

  defp accept_with(%{invitation: invitation}, account, profile),
    do: Social.accept_group_invitation_as(invitation, account, profile)

  defp account_invitation(socket, id) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> EmailInvitations.get(socket.assigns.current_scope.account, id)
      _not_an_id -> nil
    end
  end

  # The account's invitations by email and those the current profile sent,
  # narrowed by the search like the lists.
  defp assign_account_invitations(socket) do
    query = PotokIde.TextFold.fold(String.trim(socket.assigns.invitations_search_query))
    account = socket.assigns.current_scope.account

    sent =
      case socket.assigns.current_profile do
        %Profile{} = profile -> EmailInvitations.list_sent(profile)
        nil -> []
      end

    socket
    |> assign(
      :account_invitations,
      Enum.filter(EmailInvitations.list(account), &matches?(&1, query, [&1.inviter.username]))
    )
    |> assign(:sent_by_email, Enum.filter(sent, &matches?(&1, query, [&1.email])))
  end

  defp matches?(_invitation, "", _names), do: true

  defp matches?(invitation, query, names) do
    [invitation.group.name | names]
    |> Enum.reject(&is_nil/1)
    |> Enum.any?(&String.contains?(PotokIde.TextFold.fold(&1), query))
  end

  # The profile that came into the group becomes the current one, and the
  # group opens. The group's page reads the account's current profile as it
  # mounts.
  defp enter_group_as(socket, %Profile{} = profile, group) do
    {:ok, _account} = Accounts.set_current_profile(socket.assigns.current_scope.account, profile)

    socket
    |> assign(accept_as: nil, new_profile_form: nil)
    |> put_flash(
      :info,
      gettext("You joined the group as @%{username}.", username: profile.username)
    )
    |> push_navigate(to: ~p"/groups/#{group.id}")
  end

  defp accept_as_failed(socket, reason) do
    message =
      case reason do
        :already_member ->
          gettext("That profile is already a member of the group.")

        :member ->
          gettext("That profile is already a member of the group.")

        :blocked ->
          gettext("That profile is blocked in this group.")

        reason when reason in [:expired, :already_accepted, :lapsed, :not_found] ->
          gettext("This invitation was accepted or has lapsed.")

        _other ->
          gettext("Could not accept invitation.")
      end

    socket
    |> assign(accept_as: nil, new_profile_form: nil)
    |> put_flash(:error, message)
    |> assign_invitations(socket.assigns.current_profile)
  end

  # The unread overview comes first: the invitation lists read their groups'
  # counts from it.
  defp assign_invitations(socket, nil) do
    socket
    |> assign_account_invitations()
    |> assign_unread_overview()
    |> assign(:invitations_pagination, default_invitations_pagination())
    |> assign(:sent_invitations_pagination, default_sent_invitations_pagination())
    |> assign_visible_invitations([])
    |> assign_visible_sent_invitations([])
    |> stream(:invitations, [], reset: true)
    |> stream(:sent_invitations, [], reset: true)
    |> maybe_push_root_group_unread_count()
  end

  defp assign_invitations(socket, profile) do
    socket
    |> assign_account_invitations()
    |> assign_unread_overview()
    |> assign(:invitations_pagination, default_invitations_pagination())
    |> assign(:sent_invitations_pagination, default_sent_invitations_pagination())
    |> refresh_invitations(profile)
    |> refresh_sent_invitations(profile)
    |> maybe_push_root_group_unread_count()
  end

  defp refresh_invitations(socket, profile) do
    pagination = socket.assigns.invitations_pagination
    search = socket.assigns.invitations_search_query
    total_count = Social.count_group_invitations_for_invitee(profile, search: search)
    loaded_count = min(pagination.loaded_count, total_count)

    pagination =
      pagination
      |> Map.put(:loaded_count, loaded_count)
      |> Map.put(:total_count, total_count)
      |> Map.put(:has_more?, loaded_count < total_count)

    # The tab off screen only needs its count; picking it loads the list.
    if socket.assigns.section == "received" do
      invitations_page = invitations_page(profile, pagination, search, total_count)

      socket
      |> assign(:invitations_pagination, pagination_metadata(invitations_page))
      |> assign_visible_invitations(invitations_page.entries)
      |> stream(:invitations, invitations_page.entries, reset: true)
    else
      assign(socket, :invitations_pagination, pagination)
    end
  end

  defp refresh_sent_invitations(socket, profile) do
    pagination = socket.assigns.sent_invitations_pagination
    search = socket.assigns.invitations_search_query
    total_count = Social.count_group_invitations_for_inviter(profile, search: search)
    loaded_count = min(pagination.loaded_count, total_count)

    pagination =
      pagination
      |> Map.put(:loaded_count, loaded_count)
      |> Map.put(:total_count, total_count)
      |> Map.put(:has_more?, loaded_count < total_count)

    if socket.assigns.section == "sent" do
      invitations_page = sent_invitations_page(profile, pagination, search, total_count)

      socket
      |> assign(:sent_invitations_pagination, pagination_metadata(invitations_page))
      |> assign_visible_sent_invitations(invitations_page.entries)
      |> stream(:sent_invitations, invitations_page.entries, reset: true)
    else
      assign(socket, :sent_invitations_pagination, pagination)
    end
  end

  defp recount_unread(socket) do
    socket
    |> assign_unread_overview()
    |> maybe_push_root_group_unread_count()
    |> assign_group_unread_counts()
  end

  # One overview gives the header badge (its total) and the counts of the
  # invitations' groups.
  defp assign_unread_overview(socket) do
    put_unread_overview(socket, Social.unread_overview(socket.assigns.current_profile))
  end

  defp put_unread_overview(socket, overview) do
    socket
    |> assign(:unread_overview, overview)
    |> assign(:root_group_unread_count, overview.total)
  end

  defp maybe_push_root_group_unread_count(socket) do
    if connected?(socket) do
      push_event(socket, "root_group_unread_count_updated", %{
        count: socket.assigns.root_group_unread_count
      })
    else
      socket
    end
  end

  defp assign_group_unread_counts(%{assigns: %{current_profile: nil}} = socket) do
    assign(socket, :group_unread_counts, %{})
  end

  defp assign_group_unread_counts(socket) do
    group_ids =
      socket.assigns.visible_invitations
      |> Kernel.++(socket.assigns.visible_sent_invitations)
      |> Enum.map(& &1.group.id)
      |> Enum.uniq()

    assign(
      socket,
      :group_unread_counts,
      Social.unread_counts_for(socket.assigns.unread_overview, group_ids)
    )
  end

  defp assign_visible_invitations(socket, invitations) do
    socket
    |> assign(:visible_invitations, invitations)
    |> assign_group_unread_counts()
  end

  defp assign_visible_sent_invitations(socket, invitations) do
    socket
    |> assign(:visible_sent_invitations, invitations)
    |> assign_group_unread_counts()
  end

  defp invitations_page(%{} = profile, pagination, search_query, total_count \\ nil) do
    search = normalize_invitations_search_query(search_query)

    total_count =
      total_count || Social.count_group_invitations_for_invitee(profile, search: search)

    limit = pagination_limit(pagination)

    entries =
      Social.list_pending_invitations(profile,
        search: search,
        limit: limit,
        offset: 0
      )

    pagination_result(pagination, entries, total_count)
  end

  defp sent_invitations_page(%{} = profile, pagination, search_query, total_count \\ nil) do
    search = normalize_invitations_search_query(search_query)

    total_count =
      total_count || Social.count_group_invitations_for_inviter(profile, search: search)

    limit = pagination_limit(pagination)

    entries =
      Social.list_group_invitations_for_inviter(profile,
        search: search,
        limit: limit,
        offset: 0
      )

    pagination_result(pagination, entries, total_count)
  end

  # The tabs, in order: `{key, panel id, label, danger?}`.
  defp sections do
    [
      {"received", "invitations-received", pgettext("invitations tab", "Received"), false},
      {"sent", "invitations-sent", pgettext("invitations tab", "Sent"), false}
    ]
  end

  defp default_invitations_pagination do
    %{
      page: 1,
      per_page: @invitations_per_page,
      loaded_count: 0,
      total_count: 0,
      has_more?: false
    }
  end

  defp default_sent_invitations_pagination do
    %{
      page: 1,
      per_page: @sent_invitations_per_page,
      loaded_count: 0,
      total_count: 0,
      has_more?: false
    }
  end

  defp pagination_limit(%{page: page, per_page: per_page}), do: page * per_page

  defp pagination_result(pagination, entries, total_count) do
    loaded_count = length(entries)

    pagination
    |> Map.put(:loaded_count, loaded_count)
    |> Map.put(:total_count, total_count)
    |> Map.put(:has_more?, loaded_count < total_count)
    |> Map.put(:entries, entries)
  end

  defp pagination_metadata(%{entries: _entries} = pagination),
    do: Map.delete(pagination, :entries)

  defp normalize_invitations_search_query(query) when is_binary(query) do
    query
    |> String.trim()
    |> String.slice(0, 120)
  end

  defp normalize_invitations_search_query(_), do: ""

  # How long a waiting invitation still holds (`GroupInvitation.valid_days/0`).
  defp valid_for(invitation) do
    seconds = DateTime.diff(expires_at(invitation), DateTime.utc_now(:second))

    case div(seconds + 86_399, 86_400) do
      days when days > 1 ->
        ngettext("Valid for %{count} more day", "Valid for %{count} more days", days)

      _today ->
        gettext("Lapses within a day")
    end
  end

  defp expires_at(%GroupAccountInvitation{inserted_at: at}),
    do: DateTime.add(at, GroupInvitation.valid_days(), :day)

  defp expires_at(%GroupInvitation{} = invitation), do: GroupInvitation.expires_at(invitation)
end
