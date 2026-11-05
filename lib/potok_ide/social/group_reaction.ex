defmodule PotokIde.Social.GroupReaction do
  use Ecto.Schema

  import Ecto.Changeset

  alias PotokIde.Social.ValueReaction

  schema "group_reactions" do
    field :emoji, :string

    belongs_to :group, PotokIde.Social.Group
    belongs_to :profile, PotokIde.Social.Profile

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  `group_id` and `profile_id` are set on the struct by the caller, never cast.
  """
  def changeset(group_reaction, attrs) do
    group_reaction
    |> cast(attrs, [:emoji])
    |> validate_required([:emoji])
    |> validate_change(:emoji, fn :emoji, emoji ->
      if ValueReaction.emoji?(emoji), do: [], else: [emoji: "is not a valid emoji"]
    end)
    |> unique_constraint([:group_id, :profile_id, :emoji],
      name: :group_reactions_group_id_profile_id_emoji_index
    )
  end
end
