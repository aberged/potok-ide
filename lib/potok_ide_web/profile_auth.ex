defmodule PotokIdeWeb.ProfileAuth do
  @moduledoc "LiveView helpers for loading and requiring the current Profile."

  use Gettext, backend: PotokIdeWeb.Gettext

  import Phoenix.LiveView

  alias PotokIde.Accounts
  alias PotokIde.Social

  # Same debounce as the group page's refreshes; 0 (the test config) recounts
  # right after the message. A random part of the spread is added so that a
  # big group's members do not all recount in the same instant.
  @unread_recount_delay_ms Application.compile_env(:potok_ide, :live_refresh_debounce_ms, 100)
  @unread_recount_spread_ms 1_000
  @transport_gc_delay_ms Application.compile_env(:potok_ide, :transport_gc_delay_ms, 2_000)

  # Views that count unread values themselves, the header badge included:
  # unread messages are passed on to them, and the badges' query leaves the
  # unread count out.
  @unread_counting_views [PotokIdeWeb.GroupLive.Show, PotokIdeWeb.InvitationLive.Index]

  def on_mount(:mount_current_profile, _params, _session, socket) do
    current_scope = socket.assigns[:current_scope]

    socket =
      Phoenix.Component.assign_new(socket, :current_profile, fn ->
        case current_scope do
          %{account: account} when not is_nil(account) ->
            Social.get_account_current_profile(account)

          _ ->
            nil
        end
      end)

    socket = PotokIdeWeb.AccountAuth.mount_nav_counts(socket)

    socket =
      socket
      |> sync_profile_subscription()
      |> schedule_transport_gc()

    socket =
      if (connected?(socket) and current_scope) && current_scope.account do
        Social.subscribe_account(current_scope.account)

        attach_hook(socket, :sync_current_profile, :handle_info, fn
          {:account_profiles_updated, account_id}, socket ->
            if socket.assigns.current_scope.account.id == account_id do
              previous_profile = socket.assigns.current_profile
              account = Accounts.get_account!(account_id)
              current_profile = Social.get_account_current_profile(account)
              counts_unread? = not counts_unread_itself?(socket)
              counts = Social.nav_counts(current_profile, unread: counts_unread?)

              socket =
                socket
                |> Phoenix.Component.assign(:current_scope, %{
                  socket.assigns.current_scope
                  | account: account
                })
                |> Phoenix.Component.assign(:current_profile, current_profile)
                |> Phoenix.Component.assign(
                  :pending_invitations_count,
                  counts.pending_invitations
                )
                |> Phoenix.Component.assign(
                  :pending_group_join_requests_count,
                  counts.pending_group_join_requests
                )
                |> maybe_put_root_unread(counts, counts_unread?)
                |> sync_profile_subscription(previous_profile)
                |> push_current_profile_updated(current_profile)
                |> push_pending_invitations_count_updated(counts.pending_invitations)
                |> push_pending_group_join_requests_count_updated(
                  counts.pending_group_join_requests
                )

              {:cont, socket}
            else
              {:cont, socket}
            end

          {:profile_invitations_updated, profile_id},
          %{assigns: %{current_profile: current_profile}} = socket
          when not is_nil(current_profile) and current_profile.id == profile_id ->
            count = pending_invitations_count(current_profile)

            {:cont,
             socket
             |> Phoenix.Component.assign(:pending_invitations_count, count)
             |> push_pending_invitations_count_updated(count)}

          {:pending_invitations_count_updated, profile_id, count},
          %{assigns: %{current_profile: current_profile}} = socket
          when not is_nil(current_profile) and current_profile.id == profile_id ->
            {:cont,
             socket
             |> Phoenix.Component.assign(:pending_invitations_count, count)
             |> push_pending_invitations_count_updated(count)}

          {:profile_group_join_requests_updated, profile_id},
          %{assigns: %{current_profile: current_profile}} = socket
          when not is_nil(current_profile) and current_profile.id == profile_id ->
            count = pending_group_join_requests_count(current_profile)

            {:cont,
             socket
             |> Phoenix.Component.assign(:pending_group_join_requests_count, count)
             |> push_pending_group_join_requests_count_updated(count)}

          {:pending_group_join_requests_count_updated, profile_id, count},
          %{assigns: %{current_profile: current_profile}} = socket
          when not is_nil(current_profile) and current_profile.id == profile_id ->
            {:cont,
             socket
             |> Phoenix.Component.assign(:pending_group_join_requests_count, count)
             |> push_pending_group_join_requests_count_updated(count)}

          # Reads, memberships and deleted values: the badge is recounted once
          # per burst. Only views that show unread counts themselves
          # (`counts_unread_itself?/1`) see these messages.
          {:group_unread_counts_updated, _profile_id, _group_id} = message, socket ->
            cond do
              counts_unread_itself?(socket) ->
                {:cont, socket}

              current_profile_message?(message, socket) ->
                {:halt, schedule_unread_recount(socket)}

              true ->
                {:halt, socket}
            end

          # A value someone else posted: one more unread, no query needed.
          {:group_value_unread, _profile_id, unread} = message, socket ->
            cond do
              counts_unread_itself?(socket) ->
                {:cont, socket}

              current_profile_message?(message, socket) ->
                {:halt, add_unread_value(socket, unread)}

              true ->
                {:halt, socket}
            end

          :recount_root_group_unread, socket ->
            {:halt,
             socket
             |> put_private(:unread_recount_scheduled, false)
             |> recount_root_group_unread()}

          _message, socket ->
            {:cont, socket}
        end)
      else
        socket
      end

    {:cont, socket}
  end

  def on_mount(:require_profile, _params, _session, socket) do
    if socket.assigns[:current_profile] do
      {:cont, socket}
    else
      {:halt,
       socket
       |> put_flash(:error, gettext("Please select or create a profile first."))
       |> redirect(to: "/profiles")}
    end
  end

  @doc """
  Whether the socket's LiveView counts unread values itself, the header
  badge included. Such a view gets `{:group_unread_counts_updated, ...}` and
  `{:group_value_unread, ...}` passed on instead of them being handled here,
  and its header badges are loaded without the unread count.
  """
  def counts_unread_itself?(socket), do: socket.view in @unread_counting_views

  def handle_current_profile_change(socket, on_present, on_missing)
      when is_function(on_present, 2) and is_function(on_missing, 1) do
    case socket.assigns.current_profile do
      nil -> on_missing.(socket)
      current_profile -> on_present.(socket, current_profile)
    end
  end

  def sync_profile_subscription(socket, previous_profile \\ nil) do
    current_profile = socket.assigns[:current_profile]
    subscribed_profile_id = socket.private[:subscribed_profile_id]

    socket =
      if connected?(socket) do
        if is_integer(subscribed_profile_id) and
             (is_nil(current_profile) or subscribed_profile_id != current_profile.id) do
          profile_to_unsubscribe = previous_profile || %{id: subscribed_profile_id}
          Social.unsubscribe_profile(profile_to_unsubscribe)
        end

        if current_profile && current_profile.id != subscribed_profile_id do
          Social.subscribe_profile(current_profile)
        end

        socket
      else
        socket
      end

    put_private(socket, :subscribed_profile_id, current_profile && current_profile.id)
  end

  # Rendering a page passes its whole first render through the websocket's
  # transport process, whose heap then keeps that garbage while the socket
  # idles: ~1 MB per connection, ~12 KB once collected. Phoenix collects on
  # `:garbage_collect`; this asks for it once the join reply is out.
  #
  # The LiveView process keeps the same kind of garbage from its mount and
  # first render (~180 KB, ~60 KB live), and with values arriving every few
  # seconds it never idles long enough to hibernate, which would shrink it.
  # LiveView has no `:garbage_collect` message, so a hook collects once.
  defp schedule_transport_gc(socket) do
    delay = transport_gc_delay_ms()

    if delay && connected?(socket) do
      Process.send_after(socket.transport_pid, :garbage_collect, delay)
      Process.send_after(self(), :collect_first_render_garbage, delay)

      attach_hook(socket, :collect_first_render_garbage, :handle_info, fn
        :collect_first_render_garbage, socket ->
          :erlang.garbage_collect(self())
          {:halt, detach_hook(socket, :collect_first_render_garbage, :handle_info)}

        _message, socket ->
          {:cont, socket}
      end)
    else
      socket
    end
  end

  defp transport_gc_delay_ms, do: @transport_gc_delay_ms

  defp current_profile_message?({_event, profile_id, _group_id}, socket) do
    match?(%{id: ^profile_id}, socket.assigns[:current_profile])
  end

  defp schedule_unread_recount(socket) do
    case unread_recount_delay_ms() do
      0 ->
        recount_root_group_unread(socket)

      delay ->
        if socket.private[:unread_recount_scheduled] do
          socket
        else
          Process.send_after(
            self(),
            :recount_root_group_unread,
            delay + :rand.uniform(@unread_recount_spread_ms)
          )

          put_private(socket, :unread_recount_scheduled, true)
        end
    end
  end

  defp unread_recount_delay_ms, do: @unread_recount_delay_ms

  # The badge's count already holds the values up to its `as_of`; without one
  # (the count failed, or another one is shown) the badge is recounted.
  defp add_unread_value(socket, %{value_id: value_id}) do
    case socket.private[:root_unread_as_of] do
      nil ->
        schedule_unread_recount(socket)

      as_of when value_id <= as_of ->
        socket

      _as_of ->
        count = socket.assigns.root_group_unread_count + 1

        socket
        |> Phoenix.Component.assign(:root_group_unread_count, count)
        |> push_root_group_unread_count_updated(count)
    end
  end

  # A view that counts unread values itself shows its own count, so the
  # badges' query left it out.
  defp maybe_put_root_unread(socket, _counts, false), do: socket

  defp maybe_put_root_unread(socket, counts, true) do
    socket
    |> Phoenix.Component.assign(:root_group_unread_count, counts.root_unread)
    |> put_private(:root_unread_as_of, counts.root_unread_as_of)
    |> push_root_group_unread_count_updated(counts.root_unread)
  end

  defp recount_root_group_unread(socket) do
    %{count: count, as_of: as_of} =
      Social.root_group_unread_snapshot(socket.assigns.current_profile)

    socket
    |> Phoenix.Component.assign(:root_group_unread_count, count)
    |> put_private(:root_unread_as_of, as_of)
    |> push_root_group_unread_count_updated(count)
  end

  defp push_current_profile_updated(socket, nil) do
    push_event(socket, "current_profile_updated", %{username: nil, profile_picture_url: nil})
  end

  defp push_current_profile_updated(socket, profile) do
    push_event(socket, "current_profile_updated", %{
      id: profile.id,
      username: profile.username,
      profile_picture_url: profile_picture_url(profile)
    })
  end

  defp push_pending_invitations_count_updated(socket, count) do
    push_event(socket, "pending_invitations_count_updated", %{count: count})
  end

  defp push_pending_group_join_requests_count_updated(socket, count) do
    push_event(socket, "pending_group_join_requests_count_updated", %{count: count})
  end

  defp push_root_group_unread_count_updated(socket, count) do
    push_event(socket, "root_group_unread_count_updated", %{count: count})
  end

  defp profile_picture_url(profile), do: PotokIdeWeb.Avatars.profile_avatar_url(profile)

  defp pending_invitations_count(nil), do: 0
  defp pending_invitations_count(profile), do: Social.count_pending_invitations(profile)

  defp pending_group_join_requests_count(nil), do: 0

  defp pending_group_join_requests_count(profile) do
    Social.count_pending_group_join_requests_for_approver(profile)
  end
end
