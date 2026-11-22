defmodule PotokIde.Social.RequestPoll do
  @moduledoc """
  How a vote that a request raises goes, written down beforehand: by the
  statute for a role (`GroupRole.request_poll`), by the group for admission
  (`Group.join_poll`). Whoever asks reads it before sending, and nobody fits
  it to the case: the poll takes it as it stands when it is raised.

  It decides by a majority with a quorum, over `hours`, and says who votes
  by the kind of profile, as `PotokIde.Polls.Poll` does. The whole group
  votes, as on any decision that changes who holds what.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @majorities [:simple, :two_thirds, :absolute]
  @hours [24, 72, 168, 336, 720]
  @unique_votes [:yes, :no]
  @shared_votes [:as_one, :each_holder, :no]

  @primary_key false
  embedded_schema do
    field :quorum_percent, :integer, default: 50
    field :majority, Ecto.Enum, values: @majorities, default: :simple
    field :hours, :integer, default: 72
    field :unique_votes, Ecto.Enum, values: @unique_votes, default: :yes
    field :shared_votes, Ecto.Enum, values: @shared_votes, default: :as_one
    # Nothing keeps who voted for what (`PotokIde.Polls.Poll`).
    field :secret, :boolean, default: false
  end

  def majorities, do: @majorities
  def hours_choices, do: @hours

  def changeset(%__MODULE__{} = poll, attrs) do
    poll
    |> cast(attrs, [:quorum_percent, :majority, :hours, :unique_votes, :shared_votes, :secret])
    |> validate_required([:quorum_percent, :majority, :hours, :unique_votes, :shared_votes])
    |> validate_number(:quorum_percent, greater_than_or_equal_to: 1, less_than_or_equal_to: 100)
    |> validate_inclusion(:hours, @hours)
    |> validate_voters()
  end

  defp validate_voters(changeset) do
    if get_field(changeset, :unique_votes) == :no and get_field(changeset, :shared_votes) == :no,
      do: add_error(changeset, :shared_votes, "somebody has to vote"),
      else: changeset
  end
end
