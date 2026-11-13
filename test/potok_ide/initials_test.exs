defmodule PotokIde.InitialsTest do
  use ExUnit.Case, async: true

  alias PotokIde.Initials

  test "takes the first letters of the first two words" do
    assert Initials.of("Mesna zajednica Topolik") == "MZ"
    assert Initials.of("vesti") == "V"
    assert Initials.of("zgrada_cvetna-12") == "ZC"
    assert Initials.of("čitalački klub") == "ČK"
    assert Initials.of("Вести из краја") == "ВИ"
  end

  test "has a question mark for a name with no letters" do
    assert Initials.of("") == "?"
    assert Initials.of("   ") == "?"
    assert Initials.of(nil) == "?"
  end

  test "gives a name the same colours every time, from the avatars' palette" do
    {background, text} = Initials.colors("Vesti")

    assert Initials.colors("Vesti") == {background, text}
    assert background =~ ~r/\A#[0-9a-f]{6}\z/
    assert text =~ ~r/\A#[0-9a-f]{6}\z/
  end

  # The avatars hashed the name this way before the colours moved here: a
  # change would give every group without a picture another colour.
  test "keeps the colours the avatars always had" do
    assert Initials.colors("Vesti") == Enum.at(palette(), :erlang.phash2("Vesti", 8))
  end

  defp palette do
    [
      {"#4f46e5", "#e0e7ff"},
      {"#0891b2", "#cffafe"},
      {"#059669", "#d1fae5"},
      {"#d97706", "#fef3c7"},
      {"#dc2626", "#fee2e2"},
      {"#7c3aed", "#ede9fe"},
      {"#db2777", "#fce7f3"},
      {"#ea580c", "#ffedd5"}
    ]
  end
end
