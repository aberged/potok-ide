defmodule PotokIde.History.Restore do
  @moduledoc """
  Puts back what a change took away: what a thing was before it, or a thing it
  deleted. It goes the ways changes go, with the rights of whoever does it, and
  is a change of its own in the history, which says what it put back.

  What can be put back, and by whom:

  - a group's name, descriptions, home page and place; alternative
    descriptions, templates, fields and an app's config: those who edit the
    group. Who may come in and see it never is: that is decided anew;
  - a record: its author, as far as the app lets them change it;
  - a deleted description, with the records its app lost with it, a deleted
    record or collection, a deleted template or drawing: those who edit. Records
    and descriptions come back under their own ids, so what names them finds
    them, with their authors and times, starting no process and telling nobody.
    Files are not kept, so those they named are gone;
  - an earlier drawing of a process opens in its editor, unsaved
    (`GroupLive.Show.ProcessEditorState`).

  The secret part of a config is not in the history: the one it has now stays,
  and with it the scores.
  """

  import Ecto.Query

  alias PotokIde.{History, Repo, Social}
  alias PotokIde.History.{GroupChange, Reader}
  alias PotokIde.Processes.{GroupField, GroupFields}

  alias PotokIde.Social.{
    Access,
    AppData,
    DrawnProcesses,
    Group,
    GroupAltDescription,
    GroupTemplate,
    GroupTemplates,
    Profile,
    Value,
    ValueRules
  }

  @group ~w(name description description_format description_name uses_api home_page latitude
            longitude pin_icon area route)
  @description ~w(name description description_format uses_api)
  @template ~w(name purpose fields html)
  @field ~w(value type options)

  # More than this is put back in as many goes.
  @max_records 5_000

  @doc """
  Whether the reader may put back what `change` (with its old values) took
  away: `:here` for what `run/4` does, `:editor` for a drawing that opens in
  its editor, or nil.
  """
  def offered(%Reader{viewer: %Profile{}} = reader, %GroupChange{} = change) do
    cond do
      change.purged_at != nil or is_nil(change.before) -> nil
      not Reader.side?(reader, change, :before) -> nil
      true -> offer(reader, change)
    end
  end

  def offered(_reader, _change), do: nil

  defp offer(%Reader{manage?: true}, %GroupChange{subject_type: "group", op: :changed} = change),
    do: if(any?(change, @group), do: :here)

  defp offer(%Reader{manage?: true}, %GroupChange{subject_type: "description"} = change) do
    there? = Repo.exists?(from(d in GroupAltDescription, where: d.id == ^change.subject_id))

    case change.op do
      :changed -> if(there? and any?(change, @description), do: :here)
      :deleted -> if(not there?, do: :here)
      _created -> nil
    end
  end

  defp offer(%Reader{manage?: true}, %GroupChange{subject_type: "template"} = change) do
    there? = Repo.exists?(from(t in GroupTemplate, where: t.id == ^change.subject_id))
    if (change.op == :changed and there?) or change.op == :deleted, do: :here
  end

  defp offer(%Reader{manage?: true}, %GroupChange{subject_type: "field", op: :changed} = change) do
    there? = Repo.exists?(from(f in GroupField, where: f.id == ^change.subject_id))
    if there? and any?(change, @field), do: :here
  end

  defp offer(%Reader{} = reader, %GroupChange{subject_type: "process"} = change) do
    cond do
      change.op == :changed and any?(change, ~w(graph name layout trigger_config)) -> :editor
      change.op == :deleted and reader.manage? -> :here
      true -> nil
    end
  end

  defp offer(
         %Reader{manage?: true},
         %GroupChange{subject_type: "record", collection: "config", op: :changed} = change
       ),
       do: if(any?(change, ["data"]), do: :here)

  defp offer(%Reader{} = reader, %GroupChange{subject_type: "record", op: :changed} = change) do
    own? = change.creator_id == reader.profile_id and not is_nil(reader.profile_id)

    if own? and change.collection != nil and any?(change, ["data"]) and
         Repo.exists?(from(v in Value, where: v.id == ^change.subject_id)),
       do: :here
  end

  defp offer(%Reader{manage?: true}, %GroupChange{subject_type: "record", op: :deleted} = change) do
    cond do
      change.alt_description_id && not alt?(change) -> nil
      Repo.exists?(from(v in Value, where: v.id == ^change.subject_id)) -> nil
      true -> :here
    end
  end

  defp offer(_reader, _change), do: nil

  defp any?(%GroupChange{before: before}, keys), do: Enum.any?(keys, &Map.has_key?(before, &1))

  defp alt?(%GroupChange{alt_description_id: id}),
    do: Repo.exists?(from(d in GroupAltDescription, where: d.id == ^id))

  @doc """
  Puts it back. Returns `{:ok, %{records: how_many, lost_files: how_many}}` or
  `{:error, reason}`, `:not_permitted` among them and whatever the way it goes
  refuses with.
  """
  def run(%Profile{} = profile, %Group{} = group, %Reader{} = reader, %GroupChange{} = change) do
    if offered(reader, change) == :here and change.group_id == group.id do
      History.also([restored: change.id], fn -> put_back(profile, group, change) end)
      |> case do
        {:ok, %{records: _} = done} -> {:ok, done}
        {:ok, _changed} -> {:ok, %{records: 0, lost_files: 0}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :not_permitted}
    end
  end

  defp put_back(profile, group, %GroupChange{subject_type: "group"} = change),
    do: Social.update_group(profile, group, Map.take(change.before, @group))

  defp put_back(profile, group, %GroupChange{subject_type: "description", op: :changed} = change) do
    case Social.get_alt_description(group, change.subject_id) do
      nil ->
        {:error, :not_found}

      alt ->
        Social.update_alt_description(
          profile,
          group,
          alt,
          Map.take(change.before, @description)
        )
    end
  end

  # With the records that went in the same act.
  defp put_back(profile, group, %GroupChange{subject_type: "description"} = change) do
    with {:ok, _alt} <-
           Social.restore_alt_description(
             profile,
             group,
             change.subject_id,
             change.creator_id,
             change.before
           ) do
      put_records_back(profile, group, records_of(change, change.subject_id))
    end
  end

  defp put_back(profile, group, %GroupChange{subject_type: "template", op: :changed} = change) do
    case Repo.get_by(GroupTemplate, id: change.subject_id, group_id: group.id) do
      nil ->
        {:error, :not_found}

      template ->
        GroupTemplates.update(profile, group, template, Map.take(change.before, @template))
    end
  end

  defp put_back(profile, group, %GroupChange{subject_type: "template"} = change),
    do: GroupTemplates.create(profile, group, Map.take(change.before, @template))

  defp put_back(profile, group, %GroupChange{subject_type: "field"} = change) do
    access = Access.for_profile(profile, group)
    attrs = Map.take(change.before, @field)
    GroupFields.put_back(group, access, change.subject_id, attrs, profile)
  end

  defp put_back(profile, group, %GroupChange{subject_type: "process"} = change) do
    before = change.before

    DrawnProcesses.create(profile, group, %{
      "name" => before["name"],
      "graph" => before["graph"],
      "layout" => before["layout"],
      "trigger" => before["trigger"],
      "trigger_config" => before["trigger_config"],
      "collection" => before["collection"],
      "alt_id" => change.alt_description_id,
      "entry_entity_id" => before["entry_entity_id"],
      "return_entity_id" => before["return_entity_id"],
      "is_public" => before["is_public"]
    })
  end

  defp put_back(
         profile,
         group,
         %GroupChange{subject_type: "record", collection: "config", op: :changed} = change
       ) do
    alt = change.alt_description_id && %GroupAltDescription{id: change.alt_description_id}

    case AppData.get_config(group, alt) do
      nil ->
        {:error, :not_found}

      config ->
        data =
          case config.data do
            %{"secret" => secret} -> Map.put(change.before["data"], "secret", secret)
            _none -> change.before["data"]
          end

        AppData.save_config(profile, group, alt, data, config.lock_version)
    end
  end

  defp put_back(profile, group, %GroupChange{subject_type: "record", op: :changed} = change) do
    alt = change.alt_description_id && %GroupAltDescription{id: change.alt_description_id}

    case AppData.update(profile, group, alt, change.subject_id, change.before["data"], nil) do
      {:ok, value, _rule} -> {:ok, value}
      error -> error
    end
  end

  # One record, or all that went with it in the same act.
  defp put_back(profile, group, %GroupChange{subject_type: "record"} = change) do
    changes =
      if is_integer(change.cause["count"]),
        do: records_of(change, change.alt_description_id),
        else: [change]

    put_records_back(profile, group, changes)
  end

  defp records_of(%GroupChange{op_id: nil}, _alt_id), do: []

  defp records_of(%GroupChange{} = change, alt_id) do
    query =
      from(c in GroupChange,
        where:
          c.group_id == ^change.group_id and c.subject_type == "record" and c.op == :deleted and
            c.op_id == ^change.op_id and not is_nil(c.before),
        order_by: c.id,
        limit: @max_records,
        select_merge: %{before: c.before}
      )

    query =
      if alt_id,
        do: where(query, [c], c.alt_description_id == ^alt_id),
        else: where(query, [c], is_nil(c.alt_description_id))

    # A collection is put back without the rest of what its app lost.
    query =
      case change do
        %{subject_type: "record", collection: nil} -> where(query, [c], is_nil(c.collection))
        %{subject_type: "record", collection: one} -> where(query, [c], c.collection == ^one)
        _description -> query
      end

    Repo.all(query)
  end

  defp put_records_back(profile, %Group{} = group, changes) do
    access = Access.for_profile(profile, Repo.get!(Group, group.id))

    if ValueRules.manage?(access) do
      {:ok, AppData.put_back(profile, group, changes)}
    else
      {:error, :not_permitted}
    end
  end
end
