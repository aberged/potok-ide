defmodule PotokIde.TextFold do
  @moduledoc """
  Text as the searches compare it: what the database's `potok_fold()` makes
  of it (migration `20261110121402_add_map_columns_to_groups`), in lower-case
  Latin without diacritics, Serbian Cyrillic spelled out (љ → lj, ђ and đ →
  dj), so "cacak" finds "Čačak" and "чачак". The searches fold in SQL; this
  finds where a match lies in the original text, to highlight it. A test
  holds the two to the same tables.
  """

  # Two letters for one: Serbian Cyrillic's own letters, and Latin đ.
  @digraphs %{
    "Љ" => "lj",
    "љ" => "lj",
    "Њ" => "nj",
    "њ" => "nj",
    "Џ" => "dz",
    "џ" => "dz",
    "Ђ" => "dj",
    "ђ" => "dj",
    "Đ" => "dj",
    "đ" => "dj"
  }

  @letters %{
    "А" => "a",
    "Б" => "b",
    "В" => "v",
    "Г" => "g",
    "Д" => "d",
    "Е" => "e",
    "Ж" => "z",
    "З" => "z",
    "И" => "i",
    "Ј" => "j",
    "К" => "k",
    "Л" => "l",
    "М" => "m",
    "Н" => "n",
    "О" => "o",
    "П" => "p",
    "Р" => "r",
    "С" => "s",
    "Т" => "t",
    "Ћ" => "c",
    "У" => "u",
    "Ф" => "f",
    "Х" => "h",
    "Ц" => "c",
    "Ч" => "c",
    "Ш" => "s",
    "а" => "a",
    "б" => "b",
    "в" => "v",
    "г" => "g",
    "д" => "d",
    "е" => "e",
    "ж" => "z",
    "з" => "z",
    "и" => "i",
    "ј" => "j",
    "к" => "k",
    "л" => "l",
    "м" => "m",
    "н" => "n",
    "о" => "o",
    "п" => "p",
    "р" => "r",
    "с" => "s",
    "т" => "t",
    "ћ" => "c",
    "у" => "u",
    "ф" => "f",
    "х" => "h",
    "ц" => "c",
    "ч" => "c",
    "ш" => "s",
    "Č" => "c",
    "Ć" => "c",
    "Š" => "s",
    "Ž" => "z",
    "č" => "c",
    "ć" => "c",
    "š" => "s",
    "ž" => "z",
    "Á" => "a",
    "À" => "a",
    "Â" => "a",
    "Ä" => "a",
    "É" => "e",
    "È" => "e",
    "Ê" => "e",
    "Ë" => "e",
    "Í" => "i",
    "Ï" => "i",
    "Ó" => "o",
    "Ô" => "o",
    "Ö" => "o",
    "Ú" => "u",
    "Ü" => "u",
    "á" => "a",
    "à" => "a",
    "â" => "a",
    "ä" => "a",
    "é" => "e",
    "è" => "e",
    "ê" => "e",
    "ë" => "e",
    "í" => "i",
    "ï" => "i",
    "ó" => "o",
    "ô" => "o",
    "ö" => "o",
    "ú" => "u",
    "ü" => "u"
  }

  # Marks a decomposed letter carries (caron, acute, grave, diaeresis,
  # circumflex), which the fold drops.
  @marks [0x030C, 0x0301, 0x0300, 0x0308, 0x0302]
         |> Map.new(&{<<&1::utf8>>, ""})

  @map @digraphs |> Map.merge(@letters) |> Map.merge(@marks)

  @doc "The characters the fold changes, and into what (for the test against SQL)."
  def table, do: @map

  @doc "`text` folded as `potok_fold()` folds it."
  def fold(text) when is_binary(text) do
    text
    |> String.codepoints()
    |> Enum.map_join(&fold_codepoint/1)
  end

  defp fold_codepoint(codepoint),
    do: Map.get_lazy(@map, codepoint, fn -> String.downcase(codepoint) end)

  @doc """
  `text` cut into `%{text: part, match?: boolean}` around every place where
  `query` occurs once both are folded. A match covers whole graphemes, so one
  that starts inside "љ" (folded to "lj") takes the whole letter.
  """
  def segments(text, query) when is_binary(text) and is_binary(query) do
    folded_query = query |> String.trim() |> fold()

    if folded_query == "" do
      [%{text: text, match?: false}]
    else
      graphemes = String.graphemes(text)
      folded = Enum.map(graphemes, &fold/1)
      matched = matched_graphemes(folded, folded_query)

      graphemes
      |> Enum.with_index()
      |> Enum.chunk_by(fn {_grapheme, index} -> MapSet.member?(matched, index) end)
      |> Enum.map(fn [{_grapheme, index} | _rest] = chunk ->
        %{text: Enum.map_join(chunk, &elem(&1, 0)), match?: MapSet.member?(matched, index)}
      end)
    end
  end

  # The indexes of the graphemes the matches overlap, in one pass: each
  # grapheme spans its folded bytes, and the matches come in order.
  defp matched_graphemes(folded, folded_query) do
    matches = :binary.matches(Enum.join(folded), folded_query)

    {_stop, _matches, matched} =
      folded
      |> Enum.with_index()
      |> Enum.reduce({0, matches, MapSet.new()}, fn {part, index}, {start, matches, matched} ->
        stop = start + byte_size(part)
        matches = Enum.drop_while(matches, fn {at, length} -> at + length <= start end)

        matched =
          case matches do
            [{at, _length} | _rest] when at < stop and stop > start -> MapSet.put(matched, index)
            _none -> matched
          end

        {stop, matches, matched}
      end)

    matched
  end
end
