defmodule PotokIde.Social.ValueReaction do
  use Ecto.Schema

  import Ecto.Changeset

  @max_emoji_bytes 32

  schema "value_reactions" do
    field :emoji, :string

    belongs_to :value, PotokIde.Social.Value
    belongs_to :profile, PotokIde.Social.Profile

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  `value_id` and `profile_id` are set on the struct by the caller, never cast.
  """
  def changeset(value_reaction, attrs) do
    value_reaction
    |> cast(attrs, [:emoji])
    |> validate_required([:emoji])
    |> validate_emoji()
    |> unique_constraint([:value_id, :profile_id, :emoji],
      name: :value_reactions_value_id_profile_id_emoji_index
    )
  end

  # Accepts a single grapheme that is not a letter, number, separator or
  # control character. Multi-codepoint emoji (skin tones, ZWJ families, flags,
  # keycaps) are one grapheme, so they pass.
  defp validate_emoji(changeset) do
    validate_change(changeset, :emoji, fn :emoji, emoji ->
      if emoji?(emoji), do: [], else: [emoji: "is not a valid emoji"]
    end)
  end

  @doc false
  def emoji?(emoji) when is_binary(emoji) do
    String.valid?(emoji) and byte_size(emoji) <= @max_emoji_bytes and
      String.length(emoji) == 1 and not String.match?(emoji, ~r/^[\p{L}\p{N}\p{Z}\p{C}]$/u)
  end

  def emoji?(_emoji), do: false
end
