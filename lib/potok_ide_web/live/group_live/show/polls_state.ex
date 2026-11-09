defmodule PotokIdeWeb.GroupLive.Show.PollsState do
  @moduledoc """
  What `GroupLive.Show` holds about polls: the numbers on the page, the overview
  tab, and the dialog an app opens. `GroupLive.Show` delegates every `"poll_*"`
  and `"polls_*"` event and `{:polls, _}` message here, and hands every value it
  puts in the chat's stream to `with_views/2`.

  The numbers live in `poll_tallies`, which `Components.poll_tally_css/1` turns
  into a style sheet of the page. They hold only what `PotokIde.Polls.Rules`
  shows this viewer, and a vote updates them from its own message with no query
  and no message sent again, however many people vote at once. A page drops a
  count it was not allowed to show, as what it keeps comes from the view.

  The URL holds the overview's filter (`?status=closed`) and the open poll
  (`poll=12`). The root's switches are kept by the browser, as the calendar's.
  """

  use PotokIdeWeb, :verified_routes
  use Gettext, backend: PotokIdeWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3]

  import Phoenix.LiveView,
    only: [
      connected?: 1,
      get_connect_params: 1,
      push_event: 3,
      push_patch: 2,
      put_flash: 3,
      stream: 3,
      stream: 4,
      stream_configure: 3
    ]

  require Logger

  alias PotokIde.Polls
  alias PotokIde.Polls.{Poll, Stats, View}
  alias PotokIde.Social
  alias PotokIde.Social.{Group, Value}
  alias PotokIdeWeb.GroupLive.Show
  alias PotokIdeWeb.GroupLive.Show.AppHost

  @statuses ~w(open waiting closed)

  # As the calendar's: other people's changes wait this long, 0 in tests.
  @debounce_ms Application.compile_env(:potok_ide, :live_refresh_debounce_ms, 100)
  @spread_ms 500

  ## Setup

  def init(socket, params) do
    {show_groups?, show_public?} = connect_filters(socket)

    socket
    |> assign(
      poll_tallies: %{},
      poll_pending: new_pending(),
      poll_flush_scheduled?: false,
      poll_subscribed: MapSet.new(),
      poll_dialog: nil,
      polls_scope: {:groups, []},
      polls_detail: nil,
      polls_include_subgroups?: false,
      polls_show_groups?: show_groups?,
      polls_show_public?: show_public?,
      polls_empty?: true,
      polls_more?: false,
      polls_oldest_id: nil
    )
    |> stream_configure(:polls, dom_id: &"poll-row-#{&1.id}")
    |> stream(:polls, [], reset: true)
    |> assign_params(params)
  end

  @doc """
  What a LiveView needs that shows only the dialog an app opens and follows its
  group's polls (`GroupLive.Sheet`): no overview, and no connect params, which
  a nested LiveView may not read. `maybe_load/3` then follows the group.
  """
  def init_dialog(socket) do
    assign(socket,
      poll_tallies: %{},
      poll_pending: new_pending(),
      poll_flush_scheduled?: false,
      poll_subscribed: MapSet.new(),
      poll_dialog: nil,
      polls_detail: nil,
      polls_status: "open",
      polls_poll_id: nil
    )
  end

  defp new_pending, do: %{tallies: %{}, list?: false, ids: MapSet.new()}

  # The root overview's switches as the viewer left them (`polls_filters` in
  # app.js); both are on until then.
  defp connect_filters(socket) do
    filters =
      with true <- connected?(socket),
           %{"polls_filters" => %{} = filters} <- get_connect_params(socket) do
        filters
      else
        _ -> %{}
      end

    {filters["groups"] != false, filters["public"] != false}
  end

  @doc "Takes the overview's URL params into assigns, without loading anything."
  def assign_params(socket, params) do
    assign(socket,
      polls_status: parse_status(params["status"]),
      polls_poll_id: parse_id(params["poll"])
    )
  end

  def params_changed?(socket, params) do
    parse_status(params["status"]) != socket.assigns.polls_status or
      parse_id(params["poll"]) != socket.assigns.polls_poll_id
  end

  def handle_params(socket, params) do
    status_changed? = parse_status(params["status"]) != socket.assigns.polls_status
    socket = assign_params(socket, params)

    if status_changed?,
      do: socket |> load_list() |> load_detail(),
      else: load_detail(socket)
  end

  defp parse_status(status) when status in @statuses, do: status
  defp parse_status(_status), do: "open"

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp parse_id(id) when is_integer(id), do: id
  defp parse_id(_id), do: nil

  @doc "The overview's URL in `group_id` with `changes` to the current params."
  def polls_path(socket, changes \\ []) do
    assigns = socket.assigns

    overview_path(
      assigns.group.id,
      Keyword.get(changes, :status, assigns.polls_status),
      Keyword.get(changes, :poll, assigns.polls_poll_id)
    )
  end

  defp overview_path(group_id, status, poll_id) do
    query =
      [status != "open" && {"status", status}, poll_id && {"poll", poll_id}]
      |> Enum.filter(& &1)

    ~p"/groups/#{group_id}/polls?#{query}"
  end

  ## Views

  @doc """
  What the viewer sees of the polls among `values`: the same values with their
  views on, and the socket holding their numbers. Every path of a value into the
  chat's stream goes through this, as the values come read for nobody in
  particular, or from a broadcast.
  """
  def with_views(%{assigns: %{current_profile: nil}} = socket, values), do: {socket, values}

  def with_views(socket, values) when is_list(values) do
    %{group: group, access: access, current_profile: profile, current_scope: scope} =
      socket.assigns

    values = Polls.put_views(values, group, access, profile, scope.account)
    views = for %Value{poll_view: %View{} = view} <- values, do: view

    {track(socket, views), values}
  end

  def with_views(socket, %Value{} = value) do
    {socket, [value]} = with_views(socket, [value])
    {socket, value}
  end

  defp track(socket, views) do
    tallies =
      Enum.reduce(views, socket.assigns.poll_tallies, fn
        %View{scope: :full} = view, tallies -> Map.put(tallies, view.poll_id, tally(view))
        %View{}, tallies -> tallies
      end)

    assign(socket, :poll_tallies, tallies)
  end

  defp tally(%View{results?: true} = view) do
    %{voters: view.voters_count, options: Map.new(view.options, &{&1.id, &1.votes_count})}
  end

  defp tally(%View{} = view), do: %{voters: view.voters_count, options: nil}

  ## The overview

  @doc """
  Loads the overview when it is the active tab. Every open page follows its own
  group, as its chat shows polls too; the overview adds what it lists.
  """
  def maybe_load(socket, %Group{} = group, "polls") do
    {poll_scope, topics} = scope(socket, group)

    socket
    |> assign(polls_scope: poll_scope, poll_dialog: nil)
    |> sync_subscriptions(topics)
    |> load_list()
    |> load_detail()
  end

  def maybe_load(socket, %Group{} = group, _active_tab) do
    socket
    |> sync_subscriptions([group.id])
    |> assign(:polls_detail, nil)
  end

  defp scope(socket, %Group{is_root: true} = group) do
    %{current_profile: profile, polls_show_groups?: groups?, polls_show_public?: public?} =
      socket.assigns

    group_ids = if groups?, do: Social.member_group_ids_under(profile, group), else: []

    if public?,
      do: {{:groups_and_public, group_ids}, [:public | group_ids]},
      else: {{:groups, group_ids}, group_ids}
  end

  defp scope(socket, %Group{} = group) do
    %{access: access, current_profile: profile, polls_include_subgroups?: include?} =
      socket.assigns

    cond do
      not access.member? ->
        {{:public_of, group.id}, [group.id]}

      include? ->
        group_ids = Social.member_group_ids_under(profile, group)
        {{:groups, group_ids}, group_ids}

      true ->
        {{:groups, [group.id]}, [group.id]}
    end
  end

  # `topics` are group ids and `:public` (see `Polls.subscribe/1`).
  defp sync_subscriptions(socket, topics) do
    if connected?(socket) do
      wanted = MapSet.new(topics)
      current = socket.assigns.poll_subscribed

      current |> MapSet.difference(wanted) |> Enum.each(&Polls.unsubscribe/1)
      wanted |> MapSet.difference(current) |> Enum.each(&Polls.subscribe/1)

      assign(socket, :poll_subscribed, wanted)
    else
      socket
    end
  end

  defp load_list(socket) do
    page = overview_page(socket, nil)

    socket
    |> put_page(page)
    |> assign(:polls_empty?, page.rows == [])
    |> stream(:polls, page.rows, reset: true)
  end

  defp overview_page(socket, before_id) do
    %{current_profile: profile, current_scope: scope} = socket.assigns

    Polls.overview(profile, scope.account, socket.assigns.polls_scope,
      status: String.to_existing_atom(socket.assigns.polls_status),
      before_id: before_id
    )
  end

  defp put_page(socket, %{rows: rows, more?: more?}) do
    socket
    |> track(Enum.map(rows, & &1.view))
    |> assign(:polls_more?, more?)
    |> assign(:polls_oldest_id, rows |> List.last() |> oldest_id(socket))
  end

  defp oldest_id(nil, socket), do: socket.assigns.polls_oldest_id
  defp oldest_id(%{id: id}, _socket), do: id

  defp load_detail(%{assigns: %{polls_poll_id: nil}} = socket),
    do: assign(socket, :polls_detail, nil)

  defp load_detail(socket) do
    %{polls_poll_id: poll_id, current_profile: profile, current_scope: scope} = socket.assigns

    with %Poll{} = poll <- Polls.get_poll(poll_id),
         %View{scope: :full} = view <- Polls.view_of(poll, profile, scope.account) do
      stats =
        if view.details?,
          do: Stats.details(poll, poll.group, socket.assigns.calendar_time_zone)

      socket
      |> track([view])
      |> assign(:polls_detail, %{view: view, group: poll.group, stats: stats})
    else
      _hidden_or_gone -> assign(socket, :polls_detail, nil)
    end
  end

  ## Events

  def handle_event("polls_toggle_subgroups", _params, socket) do
    socket =
      assign(socket, :polls_include_subgroups?, not socket.assigns.polls_include_subgroups?)

    {:noreply, maybe_load(socket, socket.assigns.group, "polls")}
  end

  def handle_event("polls_toggle_groups", _params, socket),
    do: toggle_filter(socket, :polls_show_groups?)

  def handle_event("polls_toggle_public", _params, socket),
    do: toggle_filter(socket, :polls_show_public?)

  def handle_event("polls_load_more", _params, socket) do
    if socket.assigns.polls_more? do
      page = overview_page(socket, socket.assigns.polls_oldest_id)

      {:noreply, socket |> put_page(page) |> stream(:polls, page.rows)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("poll_vote", params, socket) do
    case {parse_id(params["poll"]), option_ids(params)} do
      {poll_id, [_ | _] = option_ids} when is_integer(poll_id) ->
        {:noreply, vote(socket, poll_id, option_ids)}

      _no_choice ->
        {:noreply, put_flash(socket, :error, dgettext("polls", "Pick an answer first."))}
    end
  end

  def handle_event("poll_add_option", %{"poll" => poll_id, "text" => text}, socket) do
    with_poll(socket, poll_id, fn poll, profile ->
      case Polls.add_option(profile, poll, %{"text" => text}) do
        {:ok, _poll} -> socket
        {:error, reason} -> put_flash(socket, :error, option_error(reason))
      end
    end)
  end

  def handle_event("poll_delete_option", %{"poll" => poll_id, "option" => option_id}, socket) do
    with_poll(socket, poll_id, fn poll, profile ->
      case Polls.delete_option(profile, poll, parse_id(option_id)) do
        {:ok, _poll} -> socket
        {:error, reason} -> put_flash(socket, :error, option_error(reason))
      end
    end)
  end

  def handle_event("poll_close", %{"id" => poll_id}, socket) do
    with_poll(socket, poll_id, fn poll, profile ->
      case Polls.close_poll(profile, poll) do
        {:ok, _poll} -> put_flash(socket, :info, dgettext("polls", "The poll has ended."))
        {:error, reason} -> put_flash(socket, :error, action_error(reason))
      end
    end)
  end

  def handle_event("poll_reopen", %{"id" => poll_id}, socket) do
    with_poll(socket, poll_id, fn poll, profile ->
      case Polls.reopen_poll(profile, poll) do
        {:ok, _poll} -> put_flash(socket, :info, dgettext("polls", "The poll is open again."))
        {:error, reason} -> put_flash(socket, :error, action_error(reason))
      end
    end)
  end

  def handle_event("poll_delete", %{"id" => poll_id}, socket) do
    with_poll(socket, poll_id, fn poll, profile ->
      case Polls.delete_poll(profile, poll) do
        {:ok, _poll} ->
          socket
          |> put_flash(:info, dgettext("polls", "The poll is deleted."))
          |> close_deleted(poll.id)

        {:error, reason} ->
          put_flash(socket, :error, action_error(reason))
      end
    end)
  end

  def handle_event("poll_nudge", %{"id" => poll_id}, socket) do
    with_poll(socket, poll_id, fn poll, profile ->
      case Polls.nudge(profile, poll) do
        {:ok, _poll} -> put_flash(socket, :info, dgettext("polls", "The reminder is on its way."))
        {:error, reason} -> put_flash(socket, :error, action_error(reason))
      end
    end)
  end

  def handle_event("poll_dialog_close", _params, socket),
    do: {:noreply, assign(socket, :poll_dialog, nil)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Only the root has these switches. The browser keeps them for the next
  # visits (`polls_filters` in app.js).
  defp toggle_filter(%{assigns: %{group: %Group{is_root: true}}} = socket, key) do
    socket = assign(socket, key, not socket.assigns[key])

    {:noreply,
     socket
     |> maybe_load(socket.assigns.group, "polls")
     |> push_event("polls_filters", %{
       groups: socket.assigns.polls_show_groups?,
       public: socket.assigns.polls_show_public?
     })}
  end

  defp toggle_filter(socket, _key), do: {:noreply, socket}

  defp with_poll(socket, poll_id, fun) do
    with id when is_integer(id) <- parse_id(poll_id),
         %Poll{} = poll <- Polls.get_poll(id) do
      {:noreply, fun.(poll, socket.assigns.current_profile)}
    else
      _gone -> {:noreply, socket}
    end
  end

  defp option_ids(%{"option" => option}), do: option_ids(%{"option_ids" => [option]})

  defp option_ids(%{"option_ids" => option_ids}) when is_list(option_ids) do
    option_ids |> Enum.map(&parse_id/1) |> Enum.filter(& &1)
  end

  defp option_ids(_params), do: []

  # The choice stays out of any report: a crash of the process would print the
  # event it was handling. A secret poll keeps nothing else that ties a voter
  # to an answer.
  defp vote(socket, poll_id, option_ids) do
    %{current_profile: profile, current_scope: scope} = socket.assigns

    case Polls.vote(profile, scope.account, %Poll{id: poll_id}, option_ids) do
      {:ok, _poll} -> socket
      {:error, reason} -> put_flash(socket, :error, vote_error(reason))
    end
  rescue
    exception ->
      Logger.error("A vote failed: #{inspect(exception.__struct__)}")
      put_flash(socket, :error, vote_error(:failed))
  catch
    kind, _reason ->
      Logger.error("A vote failed: #{kind}")
      put_flash(socket, :error, vote_error(:failed))
  end

  defp vote_error(:closed), do: dgettext("polls", "This poll has ended.")
  defp vote_error(:already_voted), do: dgettext("polls", "You have already voted.")

  defp vote_error(:voted_with_other_profile),
    do: dgettext("polls", "Another profile of yours has already voted.")

  defp vote_error(:invalid_choice), do: dgettext("polls", "That is not a valid choice.")

  defp vote_error(:rate_limited),
    do: dgettext("polls", "Too many votes at once. Try in a minute.")

  defp vote_error(:failed), do: dgettext("polls", "Your vote was not recorded. Try again.")
  defp vote_error(_not_allowed), do: dgettext("polls", "You may not vote here.")

  defp option_error(:duplicate), do: dgettext("polls", "That answer is already there.")
  defp option_error(:has_votes), do: dgettext("polls", "That answer has votes.")
  defp option_error(:too_few_options), do: dgettext("polls", "A poll needs at least two answers.")
  defp option_error(_reason), do: dgettext("polls", "You may not do that.")

  defp action_error(:closed), do: dgettext("polls", "This poll has ended.")
  defp action_error(:secret), do: dgettext("polls", "A secret poll cannot be opened again.")

  defp action_error(:too_soon),
    do: dgettext("polls", "A reminder went out less than an hour ago.")

  defp action_error(_reason), do: dgettext("polls", "You may not do that.")

  defp close_deleted(socket, poll_id) do
    if socket.assigns.polls_poll_id == poll_id,
      do: push_patch(socket, to: polls_path(socket, poll: nil)),
      else: socket
  end

  ## The dialog an app opens

  @doc """
  Opens the poll over an app. Voting happens here, on Potok's page, because an
  app runs for every viewer and must not vote in their name.
  """
  def open_dialog(socket, poll_id) do
    %{current_profile: profile, current_scope: scope, group: group} = socket.assigns

    with %Poll{group_id: group_id} = poll when group_id == group.id <- Polls.get_poll(poll_id),
         %View{scope: :full} = view <- Polls.view_of(poll, profile, scope.account) do
      {:ok, socket |> track([view]) |> assign(:poll_dialog, view)}
    else
      _hidden_or_gone -> :error
    end
  end

  defp refresh_dialog(%{assigns: %{poll_dialog: %View{poll_id: poll_id}}} = socket, poll_id) do
    %{current_profile: profile, current_scope: scope} = socket.assigns

    with %Poll{} = poll <- Polls.get_poll(poll_id),
         %View{scope: :full} = view <- Polls.view_of(poll, profile, scope.account) do
      socket |> track([view]) |> assign(:poll_dialog, view)
    else
      _hidden_or_gone -> assign(socket, :poll_dialog, nil)
    end
  end

  defp refresh_dialog(socket, _poll_id), do: socket

  ## Live updates

  @doc "Handles `{:polls, message}` messages of `PotokIde.Polls`."
  def handle_info({:tally, tally}, socket) do
    socket =
      if tally.voter_id == profile_id(socket),
        do: refresh_after_my_vote(socket, tally),
        else: socket

    {:noreply, schedule(socket, &put_in(&1, [:tallies, tally.poll_id], tally))}
  end

  def handle_info({:changed, poll_id}, socket) do
    {:noreply,
     socket
     |> refresh_dialog(poll_id)
     |> schedule(&%{&1 | list?: true, ids: MapSet.put(&1.ids, poll_id)})}
  end

  def handle_info({:deleted, poll_id}, socket) do
    socket =
      if match?(%View{poll_id: ^poll_id}, socket.assigns.poll_dialog),
        do: assign(socket, :poll_dialog, nil),
        else: socket

    {:noreply,
     socket
     |> assign(:poll_tallies, Map.delete(socket.assigns.poll_tallies, poll_id))
     |> schedule(&%{&1 | list?: true, ids: MapSet.put(&1.ids, poll_id)})}
  end

  def handle_info(:flush, socket) do
    pending = socket.assigns.poll_pending

    {:noreply,
     socket
     |> assign(poll_pending: new_pending(), poll_flush_scheduled?: false)
     |> apply_pending(pending)}
  end

  defp profile_id(%{assigns: %{current_profile: %{id: id}}}), do: id
  defp profile_id(_socket), do: nil

  # The form gives way to the bars, here and in the viewer's other tabs.
  defp refresh_after_my_vote(socket, %{poll_id: poll_id, value_id: value_id}) do
    socket
    |> Show.restream_value(value_id && %Value{id: value_id})
    |> refresh_dialog(poll_id)
    |> refresh_open_row(poll_id)
  end

  defp refresh_open_row(%{assigns: %{active_tab: "polls"}} = socket, poll_id) do
    if socket.assigns.polls_poll_id == poll_id, do: load_detail(socket), else: socket
  end

  defp refresh_open_row(socket, _poll_id), do: socket

  defp schedule(socket, change) do
    pending = change.(socket.assigns.poll_pending)

    cond do
      @debounce_ms == 0 ->
        socket |> assign(:poll_pending, new_pending()) |> apply_pending(pending)

      socket.assigns.poll_flush_scheduled? ->
        assign(socket, :poll_pending, pending)

      true ->
        Process.send_after(self(), {:polls, :flush}, @debounce_ms + :rand.uniform(@spread_ms))
        assign(socket, poll_pending: pending, poll_flush_scheduled?: true)
    end
  end

  defp apply_pending(socket, pending) do
    socket
    |> apply_tallies(pending.tallies)
    |> reload_list(pending)
    |> tell_app(pending)
  end

  # Takes the numbers a vote sent, only for polls on the page and only as far
  # as this viewer's view shows them.
  defp apply_tallies(socket, tallies) do
    updated =
      Enum.reduce(tallies, socket.assigns.poll_tallies, fn {poll_id, tally}, acc ->
        case acc do
          %{^poll_id => %{options: nil} = held} ->
            Map.put(acc, poll_id, %{held | voters: tally.voters_count})

          %{^poll_id => held} ->
            Map.put(acc, poll_id, %{
              voters: tally.voters_count,
              options: tally.counts || held.options
            })

          %{} ->
            acc
        end
      end)

    assign(socket, :poll_tallies, updated)
  end

  defp reload_list(%{assigns: %{active_tab: "polls"}} = socket, %{list?: true}),
    do: socket |> load_list() |> load_detail()

  defp reload_list(socket, _pending), do: socket

  # An app reads what changed for itself, through the same rules: all it hears
  # is which poll.
  defp tell_app(socket, %{tallies: tallies, ids: ids}) do
    if Show.description_visible?(socket.assigns) and socket.assigns.group.uses_api do
      tallies
      |> Map.keys()
      |> MapSet.new()
      |> MapSet.union(ids)
      |> Enum.reduce(socket, &AppHost.push(&2, "poll_changed", %{id: &1}))
    else
      socket
    end
  end
end
