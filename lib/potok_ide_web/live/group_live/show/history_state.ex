defmodule PotokIdeWeb.GroupLive.Show.HistoryState do
  @moduledoc """
  What the history tab of a group holds, and its events. Nothing of it is kept
  while another tab is open.

  The address may narrow it to one thing (`?of=description-12`), as the links
  from an edited description do, or ask for the group as it was at a moment
  (`?at=2026-11-20T18:00`, in the viewer's time zone), which shows that in
  place of the changes.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView

  use Gettext, backend: PotokIdeWeb.Gettext

  alias PotokIde.{History, Repo}
  alias PotokIde.History.{Feed, GroupChange, Reader, Restore, Snapshot, State}
  alias PotokIde.Social.{Access, Group, Profile}
  alias PotokIdeWeb.GroupLive.Show.HistoryWords

  @subjects ~w(group description template record process entity field poll event)

  # Of these there is more to see than the sentence says.
  @opens ~w(group description template record process entity field poll event)

  def init(socket, params) do
    socket
    |> assign(history: nil, history_open: nil)
    |> assign_params(params)
    |> stream_configure(:history_entries, dom_id: &"history-#{&1.id}")
    |> stream(:history_entries, [])
  end

  def assign_params(socket, params),
    do: assign(socket, history_of: parse_of(params["of"]), history_at: parse_at(params["at"]))

  def params_changed?(socket, params) do
    parse_of(params["of"]) != socket.assigns.history_of or
      parse_at(params["at"]) != socket.assigns.history_at
  end

  def handle_params(socket, params) do
    socket = assign_params(socket, params)

    socket
    |> assign(:history_open, nil)
    |> load(%{blank() | subject: socket.assigns.history_of})
  end

  defp parse_at(at) when is_binary(at) do
    case NaiveDateTime.from_iso8601(if(byte_size(at) == 16, do: at <> ":00", else: at)) do
      {:ok, local} -> local
      _error -> nil
    end
  end

  defp parse_at(_at), do: nil

  defp parse_of(of) when is_binary(of) do
    with [type, id] <- String.split(of, "-", parts: 2),
         true <- type in @subjects,
         {id, ""} when id > 0 <- Integer.parse(id) do
      {type, id}
    else
      _other -> nil
    end
  end

  defp parse_of(_of), do: nil

  # Filled when the tab opens, and again when the group's data is loaded again,
  # unless the viewer has gone on to older pages.
  def maybe_load(socket, %Group{}, "history") do
    case socket.assigns.history do
      nil -> load(socket, %{blank() | subject: socket.assigns.history_of})
      %{pages: 1} = history -> load(socket, history)
      _further -> socket
    end
  end

  def maybe_load(%{assigns: %{history: nil}} = socket, _group, _tab), do: socket

  def maybe_load(socket, _group, _tab) do
    socket
    |> assign(history: nil, history_open: nil)
    |> stream(:history_entries, [], reset: true)
  end

  defp blank do
    %{
      filter: :all,
      actor: nil,
      until: nil,
      subject: nil,
      subject_name: nil,
      cursor: nil,
      count: 0,
      pages: 1,
      since: History.since(),
      moment: nil,
      before_since?: false,
      snapshot: nil,
      records: nil
    }
  end

  # The group as it was, when the address asks for a moment; otherwise the
  # first page of what the filters let through.
  defp load(%{assigns: %{history_at: %NaiveDateTime{} = local}} = socket, history) do
    asked = to_utc(local, socket.assigns[:calendar_time_zone])
    # Before its beginning the history cannot tell one day from another.
    before? = DateTime.compare(asked, history.since) == :lt
    moment = if before?, do: history.since, else: asked
    now = DateTime.utc_now()
    moment = if DateTime.compare(moment, now) == :gt, do: now, else: moment
    reader = reader(socket)

    socket
    |> assign(:history, %{
      history
      | moment: moment,
        before_since?: before?,
        snapshot: reader && Snapshot.load(reader, moment),
        records: nil,
        cursor: nil,
        count: 0,
        pages: 1
    })
    |> stream(:history_entries, [], reset: true)
  end

  defp load(socket, history) do
    reader = reader(socket)
    page = reader && Feed.page(reader, options(socket, history))
    entries = if page, do: dressed(socket, reader, page.entries), else: []

    socket
    |> assign(:history, %{
      history
      | cursor: page && page.cursor,
        count: length(entries),
        pages: 1,
        subject_name: subject_name(reader, history.subject)
    })
    |> stream(:history_entries, entries, reset: true)
  end

  defp options(socket, history) do
    [
      filter: history.filter,
      actor: history.actor && history.actor.id,
      until: end_of_day(history.until, socket.assigns[:calendar_time_zone]),
      subject: history.subject
    ]
  end

  # While an admin looks as others would, the access is the preview's and
  # nothing is the viewer's own.
  defp reader(socket) do
    %{group: group, access: access, current_profile: profile} = socket.assigns

    if access.member? do
      Reader.new(group, access, profile, own: is_nil(socket.assigns[:access_preview]))
    end
  end

  defp end_of_day(nil, _zone), do: nil

  defp end_of_day(%Date{} = date, zone),
    do: date |> Date.add(1) |> NaiveDateTime.new!(~T[00:00:00]) |> to_utc(zone)

  defp to_utc(%NaiveDateTime{} = local, zone) do
    zone = if is_binary(zone), do: zone, else: "Etc/UTC"

    case DateTime.from_naive(local, zone) do
      {:ok, at} -> DateTime.shift_zone!(at, "Etc/UTC")
      {:ambiguous, at, _later} -> DateTime.shift_zone!(at, "Etc/UTC")
      {:gap, _before, at} -> DateTime.shift_zone!(at, "Etc/UTC")
      {:error, _reason} -> DateTime.from_naive!(local, "Etc/UTC")
    end
  end

  # Entries with their words, as the list shows them.
  defp dressed(socket, reader, entries) do
    names = Feed.names(reader, entries)
    Enum.map(entries, &dress(&1, socket, names))
  end

  defp dress(entry, socket, names) do
    Map.merge(entry, %{
      line: HistoryWords.line(entry, names, socket.assigns.access.manifest),
      icon: HistoryWords.icon(entry),
      actor_id: actor_id(entry),
      opens?: opens?(entry),
      burst?: entry.source == :change and not is_nil(entry.row.last_at),
      emptied?: entry.source == :change and not is_nil(entry.row.purged_at),
      message_path: message_path(entry, names)
    })
  end

  defp actor_id(%{source: :change, row: %GroupChange{actor: %Profile{id: id}, cause: cause}}),
    do: if(cause["process"], do: nil, else: id)

  defp actor_id(_entry), do: nil

  defp opens?(%{source: :change, row: %GroupChange{op: :created}}), do: false

  defp opens?(%{source: :change, row: %GroupChange{subject_type: type}}), do: type in @opens
  defp opens?(_entry), do: false

  defp message_path(%{source: :change, row: %GroupChange{subject_type: type} = row}, names)
       when type in ["message", "reaction"] do
    if names[{"message", row.subject_id}],
      do: "/groups/#{row.group_id}/values?value=#{row.subject_id}"
  end

  defp message_path(_entry, _names), do: nil

  defp subject_name(nil, _subject), do: nil
  defp subject_name(_reader, nil), do: nil
  defp subject_name(_reader, {"group", _id}), do: HistoryWords.kind("group")

  defp subject_name(_reader, {"record", id}),
    do: "#{HistoryWords.kind("record")} #{id}"

  defp subject_name(reader, {type, id}) do
    row = %GroupChange{subject_type: type, subject_id: id}
    names = Feed.names(reader, [%{source: :change, row: row}])
    "#{HistoryWords.kind(type)} “#{HistoryWords.name(row, names)}”"
  end

  # ---------
  # Events
  # ---------

  def handle_event(_event, _params, %{assigns: %{history: nil}} = socket), do: {:noreply, socket}

  def handle_event("history_filter", %{"filter" => filter}, socket) do
    case Enum.find(Feed.filters(), &(Atom.to_string(&1) == filter)) do
      nil ->
        {:noreply, socket}

      filter ->
        {:noreply, load(socket, %{socket.assigns.history | filter: filter, subject: nil})}
    end
  end

  def handle_event("history_until", params, socket) do
    until =
      case Date.from_iso8601(to_string(params["until"])) do
        {:ok, date} -> date
        _error -> nil
      end

    {:noreply, load(socket, %{socket.assigns.history | until: until})}
  end

  def handle_event("history_actor", %{"id" => id}, socket) do
    with {id, ""} <- Integer.parse(to_string(id)),
         %Profile{} = profile <- Repo.get(Profile, id) do
      actor = %{id: id, name: Profile.display_name(profile)}
      {:noreply, load(socket, %{socket.assigns.history | actor: actor})}
    else
      _unknown -> {:noreply, socket}
    end
  end

  def handle_event("history_actor_clear", _params, socket),
    do: {:noreply, load(socket, %{socket.assigns.history | actor: nil})}

  def handle_event("history_subject", %{"id" => id}, socket) do
    with %GroupChange{} = change <- change(socket, id) do
      history = %{
        blank()
        | subject: {change.subject_type, change.subject_id}
      }

      {:noreply, socket |> assign(:history_open, nil) |> load(history)}
    else
      nil -> {:noreply, socket}
    end
  end

  def handle_event("history_subject_clear", _params, socket),
    do: {:noreply, load(socket, %{socket.assigns.history | subject: nil})}

  def handle_event("history_more", _params, socket) do
    history = socket.assigns.history

    with %{} = cursor <- history.cursor,
         %Reader{} = reader <- reader(socket) do
      page = Feed.page(reader, [{:cursor, cursor} | options(socket, history)])
      entries = dressed(socket, reader, page.entries)

      {:noreply,
       socket
       |> assign(:history, %{
         history
         | cursor: page.cursor,
           count: history.count + length(entries),
           pages: history.pages + 1
       })
       |> stream(:history_entries, entries)}
    else
      _end -> {:noreply, socket}
    end
  end

  def handle_event("history_open", %{"id" => id}, socket) do
    case change(socket, id) do
      nil -> {:noreply, put_flash(socket, :error, gettext("That change is no longer there."))}
      change -> {:noreply, assign(socket, :history_open, opened(socket, change))}
    end
  end

  # The group as it was: the form leads to its address, so a moment can be
  # sent to someone.
  def handle_event("history_at", params, socket) do
    base = "/groups/#{socket.assigns.group.id}/history"

    case parse_at(params["at"]) do
      nil -> {:noreply, push_patch(socket, to: base)}
      local -> {:noreply, push_patch(socket, to: base <> "?at=" <> minute(local))}
    end
  end

  def handle_event("history_thing", %{"type" => type, "id" => id}, socket) do
    with %{moment: %DateTime{} = moment} <- socket.assigns.history,
         {id, ""} <- Integer.parse(to_string(id)),
         %Reader{} = reader <- reader(socket),
         {:ok, values} <- Snapshot.thing(reader, type, id, moment) do
      title = values["name"] || values["title"] || values["question"]
      title = if is_binary(title), do: title, else: HistoryWords.kind(type)
      {:noreply, assign(socket, :history_open, pictured(type, title, moment, values))}
    else
      _gone -> {:noreply, put_flash(socket, :error, gettext("That was not there then."))}
    end
  end

  def handle_event("history_records", %{"index" => index}, socket) do
    with %{snapshot: %{records: records}} <- socket.assigns.history,
         {index, ""} <- Integer.parse(to_string(index)),
         %{} = collection <- Enum.at(records, index) do
      {:noreply, load_records(socket, Map.put(collection, :index, index), nil, [])}
    else
      _unknown -> {:noreply, socket}
    end
  end

  def handle_event("history_records_more", _params, socket) do
    case socket.assigns.history.records do
      %{rows: [_ | _] = rows} = records ->
        {:noreply, load_records(socket, records, List.last(rows).id, rows)}

      _none ->
        {:noreply, socket}
    end
  end

  def handle_event("history_record", %{"id" => id}, socket) do
    with %{moment: %DateTime{} = moment, records: %{rows: rows}} <- socket.assigns.history,
         %{change: change} <- Enum.find(rows, &(to_string(&1.id) == to_string(id))),
         %Reader{} = reader <- reader(socket),
         {:ok, values} <- Snapshot.record(reader, change, moment) do
      title = "#{HistoryWords.kind("record")} #{id}"
      {:noreply, assign(socket, :history_open, pictured("record", title, moment, values))}
    else
      _gone -> {:noreply, socket}
    end
  end

  def handle_event("history_close", _params, socket),
    do: {:noreply, assign(socket, :history_open, nil)}

  def handle_event("history_empty", %{"id" => id}, socket) do
    %{group: group, current_profile: profile} = socket.assigns

    with %GroupChange{} = change <- change(socket, id),
         {:ok, _count} <- History.empty(profile, group, change) do
      {:noreply,
       socket
       |> assign(:history_open, nil)
       |> load(%{socket.assigns.history | cursor: nil})
       |> put_flash(:info, gettext("The old versions are emptied."))}
    else
      _refused ->
        {:noreply, put_flash(socket, :error, gettext("Could not empty the old versions."))}
    end
  end

  def handle_event("history_restore", %{"id" => id}, socket) do
    %{group: group, current_profile: profile} = socket.assigns

    with %GroupChange{} = change <- change(socket, id),
         {:ok, done} <- Restore.run(profile, group, reader(socket), change) do
      {:noreply,
       socket
       |> assign(:history_open, nil)
       |> load(%{socket.assigns.history | cursor: nil})
       |> put_flash(:info, restored_text(done))}
    else
      nil ->
        {:noreply, put_flash(socket, :error, gettext("That change is no longer there."))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, restore_error(reason))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp restored_text(%{records: 0}), do: gettext("The earlier version is back.")

  defp restored_text(%{records: n, lost_files: 0}),
    do: ngettext("%{count} record is back.", "%{count} records are back.", n)

  defp restored_text(%{records: n, lost_files: files}) do
    ngettext("%{count} record is back.", "%{count} records are back.", n) <>
      " " <>
      ngettext(
        "%{count} file they named is gone for good.",
        "%{count} files they named are gone for good.",
        files
      )
  end

  defp restore_error(:not_permitted), do: gettext("You may not put this back.")

  defp restore_error({:conflict, _current}),
    do: gettext("Someone changed it meanwhile. Look at it again.")

  defp restore_error(:too_many_alt_descriptions),
    do: gettext("The group has as many descriptions as it can.")

  defp restore_error(%Ecto.Changeset{errors: [{_field, {message, _opts}} | _]}),
    do: gettext("Could not put it back: %{reason}", reason: message)

  defp restore_error(_reason), do: gettext("Could not put it back as it was.")

  defp minute(local), do: local |> NaiveDateTime.to_iso8601() |> String.slice(0, 16)

  defp load_records(socket, collection, before_id, rows) do
    history = socket.assigns.history
    reader = reader(socket)

    {more_rows, more?} =
      if reader,
        do:
          Snapshot.record_page(
            reader,
            collection.alt_id,
            collection.collection,
            history.moment,
            before_id
          ),
        else: {[], false}

    records =
      Map.merge(collection, %{
        rows: rows ++ Enum.map(more_rows, &Map.take(&1, [:id, :values, :change])),
        more?: more?
      })

    assign(socket, :history, %{history | records: records})
  end

  # One thing as it was, for the dialog.
  defp pictured(type, title, moment, values) do
    %{
      mode: :state,
      type: type,
      text: title,
      icon: HistoryWords.icon(%{source: :change, row: %GroupChange{subject_type: type}}),
      moment: moment,
      values: Enum.sort(values)
    }
  end

  # The change, when the viewer may read it.
  defp change(socket, id) do
    with {id, ""} <- Integer.parse(to_string(id)),
         %Reader{} = reader <- reader(socket) do
      Feed.get(reader, id)
    else
      _no -> nil
    end
  end

  defp opened(socket, change) do
    reader = reader(socket)
    entry = %{source: :change, row: change, at: change.at}
    names = Feed.names(reader, [entry])
    %Access{} = access = socket.assigns.access

    %{
      mode: :change,
      change: change,
      text: HistoryWords.text(entry, names, access.manifest),
      icon: HistoryWords.icon(entry),
      sides: State.sides(reader, change),
      subject?: change.subject_type in @subjects,
      restore: if(is_nil(socket.assigns[:access_preview]), do: Restore.offered(reader, change)),
      may_empty?:
        is_nil(socket.assigns[:access_preview]) and
          History.may_empty?(access, reader.profile_id, change)
    }
  end
end
