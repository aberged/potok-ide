defmodule PotokIde.Social.ProfileDetails do
  @moduledoc """
  A profile's details (`PotokIde.Social.ProfileField`) and its description,
  and who sees each of them.

  Who sees what is a plain function of `PotokIde.Social.ProfileFacts`:

    * the accounts that hold the profile see everything;
    * `:only_me` nobody else;
    * `:signed_in` everyone signed in who sees the profile;
    * `:shared_groups` whoever is a member of a group the profile is in
      (`ProfileFacts.group_ids/1`);
    * `:groups` whoever is a member of one of the picked groups the profile
      is in too. A picked group the profile left, or one that is gone, only
      drops out.

  A process or a deleted profile has no details.
  """

  import Ecto.Query, warn: false

  alias PotokIde.Repo
  alias PotokIde.Social.{Access, Group, GroupMembership, Profile, ProfileFacts, ProfileField}
  alias PotokIde.Tags

  @max_group_choices 500
  @key [:profile_id, :key]
  @replaced [:value, :audience, :group_ids, :updated_at]

  @doc "Whether something kept for `audience` (and `group_ids`) is seen with `facts`."
  def visible?(_audience, _group_ids, %ProfileFacts{kind: kind}) when kind != :person, do: false
  def visible?(_audience, _group_ids, %ProfileFacts{holder?: true}), do: true
  def visible?(:only_me, _group_ids, _facts), do: false
  def visible?(:signed_in, _group_ids, _facts), do: true

  def visible?(:shared_groups, _group_ids, facts),
    do: MapSet.size(ProfileFacts.group_ids(facts)) > 0

  def visible?(:groups, group_ids, facts) do
    in_groups = ProfileFacts.group_ids(facts)
    Enum.any?(group_ids, &MapSet.member?(in_groups, &1))
  end

  @doc "The fields of `fields` the viewer of `facts` sees, in their order."
  def visible_fields(fields, %ProfileFacts{} = facts) when is_list(fields),
    do: Enum.filter(fields, &visible?(&1.audience, &1.group_ids, facts))

  @doc "Whether the viewer of `facts` reads the profile's description."
  def description_visible?(%Profile{} = profile, %ProfileFacts{} = facts) do
    profile.description not in [nil, ""] and
      visible?(profile.description_audience, profile.description_group_ids, facts)
  end

  @doc "The profile's filled fields, in the order a profile shows them."
  def list_fields(%Profile{id: profile_id}) do
    from(f in ProfileField, where: f.profile_id == ^profile_id)
    |> Repo.all()
    |> sort_fields()
  end

  defp sort_fields(fields) do
    order = ProfileField.keys() |> Enum.with_index() |> Map.new()
    Enum.sort_by(fields, &Map.fetch!(order, &1.key))
  end

  @doc """
  A changeset for each key, in order, for the form: the stored field (or an
  empty one) with what `params` sends for it under the key's name. A key
  `params` leaves out keeps what is stored.
  """
  def changesets(%Profile{id: profile_id}, stored_fields, params, allowed_group_ids)
      when is_list(stored_fields) do
    stored = Map.new(stored_fields, &{&1.key, &1})
    params = params || %{}

    for key <- ProfileField.keys() do
      field = Map.get(stored, key) || ProfileField.new(profile_id, key)

      changeset =
        case Map.get(params, Atom.to_string(key)) do
          attrs when is_map(attrs) -> ProfileField.changeset(field, attrs, allowed_group_ids)
          _ -> Ecto.Changeset.change(field)
        end

      {key, changeset}
    end
  end

  @doc "Whether every changeset of `changesets/4` may be saved."
  def valid?(changesets), do: Enum.all?(changesets, fn {_key, cs} -> cs.valid? end)

  @doc "Whether `changesets/4` change anything that is stored."
  def changed?(changesets) do
    Enum.any?(changesets, fn {_key, changeset} ->
      stored? = changeset.data.id != nil

      cond do
        ProfileField.blank?(changeset) -> stored?
        not stored? -> true
        true -> changeset.changes != %{}
      end
    end)
  end

  @doc """
  Writes `changesets/4` with `repo`, inside the caller's transaction: a
  filled field is inserted or updated, an emptied one deleted, and an empty
  one that was never filled left out.
  """
  def save!(repo, changesets) do
    Enum.each(changesets, fn {_key, changeset} ->
      stored? = changeset.data.id != nil

      cond do
        ProfileField.blank?(changeset) and stored? -> repo.delete!(changeset.data)
        ProfileField.blank?(changeset) -> :ok
        stored? -> if changeset.changes != %{}, do: repo.update!(changeset)
        # Saved from two pages at once, the later one wins.
        true -> repo.insert!(changeset, on_conflict: {:replace, @replaced}, conflict_target: @key)
      end
    end)
  end

  @max_card_groups 12

  @doc """
  What `viewer` (the current profile of `account`) sees on the card of
  `target`: its visible fields, whether it reads the description, the tags
  the viewer sees on it, up to #{@max_card_groups} of the groups both are in, and
  whether the viewer may write to it. Who may open the card at all is the
  caller's to say (`card_in_group?/3`, `PotokIde.Social.Discovery`).
  """
  def card(account, viewer, %Profile{} = target) do
    facts = ProfileFacts.load(account, viewer, target)

    %{
      profile: target,
      facts: facts,
      fields: target |> list_fields() |> visible_fields(facts),
      description?: description_visible?(target, facts),
      tags: card_tags(viewer, target),
      shared_groups: shared_groups(facts),
      can_message?: can_message?(facts, viewer)
    }
  end

  # Whether the viewer may open a direct conversation with the profile from
  # its card: a person, and someone else's.
  defp can_message?(%ProfileFacts{kind: :person, holder?: false}, %Profile{kind: :person}),
    do: true

  defp can_message?(_facts, _viewer), do: false

  defp card_tags(nil, _target), do: []

  defp card_tags(%Profile{} = viewer, %Profile{id: id}) do
    viewer |> Tags.tags_for(:profile, [id]) |> Map.get(id, [])
  end

  defp shared_groups(%ProfileFacts{holder?: true}), do: []

  # A sub-group that takes in all of its parent's members says nothing more
  # when the parent is shared too, like a map's places.
  defp shared_groups(%ProfileFacts{shared_group_ids: shared}) do
    ids = MapSet.to_list(shared)

    from(g in Group,
      where: g.id in ^ids,
      where:
        not (g.inherits_members and g.inherit_role_keys == ^[] and
               g.parent_id in ^ids),
      order_by: [asc: fragment("lower(?)", g.name), asc: g.id],
      limit: @max_card_groups,
      select: %{id: g.id, name: g.name}
    )
    |> Repo.all()
  end

  @doc """
  Whether the card of `target` opens on the page of `group` for a viewer
  with `access`, whatever the profile lets others find: the group shows the
  profile there already. That is a member to a member, an author of a
  message to whoever reads the chat (a public group's open chat too),
  someone asking to join to whoever decides it, and someone blocked to
  whoever may remove members.
  """
  def card_in_group?(%Access{} = access, %Group{id: group_id} = group, %Profile{
        kind: :person,
        id: id
      }) do
    sql = """
    SELECT
      EXISTS(SELECT 1 FROM group_memberships WHERE group_id = $1 AND profile_id = $2),
      EXISTS(SELECT 1 FROM values
             WHERE group_id = $1 AND creator_id = $2 AND NOT is_data),
      EXISTS(SELECT 1 FROM group_join_requests WHERE group_id = $1 AND requester_id = $2),
      EXISTS(SELECT 1 FROM group_blocks WHERE group_id = $1 AND profile_id = $2)
    """

    %{rows: [[member?, author?, asking?, blocked?]]} =
      Repo.query!(sql, [group_id, id], cache_statement: "profile_card_in_group_v1")

    (access.member? and member?) or (Access.can_read_chat?(access, group) and author?) or
      (Access.can?(access, :manage_join_requests) and asking?) or
      (Access.can?(access, :remove_members) and blocked?)
  end

  def card_in_group?(_access, _group, _target), do: false

  @doc """
  The full names the viewer sees of `profile_ids`, members of `group` (the
  page they are listed on), as `%{profile_id => "First Last"}`; a profile
  whose names the viewer sees neither of is left out. Two queries at most: in
  a shared group the viewer is a member of, every member shares it, so only
  names shown to picked groups other than this one need the groups both are
  in.
  """
  def names_for(account, %Profile{} = viewer, profile_ids, %Group{} = group, %Access{} = access)
      when is_list(profile_ids) do
    rows = name_rows(account, profile_ids)
    here? = access.member? and plain_group?(group)

    {decided, open} =
      Enum.split_with(rows, fn row ->
        row.held? or row.profile_id == viewer.id or row.audience in [:only_me, :signed_in] or
          (here? and (row.audience == :shared_groups or group.id in row.group_ids))
      end)

    shared = shared_ids_many(viewer, open |> Enum.map(& &1.profile_id) |> Enum.uniq())

    visible =
      Enum.filter(decided, fn row ->
        row.held? or row.profile_id == viewer.id or row.audience != :only_me
      end) ++
        Enum.filter(open, fn row ->
          in_groups = Map.get(shared, row.profile_id, MapSet.new())

          case row.audience do
            :shared_groups -> MapSet.size(in_groups) > 0
            :groups -> Enum.any?(row.group_ids, &MapSet.member?(in_groups, &1))
          end
        end)

    visible
    |> Enum.group_by(& &1.profile_id)
    |> Map.new(fn {profile_id, rows} ->
      keys = Map.new(rows, &{&1.key, &1.value})
      {profile_id, Enum.join(Enum.reject([keys[:first_name], keys[:last_name]], &is_nil/1), " ")}
    end)
  end

  defp name_rows(_account, []), do: []

  defp name_rows(account, profile_ids) do
    # No account holds an id of 0.
    account_id = if account, do: account.id, else: 0

    from(f in ProfileField,
      left_join: ap in "accounts_profiles",
      on: ap.profile_id == f.profile_id and ap.account_id == ^account_id,
      where: f.profile_id in ^profile_ids and f.key in [:first_name, :last_name],
      select: %{
        profile_id: f.profile_id,
        key: f.key,
        value: f.value,
        audience: f.audience,
        group_ids: f.group_ids,
        held?: not is_nil(ap.profile_id)
      }
    )
    |> Repo.all()
  end

  # The shared groups each of `profile_ids` is in with the viewer.
  defp shared_ids_many(_viewer, []), do: %{}

  defp shared_ids_many(%Profile{id: viewer_id}, profile_ids) do
    sql = """
    SELECT t.profile_id, array_agg(t.group_id)
    FROM group_memberships t
    JOIN group_memberships v ON v.group_id = t.group_id AND v.profile_id = $1
    JOIN groups g ON g.id = t.group_id
    WHERE t.profile_id = ANY($2) AND #{ProfileFacts.plain_group_sql("g")}
    GROUP BY t.profile_id
    """

    %{rows: rows} =
      Repo.query!(sql, [viewer_id, profile_ids], cache_statement: "profile_shared_ids_many_v1")

    Map.new(rows, fn [profile_id, ids] -> {profile_id, MapSet.new(ids)} end)
  end

  defp plain_group?(%Group{} = group) do
    not group.is_root and not group.is_direct and is_nil(group.parent_value_id) and
      is_nil(group.external_key)
  end

  @doc """
  The groups the profile may show a detail to, by name, each with the name of
  the group it is in unless that is the root, as names repeat ("Ulaz A").

  They are the shared groups (`ProfileFacts.plain_group_sql/1`) it joined
  itself, and those it is in through a parent that passes on only some
  roles, like a council: a sub-group that takes in all of its parent's
  members, such as a map's places, has no one the parent lacks.
  """
  def group_choices(%Profile{} = profile) do
    profile
    |> choices_query()
    |> join(:left, [gm, g], parent in Group, on: parent.id == g.parent_id and not parent.is_root)
    |> order_by([gm, g], asc: fragment("lower(?)", g.name), asc: g.id)
    |> limit(@max_group_choices)
    |> select([gm, g, parent], %{id: g.id, name: g.name, parent_name: parent.name})
    |> Repo.all()
  end

  @doc "The ids a detail of the profile may pick: those of `group_choices/1`."
  def allowed_group_ids(%Profile{} = profile) do
    profile
    |> choices_query()
    |> select([gm], gm.group_id)
    |> Repo.all()
  end

  defp choices_query(%Profile{id: profile_id}) do
    from(gm in GroupMembership,
      join: g in Group,
      on: g.id == gm.group_id,
      where:
        gm.profile_id == ^profile_id and not g.is_root and not g.is_direct and
          is_nil(g.parent_value_id) and is_nil(g.external_key),
      where: not gm.inherited or g.inherit_role_keys != ^[]
    )
  end
end
