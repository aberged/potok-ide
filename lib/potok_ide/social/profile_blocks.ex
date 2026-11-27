defmodule PotokIde.Social.ProfileBlocks do
  @moduledoc """
  Profiles blocking profiles (`PotokIde.Social.ProfileBlock`). A block closes
  the direct conversation of the two, whoever of them made it: `Access` gives
  neither of them any permission there, so nobody writes, reacts or votes, and
  `Social.get_or_create_direct_group/2` opens no new one. What was written
  stays readable. The two still meet in the groups they share, where the
  admins decide (`Social.block_from_group/3`).

  Only people block and are blocked: a process writes to nobody directly and
  a deleted profile is written to no more.
  """

  import Ecto.Query, warn: false

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, Group, GroupMembership, Profile, ProfileBlock}

  @doc """
  `blocker` blocks `blocked`. Blocking again changes nothing. The pages of
  their direct conversation read their access again.
  """
  def block(%Profile{id: id}, %Profile{id: id}), do: {:error, :same_profile}

  def block(%Profile{kind: :person} = blocker, %Profile{kind: :person} = blocked) do
    %ProfileBlock{blocker_id: blocker.id, blocked_id: blocked.id}
    |> Repo.insert(on_conflict: :nothing, conflict_target: [:blocker_id, :blocked_id])
    |> case do
      {:ok, _block} ->
        closed_or_opened(blocker.id, blocked.id)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  def block(%Profile{}, %Profile{}), do: {:error, :not_a_person}

  @doc "`blocker` lifts its block on `blocked_id`. A block made by the other one stays."
  def unblock(%Profile{id: blocker_id}, blocked_id) when is_integer(blocked_id) do
    from(b in ProfileBlock, where: b.blocker_id == ^blocker_id and b.blocked_id == ^blocked_id)
    |> Repo.delete_all()
    |> case do
      {0, _} -> :ok
      {_count, _} -> closed_or_opened(blocker_id, blocked_id)
    end

    :ok
  end

  @doc "Whether `blocker_id` blocked `blocked_id`."
  def blocked?(blocker_id, blocked_id) when is_integer(blocker_id) and is_integer(blocked_id) do
    Repo.exists?(
      from(b in ProfileBlock, where: b.blocker_id == ^blocker_id and b.blocked_id == ^blocked_id)
    )
  end

  @doc "Whether either of the two blocked the other."
  def between?(first_id, second_id) when is_integer(first_id) and is_integer(second_id) do
    Repo.exists?(
      from(b in ProfileBlock,
        where:
          (b.blocker_id == ^first_id and b.blocked_id == ^second_id) or
            (b.blocker_id == ^second_id and b.blocked_id == ^first_id)
      )
    )
  end

  @doc """
  Whether the direct conversation `group_id` is closed: one of its members
  blocked the other. `Access` asks it when it reads a member's roles there.
  """
  def direct_group_closed?(group_id) when is_integer(group_id),
    do: closed_direct_group_ids([group_id]) != MapSet.new()

  @doc "Which of `group_ids` (direct conversations) are closed, in one query."
  def closed_direct_group_ids([]), do: MapSet.new()

  def closed_direct_group_ids(group_ids) when is_list(group_ids) do
    from(b in ProfileBlock,
      join: m1 in GroupMembership,
      on: m1.profile_id == b.blocker_id,
      join: m2 in GroupMembership,
      on: m2.profile_id == b.blocked_id and m2.group_id == m1.group_id,
      where: m1.group_id in ^group_ids,
      distinct: true,
      select: m1.group_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  The member of the direct conversation `group_id` that `profile` blocked, or
  nil: the composer of a closed conversation offers to lift that block.
  """
  def blocked_member_id(%Profile{id: profile_id}, group_id) when is_integer(group_id) do
    from(b in ProfileBlock,
      join: m in GroupMembership,
      on: m.profile_id == b.blocked_id and m.group_id == ^group_id,
      where: b.blocker_id == ^profile_id,
      select: b.blocked_id,
      limit: 1
    )
    |> Repo.one()
  end

  def blocked_member_id(_profile, _group_id), do: nil

  @doc "The profiles `profile` blocked, newest first, for its list in the settings."
  def list_blocked(%Profile{id: profile_id}) do
    from(p in Profile,
      join: b in ProfileBlock,
      on: b.blocked_id == p.id,
      where: b.blocker_id == ^profile_id,
      order_by: [desc: b.inserted_at, desc: b.id]
    )
    |> Repo.all()
  end

  # The direct conversations of the two: closed or opened again, so `Access`
  # forgets what it kept of them and the pages of both read it once more.
  defp closed_or_opened(first_id, second_id) do
    group_ids = direct_group_ids(first_id, second_id)

    if group_ids != [] do
      Access.forget(group_ids)

      for group_id <- group_ids, profile_id <- [first_id, second_id] do
        Social.broadcast_group_members_changed(group_id, [:blocks],
          numbers: false,
          profile_id: profile_id
        )
      end
    end

    :ok
  end

  defp direct_group_ids(first_id, second_id) do
    from(g in Group,
      join: m in GroupMembership,
      on: m.group_id == g.id,
      where: g.is_direct and m.profile_id in ^[first_id, second_id],
      group_by: g.id,
      having: count(m.profile_id) == 2,
      select: g.id
    )
    |> Repo.all()
  end
end
