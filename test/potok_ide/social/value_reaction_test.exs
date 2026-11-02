defmodule PotokIde.Social.ValueReactionTest do
  use ExUnit.Case, async: true

  alias PotokIde.Social.ValueReaction

  # The picker's self-hosted data (see assets/js/reaction_picker.js). Every
  # emoji it can send, skin tone variants included, must be accepted.
  for locale <- ["en", "pl"] do
    test "accepts every emoji of the #{locale} picker data" do
      rejected =
        Application.app_dir(:potok_ide, "priv/static/emoji/#{unquote(locale)}.json")
        |> File.read!()
        |> Jason.decode!()
        |> Enum.flat_map(fn emoji ->
          [emoji["emoji"] | for(skin <- Map.get(emoji, "skins", []), do: skin["emoji"])]
        end)
        |> Enum.reject(&ValueReaction.emoji?/1)

      assert rejected == []
    end
  end

  test "rejects letters, numbers, separators, control, format and private-use characters" do
    for invalid <- ["a", "ž", "7", " ", " ", "\u0000", "‍", "­", ""] do
      refute ValueReaction.emoji?(invalid), "expected #{inspect(invalid)} to be rejected"
    end
  end
end
