defmodule PotokIdeWeb.NoticeLive.Index do
  @moduledoc """
  The notices of the groups the current profile follows, newest first, and
  the groups it follows with their push switches.

  Opening the page reads every notice: the ones unread until then keep their
  mark while the page is open. One that arrives meanwhile comes on top, marked
  and already read, so the badge never counts it (`ProfileAuth` passes the
  profile's `{:notices, _}` messages here).
  """

  use PotokIdeWeb, :live_view

  alias PotokIde.Notices
  alias PotokIdeWeb.GroupLive.Show.Components
  alias PotokIdeWeb.NoticeComponents
  alias PotokIdeWeb.ProfileAuth

  @sections ~w(received followed)

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
      unread_notices_count={@unread_notices_count}
      full_width
    >
      <.page_container id="notices-page">
        <.page_header id="notices-header" icon="hero-bell">
          {gettext("Notices")}
          <:subtitle>
            {gettext("What the groups your current profile follows send to their followers.")}
          </:subtitle>
        </.page_header>

        <Components.settings_tabs
          id="notices-sections"
          tabs={sections()}
          current={@section}
          event="set_section"
          tab_id_prefix="notices-tab"
          counts={%{"followed" => @followed_count}}
        />

        <Components.settings_card
          id="notices-received"
          tab_id="notices-tab-received"
          active={@section == "received"}
          icon="hero-bell"
          title={gettext("Received notices")}
          subtitle={gettext("Opening this page reads them all.")}
        >
          <div id="notices" phx-update="stream" class="space-y-3">
            <p
              id="notices-empty"
              class="hidden rounded-2xl border border-base-300/60 bg-base-100/70 px-4 py-3 text-sm text-base-content/70 only:block"
            >
              {gettext("No notices yet. Follow a group and its notices come here.")}
            </p>
            <article
              :for={{dom_id, row} <- @streams.notices}
              id={dom_id}
              data-unread={row.unread? && "true"}
              class={[
                "relative rounded-2xl border px-3 py-3 transition",
                if(row.unread?,
                  do: "border-primary/40 bg-primary/5",
                  else: "border-base-300/70 bg-base-100/80"
                )
              ]}
            >
              <span
                :if={row.unread?}
                id={"#{dom_id}-unread"}
                class="absolute right-3 top-3 size-2.5 rounded-full bg-primary"
                title={gettext("New")}
              >
                <span class="sr-only">{gettext("New")}</span>
              </span>
              <Components.group_identity
                group={row.group}
                current_profile={@current_profile}
                avatar_size="size-10"
                navigate={~p"/groups/#{row.group.id}/notices?notice=#{row.notice.id}"}
              >
                <:subtitle>
                  <Components.local_time
                    id={"#{dom_id}-time"}
                    datetime={row.notice.inserted_at}
                    class="text-xs text-base-content/60"
                  />
                </:subtitle>
              </Components.group_identity>
              <NoticeComponents.notice_body body={row.notice.body} class="mt-2 px-1" />
            </article>
          </div>

          <div :if={@notices_more?} class="mt-4 flex justify-center">
            <.button id="notices-load-more" type="button" phx-click="load_more" size="sm">
              {gettext("Load more")}
            </.button>
          </div>
        </Components.settings_card>

        <Components.settings_card
          id="notices-followed"
          tab_id="notices-tab-followed"
          active={@section == "followed"}
          icon="hero-user-group"
          title={gettext("Followed groups")}
          subtitle={gettext("Each group can push to your devices or not. A group's bell follows it.")}
        >
          <div
            :if={!@current_profile.notice_push}
            class="mb-3 rounded-2xl border border-warning/40 bg-warning/10 px-4 py-3"
          >
            <NoticeComponents.push_off_note id="notices-push-off" />
          </div>

          <div id="followed-groups" phx-update="stream" class="space-y-3">
            <p
              id="followed-groups-empty"
              class="hidden rounded-2xl border border-base-300/60 bg-base-100/70 px-4 py-3 text-sm text-base-content/70 only:block"
            >
              {gettext("You follow no group yet. Open a group and tap its bell.")}
            </p>
            <div
              :for={{dom_id, follow} <- @streams.followed_groups}
              id={dom_id}
              class="rounded-2xl border border-base-300/70 bg-base-100/80 px-3 py-3"
            >
              <Components.group_identity
                group={follow.group}
                current_profile={@current_profile}
                avatar_size="size-10"
                navigate={~p"/groups/#{follow.group.id}/notices"}
              />
              <div class="mt-2 flex flex-wrap items-center justify-between gap-2 px-1">
                <NoticeComponents.push_switch
                  id={"follow-push-#{follow.id}"}
                  checked={follow.push?}
                  disabled={!@current_profile.notice_push}
                  label={gettext("Push notifications")}
                  phx-click="set_follow_push"
                  phx-value-group-id={follow.id}
                  phx-value-push={to_string(!follow.push?)}
                />
                <.button
                  id={"unfollow-#{follow.id}"}
                  type="button"
                  phx-click="unfollow"
                  phx-value-group-id={follow.id}
                  variant="ghost"
                  size="sm"
                >
                  {gettext("Stop following")}
                </.button>
              </div>
            </div>
          </div>
        </Components.settings_card>
      </.page_container>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> put_private(:previous_current_profile, socket.assigns.current_profile)
     |> assign(:section, "received")
     |> stream_configure(:notices, dom_id: &"notice-#{&1.notice.id}")
     |> stream_configure(:followed_groups, dom_id: &"followed-group-#{&1.id}")
     |> ProfileAuth.sync_profile_subscription()
     |> load(socket.assigns.current_profile)}
  end

  # The list is read before it is marked read, so the unread keep their mark.
  defp load(socket, profile) do
    %{entries: rows, more?: more?} = Notices.list_received(profile)

    socket =
      if connected?(socket) do
        Notices.mark_all_read(profile)
        assign(socket, :unread_notices_count, 0)
      else
        socket
      end

    socket
    |> assign(:notices_more?, more?)
    |> assign(:notices_oldest_id, oldest_id(rows))
    |> stream(:notices, rows, reset: true)
    |> load_followed(profile)
  end

  defp load_followed(socket, profile) do
    followed =
      for {group, push?} <- Notices.list_followed_groups(profile),
          do: %{id: group.id, group: group, push?: push?}

    socket
    |> assign(:followed_count, length(followed))
    |> stream(:followed_groups, followed, reset: true)
  end

  @impl true
  def handle_event("set_section", %{"section" => section}, socket) when section in @sections,
    do: {:noreply, assign(socket, :section, section)}

  def handle_event("load_more", _params, socket) do
    %{entries: rows, more?: more?} =
      Notices.list_received(socket.assigns.current_profile,
        before_id: socket.assigns.notices_oldest_id
      )

    {:noreply,
     socket
     |> assign(:notices_more?, more?)
     |> assign(:notices_oldest_id, oldest_id(rows) || socket.assigns.notices_oldest_id)
     |> stream(:notices, rows)}
  end

  def handle_event("set_follow_push", %{"group-id" => group_id, "push" => push}, socket) do
    profile = socket.assigns.current_profile

    with {group_id, ""} <- Integer.parse(group_id),
         :ok <- Notices.set_follow_push(profile, group_id, push == "true") do
      {:noreply, load_followed(socket, profile)}
    else
      _not_following -> {:noreply, socket}
    end
  end

  def handle_event("unfollow", %{"group-id" => group_id}, socket) do
    profile = socket.assigns.current_profile

    case Integer.parse(group_id) do
      {group_id, ""} ->
        Notices.unfollow(profile, group_id)
        {:noreply, load_followed(socket, profile)}

      _other ->
        {:noreply, socket}
    end
  end

  # A notice that arrives while the page is open is read on it.
  @impl true
  def handle_info({:notices, {:received, profile_id, notice_id, _group_id}}, socket)
      when profile_id == socket.assigns.current_profile.id do
    profile = socket.assigns.current_profile

    case Notices.get_received(profile, notice_id) do
      nil ->
        {:noreply, socket}

      row ->
        Notices.mark_read(profile, notice_id)
        {:noreply, stream_insert(socket, :notices, row, at: 0)}
    end
  end

  def handle_info({:notices, {:deleted, _profile_id, notice_id, _group_id, _unread?}}, socket),
    do: {:noreply, stream_delete_by_dom_id(socket, :notices, "notice-#{notice_id}")}

  # A follow changed here or on another page; the profile's own switch is in
  # `current_profile` already, and the switches in the list follow it.
  def handle_info({:notices, {change, profile_id, _}}, socket)
      when change in [:follow_changed, :push_changed] and
             profile_id == socket.assigns.current_profile.id do
    {:noreply, load_followed(socket, socket.assigns.current_profile)}
  end

  def handle_info({:account_profiles_updated, account_id}, socket)
      when socket.assigns.current_scope.account.id == account_id do
    previous_profile = socket.private[:previous_current_profile]

    ProfileAuth.handle_current_profile_change(
      socket,
      fn socket, current_profile ->
        {:noreply,
         socket
         |> put_private(:previous_current_profile, current_profile)
         |> ProfileAuth.sync_profile_subscription(previous_profile)
         |> load(current_profile)}
      end,
      fn socket ->
        {:noreply,
         socket
         |> put_private(:previous_current_profile, nil)
         |> ProfileAuth.sync_profile_subscription(previous_profile)
         |> push_navigate(to: ~p"/profiles")}
      end
    )
  end

  # The profile's other messages (invitations, unread values, ...) concern the
  # header, which `ProfileAuth` keeps.
  def handle_info(_message, socket), do: {:noreply, socket}

  defp sections do
    [
      {"received", "notices-received", gettext("Received"), false},
      {"followed", "notices-followed", gettext("Followed groups"), false}
    ]
  end

  defp oldest_id([]), do: nil
  defp oldest_id(rows), do: List.last(rows).notice.id
end
