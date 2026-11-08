defmodule PotokIde.Social.ValueScoring do
  @moduledoc """
  Scores a value against a key only the app's editors see: what a quiz needs.
  The key maps each answer (under the rule's `under`) to a check and its points:

  | Check | Right when |
  |---|---|
  | `eq` | the answer is that value: one choice |
  | `set` | the answers are exactly those values: checkboxes |
  | `text` | the answer is one of those texts, whatever the letter case and spacing. With `others_wrong` anything else is wrong, otherwise it waits for an editor |
  | `rows` | per row, the row's answer is that value; points for each right row |
  | `row_sets` | per row, exactly those values; points for each right row |
  | `manual` | an editor grades it |

  The result goes into `Value.managed`: `score`, `max`, `pending` (answers
  waiting for an editor) and per answer `ok` and `points`. Points an editor gave
  (`graded`) stay when the key changes, cut to what the answer is worth now.
  """

  @max_points 1_000

  @doc """
  `managed` for `answers` (the map under the rule's `under`) against `key`.
  `previous` is the value's earlier `managed`, whose graded answers stay.
  """
  def score(answers, key, previous \\ nil)

  def score(answers, key, previous) when is_map(key) do
    answers = if is_map(answers), do: answers, else: %{}
    previous_items = previous_items(previous)

    items =
      Map.new(key, fn {question, check} ->
        {question, item(Map.get(answers, question), check, Map.get(previous_items, question))}
      end)

    total(items, key)
  end

  def score(_answers, _key, _previous), do: nil

  @doc """
  An editor's grades: per question `points` (nil gives the answer back to
  the key) and `feedback`. Returns the new `managed`.
  """
  def grade(managed, patch, answers, key) when is_map(patch) and is_map(key) do
    current = score(answers, key, managed) || %{"items" => %{}}

    items =
      Enum.reduce(patch, current["items"], fn {question, grade}, items ->
        case {Map.get(key, question), Map.get(items, question)} do
          {check, %{} = item} when is_map(check) and is_map(grade) ->
            Map.put(
              items,
              question,
              graded(item, check, grade, Map.get(answers || %{}, question))
            )

          _unknown ->
            items
        end
      end)

    total(items, key)
  end

  def grade(managed, _patch, _answers, _key), do: managed

  defp graded(item, check, grade, answer) do
    item = put_feedback(item, grade["feedback"])

    case grade["points"] do
      points when is_integer(points) ->
        max = item_max(check)
        points = points |> max(0) |> min(max)
        item |> Map.merge(%{"points" => points, "ok" => points >= max, "graded" => true})

      nil ->
        item
        |> Map.drop(["graded"])
        |> Map.merge(check(answer, check))

      _invalid ->
        item
    end
  end

  defp put_feedback(item, feedback) when is_binary(feedback) do
    case String.trim(feedback) do
      "" -> Map.delete(item, "feedback")
      text -> Map.put(item, "feedback", String.slice(text, 0, 2_000))
    end
  end

  defp put_feedback(item, _feedback), do: item

  defp previous_items(%{"items" => items}) when is_map(items), do: items
  defp previous_items(_previous), do: %{}

  defp total(items, key) do
    %{
      "score" => items |> Map.values() |> Enum.map(&(&1["points"] || 0)) |> Enum.sum(),
      "max" => key |> Map.values() |> Enum.map(&item_max/1) |> Enum.sum(),
      "pending" => Enum.count(items, fn {_question, item} -> is_nil(item["points"]) end),
      "items" => items
    }
  end

  # An editor's points and words stay; the rest comes from the key again.
  defp item(_answer, check, %{"graded" => true} = previous) do
    max = item_max(check)
    points = previous["points"] |> to_points() |> min(max)

    %{"ok" => points >= max, "points" => points, "graded" => true}
    |> put_feedback(previous["feedback"])
  end

  defp item(answer, check, previous) do
    answer
    |> check(check)
    |> put_feedback(previous && previous["feedback"])
  end

  defp check(answer, %{"eq" => expected} = check) do
    right(answer == expected and not is_nil(answer), points(check))
  end

  defp check(answer, %{"set" => expected} = check) when is_list(expected) do
    right(
      is_list(answer) and answer != [] and MapSet.new(answer) == MapSet.new(expected),
      points(check)
    )
  end

  defp check(answer, %{"text" => accepted} = check) when is_list(accepted) do
    accepted = accepted |> Enum.filter(&is_binary/1) |> Enum.map(&normalize_text/1)

    cond do
      not is_binary(answer) or normalize_text(answer) == "" -> right(false, points(check))
      normalize_text(answer) in accepted -> right(true, points(check))
      check["others_wrong"] == true -> right(false, points(check))
      true -> %{"ok" => nil, "points" => nil}
    end
  end

  defp check(answer, %{"rows" => expected} = check) when is_map(expected) do
    answer = if is_map(answer), do: answer, else: %{}
    right_rows = Enum.count(expected, fn {row, column} -> Map.get(answer, row) == column end)
    rows(right_rows, map_size(expected), points(check))
  end

  defp check(answer, %{"row_sets" => expected} = check) when is_map(expected) do
    answer = if is_map(answer), do: answer, else: %{}

    right_rows =
      Enum.count(expected, fn {row, columns} ->
        chosen = Map.get(answer, row)

        is_list(chosen) and is_list(columns) and chosen != [] and
          MapSet.new(chosen) == MapSet.new(columns)
      end)

    rows(right_rows, map_size(expected), points(check))
  end

  defp check(_answer, _manual), do: %{"ok" => nil, "points" => nil}

  defp right(true, points), do: %{"ok" => true, "points" => points}
  defp right(false, _points), do: %{"ok" => false, "points" => 0}

  defp rows(right_rows, all_rows, points),
    do: %{"ok" => all_rows > 0 and right_rows == all_rows, "points" => right_rows * points}

  @doc "What an answer is worth at most under `check`."
  def item_max(%{"rows" => rows} = check) when is_map(rows), do: points(check) * map_size(rows)

  def item_max(%{"row_sets" => rows} = check) when is_map(rows),
    do: points(check) * map_size(rows)

  def item_max(check) when is_map(check), do: points(check)
  def item_max(_check), do: 0

  defp points(%{"points" => points}) when is_integer(points),
    do: points |> max(0) |> min(@max_points)

  defp points(_check), do: 0

  defp to_points(points) when is_integer(points), do: max(points, 0)
  defp to_points(_points), do: 0

  defp normalize_text(text) do
    text
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
  end
end
