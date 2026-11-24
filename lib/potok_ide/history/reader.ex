defmodule PotokIde.History.Reader do
  @moduledoc """
  What of a group's history its reader may see: the group's members, by the
  rules they see the things themselves by.

  - the group's own description and settings, its polls, events, notices,
    messages and reactions: every member;
  - an alternative description: who sees it now, and each side of a change
    only who could see that side then (`side?/3`); a deleted one its editors;
  - an app's record: who reads its collection, and its author; the app's
    config, and values with no collection, every member who sees the app;
  - drawn processes that are on: every member; those that are off, templates,
    entities, fields and where an app moved: those who edit the group;
  - sub-groups and shortcuts: who sees the group they lead to.

  It holds what the questions need, read once (`new/3`). `viewer` is nil where
  nothing is the reader's own, as in a preview of the page under other roles.
  """

  import Ecto.Query

  alias PotokIde.History.GroupChange
  alias PotokIde.Repo

  alias PotokIde.Social.{
    Access,
    AppProcess,
    Group,
    GroupAltDescription,
    Profile,
    Value,
    ValueRules,
    Visibility
  }

  defstruct [:group, :access, :viewer, :profile_id, :manage?, :alts, :rules]

  @open ~w(group message reaction group_reaction poll event notice)
  @editors ~w(template field entity app)

  @doc "The reader for the holder of `access`, nil for someone outside the group."
  def new(%Group{} = group, %Access{member?: true} = access, viewer, opts \\ []) do
    alts =
      from(d in GroupAltDescription,
        where: d.group_id == ^group.id,
        select: struct(d, [:id, :group_id, :name, :uses_api, :visible_role_keys, :for_guests])
      )
      |> Repo.all()
      |> Enum.filter(&Access.sees_alt_description?(access, &1))
      |> Map.new(&{&1.id, &1})

    %__MODULE__{
      group: group,
      access: access,
      viewer: viewer,
      profile_id: if(Keyword.get(opts, :own, true), do: viewer && viewer.id),
      manage?: ValueRules.manage?(access),
      alts: alts,
      rules: rules(group, Map.keys(alts))
    }
  end

  # The rules of each app the reader sees, by its description (nil for the default one).
  defp rules(%Group{id: group_id}, alt_ids) do
    from(v in Value,
      where:
        v.group_id == ^group_id and v.collection == "config" and
          (is_nil(v.alt_description_id) or v.alt_description_id in ^alt_ids),
      order_by: [asc: v.id],
      select: {v.alt_description_id, fragment("? -> 'rules'", v.data)}
    )
    |> Repo.all()
    |> Map.new(fn {alt_id, rules} -> {alt_id, if(is_map(rules), do: rules, else: %{})} end)
  end

  @doc "Whether the reader holds a side of a change that only the holders of `keys` saw."
  def keys?(%__MODULE__{}, keys) when keys in [nil, []], do: true
  def keys?(%__MODULE__{manage?: true}, _keys), do: true
  def keys?(%__MODULE__{access: access}, keys), do: Enum.any?(keys, &(&1 in access.role_keys))

  @doc "Whether the reader may see what `change` was (`:before`) or became (`:after`)."
  def side?(%__MODULE__{} = reader, %GroupChange{} = change, :before),
    do: keys?(reader, change.keys_before)

  def side?(%__MODULE__{} = reader, %GroupChange{} = change, :after),
    do: keys?(reader, change.keys_after)

  @doc "The rule of a collection of the app of `alt_id` (nil for the default description's)."
  def rule(%__MODULE__{rules: rules}, alt_id, collection),
    do: ValueRules.rule(Map.get(rules, alt_id, %{}), collection || "")

  @doc "Whether the reader reads every record of the collection, and not only their own."
  def reads_all?(%__MODULE__{manage?: true}, _alt_id, _collection), do: true

  def reads_all?(%__MODULE__{} = reader, alt_id, collection) do
    app?(reader, alt_id) and
      (collection in [nil, "config"] or
         ValueRules.full_reader?(rule(reader, alt_id, collection), reader.access))
  end

  @doc "Whether the reader sees the app of `alt_id`."
  def app?(%__MODULE__{}, nil), do: true
  def app?(%__MODULE__{alts: alts}, alt_id), do: Map.has_key?(alts, alt_id)

  @doc "The changes of `query` the reader may see."
  def visible(query, %__MODULE__{manage?: true} = reader) do
    # An editor sees all that is the group's; other groups keep their own rules.
    where(
      query,
      ^dynamic([c], c.subject_type not in ["sub_group", "shortcut"] or ^groups(reader))
    )
  end

  def visible(query, %__MODULE__{} = reader) do
    alt_ids = Map.keys(reader.alts)
    records = records(reader)
    active = from(p in AppProcess, where: p.drawn and p.active, select: p.id)

    where(
      query,
      ^dynamic(
        [c],
        c.subject_type in @open or
          ^groups(reader) or
          (c.subject_type == "description" and c.subject_id in ^alt_ids) or
          (c.subject_type == "process" and is_nil(c.keys_before) and is_nil(c.keys_after) and
             c.subject_id in subquery(active)) or
          (c.subject_type == "record" and ^records)
      )
    )
  end

  # One made that the reader sees now, one deleted that everybody saw; and
  # shortcuts to a group the reader sees.
  defp groups(%__MODULE__{viewer: %Profile{} = viewer}) do
    seen = from([group: g] in Visibility.plain_groups(viewer), select: g.id)

    dynamic(
      [c],
      (c.subject_type == "sub_group" and (c.op == :deleted or c.subject_id in subquery(seen))) or
        (c.subject_type == "shortcut" and c.subject_id in subquery(seen))
    )
  end

  defp groups(%__MODULE__{}), do: dynamic(false)

  # Records of the collections the reader reads, and the reader's own.
  defp records(%__MODULE__{} = reader) do
    own =
      if reader.profile_id,
        do: dynamic([c], c.creator_id == ^reader.profile_id),
        else: dynamic(false)

    Enum.reduce([nil | Map.keys(reader.alts)], own, fn alt_id, acc ->
      collections =
        for {name, _rule} <- Map.get(reader.rules, alt_id, %{}),
            reads_all?(reader, alt_id, name),
            do: name

      collections = ["config" | collections]

      scope =
        if alt_id,
          do: dynamic([c], c.alt_description_id == ^alt_id),
          else: dynamic([c], is_nil(c.alt_description_id))

      dynamic([c], ^acc or (^scope and (is_nil(c.collection) or c.collection in ^collections)))
    end)
  end

  @doc "The kinds of things only those who edit the group read of."
  def editors_types, do: @editors
end
