defmodule PotokIdeWeb.ActivityLive.Index do
  @moduledoc """
  The current profile's timeline: what it did over all its groups, and the
  reactions of others to its messages, the newest first, by the day
  (`PotokIde.Activity`). Only the profile reads it.

  What to show and the day it goes up to are in the address, so that coming
  back from a group finds the list as it was left. The list is of the moment it
  was read: nothing is added while the page is open.

  It is read only once the page is connected, as days are those of the
  browser's time zone; until then the rows are outlines.
  """

  use PotokIdeWeb, :live_view

  alias PotokIde.Activity
  alias PotokIde.Events.{Format, Recurrence}
  alias PotokIdeWeb.ActivityLive.Words
  alias PotokIdeWeb.GroupLive.Show.{CalendarState, Components}
  alias PotokIdeWeb.ProfileAuth

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
      <.page_container id="activity-page">
        <.page_header id="activity-header" icon="hero-clock">
          {gettext("My activity")}
          <:subtitle>
            <%= if @current_profile.sharing == :shared do %>
              {gettext(
                "What the profile %{name} did in the groups it reads now, the newest first. Only those who hold this profile see it.",
                name: @current_profile.username
              )}
            <% else %>
              {gettext(
                "What the profile %{name} did in the groups it reads now, the newest first. Only you see it.",
                name: @current_profile.username
              )}
            <% end %>
          </:subtitle>
        </.page_header>

        <nav
          id="activity-kinds"
          aria-label={gettext("What to show")}
          class="-mx-4 mb-3 flex gap-1.5 overflow-x-auto px-4 pb-1 [scrollbar-width:none] sm:mx-0 sm:flex-wrap sm:px-0"
        >
          <.link
            :for={filter <- Activity.filters()}
            id={"activity-kind-#{filter}"}
            patch={activity_path(filter, @until)}
            aria-current={@filter == filter && "page"}
            class={[
              "inline-flex h-9 shrink-0 items-center gap-1.5 rounded-full border px-3.5 text-sm font-semibold transition duration-150 ease-out active:scale-95 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40",
              if(@filter == filter,
                do: "border-base-content bg-base-content text-base-100 shadow-sm",
                else:
                  "border-base-300 bg-base-100/80 text-base-content/70 hover:border-base-content/25 hover:text-base-content"
              )
            ]}
          >
            <.icon name={Words.filter_icon(filter)} class="size-4" />
            {Words.filter(filter)}
          </.link>
        </nav>

        <div class="mb-2 flex flex-wrap items-center gap-2">
          <.form
            for={@until_form}
            id="activity-until-form"
            phx-change="until"
            phx-submit="until"
            class="inline-flex items-center gap-2 text-sm"
          >
            <label for="activity-until" class="text-base-content/65">
              {gettext("Up to the day")}
            </label>
            <input
              type="date"
              id="activity-until"
              name="until"
              value={@until_form[:until].value}
              class="rounded-full border border-base-300 bg-base-100 px-3 py-1 text-sm"
            />
          </.form>
          <.link
            :if={@until}
            id="activity-until-clear"
            patch={activity_path(@filter, nil)}
            class="inline-flex items-center gap-1 rounded-full bg-primary/10 px-3 py-1 text-sm font-semibold text-primary transition hover:bg-primary/15"
          >
            <.icon name="hero-x-mark" class="size-4" />
            {gettext("Up to today")}
          </.link>
        </div>

        <ul :if={@loading?} id="activity-loading" aria-hidden="true" class="space-y-2 pt-4">
          <li :for={_n <- 1..6} class="flex items-start gap-3 px-2 py-2">
            <span class="size-9 shrink-0 rounded-xl bg-base-200 motion-safe:animate-pulse"></span>
            <span class="flex-1 space-y-2">
              <span class="block h-3 w-1/3 rounded-full bg-base-200 motion-safe:animate-pulse"></span>
              <span class="block h-3 w-4/5 rounded-full bg-base-200 motion-safe:animate-pulse"></span>
            </span>
          </li>
        </ul>

        <p
          :if={!@loading? and !@timeout? and @count == 0}
          id="activity-empty"
          class="rounded-2xl border border-base-300/60 bg-base-100/70 px-4 py-3 text-sm text-base-content/70"
        >
          {if @until,
            do: gettext("Nothing like that up to this day."),
            else: Words.none(@filter)}
        </p>

        <ol id="activity-list" phx-update="stream">
          <li
            :for={{dom_id, entry} <- @streams.entries}
            id={dom_id}
            data-source={entry.source}
            class={[
              if(entry.source == :day,
                do: "pointer-events-none sticky top-0 z-10 pt-4 pb-1.5",
                else: "relative rounded-2xl transition-colors hover:bg-base-200/60"
              )
            ]}
          >
            <%= if entry.source == :day do %>
              <h2 class="inline-flex rounded-full border border-base-300/70 bg-base-100/95 px-3 py-1 text-xs font-semibold text-base-content/75 shadow-sm backdrop-blur">
                {entry.label}
              </h2>
            <% else %>
              <.entry id={dom_id} entry={entry} current_profile={@current_profile} />
            <% end %>
          </li>
        </ol>

        <p
          :if={@timeout?}
          id="activity-timeout"
          role="alert"
          class="mt-4 rounded-2xl border border-warning/40 bg-warning/10 px-4 py-3 text-sm"
        >
          {if @filter == :all,
            do: gettext("There is too much to look through at once. Pick one of the kinds above."),
            else: gettext("This took too long to read. Try again in a while.")}
        </p>

        <div :if={@cursor} class="mt-4 flex justify-center">
          <.button id="activity-more" type="button" phx-click="more" size="sm">
            {pgettext("activity", "Older")}
          </.button>
        </div>

        <p
          :if={!@loading? and !@timeout? and is_nil(@cursor) and @count > 0}
          id="activity-end"
          class="mt-6 text-center text-xs text-base-content/55"
        >
          {gettext(
            "That is all. What is in groups you do not read any more is not here, and comes back if you come back to them."
          )}
        </p>
      </.page_container>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :entry, :map, required: true
  attr :current_profile, :map, required: true

  # The link holds the title; its `after:` box covers the row, as links of its
  # own inside another are not allowed.
  defp entry(assigns) do
    ~H"""
    <div class="flex items-start gap-3 px-2 py-2.5">
      <span class={[
        "mt-0.5 inline-flex size-9 shrink-0 items-center justify-center rounded-xl",
        tile_class(@entry.source)
      ]}>
        <.icon name={@entry.icon} class="size-4.5" />
      </span>
      <div class="min-w-0 flex-1">
        <div class="flex items-baseline justify-between gap-3">
          <.link
            id={"#{@id}-link"}
            {link_attrs(@entry)}
            aria-describedby={described_by(@id, @entry)}
            class="min-w-0 text-xs font-semibold text-base-content/65 after:absolute after:inset-0 after:rounded-2xl focus-visible:outline-none focus-visible:after:ring-2 focus-visible:after:ring-primary/40"
          >
            {@entry.title}
          </.link>
          <time
            datetime={DateTime.to_iso8601(@entry.at)}
            class="shrink-0 text-xs tabular-nums text-base-content/55"
          >
            {@entry.time}
          </time>
        </div>

        <p
          :if={@entry.text}
          id={"#{@id}-text"}
          class="mt-0.5 line-clamp-2 text-sm text-base-content [overflow-wrap:anywhere]"
        >
          <span :if={@entry.author} class="font-semibold">{@entry.author <> ": "}</span>{@entry.text}
        </p>

        <p :if={@entry.choice} id={"#{@id}-choice"} class="mt-0.5 text-sm text-base-content/75">
          {@entry.choice}
        </p>

        <p
          :if={@entry.source == :received}
          id={"#{@id}-reactions"}
          class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-sm"
        >
          <span
            :for={{emoji, count} <- @entry.reactions}
            class="inline-flex items-center gap-1 rounded-full bg-base-200 px-2 py-0.5 text-xs tabular-nums"
          >
            <span>{emoji}</span><span class="font-semibold">{count}</span>
          </span>
          <span class="min-w-0 text-xs text-base-content/65 [overflow-wrap:anywhere]">
            {Words.people(@entry)}
          </span>
        </p>

        <div class="mt-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-base-content/60">
          <span :if={@entry.emoji != []} id={"#{@id}-emoji"} class="text-base leading-none">
            {Enum.join(@entry.emoji, " ")}
          </span>
          <span
            :for={tag <- @entry.tag_names}
            class="inline-flex items-center rounded-full bg-base-200 px-2 py-0.5 font-semibold"
          >
            {tag}
          </span>
          <span
            :if={@entry.mark}
            id={"#{@id}-mark"}
            class={["rounded-full px-2 py-0.5 font-semibold", mark_class(elem(@entry.mark, 1))]}
          >
            {elem(@entry.mark, 0)}
          </span>
          <span :if={@entry.place} id={"#{@id}-place"} class="inline-flex min-w-0 items-center gap-1">
            <.icon name={@entry.place_icon} class="size-3.5 shrink-0" />
            <span class="min-w-0 truncate">{@entry.place}</span>
          </span>
        </div>
      </div>
    </div>
    """
  end

  # The link says what the row is; what it is of stands next to it.
  defp described_by(id, entry) do
    [entry.text && "#{id}-text", entry.place && "#{id}-place"]
    |> Enum.filter(& &1)
    |> Enum.join(" ")
  end

  defp link_attrs(%{file?: true, path: path}),
    do: [href: path, target: "_blank", rel: "noopener"]

  defp link_attrs(%{path: path}), do: [navigate: path]

  defp tile_class(source) when source in [:given, :received, :group_reaction],
    do: "bg-rose-500/10 text-rose-700 dark:text-rose-300"

  defp tile_class(source) when source in [:ballot, :poll],
    do: "bg-violet-500/10 text-violet-700 dark:text-violet-300"

  defp tile_class(source) when source in [:event, :rsvp],
    do: "bg-amber-500/15 text-amber-800 dark:text-amber-300"

  defp tile_class(source) when source in [:group_made, :joined, :left],
    do: "bg-emerald-500/10 text-emerald-800 dark:text-emerald-300"

  defp tile_class(source) when source in [:message, :file], do: "bg-primary/10 text-primary"
  defp tile_class(_source), do: "bg-base-200 text-base-content/65"

  defp mark_class(:good), do: "bg-emerald-500/15 text-emerald-800 dark:text-emerald-200"
  defp mark_class(:bad), do: "bg-error/10 text-error"
  defp mark_class(:neutral), do: "bg-base-200 text-base-content/75"

  # ---------
  # State
  # ---------

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> put_private(:previous_current_profile, socket.assigns.current_profile)
     |> assign(:page_title, gettext("My activity"))
     |> assign(:time_zone, CalendarState.connect_time_zone(socket))
     |> assign(
       filter: :all,
       until: nil,
       until_form: until_form(nil),
       count: 0,
       cursor: nil,
       timeout?: false,
       loading?: true
     )
     |> stream_configure(:entries, dom_id: &"activity-#{&1.key}")
     |> stream(:entries, [])
     |> ProfileAuth.sync_profile_subscription()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    until = parse_date(params["until"])

    {:noreply,
     socket
     |> assign(:filter, parse_filter(params["kind"]))
     |> assign(:until, until)
     |> assign(:until_form, until_form(until))
     |> load()}
  end

  @impl true
  def handle_event("until", params, socket),
    do:
      {:noreply,
       push_patch(socket,
         to: activity_path(socket.assigns.filter, parse_date(params["until"]))
       )}

  def handle_event("more", _params, %{assigns: %{cursor: %{}}} = socket),
    do: {:noreply, read(socket)}

  def handle_event("more", _params, socket), do: {:noreply, socket}

  @impl true
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
         |> load()}
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

  # The profile's other messages concern the header, which `ProfileAuth` keeps.
  def handle_info(_message, socket), do: {:noreply, socket}

  # The list from its start.
  defp load(socket) do
    if connected?(socket) do
      socket
      |> assign(count: 0, cursor: nil, loading?: false)
      |> put_private(:shown, MapSet.new())
      |> put_private(:last_day, nil)
      |> stream(:entries, [], reset: true)
      |> read()
    else
      socket
    end
  end

  # The next page. A row that moved down meanwhile (a reaction taken back) is
  # on the page already, and stays where it is.
  defp read(socket) do
    %{current_profile: profile, current_scope: scope, time_zone: zone} = socket.assigns

    page =
      Activity.page(profile, scope.account,
        filter: socket.assigns.filter,
        until: end_of_day(socket.assigns.until, zone),
        zone: zone,
        cursor: socket.assigns.cursor
      )

    case page do
      {:ok, %{entries: entries, cursor: cursor}} ->
        shown = socket.private.shown
        entries = Enum.reject(entries, &MapSet.member?(shown, &1.key))
        {rows, last_day} = with_days(entries, socket.private.last_day, zone)

        socket
        |> assign(cursor: cursor, timeout?: false)
        |> update(:count, &(&1 + length(entries)))
        |> put_private(:shown, MapSet.union(shown, MapSet.new(entries, & &1.key)))
        |> put_private(:last_day, last_day)
        |> stream(:entries, Enum.map(rows, &dress(&1, socket)))

      # The cursor stays, so the button tries again.
      {:error, :timeout} ->
        assign(socket, :timeout?, true)
    end
  end

  # A heading before the first row of each day.
  defp with_days(entries, last_day, zone) do
    today = Recurrence.local_date(DateTime.utc_now(), zone)

    Enum.flat_map_reduce(entries, last_day, fn entry, last_day ->
      case Recurrence.local_date(entry.at, zone) do
        ^last_day ->
          {[entry], last_day}

        day ->
          heading = %{key: "day-#{day}", source: :day, label: day_label(day, today)}
          {[heading, entry], day}
      end
    end)
  end

  defp day_label(day, today) do
    case Date.diff(today, day) do
      0 -> gettext("Today")
      1 -> dgettext("events", "Yesterday")
      _days -> Format.date(day, today)
    end
  end

  # A row as the list draws it, so that drawing it again reads nothing.
  defp dress(%{source: :day} = day, _socket), do: day

  defp dress(entry, socket) do
    %{current_profile: profile, time_zone: zone} = socket.assigns
    today = Recurrence.local_date(DateTime.utc_now(), zone)

    Map.merge(entry, %{
      icon: Words.icon(entry),
      title: Words.title(entry),
      text: Words.text(entry, today),
      author: Words.author(entry),
      choice: Words.choice(entry),
      emoji: Map.get(entry, :emoji, []),
      tag_names: Words.tags(entry),
      mark: Words.mark(entry),
      path: Words.path(entry),
      file?: Words.file?(entry),
      time: Format.time(entry.at, zone),
      place: place(entry, profile),
      place_icon: place_icon(entry)
    })
  end

  # A thread is named after the message it hangs from, so its group is told too.
  defp place(%{group: nil}, _profile), do: nil

  defp place(%{group: group, parent: nil}, profile),
    do: Components.group_identity_name(group, profile)

  defp place(%{group: group, parent: parent}, profile),
    do: Components.group_identity_name(parent, profile) <> " › " <> group.name

  defp place_icon(%{group: %{is_direct: true}}), do: "hero-user-micro"

  defp place_icon(entry),
    do:
      if(Words.thread?(entry),
        do: "hero-chat-bubble-left-right-micro",
        else: "hero-user-group-micro"
      )

  # ---------
  # Address
  # ---------

  defp activity_path(filter, until) do
    query =
      [filter != :all && {"kind", filter}, until && {"until", Date.to_iso8601(until)}]
      |> Enum.filter(& &1)

    ~p"/activity?#{query}"
  end

  defp parse_filter(kind),
    do: Enum.find(Activity.filters(), :all, &(Atom.to_string(&1) == kind))

  # A year of five digits, or one before any of this, is no day to look from.
  defp parse_date(date) when is_binary(date) do
    case Date.from_iso8601(date) do
      {:ok, %Date{year: year} = date} when year in 2000..9000 -> date
      _error -> nil
    end
  end

  defp parse_date(_date), do: nil

  defp until_form(until), do: to_form(%{"until" => until && Date.to_iso8601(until)})

  defp end_of_day(nil, _zone), do: nil

  defp end_of_day(%Date{} = date, zone),
    do: date |> Date.add(1) |> Recurrence.to_utc(~T[00:00:00], zone)
end
