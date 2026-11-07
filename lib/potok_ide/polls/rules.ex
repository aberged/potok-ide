defmodule PotokIde.Polls.Rules do
  @moduledoc """
  Who may do and see what in a poll. Plain functions over what the caller has
  already read, so that one rule answers for a card in the chat, the overview,
  an app and a file of results.

  | Who | Votes | Results | Details |
  |---|---|---|---|
  | Someone outside, a poll for members | no | no | no |
  | Someone outside, a public poll | while "everyone" holds `vote_polls`, unless blocked | if "everyone" is on the list | never |
  | A member | `vote_polls` and a role on the list | a role on the list, at the chosen time | a role on the list, at the chosen time |
  | The organizer, while a member, and holders of `manage_polls` | as a member | always, but a secret poll only once closed | always; of a secret poll only who took part |

  Those who see the details see the choices, so they see the results too, except
  in a secret poll, whose details hold no choices.
  """

  alias PotokIde.Polls.{Poll, PollBallot, View}
  alias PotokIde.Social.{Access, Group, Profile}

  @doc "Whether the holder of `access` may start polls in `group`."
  def can_create?(%Access{} = access, %Group{} = group) do
    not group.is_root and not group.is_direct and Access.can?(access, :create_polls)
  end

  @doc "Whether the holder of `access` may open a poll of `group` to non-members."
  def can_publish?(%Access{} = access, %Group{} = group) do
    Group.guest_preview?(group) and Access.can?(access, :publish_polls)
  end

  @doc "Whether the poll takes non-members now: a group that stopped being public closes it to them."
  def public?(%Poll{is_public: true}, %Group{} = group), do: Group.guest_preview?(group)
  def public?(%Poll{}, %Group{}), do: false

  @doc "Whether `profile` may close, change or delete the poll, and sees all there is to see."
  def manage?(%Poll{} = poll, %Access{} = access, profile) do
    access.member? and
      (Access.can?(access, :manage_polls) or owner?(poll, profile))
  end

  defp owner?(%Poll{creator_id: creator_id}, %Profile{id: id}), do: creator_id == id
  defp owner?(%Poll{}, nil), do: false

  @doc "Why `profile` cannot vote in the poll at `now`, or nil when it can."
  def vote_block(%Poll{} = poll, %Group{} = group, %Access{} = access, profile, %DateTime{} = now) do
    cond do
      is_nil(profile) -> :not_permitted
      not Poll.open?(poll, now) -> :closed
      access.member? -> member_vote_block(poll, access)
      access.blocked? -> :blocked
      not public?(poll, group) -> :members_only
      not Access.everyone_can?(access, :vote_polls) -> :not_permitted
      true -> nil
    end
  end

  defp member_vote_block(%Poll{} = poll, %Access{} = access) do
    cond do
      not Access.can?(access, :vote_polls) -> :not_permitted
      not on_list?(poll.voter_role_keys, access) -> :role
      true -> nil
    end
  end

  @doc "Whether the viewer sees the counts of the answers at `now`."
  def results?(%Poll{} = poll, group, %Access{} = access, profile, voted?, %DateTime{} = now) do
    closed? = not Poll.open?(poll, now)

    cond do
      poll.secret and not closed? ->
        false

      manage?(poll, access, profile) ->
        true

      not poll.secret and details?(poll, access, profile, now) ->
        true

      not sees_results?(poll, group, access) ->
        false

      true ->
        case poll.results_when do
          :always -> true
          :voted -> voted? or closed?
          :closed -> closed?
        end
    end
  end

  defp sees_results?(%Poll{} = poll, _group, %Access{member?: true} = access),
    do: on_list?(poll.results_role_keys, access)

  defp sees_results?(%Poll{} = poll, %Group{} = group, %Access{}),
    do: public?(poll, group) and "everyone" in poll.results_role_keys

  @doc "Whether the viewer sees who took part, and in a poll that is not secret what they chose."
  def details?(%Poll{} = poll, %Access{} = access, profile, %DateTime{} = now) do
    cond do
      not access.member? -> false
      manage?(poll, access, profile) -> true
      not on_list?(poll.details_role_keys, access) -> false
      poll.details_when == :always -> true
      true -> not Poll.open?(poll, now)
    end
  end

  defp on_list?(keys, %Access{role_keys: role_keys}), do: Enum.any?(keys, &(&1 in role_keys))

  @doc """
  The poll as `profile` sees it at `now`. `ballot` is its own ballot, and
  `other_ballot` the one its account gave with another of its profiles.
  """
  def view(
        %Poll{} = poll,
        %Group{} = group,
        %Access{} = access,
        profile,
        ballot,
        other_ballot,
        now
      ) do
    voted? = match?(%PollBallot{}, ballot)
    vote_block = vote_block(poll, group, access, profile, now)
    results? = results?(poll, group, access, profile, voted?, now)
    my_option_ids = if voted?, do: ballot.option_ids, else: []

    can_vote? =
      is_nil(vote_block) and is_nil(other_ballot) and (not voted? or poll.allow_change)

    %View{
      poll_id: poll.id,
      group_id: poll.group_id,
      value_id: poll.value_id,
      question: poll.question,
      description: poll.description,
      kind: poll.kind,
      max_choices: poll.max_choices,
      closes_at: poll.closes_at,
      closed_at: poll.closed_at,
      scope: scope(poll, group, access),
      open?: Poll.open?(poll, now),
      secret?: poll.secret,
      public?: public?(poll, group),
      allow_change?: poll.allow_change,
      vote_block: vote_block,
      can_vote?: can_vote?,
      voted?: voted?,
      voted_with_other_profile?: not voted? and not is_nil(other_ballot),
      one_tap?: can_vote? and poll.kind == :single and poll.allow_change,
      results?: results?,
      details?: details?(poll, access, profile, now),
      manage?: manage?(poll, access, profile),
      can_add_option?: can_add_option?(poll, group, access, vote_block),
      voters_count: poll.voters_count,
      outcome: if(results?, do: poll.outcome),
      winner_option_id: if(results?, do: poll.winner_option_id),
      eligible_count: if(results?, do: poll.eligible_count),
      quorum_percent: poll.quorum_percent,
      majority: poll.majority,
      form_key: form_key(poll, my_option_ids, can_vote?),
      options: Enum.map(poll.options, &option(&1, results?, my_option_ids)),
      removable_option_ids: removable_option_ids(poll, access, profile),
      my_option_ids: my_option_ids,
      voter_roles: roles_on_list(poll.voter_role_keys, access),
      detail_roles: roles_on_list(poll.details_role_keys, access)
    }
    |> limit_to_scope()
  end

  defp scope(%Poll{} = poll, group, %Access{member?: member?}) do
    if member? or public?(poll, group), do: :full, else: :teaser
  end

  # Someone outside keeps the question, which an open chat shows anyway.
  defp limit_to_scope(%View{scope: :teaser} = view) do
    %{
      view
      | description: "",
        options: [],
        removable_option_ids: [],
        voters_count: nil,
        voter_roles: [],
        detail_roles: [],
        form_key: 0
    }
  end

  defp limit_to_scope(%View{} = view), do: view

  defp can_add_option?(%Poll{} = poll, group, %Access{} = access, vote_block) do
    poll.allow_member_options and access.member? and is_nil(vote_block) and
      not poll.secret and not public?(poll, group) and
      length(poll.options) < Poll.max_options_with_members()
  end

  # Counts reach the page through its tally styles, so that a vote re-renders no
  # message: here an answer only says it has some to show.
  defp option(option, results?, my_option_ids) do
    %{
      id: option.id,
      text: option.text,
      votes_count: if(results?, do: option.votes_count),
      mine?: option.id in my_option_ids
    }
  end

  # A poll keeps at least two answers, and those with votes stay. A secret poll
  # offers nothing: which answers have no votes is a count.
  defp removable_option_ids(%Poll{secret: true}, _access, _profile), do: []

  defp removable_option_ids(%Poll{} = poll, %Access{} = access, profile) do
    if manage?(poll, access, profile) and length(poll.options) > Poll.min_options() do
      for %{id: id, votes_count: 0} <- poll.options, do: id
    else
      []
    end
  end

  # Changes when the voting form has to change, and with it the element a stream
  # would otherwise leave alone: see `PotokIdeWeb.GroupLive.Show.PollCard`.
  defp form_key(%Poll{} = poll, my_option_ids, can_vote?) do
    :erlang.phash2({Enum.map(poll.options, &{&1.id, &1.text}), my_option_ids, can_vote?})
  end

  # The roles still there: a role deleted since leaves the list to those left.
  defp roles_on_list(_keys, %Access{manifest: nil}), do: []

  defp roles_on_list(keys, %Access{manifest: manifest}),
    do: Enum.filter(manifest.roles, &(&1.key in keys))
end
