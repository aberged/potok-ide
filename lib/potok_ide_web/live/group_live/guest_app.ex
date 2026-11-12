defmodule PotokIdeWeb.GroupLive.GuestApp do
  @moduledoc """
  An app from a public group's description, for a guest: a visitor without an
  account at a group that opened its description to guests
  (`Group.guest_description?/1`). It sits inside the plain page
  `PotokIdeWeb.PublicPreview` renders, which shows text with no process at
  all; an app needs this one, as it talks to Potok through `AppApi`.

  The guest has no profile, so `AppApi` answers only what anyone may read:
  the public groups below, with the descriptions of those open to guests, a
  map of them, public polls, and what public rules of the app's values show.
  It writes nothing, reacts to nothing and votes in nothing. A sub-group opens
  over the app as text (`GuestSheet`), and its own page is a link away.

  It follows no topic of the group, which carries every message and would wake
  each sleeping guest. Instead it asks again whether guests still read the
  description when a call comes after `:guest_recheck_ms`, and only an app
  that reads polls follows them. A changed app reaches guests when they load
  the page again.
  """
  use PotokIdeWeb, :live_view

  alias PotokIde.{Cache, RateLimit, Social}
  alias PotokIde.Social.{Access, Group}
  alias PotokIdeWeb.GroupLive.GuestSheet
  alias PotokIdeWeb.GroupLive.Show.{AppApi, GroupDescriptionTab, PollsState}
  alias PotokIdeWeb.GuestDescriptions

  on_mount {PotokIdeWeb.Locale, :mount_locale}
  on_mount {PotokIdeWeb.ProfileAuth, :collect_socket_garbage}

  @poll_methods ~w(list_polls get_poll)

  # How long the cache keeps one copy of an app's code for all its guests.
  @html_ttl :timer.minutes(10)
  # Below this a copy of its own costs a process less than looking one up.
  @shared_html_bytes 4_096

  @impl true
  def render(assigns) do
    ~H"""
    <div id="guest-app-body" class="flex min-h-0 flex-1 flex-col">
      <div
        :if={@unavailable?}
        id="guest-app-unavailable"
        class="flex flex-1 flex-col items-center justify-center gap-2 px-6 py-12 text-center text-sm text-base-content/65"
      >
        <.icon name="hero-eye-slash" class="size-6" />
        <p>{gettext("This description is no longer open to guests.")}</p>
      </div>
      <GroupDescriptionTab.panel
        :if={!@unavailable?}
        group={@group}
        alt_descriptions={@visible_alt_descriptions}
        active_alt_description={@active_alt_description}
        switcher={false}
      />
      <GuestSheet.dialog :if={!@unavailable?} sheet={@guest_sheet} />
    </div>
    """
  end

  @impl true
  def mount(:not_mounted_at_router, session, socket) do
    with group_id when is_integer(group_id) <- session["group_id"],
         alt_id when is_nil(alt_id) or is_integer(alt_id) <- session["alt_id"],
         %Group{} = group <- Social.get_public_group(group_id),
         %{uses_api: true} = entry <-
           group |> GuestDescriptions.entries() |> Enum.find(&(&1.id == alt_id)),
         source when not is_nil(source) <- GuestDescriptions.source(group, entry) do
      alt = if entry.id, do: shared(source)

      {:ok,
       socket
       |> assign(
         current_scope: nil,
         current_profile: nil,
         access: Access.for_profile(nil, group),
         is_member: false,
         group: shared(group),
         active_alt_description: alt,
         visible_alt_descriptions: List.wrap(alt),
         client: session["client"],
         checked_at: System.monotonic_time(:millisecond),
         unavailable?: false,
         # What the shared description code reads of a page (`Show`).
         in_group_sheet: false,
         active_tab: "group_home",
         description_param: nil,
         loaded_value_ids: MapSet.new(),
         app_api_bucket: AppApi.new_bucket(),
         app_upload: nil
       )
       |> GuestSheet.init()
       |> PollsState.init_dialog(), layout: false}
    else
      _closed ->
        {:ok, assign(socket, unavailable?: true, group: nil, guest_sheet: nil), layout: false}
    end
  end

  # Every guest at the same app holds the same copy of its code: an app can
  # run to hundreds of kilobytes, and each process would read its own.
  defp shared(%{description: html} = source)
       when is_binary(html) and byte_size(html) > @shared_html_bytes do
    key = {:guest_app_html, :crypto.hash(:sha256, html)}

    %{source | description: Cache.fetch(key, @html_ttl, fn -> :binary.copy(html) end)}
  end

  defp shared(source), do: source

  @impl true
  def handle_event("app_api", %{"method" => method} = params, socket) when is_binary(method) do
    with {:ok, socket} <- still_open(socket),
         :ok <- client_turn(socket) do
      {reply, socket} =
        socket
        |> follow_polls(method)
        |> then(
          &AppApi.call(method, Map.get(params, "params") || %{}, Map.get(params, "app_id"), &1)
        )

      {:reply, reply, socket}
    else
      {:closed, socket} -> {:reply, %{ok: false, error: "unavailable"}, socket}
      {:error, reply} -> {:reply, reply, socket}
    end
  end

  def handle_event("app_api", _params, socket) do
    {:reply, %{ok: false, error: "unknown_method"}, socket}
  end

  def handle_event("guest_sheet_close", _params, socket),
    do: {:noreply, GuestSheet.close(socket)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def handle_info(_message, %{assigns: %{unavailable?: true}} = socket), do: {:noreply, socket}

  def handle_info({:polls, message}, socket), do: PollsState.handle_info(message, socket)

  def handle_info(_message, socket), do: {:noreply, socket}

  # Asks again whether guests read the description, at most once in
  # `:guest_recheck_ms`: closing it cuts the guests off within that time.
  defp still_open(%{assigns: %{unavailable?: true}} = socket), do: {:closed, socket}

  defp still_open(socket) do
    %{group: group, active_alt_description: alt, checked_at: checked_at} = socket.assigns
    now = System.monotonic_time(:millisecond)

    cond do
      now - checked_at < recheck_ms() ->
        {:ok, socket}

      Social.guest_description_open?(group.id, alt && alt.id) ->
        {:ok, assign(socket, :checked_at, now)}

      true ->
        {:closed, socket |> GuestSheet.close() |> assign(:unavailable?, true)}
    end
  end

  defp recheck_ms, do: Application.get_env(:potok_ide, :guest_recheck_ms, :timer.minutes(1))

  # What one address asks of the apps, all the pages of its guests together.
  defp client_turn(%{assigns: %{client: client}}) when is_binary(client) do
    case RateLimit.hit(:app_guest_client, client) do
      :ok ->
        :ok

      {:error, :rate_limited, _retry_after} ->
        {:error,
         %{
           ok: false,
           error: "rate_limited",
           message: gettext("Too many requests in a short time. Try again shortly.")
         }}
    end
  end

  defp client_turn(_socket), do: :ok

  # Only an app that reads polls follows them, so the others never wake for a vote.
  defp follow_polls(%{assigns: %{poll_subscribed: subscribed}} = socket, method)
       when method in @poll_methods do
    if MapSet.size(subscribed) == 0,
      do: PollsState.maybe_load(socket, socket.assigns.group, "group_home"),
      else: socket
  end

  defp follow_polls(socket, _method), do: socket
end
