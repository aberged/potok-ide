defmodule PotokIde.Tags do
  @moduledoc """
  Tags on groups, profiles, events, values (chat values) and files.

  A private tag belongs to one profile, which can put it on anything it can
  open, and only that profile sees it. A public tag has no owner and is seen
  by everyone who can open the item. Public tags are one vocabulary for the
  whole app: putting one on an item needs `manage_tags` in the item's group
  (for a group, in the group itself or in its parent), and a profile's public
  tags are put on it by the profile itself.

  A public tag is created when it is first used and kept afterwards; lists
  and suggestions show only those still on some item. Private tags stay
  until their owner deletes them.

  Changes to public tags are broadcast on the item's group topic
  (`Social.subscribe_group/1`) as `{:tags_changed, kind, item_id}`, and for
  events as the calendar's `{:calendar, {:events_changed, group_id}}`.
  """

  import Ecto.Query, warn: false

  alias PotokIde.Events
  alias PotokIde.Events.Event
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, Group, GroupMembership, Profile, Value, ValueAttachment}
  alias PotokIde.Tags.{Tag, Tagging}

  @kinds [:group, :profile, :event, :value, :attachment]
  @columns %{
    group: :group_id,
    profile: :profile_id,
    event: :event_id,
    value: :value_id,
    attachment: :attachment_id
  }

  @max_tags_per_item 10
  @max_filter_tags 5
  @directory_limit 100

  def kinds, do: @kinds
  def max_tags_per_item, do: @max_tags_per_item
  def max_filter_tags, do: @max_filter_tags

  ## Reading an item's tags

  @doc """
  The tags `viewer` sees on each of the items of `kind` with `ids`: the
  public ones first, then its own private ones, each by name. Access to the
  items is not checked; callers ask only for items they already show.
  """
  def tags_for(_viewer, kind, []) when kind in @kinds, do: %{}

  def tags_for(%Profile{id: viewer_id}, kind, ids) when kind in @kinds and is_list(ids) do
    column = Map.fetch!(@columns, kind)

    from(t in Tagging,
      join: tag in assoc(t, :tag),
      where: field(t, ^column) in ^ids,
      where: is_nil(tag.owner_id) or tag.owner_id == ^viewer_id,
      order_by: [
        asc: fragment("? IS NOT NULL", tag.owner_id),
        asc: fragment("lower(?)", tag.name),
        asc: tag.id
      ],
      select: {field(t, ^column), tag}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc """
  Puts the tags `viewer` sees into the `:tags` field of each item (a list or
  one item). An empty list needs no query.
  """
  def put_tags([], _viewer, _kind), do: []

  def put_tags(items, %Profile{} = viewer, kind) when is_list(items) do
    tags = tags_for(viewer, kind, Enum.map(items, & &1.id))
    Enum.map(items, &%{&1 | tags: Map.get(tags, &1.id, [])})
  end

  def put_tags(%{id: _} = item, %Profile{} = viewer, kind),
    do: hd(put_tags([item], viewer, kind))

  ## Tagging

  @doc """
  The item when `profile` can open it, with whether it may put public tags
  on it. Values come with their creator, events, values and files with their
  group.
  """
  def get_taggable(%Profile{} = profile, kind, item_id)
      when kind in @kinds and is_integer(item_id) do
    with {:ok, item} <- fetch_accessible(profile, kind, item_id) do
      {:ok, %{item: item, can_public?: can_tag_public?(profile, kind, item)}}
    end
  end

  def get_taggable(_profile, _kind, _item_id), do: {:error, :not_found}

  @doc """
  Puts the tag named `name` on the item, creating the tag on first use.
  `visibility` is `:private` (the actor's own tag) or `:public`.
  """
  def add_tag(%Profile{} = actor, kind, item_id, name, visibility)
      when kind in @kinds and is_integer(item_id) and visibility in [:private, :public] do
    name = Tag.normalize_name(name)
    owner_id = if visibility == :private, do: actor.id

    with {:ok, item} <- fetch_accessible(actor, kind, item_id),
         :ok <- ensure_can_tag(actor, kind, item, visibility) do
      existing = get_tag_by_name(owner_id, name)

      cond do
        existing && tagged?(existing, kind, item.id) ->
          {:ok, existing}

        count_item_tags(kind, item.id, owner_id) >= @max_tags_per_item ->
          {:error, :too_many_tags}

        true ->
          with {:ok, tag} <- existing_or_insert(existing, owner_id, name) do
            %Tagging{tag_id: tag.id, added_by_id: actor.id}
            |> Map.put(Map.fetch!(@columns, kind), item.id)
            # A double submit races `tagged?/3`; the unique index settles it.
            |> Repo.insert!(on_conflict: :nothing)

            maybe_broadcast(tag, kind, item)
            {:ok, tag}
          end
      end
    end
  end

  def add_tag(_actor, _kind, _item_id, _name, _visibility), do: {:error, :not_found}

  @doc """
  Takes the tag off the item. A private tag is taken off only by its owner,
  a public one by whoever may put it on.
  """
  def remove_tag(%Profile{} = actor, kind, item_id, tag_id)
      when kind in @kinds and is_integer(item_id) and is_integer(tag_id) do
    with {:ok, item} <- fetch_accessible(actor, kind, item_id),
         %Tag{} = tag <- Repo.get(Tag, tag_id),
         :ok <- ensure_can_remove(actor, kind, item, tag) do
      column = Map.fetch!(@columns, kind)

      {count, _} =
        from(t in Tagging, where: t.tag_id == ^tag.id and field(t, ^column) == ^item.id)
        |> Repo.delete_all()

      if count > 0, do: maybe_broadcast(tag, kind, item)
      {:ok, tag}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  def remove_tag(_actor, _kind, _item_id, _tag_id), do: {:error, :not_found}

  defp fetch_accessible(profile, kind, item_id) do
    case load_item(kind, item_id) do
      nil ->
        {:error, :not_found}

      item ->
        if accessible?(profile, kind, item), do: {:ok, item}, else: {:error, :not_found}
    end
  end

  defp load_item(:group, id), do: Repo.get(Group, id)
  defp load_item(:profile, id), do: Repo.get(Profile, id)
  defp load_item(:event, id), do: Repo.one(from e in Event, where: e.id == ^id, preload: :group)

  defp load_item(:value, id),
    do: Repo.one(from v in Value, where: v.id == ^id, preload: [:group, :creator, :attachments])

  defp load_item(:attachment, id),
    do: Repo.one(from a in ValueAttachment, where: a.id == ^id, preload: :group)

  # The same rules as the pages that show the items: groups to members and,
  # when public, to everyone; values and files to members; events to members
  # and, when public, to everyone.
  defp accessible?(profile, :group, %Group{} = group),
    do: not group.is_root and (group.is_public or Social.member_of_group?(profile, group))

  defp accessible?(_profile, :profile, %Profile{}), do: true

  defp accessible?(profile, :event, %Event{} = event),
    do: is_nil(event.cancelled_at) and Events.visible?(profile, event)

  defp accessible?(profile, :value, %Value{} = value),
    do: not value.is_data and Social.member_of_group?(profile, value.group)

  defp accessible?(profile, :attachment, %ValueAttachment{} = attachment),
    do: Social.member_of_group?(profile, attachment.group)

  defp can_tag_public?(profile, :profile, %Profile{id: id}), do: profile.id == id

  defp can_tag_public?(profile, :group, %Group{} = group) do
    Access.can?(profile, group, :manage_tags) or
      (is_integer(group.parent_id) and
         Access.can?(profile, Repo.get!(Group, group.parent_id), :manage_tags))
  end

  defp can_tag_public?(profile, _kind, %{group: %Group{} = group}),
    do: Access.can?(profile, group, :manage_tags)

  defp ensure_can_tag(_actor, _kind, _item, :private), do: :ok

  defp ensure_can_tag(actor, kind, item, :public) do
    if can_tag_public?(actor, kind, item), do: :ok, else: {:error, :not_permitted}
  end

  defp ensure_can_remove(actor, kind, item, %Tag{owner_id: nil}),
    do: ensure_can_tag(actor, kind, item, :public)

  defp ensure_can_remove(%Profile{id: id}, _kind, _item, %Tag{owner_id: id}), do: :ok
  defp ensure_can_remove(_actor, _kind, _item, %Tag{}), do: {:error, :not_found}

  defp get_tag_by_name(owner_id, name) when is_binary(name) do
    from(tag in Tag, as: :tag, where: fragment("lower(?)", tag.name) == ^String.downcase(name))
    |> where_owner(owner_id)
    |> Repo.one()
  end

  defp get_tag_by_name(_owner_id, _name), do: nil

  # On queries that name the tag `:tag`.
  defp where_owner(query, nil), do: where(query, [tag: tag], is_nil(tag.owner_id))
  defp where_owner(query, owner_id), do: where(query, [tag: tag], tag.owner_id == ^owner_id)

  defp tagged?(%Tag{id: tag_id}, kind, item_id) do
    column = Map.fetch!(@columns, kind)
    Repo.exists?(from t in Tagging, where: t.tag_id == ^tag_id and field(t, ^column) == ^item_id)
  end

  # The item's public tags, or `owner_id`'s private ones on it.
  defp count_item_tags(kind, item_id, owner_id) do
    column = Map.fetch!(@columns, kind)

    from(t in Tagging,
      join: tag in assoc(t, :tag),
      as: :tag,
      where: field(t, ^column) == ^item_id
    )
    |> where_owner(owner_id)
    |> Repo.aggregate(:count)
  end

  defp existing_or_insert(%Tag{} = tag, _owner_id, _name), do: {:ok, tag}

  defp existing_or_insert(nil, owner_id, name) do
    case %Tag{owner_id: owner_id} |> Tag.changeset(%{name: name}) |> Repo.insert() do
      {:ok, tag} ->
        {:ok, tag}

      # Someone else created it in the meantime.
      {:error, changeset} ->
        case get_tag_by_name(owner_id, name) do
          %Tag{} = tag -> {:ok, tag}
          nil -> {:error, changeset}
        end
    end
  end

  # Private tags are seen by their owner only, whose page updates itself.
  defp maybe_broadcast(%Tag{owner_id: owner_id}, _kind, _item) when not is_nil(owner_id),
    do: :ok

  defp maybe_broadcast(_tag, :profile, _profile), do: :ok

  defp maybe_broadcast(_tag, :event, %Event{} = event),
    do: Events.broadcast_events_changed(event)

  defp maybe_broadcast(_tag, :group, %Group{} = group) do
    # The parent lists the group among its sub-groups.
    [group.id, group.parent_id]
    |> Enum.reject(&is_nil/1)
    |> Enum.each(&Social.broadcast_tags_changed(&1, :group, group.id))
  end

  defp maybe_broadcast(_tag, kind, %{id: id, group_id: group_id}),
    do: Social.broadcast_tags_changed(group_id, kind, id)

  ## Suggestions and the tag directory

  @doc """
  Tags `viewer` can use whose name contains `query`, those starting with it
  first: its own private tags and the public tags still on some item.
  """
  def suggest_tags(%Profile{} = viewer, query, limit \\ 8) do
    query = query |> to_string() |> Tag.normalize_name() |> String.downcase()

    from(tag in Tag, as: :tag)
    |> where_usable(viewer)
    |> where([tag], like(fragment("lower(?)", tag.name), ^"%#{escape_like(query)}%"))
    |> order_by([tag],
      desc: fragment("starts_with(lower(?), ?)", tag.name, ^query),
      asc: fragment("lower(?)", tag.name),
      asc: tag.id
    )
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  The tag directory of `viewer`: its private tags and the public tags still
  on some item, each by name and narrowed by `search`.
  """
  def list_directory(%Profile{id: viewer_id}, search \\ nil) do
    pattern = "%#{search |> to_string() |> String.trim() |> String.downcase() |> escape_like()}%"

    base =
      from(tag in Tag,
        as: :tag,
        where: like(fragment("lower(?)", tag.name), ^pattern),
        order_by: [asc: fragment("lower(?)", tag.name), asc: tag.id],
        limit: @directory_limit
      )

    %{
      mine: Repo.all(where(base, [tag], tag.owner_id == ^viewer_id)),
      public: base |> where([tag], is_nil(tag.owner_id)) |> where_in_use() |> Repo.all()
    }
  end

  @doc "The tags of `ids` that `viewer` may see, in the order of `ids`."
  def get_visible_tags(%Profile{} = viewer, ids) when is_list(ids) do
    ids = ids |> Enum.filter(&is_integer/1) |> Enum.uniq()

    by_id =
      from(tag in Tag,
        where: tag.id in ^ids,
        where: is_nil(tag.owner_id) or tag.owner_id == ^viewer.id
      )
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    ids |> Enum.map(&by_id[&1]) |> Enum.reject(&is_nil/1)
  end

  defp where_usable(query, %Profile{id: viewer_id}) do
    where(
      query,
      [tag],
      tag.owner_id == ^viewer_id or
        (is_nil(tag.owner_id) and
           exists(from t in Tagging, where: t.tag_id == parent_as(:tag).id, select: 1))
    )
  end

  defp where_in_use(query) do
    where(
      query,
      [tag],
      exists(from t in Tagging, where: t.tag_id == parent_as(:tag).id, select: 1)
    )
  end

  defp escape_like(text), do: String.replace(text, ~r/[\\%_]/, fn char -> "\\" <> char end)

  ## Private tags

  @doc "Renames one of `owner`'s private tags."
  def rename_private_tag(%Profile{id: owner_id}, tag_id, name) when is_integer(tag_id) do
    case Repo.get_by(Tag, id: tag_id, owner_id: owner_id) do
      nil -> {:error, :not_found}
      tag -> tag |> Tag.changeset(%{name: name}) |> Repo.update()
    end
  end

  def rename_private_tag(_owner, _tag_id, _name), do: {:error, :not_found}

  @doc "Deletes one of `owner`'s private tags, taking it off every item."
  def delete_private_tag(%Profile{id: owner_id}, tag_id) when is_integer(tag_id) do
    case Repo.get_by(Tag, id: tag_id, owner_id: owner_id) do
      nil -> {:error, :not_found}
      tag -> Repo.delete(tag)
    end
  end

  def delete_private_tag(_owner, _tag_id), do: {:error, :not_found}

  ## Items by tag

  @doc """
  A keyset page of the items of `kind` that carry every one of `tags` and
  that `viewer` can open, newest first. Returns `{items, more?}`.

  Options: `:group` limits the items to a group and its sub-groups (for
  profiles, to the group's members); callers pass only a group the viewer
  can see. `:limit` (default 30) and `:before_id`.
  """
  def list_tagged(%Profile{} = viewer, kind, tags, opts \\ []) when kind in @kinds do
    limit = Keyword.get(opts, :limit, 30)

    case tagged_query(viewer, kind, tags, opts[:group]) do
      nil ->
        {[], false}

      query ->
        rows =
          query
          |> maybe_before_id(opts[:before_id])
          |> order_by([item], desc: item.id)
          |> limit(^(limit + 1))
          |> preload(^tagged_preloads(kind))
          |> Repo.all()

        {rows |> Enum.take(limit) |> put_tags(viewer, kind), length(rows) > limit}
    end
  end

  @doc "How many items of `kind` `list_tagged/4` finds."
  def count_tagged(%Profile{} = viewer, kind, tags, opts \\ []) when kind in @kinds do
    case tagged_query(viewer, kind, tags, opts[:group]) do
      nil -> 0
      query -> Repo.aggregate(query, :count)
    end
  end

  defp tagged_query(_viewer, _kind, [], _group), do: nil

  defp tagged_query(%Profile{} = viewer, kind, tags, group) do
    tag_ids = Enum.map(tags, & &1.id)

    kind
    |> base_query(viewer.id)
    |> join(:inner, [item], m in subquery(matching_ids(viewer.id, kind, tag_ids)),
      on: m.id == item.id
    )
    |> scope_to_group(kind, group)
  end

  # Items carrying every tag in `tag_ids`, counting only tags the viewer sees.
  defp matching_ids(viewer_id, kind, tag_ids) do
    column = Map.fetch!(@columns, kind)
    count = length(tag_ids)

    from(t in Tagging,
      join: tag in assoc(t, :tag),
      where: t.tag_id in ^tag_ids and not is_nil(field(t, ^column)),
      where: is_nil(tag.owner_id) or tag.owner_id == ^viewer_id,
      group_by: field(t, ^column),
      having: count(t.tag_id, :distinct) == ^count,
      select: %{id: field(t, ^column)}
    )
  end

  defp base_query(:group, viewer_id) do
    from(g in Group,
      left_join: gm in GroupMembership,
      on: gm.group_id == g.id and gm.profile_id == ^viewer_id,
      where: not g.is_root and (g.is_public or not is_nil(gm.profile_id))
    )
  end

  defp base_query(:profile, _viewer_id), do: from(p in Profile)

  defp base_query(:event, viewer_id) do
    from(e in Event,
      left_join: gm in GroupMembership,
      on: gm.group_id == e.group_id and gm.profile_id == ^viewer_id,
      where: is_nil(e.cancelled_at) and (e.is_public or not is_nil(gm.profile_id))
    )
  end

  defp base_query(:value, viewer_id) do
    from(v in Value,
      join: gm in GroupMembership,
      on: gm.group_id == v.group_id and gm.profile_id == ^viewer_id,
      where: v.is_data == false
    )
  end

  defp base_query(:attachment, viewer_id) do
    from(a in ValueAttachment,
      join: gm in GroupMembership,
      on: gm.group_id == a.group_id and gm.profile_id == ^viewer_id
    )
  end

  defp scope_to_group(query, _kind, nil), do: query
  defp scope_to_group(query, _kind, %Group{is_root: true}), do: query

  defp scope_to_group(query, :profile, %Group{id: group_id}) do
    join(query, :inner, [p], scope in GroupMembership,
      on: scope.profile_id == p.id and scope.group_id == ^group_id
    )
  end

  defp scope_to_group(query, :group, %Group{id: group_id}),
    do: where(query, [g], g.id in subquery(subtree_ids(group_id)))

  defp scope_to_group(query, _kind, %Group{id: group_id}),
    do: where(query, [item], item.group_id in subquery(subtree_ids(group_id)))

  defp subtree_ids(group_id) do
    initial = from(g in Group, where: g.id == ^group_id, select: %{id: g.id})

    descendants =
      from(g in Group, join: s in "tag_scope", on: g.parent_id == s.id, select: %{id: g.id})

    from(s in "tag_scope", select: s.id)
    |> recursive_ctes(true)
    |> with_cte("tag_scope", as: ^union_all(initial, ^descendants))
  end

  defp maybe_before_id(query, before_id) when is_integer(before_id),
    do: where(query, [item], item.id < ^before_id)

  defp maybe_before_id(query, _before_id), do: query

  defp tagged_preloads(:group), do: []
  defp tagged_preloads(:profile), do: []
  defp tagged_preloads(:event), do: [:group]
  defp tagged_preloads(:value), do: [:group, :creator, :attachments]
  defp tagged_preloads(:attachment), do: [:group, :profile]
end
