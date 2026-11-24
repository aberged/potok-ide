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
  alias PotokIde.Social.{Group, GroupMembership, Profile, ProfileFacts, ProfileField}

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
