defmodule PotokIde.Notices.GroupNotice do
  @moduledoc """
  A notice a group sent to its followers: one text, markdown like a message.
  It is never edited. `recipients_count` is how many followers it reached,
  written once when it is sent. Deleting it deletes it for everyone who
  received it.

  `link_preview` is the card of its first link, written once after it is sent
  (`PotokIde.LinkPreviews`). Whoever may delete the notice may remove the
  card, and as the text never changes, it is never fetched again.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @max_body_length 2_000

  schema "group_notices" do
    field :body, :string
    field :recipients_count, :integer, default: 0
    field :link_preview, :map

    belongs_to :group, PotokIde.Social.Group
    belongs_to :creator, PotokIde.Social.Profile

    timestamps(type: :utc_datetime, updated_at: false)
  end

  def max_body_length, do: @max_body_length

  @doc """
  Only `body` is cast; `group_id` and `creator_id` are set on the struct by the
  caller. The length counts code points, as the database's check does, so an
  emoji counts the same on both sides.
  """
  def changeset(notice, attrs) do
    notice
    |> cast(attrs, [:body])
    |> update_change(:body, &String.trim/1)
    |> validate_required([:body])
    |> validate_length(:body, min: 1, max: @max_body_length, count: :codepoints)
    |> check_constraint(:body, name: :group_notices_body_check)
  end
end
