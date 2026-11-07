defmodule PotokIde.Polls.PollOption do
  @moduledoc """
  An answer of a poll. `votes_count` is how many ballots hold it, and in a
  secret poll the only record of them, so every vote writes it together with
  the other answers of the poll (`PotokIde.Polls.vote/4`).

  It has no timestamps on purpose: a change of this row is a vote, and the time
  of the last one would show what the last voter chose.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @max_text 200

  schema "poll_options" do
    field :text, :string
    field :position, :integer, default: 0
    field :votes_count, :integer, default: 0

    belongs_to :poll, PotokIde.Polls.Poll
    # Who added it, when the poll lets members add answers.
    belongs_to :creator, PotokIde.Social.Profile
  end

  def max_text, do: @max_text

  @doc """
  An answer as the poll's form writes it, at `position` in the list.
  `poll_id`, `creator_id` and `votes_count` are never cast.
  """
  def changeset(option, attrs, position) do
    option
    |> text_changeset(attrs)
    |> put_change(:position, position)
  end

  @doc "The answer's text alone, as a member adds it to an open poll."
  def text_changeset(option, attrs) do
    option
    |> cast(attrs, [:text])
    |> update_change(:text, &trim/1)
    |> validate_required([:text])
    |> validate_length(:text, max: @max_text, count: :codepoints)
  end

  @doc "What two answers are compared by: the same words in any letter case are one answer."
  def normalize(text) when is_binary(text) do
    text |> String.trim() |> String.normalize(:nfc) |> String.downcase()
  end

  def normalize(_text), do: ""

  defp trim(text) when is_binary(text), do: String.trim(text)
  defp trim(text), do: text
end
