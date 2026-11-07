defmodule PotokIde.Polls.Stats do
  @moduledoc """
  The details of a poll, for those `PotokIde.Polls.Rules.details?/4` lets see
  them: turnout, who voted for what, how each role voted, the course of the
  voting and who has not voted.

  A secret poll has no answers on its ballots, so all of this stops at who took
  part. Lists go by profile: one that could not vote, as its account voted with
  another profile, stays among those who have not voted, as leaving it out would
  tie the two profiles together.
  """

  import Ecto.Query

  alias PotokIde.Polls
  alias PotokIde.Polls.{Poll, PollBallot}
  alias PotokIde.Repo
  alias PotokIde.Social.{Access, Group, Profile}

  # How many names show at each answer before "Show all".
  @names_shown 12

  def names_shown, do: @names_shown

  @doc """
  The details of `poll`, with `poll.options` loaded. Times are read in
  `time_zone`.
  """
  def details(%Poll{} = poll, %Group{} = group, time_zone) do
    ballots = ballots(poll)
    members = Access.for_members(group)
    eligible_ids = Polls.eligible_profile_ids(poll, group)
    voted_ids = MapSet.new(ballots, & &1.profile_id)

    %{
      voters: poll.voters_count,
      eligible: poll.eligible_count || Polls.eligible_count(poll, group),
      voters_list: ballots |> Enum.map(& &1.profile) |> Enum.reject(&is_nil/1),
      not_voted: not_voted(eligible_ids, voted_ids),
      by_option: by_option(poll, ballots),
      by_role: by_role(poll, group, ballots, members),
      outsiders: outsiders(poll, ballots, members),
      timeline: timeline(ballots, time_zone)
    }
  end

  defp ballots(%Poll{id: poll_id}) do
    from(b in PollBallot,
      where: b.poll_id == ^poll_id,
      order_by: [asc: b.inserted_at, asc: b.id],
      preload: :profile
    )
    |> Repo.all()
  end

  defp not_voted(eligible_ids, voted_ids) do
    ids = Enum.reject(eligible_ids, &MapSet.member?(voted_ids, &1))

    from(p in Profile, where: p.id in ^ids, order_by: [asc: p.username])
    |> Repo.all()
  end

  defp by_option(%Poll{secret: true}, _ballots), do: %{}

  defp by_option(%Poll{} = poll, ballots) do
    Map.new(poll.options, fn option ->
      voters =
        for %PollBallot{profile: %Profile{} = profile, option_ids: option_ids} <- ballots,
            option.id in option_ids,
            do: profile

      {option.id, voters}
    end)
  end

  # The roles of the group with who holds them, in the order of the roles tab.
  defp by_role(%Poll{} = poll, %Group{} = group, ballots, members) do
    manifest = Access.effective_manifest(group)
    roles = if manifest, do: manifest.roles, else: []

    for role <- roles do
      holders =
        for {profile_id, access} <- members, role.key in access.role_keys, into: MapSet.new() do
          profile_id
        end

      held = Enum.filter(ballots, &MapSet.member?(holders, &1.profile_id))

      %{
        role: role,
        members: MapSet.size(holders),
        voted: length(held),
        counts: role_counts(poll, held)
      }
    end
    |> Enum.filter(&(&1.members > 0))
  end

  defp role_counts(%Poll{secret: true}, _ballots), do: nil

  defp role_counts(%Poll{} = poll, ballots) do
    Map.new(poll.options, fn option ->
      {option.id, Enum.count(ballots, &(option.id in &1.option_ids))}
    end)
  end

  # Those who voted from outside a public poll's group.
  defp outsiders(%Poll{is_public: false}, _ballots, _members), do: nil

  defp outsiders(%Poll{} = poll, ballots, members) do
    held = Enum.reject(ballots, &is_map_key(members, &1.profile_id))

    %{voted: length(held), counts: role_counts(poll, held)}
  end

  # By the hour for a voting of up to two days, by the day after that.
  defp timeline([], _time_zone), do: []

  defp timeline(ballots, time_zone) do
    times = Enum.map(ballots, &DateTime.shift_zone!(&1.inserted_at, time_zone))
    span = DateTime.diff(List.last(times), hd(times), :hour)
    step = if span <= 48, do: :hour, else: :day

    times
    |> Enum.group_by(&bucket(&1, step))
    |> Enum.map(fn {at, voted} -> %{at: at, step: step, count: length(voted)} end)
    |> Enum.sort_by(& &1.at, NaiveDateTime)
  end

  defp bucket(%DateTime{} = time, :hour) do
    NaiveDateTime.new!(DateTime.to_date(time), Time.new!(time.hour, 0, 0))
  end

  defp bucket(%DateTime{} = time, :day) do
    NaiveDateTime.new!(DateTime.to_date(time), ~T[00:00:00])
  end
end
