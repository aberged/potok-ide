defmodule PotokIde.Social.PinnedGroups do
  @moduledoc """
  The groups a profile pins at the top of its column beside a group's page
  (`PotokIdeWeb.GroupLive.Show.GroupSidebar`), up to 20 of them, in the
  order it pinned them. Only that profile sees them.

  Any group it may see can be pinned but the root and a direct conversation,
  which have places of their own. A pinned group it can no longer see (it
  left a private group) stays pinned but is not listed, and comes back if it
  may see the group again; deleting the group deletes the pin.
  """

  import Ecto.Query

  alias PotokIde.Repo
  alias PotokIde.Social.{Group, PinnedGroup, Profile}

  @max 20

  def max, do: @max

  @doc "Whether the profile may pin `group` at all (not which it can see)."
  def pinnable?(%Group{is_root: true}), do: false
  def pinnable?(%Group{is_direct: true}), do: false
  def pinnable?(%Group{}), do: true

  @doc """
  Pins `group`, which the caller made sure the profile sees. Pinning a group
  twice is fine. `{:error, :too_many}` past #{@max}.
  """
  def pin(%Profile{id: profile_id}, %Group{id: group_id} = group) do
    cond do
      not pinnable?(group) ->
        {:error, :not_pinnable}

      pinned?(%Profile{id: profile_id}, group_id) ->
        :ok

      count(profile_id) >= @max ->
        {:error, :too_many}

      true ->
        %PinnedGroup{profile_id: profile_id, group_id: group_id}
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:profile_id, :group_id])
        |> case do
          {:ok, _pin} -> :ok
          {:error, _changeset} = error -> error
        end
    end
  end

  @doc "Takes the pin off, if there is one."
  def unpin(%Profile{id: profile_id}, group_id) when is_integer(group_id) do
    from(p in PinnedGroup, where: p.profile_id == ^profile_id and p.group_id == ^group_id)
    |> Repo.delete_all()

    :ok
  end

  def pinned?(%Profile{id: profile_id}, group_id) when is_integer(group_id) do
    Repo.exists?(
      from(p in PinnedGroup, where: p.profile_id == ^profile_id and p.group_id == ^group_id)
    )
  end

  def pinned?(_profile, _group_id), do: false

  @doc "The ids of the groups the profile pinned, seen or not."
  def ids(%Profile{id: profile_id}) do
    from(p in PinnedGroup, where: p.profile_id == ^profile_id, select: p.group_id)
    |> Repo.all()
  end

  @doc """
  The pinned groups the profile sees, in the order it pinned them, each as
  `%{group: %Group{}, path: [name]}`: the names of the groups above it it
  sees, from the top, the root left out. One statement for the pins and
  their paths, one for the groups.
  """
  def list(%Profile{id: profile_id}) do
    sql = """
    WITH RECURSIVE pins AS (
      SELECT p.id AS pin_id, g.id AS group_id, g.parent_id
      FROM pinned_groups p
      JOIN groups g ON g.id = p.group_id
      WHERE p.profile_id = $1 AND #{visible_sql("g")}
    ),
    up AS (
      SELECT pins.pin_id, pins.parent_id AS id, 1 AS depth FROM pins
      UNION ALL
      SELECT up.pin_id, g.parent_id, up.depth + 1
      FROM up
      JOIN groups g ON g.id = up.id
      WHERE g.parent_id IS NOT NULL AND up.depth < 30
    )
    SELECT pins.group_id, ARRAY(
      SELECT g.name
      FROM up
      JOIN groups g ON g.id = up.id
      WHERE up.pin_id = pins.pin_id AND NOT g.is_root AND #{visible_sql("g")}
      ORDER BY up.depth DESC
    )
    FROM pins
    ORDER BY pins.pin_id
    """

    %{rows: rows} = Repo.query!(sql, [profile_id], cache_statement: "pinned_groups_list")
    ids = Enum.map(rows, &hd/1)
    groups = from(g in Group, where: g.id in ^ids) |> Repo.all() |> Map.new(&{&1.id, &1})

    for [id, path] <- rows, %Group{} = group <- [groups[id]], do: %{group: group, path: path}
  end

  defp count(profile_id),
    do: Repo.aggregate(from(p in PinnedGroup, where: p.profile_id == ^profile_id), :count)

  # What `Social.get_visible_group/2` lets the profile ($1) see: a public
  # group or one it is a member of.
  defp visible_sql(alias) do
    "(#{alias}.is_public OR EXISTS (" <>
      "SELECT 1 FROM group_memberships gm WHERE gm.group_id = #{alias}.id AND gm.profile_id = $1))"
  end
end
