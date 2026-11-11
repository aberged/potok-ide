defmodule PotokIde.TextFoldTest do
  use PotokIde.DataCase, async: true

  alias PotokIde.TextFold

  test "folds every character as the database's potok_fold() does" do
    samples =
      Map.keys(TextFold.table()) ++
        ["Čačak", "Чачак", "Љубовија", "Ђурђевдан", "Đurđevdan", "ABC xyz 123 %_\\", "čačak"]

    %{rows: rows} =
      Repo.query!("SELECT s, potok_fold(s) FROM unnest($1::text[]) AS s", [samples])

    for [sample, folded] <- rows do
      assert TextFold.fold(sample) == folded, "#{inspect(sample)}: #{inspect(folded)}"
    end
  end

  test "segments light up a folded match in the original text" do
    assert TextFold.segments("Idemo u Čačak sutra", "cacak") == [
             %{text: "Idemo u ", match?: false},
             %{text: "Čačak", match?: true},
             %{text: " sutra", match?: false}
           ]

    assert [
             %{text: "Чачак", match?: true},
             %{text: " и ", match?: false},
             %{text: "čačak", match?: true}
           ] =
             TextFold.segments("Чачак и čačak", "ČAČAK")
  end

  test "a match inside a two-letter fold takes the whole letter" do
    assert TextFold.segments("Љубовија", "ljub") == [
             %{text: "Љуб", match?: true},
             %{text: "овија", match?: false}
           ]

    assert TextFold.segments("Ђак", "j") == [
             %{text: "Ђ", match?: true},
             %{text: "ак", match?: false}
           ]
  end

  test "a blank query or no match leaves the text whole" do
    assert TextFold.segments("Novi Sad", "  ") == [%{text: "Novi Sad", match?: false}]
    assert TextFold.segments("Novi Sad", "niš") == [%{text: "Novi Sad", match?: false}]
  end
end
