defmodule PotokIde.Social.GroupAccessChange do
  @moduledoc """
  One change of who may do what in a group, kept for its members to read:
  a role given or taken, a permission or a role of the statute changed, a
  setting of the group that lets people in or out, a member admitted, removed
  or blocked. `PotokIde.Social.AccessHistory` writes it in the same
  transaction as the change, so a change that did not happen leaves no row.

  `actor` is who did it, nil for a decision of a poll (`poll`) or a profile
  since deleted; `subject` is whom it was done to. `data` holds what the row
  needs to be told later, such as a role's name at the time or a setting's
  old and new value, and never anyone's name, so deleting a profile forgets
  them here too.
  """

  use Ecto.Schema

  @kinds [
    :role_given,
    :role_taken,
    :permission_set,
    :role_added,
    :role_renamed,
    :role_removed,
    :request_rule_set,
    :manifest_copied,
    :manifest_dropped,
    :settings_changed,
    :alt_visibility_set,
    :join_rule_set,
    :elections_on,
    :elections_off,
    :member_admitted,
    :member_removed,
    :member_blocked,
    :member_unblocked
  ]

  # What only those who may lift blocks read (`PotokIde.Social.AccessHistory.list/3`).
  @block_kinds [:member_blocked, :member_unblocked]

  @doc "What a change can be."
  def kinds, do: @kinds

  @doc "The changes only those who may remove members read, as they see the blocks."
  def block_kinds, do: @block_kinds

  schema "group_access_changes" do
    belongs_to :group, PotokIde.Social.Group
    belongs_to :actor, PotokIde.Social.Profile
    belongs_to :subject, PotokIde.Social.Profile
    belongs_to :poll, PotokIde.Polls.Poll
    field :kind, Ecto.Enum, values: @kinds
    field :role_key, :string
    field :data, :map, default: %{}

    timestamps(type: :utc_datetime, updated_at: false)
  end
end
