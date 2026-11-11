defmodule PotokIdeWeb.GroupLive.Show.NoticesState do
  @moduledoc """
  What `GroupLive.Show` holds about following its group and the group's
  notices: the bell in the header, the notices tab and its composer.
  `GroupLive.Show` delegates every `"notice_*"` event and the `{:notices, _}`
  and `{:group_notices, _}` messages here.

  `notice_state` is loaded once, when the page mounts or its profile changes,
  and kept by the page's own actions and messages afterwards, so a refresh of
  the page costs no query for it. The URL's `?notice=` marks one notice.
  """

  use PotokIdeWeb, :verified_routes
  use Gettext, backend: PotokIdeWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 2]

  import Phoenix.LiveView,
    only: [
      connected?: 1,
      put_flash: 3,
      stream: 3,
      stream: 4,
      stream_configure: 3,
      stream_delete_by_dom_id: 3,
      stream_insert: 4
    ]

  alias PotokIde.Notices
  alias PotokIde.Notices.GroupNotice
  alias PotokIde.Social.Group
  alias PotokIdeWeb.RateLimited

  ## Setup

  def init(socket, params) do
    %{group: group, current_profile: profile, access: access} = socket.assigns

    if connected?(socket) and Notices.followable?(group), do: Notices.subscribe_group(group)

    socket
    |> assign(
      notices_more?: false,
      notices_oldest_id: nil,
      notices_empty?: true
    )
    |> stream_configure(:group_notices, dom_id: &"group-notice-#{&1.id}")
    |> stream(:group_notices, [], reset: true)
    |> put_state(group, profile, access)
    |> assign_params(params)
  end

  @doc "Loads the follow and the rights again, for a new profile or new rights."
  def reload(socket, %Group{} = group, access) do
    put_state(socket, group, socket.assigns.current_profile, access)
  end

  defp put_state(socket, group, profile, access) do
    state =
      if Notices.followable?(group),
        do: Notices.group_state(group, profile),
        else: %{notices?: false, following?: false, push?: false, followers: 0}

    can_send? = not is_nil(profile) and Notices.can_send?(access, group)

    socket
    |> assign(:notice_state, state)
    |> assign(:can_follow_group?, Notices.can_follow?(profile, group, access))
    |> assign(:can_send_notices?, can_send?)
    # A draft being written stays through a reload of the rights.
    |> assign(:notice_form, if(can_send?, do: socket.assigns[:notice_form] || empty_form()))
  end

  def assign_params(socket, params) do
    assign(socket, :notice_focus_id, parse_id(Map.get(params, "notice")))
  end

  @doc "Whether the section bar has a place for notices: once the group has sent one."
  def section?(%{notice_state: %{notices?: notices?}}), do: notices?

  ## Loading

  def maybe_load(socket, %Group{} = group, "notices") do
    profile = socket.assigns.current_profile
    %{entries: notices, more?: more?} = Notices.list_group_notices(group)
    if profile, do: Notices.mark_group_read(profile, group)

    socket
    |> assign(:notices_more?, more?)
    |> assign(:notices_oldest_id, oldest_id(notices))
    |> assign(:notices_empty?, notices == [])
    |> stream(:group_notices, notices, reset: true)
  end

  def maybe_load(socket, _group, _active_tab), do: socket

  ## Events

  def handle_event("notice_follow", _params, socket) do
    %{current_profile: profile, group: group} = socket.assigns

    case profile && Notices.follow(profile, group) do
      {:ok, follow} ->
        {:noreply,
         socket
         |> update_state(&%{&1 | following?: true, push?: follow.push})
         |> refresh_followers()
         |> put_flash(:info, gettext("You follow %{group}.", group: group.name))}

      _refused ->
        {:noreply, put_flash(socket, :error, gettext("You cannot follow this group."))}
    end
  end

  def handle_event("notice_unfollow", _params, socket) do
    %{current_profile: profile, group: group} = socket.assigns
    if profile, do: Notices.unfollow(profile, group.id)

    {:noreply,
     socket
     |> update_state(&%{&1 | following?: false, push?: false})
     |> refresh_followers()}
  end

  def handle_event("notice_follow_push", %{"push" => push}, socket) do
    %{current_profile: profile, group: group} = socket.assigns
    push? = push == "true"

    case profile && Notices.set_follow_push(profile, group.id, push?) do
      :ok -> {:noreply, update_state(socket, &%{&1 | push?: push?})}
      _not_following -> {:noreply, socket}
    end
  end

  def handle_event("notice_validate", %{"notice" => attrs}, socket) do
    form =
      attrs
      |> Notices.change_notice()
      |> Map.put(:action, :validate)
      |> to_form(as: "notice")

    {:noreply, assign(socket, :notice_form, form)}
  end

  def handle_event("notice_send", %{"notice" => attrs}, socket) do
    %{current_profile: profile, group: group, access: access} = socket.assigns

    case Notices.send_notice(profile, group, access, attrs) do
      {:ok, notice} ->
        notice = %{notice | creator: profile}

        {:noreply,
         socket
         |> assign(:notice_form, empty_form())
         |> assign(:notices_empty?, false)
         |> update_state(&%{&1 | notices?: true})
         |> stream_insert(:group_notices, notice, at: 0)
         |> put_flash(
           :info,
           ngettext(
             "The notice went to %{count} follower.",
             "The notice went to %{count} followers.",
             notice.recipients_count
           )
         )}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :notice_form, to_form(changeset, as: "notice"))}

      {:error, {:rate_limited, retry_after}} ->
        {:noreply, put_flash(socket, :error, RateLimited.message(retry_after))}

      {:error, :not_allowed} ->
        {:noreply, put_flash(socket, :error, gettext("You cannot send notices here."))}
    end
  end

  def handle_event("notice_delete", %{"id" => id}, socket) do
    %{current_profile: profile, group: group, access: access} = socket.assigns

    with %{} <- profile,
         id when is_integer(id) <- parse_id(id),
         {:ok, notice} <- Notices.delete_notice(profile, group, access, id) do
      {:noreply,
       socket
       |> stream_delete_by_dom_id(:group_notices, "group-notice-#{notice.id}")
       |> put_flash(:info, gettext("The notice is deleted."))}
    else
      _refused -> {:noreply, put_flash(socket, :error, gettext("You cannot delete this notice."))}
    end
  end

  def handle_event("notice_load_more", _params, socket) do
    %{entries: notices, more?: more?} =
      Notices.list_group_notices(socket.assigns.group,
        before_id: socket.assigns.notices_oldest_id
      )

    {:noreply,
     socket
     |> assign(:notices_more?, more?)
     |> assign(:notices_oldest_id, oldest_id(notices) || socket.assigns.notices_oldest_id)
     |> stream(:group_notices, notices)}
  end

  ## Messages

  @doc "What the group's own topic says: a notice was sent or deleted here."
  def handle_info({:posted, notice_id}, socket) do
    %{group: group, current_profile: profile, active_tab: active_tab} = socket.assigns
    socket = update_state(socket, &%{&1 | notices?: true})

    with "notices" <- active_tab,
         %GroupNotice{} = notice <- Notices.get_group_notice(group, notice_id) do
      # It is on screen, so it is read.
      if profile, do: Notices.mark_read(profile, notice.id)

      {:noreply,
       socket
       |> assign(:notices_empty?, false)
       |> stream_insert(:group_notices, notice, at: 0)}
    else
      _elsewhere -> {:noreply, socket}
    end
  end

  def handle_info({:removed, notice_id}, socket) do
    {:noreply, stream_delete_by_dom_id(socket, :group_notices, "group-notice-#{notice_id}")}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @doc "What the profile's topic says that this page shows: its follow of this group changed."
  def handle_profile_message({:follow_changed, _profile_id, group_id}, socket)
      when group_id == socket.assigns.group.id do
    {:noreply, reload(socket, socket.assigns.group, socket.assigns.access)}
  end

  def handle_profile_message(_message, socket), do: {:noreply, socket}

  ## Helpers

  defp update_state(socket, fun),
    do: assign(socket, :notice_state, fun.(socket.assigns.notice_state))

  defp refresh_followers(socket) do
    %{followers: followers} = Notices.group_state(socket.assigns.group, nil)
    update_state(socket, &%{&1 | followers: followers})
  end

  defp empty_form, do: to_form(Notices.change_notice(), as: "notice")

  defp oldest_id([]), do: nil
  defp oldest_id(notices), do: notices |> List.last() |> Map.fetch!(:id)

  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} -> id
      _other -> nil
    end
  end

  defp parse_id(_id), do: nil
end
