defmodule PotokIdeWeb.GroupLive.Show.HistoryWords do
  @moduledoc """
  The words of a group's history: a sentence for each entry
  (`PotokIde.History.Feed`), and the names of what changed and of its values.

  Who did it stands in the sentence wherever the language puts it, and the
  page makes it a button, so a sentence comes as `{before, who, after}`.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  alias PotokIde.History.GroupChange
  alias PotokIde.Social.Profile
  alias PotokIdeWeb.GroupLive.Show.AccessTab

  # Where the sentence has its actor; no name has it.
  @mark <<0xE000::utf8>>

  @access ~w(is_public has_public_chat description_for_guests inherits_members
             inherit_role_keys elects_admins join_mode join_poll published_at visible_role_keys
             for_guests)
  @place ~w(latitude longitude pin_icon area route)

  @doc "The sentence of an entry, as `{before, who, after}`; `who` is nil when it names nobody."
  def line(%{source: :access, row: row}, _names, manifest),
    do: {AccessTab.change_text(row, manifest), nil, ""}

  def line(%{source: :change, row: %GroupChange{} = row}, names, _manifest) do
    case row |> sentence(names) |> String.split(@mark, parts: 2) do
      [before, rest] -> {before, actor(row, names), rest}
      [whole] -> {whole, nil, ""}
    end
  end

  @doc "The sentence of an entry as a plain text."
  def text(entry, names, manifest) do
    {before, who, rest} = line(entry, names, manifest)
    before <> (who || "") <> rest
  end

  @doc "Who a change is by: a profile, a run of a process, a decision, or someone unknown."
  def actor(%GroupChange{} = row, names) do
    run = row.cause["process"] && names[{"run", row.cause["process"]}]

    cond do
      match?(%Profile{kind: :process}, row.actor) and run -> process(run)
      match?(%Profile{}, row.actor) -> Profile.display_name(row.actor)
      run -> process(run)
      row.cause["poll"] -> decision(names[{"poll", row.cause["poll"]}])
      row.cause["process"] -> gettext("A process")
      row.anonymous -> gettext("The author")
      true -> gettext("Someone")
    end
  end

  defp process(name), do: gettext("The process “%{name}”", name: name)
  defp decision(nil), do: gettext("A decision of a poll")
  defp decision(name), do: gettext("The decision of the poll “%{name}”", name: name)

  # ---------
  # Sentences
  # ---------

  defp sentence(%GroupChange{cause: %{"via" => "parent"}}, _names),
    do: gettext("The roles of the group above changed, and with them those this one inherits by.")

  defp sentence(
         %GroupChange{subject_type: "record", cause: %{"restored" => _, "count" => count}} = row,
         _names
       ) do
    case row.collection do
      nil ->
        ngettext(
          "%{actor} puts back %{count} record of an app.",
          "%{actor} puts back %{count} records of an app.",
          count,
          actor: @mark
        )

      where ->
        ngettext(
          "%{actor} puts back %{count} record of “%{where}”.",
          "%{actor} puts back %{count} records of “%{where}”.",
          count,
          actor: @mark,
          where: where
        )
    end
  end

  defp sentence(%GroupChange{cause: %{"restored" => _}} = row, names) do
    gettext("%{actor} puts back an earlier version: %{what}.",
      actor: @mark,
      what: thing(row, names)
    )
  end

  defp sentence(%GroupChange{subject_type: "group", cause: %{"via" => "kind"}}, _names),
    do: gettext("%{actor} gives the group another kind.", actor: @mark)

  defp sentence(%GroupChange{subject_type: "group", cause: %{"via" => "refresh"}}, _names),
    do: gettext("%{actor} brings the group's app to the newest version.", actor: @mark)

  defp sentence(%GroupChange{subject_type: "group"} = row, _names),
    do: gettext("%{actor} changes %{what}.", actor: @mark, what: fields_words("group", row))

  defp sentence(%GroupChange{subject_type: "sub_group", op: op} = row, names) do
    words = [actor: @mark, name: name(row, names)]

    if op == :created,
      do: gettext("%{actor} makes the sub-group “%{name}”.", words),
      else: gettext("%{actor} deletes the sub-group “%{name}”.", words)
  end

  defp sentence(%GroupChange{subject_type: "shortcut", op: op} = row, names) do
    words = [actor: @mark, name: name(row, names)]

    if op == :created,
      do: gettext("%{actor} places a shortcut to “%{name}”.", words),
      else: gettext("%{actor} takes away the shortcut to “%{name}”.", words)
  end

  defp sentence(
         %GroupChange{subject_type: "description", cause: %{"via" => "refresh"}} = row,
         names
       ),
       do:
         gettext("%{actor} brings the app “%{name}” to the newest version.",
           actor: @mark,
           name: name(row, names)
         )

  defp sentence(%GroupChange{subject_type: "description"} = row, names) do
    words = [actor: @mark, name: name(row, names)]

    case row.op do
      :created ->
        gettext("%{actor} adds the description “%{name}”.", words)

      :changed ->
        gettext("%{actor} changes the description “%{name}”: %{what}.",
          actor: @mark,
          name: name(row, names),
          what: fields_words("description", row)
        )

      :deleted ->
        gettext("%{actor} deletes the description “%{name}” with all its app kept.", words)
    end
  end

  defp sentence(%GroupChange{subject_type: "app"}, _names),
    do: gettext("%{actor} moves an app to another description, with all it keeps.", actor: @mark)

  defp sentence(%GroupChange{subject_type: "template"} = row, names) do
    words = [actor: @mark, name: name(row, names)]

    case row.op do
      :created -> gettext("%{actor} adds the template “%{name}”.", words)
      :changed -> gettext("%{actor} changes the template “%{name}”.", words)
      :deleted -> gettext("%{actor} deletes the template “%{name}”.", words)
    end
  end

  defp sentence(%GroupChange{subject_type: "record", collection: "config"} = row, _names) do
    case row.op do
      :created -> gettext("%{actor} sets an app up.", actor: @mark)
      :changed -> gettext("%{actor} changes the settings of an app.", actor: @mark)
      :deleted -> gettext("%{actor} deletes the settings of an app.", actor: @mark)
    end
  end

  defp sentence(%GroupChange{subject_type: "record"} = row, _names) do
    words = [actor: @mark, where: row.collection]

    case {row.op, row.collection, row.cause["count"]} do
      {:deleted, nil, n} when is_integer(n) ->
        ngettext(
          "%{actor} deletes %{count} record of an app.",
          "%{actor} deletes %{count} records of an app.",
          n,
          words
        )

      {:deleted, _where, n} when is_integer(n) ->
        ngettext(
          "%{actor} deletes %{count} record of “%{where}”.",
          "%{actor} deletes %{count} records of “%{where}”.",
          n,
          words
        )

      {:created, nil, _} ->
        gettext("%{actor} adds a record to an app.", words)

      {:created, _where, _} ->
        gettext("%{actor} adds a record to “%{where}”.", words)

      {:changed, _where, _} when row.fields == ["managed"] ->
        gettext("%{actor} grades a record of “%{where}”.", words)

      {:changed, nil, _} ->
        gettext("%{actor} changes a record of an app.", words)

      {:changed, _where, _} ->
        gettext("%{actor} changes a record of “%{where}”.", words)

      {:deleted, nil, _} ->
        gettext("%{actor} deletes a record of an app.", words)

      {:deleted, _where, _} ->
        gettext("%{actor} deletes a record of “%{where}”.", words)
    end
  end

  defp sentence(%GroupChange{subject_type: "process"} = row, names) do
    words = [actor: @mark, name: name(row, names)]

    cond do
      row.op == :created -> gettext("%{actor} draws the process “%{name}”.", words)
      row.op == :deleted -> gettext("%{actor} deletes the process “%{name}”.", words)
      "active" not in row.fields -> gettext("%{actor} changes the process “%{name}”.", words)
      is_nil(row.keys_after) -> gettext("%{actor} switches the process “%{name}” on.", words)
      true -> gettext("%{actor} switches the process “%{name}” off.", words)
    end
  end

  defp sentence(%GroupChange{subject_type: "entity"} = row, names) do
    words = [actor: @mark, name: name(row, names)]

    case row.op do
      :created -> gettext("%{actor} defines the entity “%{name}”.", words)
      :changed -> gettext("%{actor} changes the entity “%{name}”.", words)
      :deleted -> gettext("%{actor} deletes the entity “%{name}”.", words)
    end
  end

  defp sentence(%GroupChange{subject_type: "field"} = row, names) do
    words = [actor: @mark, name: name(row, names)]

    cond do
      row.op == :created -> gettext("%{actor} adds the field “%{name}”.", words)
      row.op == :deleted -> gettext("%{actor} deletes the field “%{name}”.", words)
      row.fields == ["value"] -> gettext("%{actor} sets the field “%{name}”.", words)
      true -> gettext("%{actor} changes the field “%{name}”.", words)
    end
  end

  defp sentence(%GroupChange{subject_type: "message", op: :changed}, _names),
    do: gettext("%{actor} edits a message.", actor: @mark)

  defp sentence(%GroupChange{subject_type: "message"} = row, _names) do
    words = [actor: @mark]

    cond do
      is_integer(row.cause["count"]) ->
        ngettext(
          "%{actor} deletes %{count} message.",
          "%{actor} deletes %{count} messages.",
          row.cause["count"],
          words
        )

      not is_nil(row.actor_id) and row.actor_id == row.creator_id ->
        gettext("%{actor} deletes a message of their own.", words)

      match?(%Profile{}, row.creator) ->
        gettext("%{actor} deletes a message by %{author}.",
          actor: @mark,
          author: Profile.display_name(row.creator)
        )

      true ->
        gettext("%{actor} deletes a message.", words)
    end
  end

  defp sentence(%GroupChange{subject_type: "reaction", op: op}, _names) do
    if op == :created,
      do: gettext("%{actor} reacts to a message.", actor: @mark),
      else: gettext("%{actor} takes back a reaction to a message.", actor: @mark)
  end

  defp sentence(%GroupChange{subject_type: "group_reaction", op: op}, _names) do
    if op == :created,
      do: gettext("%{actor} reacts to the group.", actor: @mark),
      else: gettext("%{actor} takes back a reaction to the group.", actor: @mark)
  end

  defp sentence(%GroupChange{subject_type: "poll", cause: %{"via" => "deadline"}} = row, names),
    do: gettext("The poll “%{name}” ends at its deadline.", name: name(row, names))

  defp sentence(
         %GroupChange{subject_type: "poll", cause: %{"via" => "member_option"}} = row,
         names
       ),
       do: gettext("The poll “%{name}” gets another answer.", name: name(row, names))

  defp sentence(%GroupChange{subject_type: "poll"} = row, names) do
    words = [actor: @mark, name: name(row, names)]

    cond do
      row.op == :created -> gettext("%{actor} starts the poll “%{name}”.", words)
      row.op == :deleted -> gettext("%{actor} deletes the poll “%{name}”.", words)
      row.closing? == true -> gettext("%{actor} ends the poll “%{name}”.", words)
      row.closing? == false -> gettext("%{actor} reopens the poll “%{name}”.", words)
      true -> gettext("%{actor} changes the poll “%{name}”.", words)
    end
  end

  defp sentence(%GroupChange{subject_type: "event", cause: %{"via" => "gone"}} = row, names),
    do: gettext("The group the event “%{name}” was held in is no more.", name: name(row, names))

  defp sentence(%GroupChange{subject_type: "event"} = row, names) do
    words = [actor: @mark, name: name(row, names)]

    cond do
      row.op == :created -> gettext("%{actor} adds the event “%{name}”.", words)
      row.op == :deleted -> gettext("%{actor} deletes the event “%{name}”.", words)
      "cancelled_at" in row.fields -> gettext("%{actor} cancels the event “%{name}”.", words)
      true -> gettext("%{actor} changes the event “%{name}”.", words)
    end
  end

  defp sentence(%GroupChange{subject_type: "notice"}, _names),
    do: gettext("%{actor} deletes a notice.", actor: @mark)

  # What was put back, in a word.
  defp thing(%GroupChange{subject_type: "group"} = row, _names), do: fields_words("group", row)
  defp thing(%GroupChange{subject_type: "record"}, _names), do: gettext("a record of an app")

  defp thing(%GroupChange{} = row, names),
    do: "#{kind(row.subject_type)} “#{name(row, names)}”"

  @doc "What a kind of thing is called."
  def kind("group"), do: gettext("the group")
  def kind("description"), do: gettext("the description")
  def kind("template"), do: gettext("the template")
  def kind("record"), do: gettext("the record")
  def kind("process"), do: gettext("the process")
  def kind("entity"), do: gettext("the entity")
  def kind("field"), do: gettext("the field")
  def kind("poll"), do: gettext("the poll")
  def kind("event"), do: gettext("the event")
  def kind(_other), do: gettext("the change")

  @doc "What the thing of a change is called, now or when it was deleted."
  def name(%GroupChange{subject_type: type, subject_id: id}, names),
    do: names[{type, id}] || gettext("deleted since")

  defp fields_words(type, %GroupChange{fields: fields}) do
    fields
    |> Enum.map(&summary(type, &1))
    |> Enum.uniq()
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  # The fields of a group or a description, gathered into what one sees changed.
  defp summary(_type, field) when field in @access, do: gettext("who may come in and see it")
  defp summary(_type, field) when field in @place, do: gettext("the place on the map")
  defp summary("group", "name"), do: gettext("the group's name")
  defp summary("group", "group_picture_url"), do: gettext("the group's picture")
  defp summary("group", "preset"), do: gettext("the kind of the group")
  defp summary("group", "is_root_public"), do: gettext("whether it shows among the first groups")

  defp summary("group", field) when field in ["home_page", "home_alt_description_id"],
    do: gettext("what the group opens on")

  defp summary("group", "description_name"), do: gettext("the description's name")
  defp summary("group", "external_key"), do: gettext("its key in an app")
  defp summary("description", "name"), do: gettext("its name")
  defp summary("description", "description"), do: gettext("its text")
  defp summary(_type, "description"), do: gettext("the description")

  defp summary(_type, field) when field in ["description_format", "uses_api"],
    do: gettext("how the description is shown")

  defp summary(_type, _field), do: gettext("other settings")

  @doc "The icon of an entry."
  def icon(%{source: :access, row: row}), do: AccessTab.change_icon(row.kind)
  def icon(%{row: %GroupChange{subject_type: "group"}}), do: "hero-cog-6-tooth"
  def icon(%{row: %GroupChange{subject_type: "sub_group"}}), do: "hero-folder"
  def icon(%{row: %GroupChange{subject_type: "shortcut"}}), do: "hero-arrow-up-right"
  def icon(%{row: %GroupChange{subject_type: "description"}}), do: "hero-document-text"
  def icon(%{row: %GroupChange{subject_type: "template"}}), do: "hero-rectangle-stack"
  def icon(%{row: %GroupChange{subject_type: "app"}}), do: "hero-arrows-right-left"
  def icon(%{row: %GroupChange{subject_type: "record"}}), do: "hero-table-cells"
  def icon(%{row: %GroupChange{subject_type: "process"}}), do: "hero-arrow-path-rounded-square"
  def icon(%{row: %GroupChange{subject_type: "entity"}}), do: "hero-cube"
  def icon(%{row: %GroupChange{subject_type: "field"}}), do: "hero-pencil"
  def icon(%{row: %GroupChange{subject_type: "message"}}), do: "hero-chat-bubble-oval-left"

  def icon(%{row: %GroupChange{subject_type: type}}) when type in ["reaction", "group_reaction"],
    do: "hero-face-smile"

  def icon(%{row: %GroupChange{subject_type: "poll"}}), do: "hero-chart-bar"
  def icon(%{row: %GroupChange{subject_type: "event"}}), do: "hero-calendar-days"
  def icon(%{row: %GroupChange{subject_type: "notice"}}), do: "hero-bell-alert"
  def icon(_entry), do: "hero-clock"

  # ---------
  # Fields and values
  # ---------

  @doc "What a field of a thing is called."
  def field("name"), do: gettext("Name")
  def field("title"), do: gettext("Title")
  def field("question"), do: gettext("Question")
  def field("options"), do: gettext("Options")
  def field("description"), do: gettext("Description")
  def field("description_format"), do: gettext("Format of the description")
  def field("description_name"), do: gettext("Name of the description")
  def field("home_page"), do: gettext("Opens on")
  def field("home_alt_description_id"), do: gettext("Description it opens on")
  def field("has_public_chat"), do: gettext("Chat open to non-members")
  def field("description_for_guests"), do: gettext("Description open to guests")
  def field("is_public"), do: gettext("Public")
  def field("is_root_public"), do: gettext("Among the first groups")
  def field("uses_api"), do: gettext("Is an app")
  def field("preset"), do: gettext("Kind of the group")
  def field("inherits_members"), do: gettext("Takes the parent's members")
  def field("inherit_role_keys"), do: gettext("Roles it takes them by")
  def field("elects_admins"), do: gettext("Elects its admins")
  def field("join_mode"), do: gettext("How one joins")
  def field("join_poll"), do: gettext("Vote on joining")
  def field("published_at"), do: gettext("Published")
  def field("latitude"), do: gettext("Latitude")
  def field("longitude"), do: gettext("Longitude")
  def field("pin_icon"), do: gettext("Pin")
  def field("area"), do: gettext("Area on the map")
  def field("route"), do: gettext("Route on the map")
  def field("external_key"), do: gettext("Key in an app")
  def field("group_picture_url"), do: gettext("Picture")
  def field("visible_role_keys"), do: gettext("Roles that see it")
  def field("for_guests"), do: gettext("For guests")
  def field("purpose"), do: gettext("Purpose")
  def field("fields"), do: gettext("Fields")
  def field("html"), do: gettext("HTML")
  def field("data"), do: gettext("Data")
  def field("managed"), do: gettext("Grades")
  def field("content"), do: gettext("Text")
  def field("content_format"), do: gettext("Format of the text")
  def field("secret"), do: gettext("Secret")
  def field("active"), do: gettext("Switched on")
  def field("graph"), do: gettext("Drawing")
  def field("layout"), do: gettext("Places on the drawing")
  def field("trigger"), do: gettext("Starts on")
  def field("trigger_config"), do: gettext("How it starts")
  def field("collection"), do: gettext("Collection")
  def field("entry_entity_id"), do: gettext("Entity it takes")
  def field("return_entity_id"), do: gettext("Entity it hands back")
  def field("hears_related"), do: gettext("Hears the groups above and below")
  def field("attributes"), do: gettext("Attributes")
  def field("value"), do: gettext("Value")
  def field("type"), do: gettext("Type")
  def field("location"), do: gettext("Place")
  def field("all_day"), do: gettext("All day")
  def field("starts_at"), do: gettext("Starts")
  def field("ends_at"), do: gettext("Ends")
  def field("time_zone"), do: gettext("Time zone")
  def field("recurrence" <> _), do: gettext("Repeats")
  def field("excluded_dates"), do: gettext("Days left out")
  def field("reminder_minutes"), do: gettext("Reminders")
  def field("cancelled_at"), do: gettext("Cancelled")
  def field("place_group_id"), do: gettext("Group it is held in")
  def field("kind"), do: gettext("Kind")
  def field("max_choices"), do: gettext("Most answers")
  def field("allow_change"), do: gettext("The vote may be changed")
  def field("allow_member_options"), do: gettext("Members add answers")
  def field("closes_at"), do: gettext("Deadline")
  def field("closed_at"), do: gettext("Ended")
  def field("voter_role_keys"), do: gettext("Who votes")
  def field("results_role_keys"), do: gettext("Who sees the results")
  def field("details_role_keys"), do: gettext("Who sees the details")
  def field("results_when"), do: gettext("When the results show")
  def field("details_when"), do: gettext("When the details show")
  def field("quorum_percent"), do: gettext("Quorum")
  def field("majority"), do: gettext("Majority")
  def field("effect" <> _), do: gettext("What the decision changes")
  def field("unique_votes"), do: gettext("How unique profiles vote")
  def field("shared_votes"), do: gettext("How shared profiles vote")
  def field(other), do: other

  @doc "The fields whose text is compared line by line."
  def long?(field, values) do
    field in ["description", "html", "content"] or
      Enum.any?(values, &(is_binary(&1) and (String.contains?(&1, "\n") or byte_size(&1) > 160)))
  end

  @doc "A short value as it reads: yes and no, a dash for nothing, roles by their names."
  def value(field, value, manifest)
  def value(_field, nil, _manifest), do: "—"
  def value(_field, "", _manifest), do: "—"
  def value(_field, [], _manifest), do: "—"
  def value(_field, true, _manifest), do: gettext("yes")
  def value(_field, false, _manifest), do: gettext("no")

  def value(field, keys, manifest) when is_list(keys) do
    cond do
      String.ends_with?(field, "role_keys") ->
        Enum.map_join(keys, ", ", &AccessTab.role_name(&1, manifest))

      field == "options" ->
        Enum.map_join(keys, ", ", fn
          %{"text" => text} -> text
          %{"profile_id" => _} -> gettext("a candidate")
          text when is_binary(text) -> text
          other -> Jason.encode!(other)
        end)

      Enum.all?(keys, &(is_binary(&1) or is_number(&1))) ->
        Enum.join(keys, ", ")

      true ->
        Jason.encode!(keys)
    end
  end

  def value("preset", key, _manifest) when is_binary(key), do: key
  def value(_field, %{"type" => type, "coordinates" => _}, _manifest), do: type
  def value(_field, value, _manifest) when is_map(value), do: Jason.encode!(value)
  def value(_field, value, _manifest), do: to_string(value)
end
