defmodule Mix.Tasks.Potok.SrCyrlTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Potok.SrCyrl

  describe "transliterate/1" do
    test "writes Serbian in Cyrillic" do
      assert SrCyrl.transliterate("Šta je Potok? Đak čeka, žuti ćošak.") ==
               "Шта је Поток? Ђак чека, жути ћошак."
    end

    test "treats a digraph as one letter, in every case" do
      assert SrCyrl.transliterate("ljudi njihove emodžija") == "људи њихове емоџија"
      assert SrCyrl.transliterate("Ljudi Njihove Džep") == "Људи Њихове Џеп"
      assert SrCyrl.transliterate("LJUDI NJIHOVE DŽEP") == "ЉУДИ ЊИХОВЕ ЏЕП"
    end

    test "keeps dj as two letters" do
      assert SrCyrl.transliterate("Odjavi") == "Одјави"
    end

    test "leaves interpolations, markup and addresses in Latin" do
      assert SrCyrl.transliterate("Grupa %{name} i boja {skinTone}") ==
               "Група %{name} и боја {skinTone}"

      assert SrCyrl.transliterate(~s(tagom <meta name="description">.)) ==
               ~s(тагом <meta name="description">.)

      assert SrCyrl.transliterate("https://example.com/group.png ili data:image/...") ==
               "https://example.com/group.png или data:image/..."
    end

    test "leaves role names, technical names and brands in Latin" do
      assert SrCyrl.transliterate("Uloge admin i @everyone") == "Улоге admin и @everyone"
      assert SrCyrl.transliterate("Vrednost u Markdown-u") == "Вредност у Markdown-у"
      assert SrCyrl.transliterate("Google i Outlook") == "Google и Outlook"
    end

    test "respells foreign words" do
      assert SrCyrl.transliterate("Chat") == "Чет"
      assert SrCyrl.transliterate("Push obaveštenja") == "Пуш обавештења"
    end
  end

  describe "the sr_Cyrl files" do
    test "are what `mix potok.sr_cyrl` writes from sr" do
      files = SrCyrl.generate()

      assert Enum.map(files, &elem(&1, 0)) ==
               Path.wildcard("priv/gettext/sr_Cyrl/LC_MESSAGES/*.po")

      assert files != []

      for {path, contents} <- files do
        assert File.read!(path) == contents, "#{path} is stale, run `mix potok.sr_cyrl`"
      end
    end

    test "have the interpolations of sr" do
      interpolations = fn path -> Regex.scan(~r/%?\{[^}]*\}/, File.read!(path)) end

      for {path, _contents} <- SrCyrl.generate() do
        source = String.replace(path, "sr_Cyrl", "sr")

        assert interpolations.(path) == interpolations.(source)
      end
    end

    test "have no word that mixes the scripts" do
      mixed =
        for {_path, contents} <- SrCyrl.generate(),
            line <- String.split(contents, "\n"),
            String.starts_with?(line, "msgstr"),
            [word] <- Regex.scan(~r/\p{L}+/u, line),
            word =~ ~r/\p{Latin}/u and word =~ ~r/\p{Cyrillic}/u,
            do: word

      assert mixed == []
    end
  end
end
