defmodule PotokIde.Social.GroupRequestDecision do
  @moduledoc """
  What became of a request (`PotokIde.Social.GroupRequests`): admission
  (`role_key` nil) or one role, given (`granted`), refused (`declined`) or put
  to a vote (`voted`, with its `poll_id`). `decider_id` names who decided,
  nil where the rule itself put it to a vote, and `reason` what they said
  to the one who asked. A trace of who decided what and why, which the one
  who asked reads too. An admission someone granted stays as a
  `PotokIde.Social.GroupJoinRequestApproval`, as before.
  """

  use Ecto.Schema

  @decisions [:granted, :declined, :voted]

  schema "group_request_decisions" do
    field :role_key, :string
    field :decision, Ecto.Enum, values: @decisions
    field :reason, :string

    belongs_to :group, PotokIde.Social.Group
    belongs_to :profile, PotokIde.Social.Profile
    belongs_to :decider, PotokIde.Social.Profile
    belongs_to :poll, PotokIde.Polls.Poll

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def decisions, do: @decisions
end
