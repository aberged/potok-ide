defmodule PotokIde.Social.GroupMutes do
  @moduledoc """
  A member can silence a group for a while (`group_memberships.muted_until`).

  A silenced group sends that member no push of what goes to everyone: new
  messages and the announcements among them, polls, events, an app's notices,
  a process's push to everyone. Its unread values leave the home badge and
  the sums of the groups above it, while its own row still shows them, in
  grey. What is meant for the member alone still arrives: a mention, an
  answer to their message, a reaction, a process asking them or their role.

  A thread follows the conversation it was started from: silencing a group
  silences its threads for the member, with no row of their own changed.
  Until "forever" is a far date (`forever?/1`).
  """

  import Ecto.Query

  alias PotokIde.Repo
  alias PotokIde.Social.{Group, GroupMembership, Profile}

  @seconds %{"hour" => 3_600, "eight_hours" => 8 * 3_600, "week" => 7 * 86_400}
  @forever ~U[9999-12-31 00:00:00Z]

  @doc "The lengths a member can pick, `forever` last."
  def durations, do: ~w(hour eight_hours week forever)

  @doc "Whether a mute lasts until the member turns it off."
  def forever?(%DateTime{year: year}), do: year == @forever.year
  def forever?(_until), do: false

  @doc """
  SQL of whether the membership `gm` (an alias in the caller's query) is
  silenced: its own mute, or for a thread the mute of the same profile in
  the conversation the thread started from. Never NULL, so `NOT` of it
  keeps every membership with no mute.
  """
  def muted_sql(gm \\ "gm") do
    """
    ((#{gm}.muted_until IS NOT NULL AND #{gm}.muted_until > now()) OR EXISTS (
      SELECT 1
      FROM groups mt
      JOIN group_memberships mp
        ON mp.group_id = mt.parent_id AND mp.profile_id = #{gm}.profile_id
      WHERE mt.id = #{gm}.group_id
        AND mt.parent_value_id IS NOT NULL
        AND mp.muted_until > now()
    ))
    """
  end

  @doc """
  A query of the profiles that silenced `group` (for a thread, its
  conversation), to leave out of a push that goes to everyone.
  """
  def muted_profile_ids(%Group{} = group) do
    now = DateTime.utc_now()
    ids = source_ids(group)

    from(gm in GroupMembership,
      where: gm.group_id in ^ids and gm.muted_until > ^now,
      select: gm.profile_id
    )
  end

  @doc """
  Until when the profile silenced `group`, or the conversation a thread
  `group` started from; nil while it is not silenced.
  """
  def muted_until(%Profile{id: profile_id}, %Group{} = group) do
    now = DateTime.utc_now()
    ids = source_ids(group)

    from(gm in GroupMembership,
      where: gm.profile_id == ^profile_id and gm.group_id in ^ids and gm.muted_until > ^now,
      select: max(gm.muted_until)
    )
    |> Repo.one()
  end

  def muted_until(_profile, _group), do: nil

  @doc "The groups the profile silenced, the threads of those included."
  def muted_group_ids(%Profile{id: profile_id}) do
    %{rows: rows} =
      Repo.query!(
        "SELECT gm.group_id FROM group_memberships gm WHERE gm.profile_id = $1 AND #{muted_sql()}",
        [profile_id],
        cache_statement: "group_mutes_muted_group_ids_v1"
      )

    List.flatten(rows)
  end

  @doc """
  Silences `group` for the profile for one of `durations/0`, or lets it
  speak again with `nil`. Only its members can: `{:error, :not_a_member}`
  otherwise. Returns `{:ok, until}`.
  """
  def set(%Profile{id: profile_id}, %Group{id: group_id}, duration)
      when is_nil(duration) or is_map_key(@seconds, duration) or duration == "forever" do
    until = until(duration)

    from(gm in GroupMembership, where: gm.profile_id == ^profile_id and gm.group_id == ^group_id)
    |> Repo.update_all(set: [muted_until: until])
    |> case do
      {1, _rows} -> {:ok, until}
      {0, _rows} -> {:error, :not_a_member}
    end
  end

  def set(_profile, _group, _duration), do: {:error, :invalid_duration}

  defp until(nil), do: nil
  defp until("forever"), do: @forever

  defp until(duration) do
    DateTime.utc_now() |> DateTime.add(@seconds[duration]) |> DateTime.truncate(:second)
  end

  # A thread is silenced by its conversation's mute as well as its own.
  defp source_ids(%Group{id: id, parent_value_id: value_id, parent_id: parent_id})
       when not is_nil(value_id) and not is_nil(parent_id),
       do: [id, parent_id]

  defp source_ids(%Group{id: id}), do: [id]
end
