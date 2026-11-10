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
      assert SrCyrl.transliterate("Google Play i Outlook") == "Google Play и Outlook"

      assert SrCyrl.transliterate("Phoenix na BEAM-u, stilovi u Tailwind-u") ==
               "Phoenix на BEAM-у, стилови у Tailwind-у"

      assert SrCyrl.transliterate("Na iPhone-u, pišite na `ABER.GED@GMAIL.COM`") ==
               "На iPhone-у, пишите на `ABER.GED@GMAIL.COM`"
    end

    test "respells foreign words" do
      assert SrCyrl.transliterate("Chat") == "Чет"
      assert SrCyrl.transliterate("Push obaveštenja") == "Пуш обавештења"
      assert SrCyrl.transliterate("u Viber grupi, s Viberom") == "у Вајбер групи, с Вајбером"
    end

    test "leaves site names and text marked as English in Latin" do
      assert SrCyrl.transliterate("na nszbor.org i obuka.itblokada.org") ==
               "на nszbor.org и obuka.itblokada.org"

      assert SrCyrl.transliterate("Naslov <span lang=en>Signal Polls: Yes</span> i Google Forms") ==
               "Наслов <span lang=en>Signal Polls: Yes</span> и Google Forms"
    end

    test "writes a mention as a word" do
      assert SrCyrl.transliterate("@pominjanje ljudi") == "@помињање људи"
    end
  end

  describe "the overview at /origin" do
    test "keeps the handles of accounts in Latin" do
      {_path, contents} =
        Enum.find(SrCyrl.generate(), fn {path, _} -> path =~ "ORIGIN.sr_Cyrl.md" end)

      assert contents =~ ~S(@studenti\_u\_blokadi)
      assert contents =~ "@sviublokadefdu"
    end
  end

  describe "the sr_Cyrl files" do
    test "are what `mix potok.sr_cyrl` writes from sr" do
      files = SrCyrl.generate()

      paths = Enum.map(files, &elem(&1, 0))

      assert "priv/static/PRIVACY_POLICY.sr_Cyrl.md" in paths

      assert Enum.filter(paths, &String.ends_with?(&1, ".po")) ==
               Path.wildcard("priv/gettext/sr_Cyrl/LC_MESSAGES/*.po")

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
        for {path, contents} <- SrCyrl.generate(),
            line <- String.split(contents, "\n"),
            Path.extname(path) == ".md" or String.starts_with?(line, "msgstr"),
            [word] <- Regex.scan(~r/\p{L}+/u, line),
            word =~ ~r/\p{Latin}/u and word =~ ~r/\p{Cyrillic}/u,
            do: word

      assert mixed == []
    end
  end
end
