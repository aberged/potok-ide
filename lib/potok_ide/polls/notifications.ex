defmodule PotokIde.Polls.Notifications do
  @moduledoc """
  What goes out about polls: a push for a new poll goes with its message
  (`PotokIde.Social.post_announcement/6`), a reminder to those who may vote and
  have not, and word of the end to those who voted and the organizer. Each
  payload is built in every language, for the language of each device.

  None of them says how anyone voted or how the vote went.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  import Ecto.Query
  import PotokIde.PushNotifications, only: [localized: 1]

  alias PotokIde.Polls
  alias PotokIde.Polls.{Poll, PollBallot}
  alias PotokIde.PushNotifications.Dispatch
  alias PotokIde.Repo
  alias PotokIde.Social.{AccountProfile, Group, Profile}

  def created(%Profile{} = creator, %Group{} = group, %Poll{} = poll) do
    localized(fn ->
      %{
        title:
          dgettext("polls", "%{name} started a poll in %{group}",
            name: creator.username,
            group: group.name
          ),
        body: poll.question,
        tag: tag(poll),
        url: url(poll),
        badge: "/avatar/profile/#{creator.id}?format=png"
      }
    end)
  end

  def reminder(%Group{} = group, %Poll{} = poll) do
    localized(fn ->
      %{
        title: poll.question,
        body: dgettext("polls", "You have not voted yet · %{group}", group: group.name),
        tag: "#{tag(poll)}-reminder",
        url: url(poll),
        badge: group_badge(group)
      }
    end)
  end

  def closed(%Group{} = group, %Poll{} = poll) do
    localized(fn ->
      %{
        title: dgettext("polls", "Voting ended: %{question}", question: poll.question),
        body: group.name,
        tag: "#{tag(poll)}-closed",
        url: url(poll),
        badge: group_badge(group)
      }
    end)
  end

  @doc """
  Reminds those who may vote and have not. Goes by account, and past one that
  voted with another of its profiles, while the lists on the page stay by
  profile.
  """
  def deliver_reminder(%Poll{} = poll, %Group{} = group) do
    Dispatch.run(fn ->
      poll
      |> not_voted_account_ids(group)
      |> Dispatch.subscriptions_by_account()
      |> Dispatch.deliver_localized("poll reminder", poll.id, reminder(group, poll))
    end)
  end

  @doc "Tells those who voted and the organizer that the voting ended; `actor` knows."
  def deliver_closed(%Poll{} = poll, actor) do
    Dispatch.run(fn ->
      group = Repo.get!(Group, poll.group_id)

      poll
      |> voter_account_ids(actor)
      |> Dispatch.subscriptions_by_account()
      |> Dispatch.deliver_localized("poll closed", poll.id, closed(group, poll))
    end)
  end

  defp not_voted_account_ids(%Poll{} = poll, %Group{} = group) do
    profile_ids = Polls.eligible_profile_ids(poll, group)

    voted_profiles =
      from(b in PollBallot,
        where: b.poll_id == ^poll.id and not is_nil(b.profile_id),
        select: b.profile_id
      )

    voted_accounts =
      from(b in PollBallot,
        where: b.poll_id == ^poll.id and not is_nil(b.account_id),
        select: b.account_id
      )

    from(ap in AccountProfile,
      where:
        ap.profile_id in ^profile_ids and ap.profile_id not in subquery(voted_profiles) and
          ap.account_id not in subquery(voted_accounts),
      select: ap.account_id
    )
  end

  defp voter_account_ids(%Poll{} = poll, actor) do
    voters =
      from(b in PollBallot,
        where: b.poll_id == ^poll.id and not is_nil(b.profile_id),
        select: b.profile_id
      )

    query =
      from(ap in AccountProfile,
        where: ap.profile_id in subquery(voters) or ap.profile_id in ^List.wrap(poll.creator_id),
        select: ap.account_id
      )

    case actor do
      %Profile{id: actor_id} -> where(query, [ap], ap.profile_id != ^actor_id)
      nil -> query
    end
  end

  # One tag per poll, so a later notification replaces the earlier one.
  defp tag(%Poll{id: id, group_id: group_id}), do: "group-#{group_id}-poll-#{id}"

  defp url(%Poll{id: id, group_id: group_id}), do: "/groups/#{group_id}/polls?poll=#{id}"

  defp group_badge(%Group{} = group), do: PotokIdeWeb.Avatars.group_badge_url(group)
end
