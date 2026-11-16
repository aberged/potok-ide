defmodule PotokIde.Processes.Legacy do
  @moduledoc """
  How a graph without a version reads its texts and conditions: the first
  language of processes, which an app's own process still speaks
  (`process.graph` in its rules) and every run started before
  `PotokIde.Processes.Expr` keeps to its end.

  - A text may hold fields as `{{naslov}}` or `{{odluka.outcome}}`: a path
    of names with dots between them, and nothing else. What is not there
    reads as nothing.
  - A condition compares one field: `=`, `!=`, `<`, `>` or `empty`, as
    numbers when both sides are numbers and as texts otherwise.

  It stays as it was: `PotokIde.Processes.Graph.upgrade/1` turns a drawing
  into today's language, and this module is what tells the two apart.
  """

  @placeholder ~r/\{\{\s*([\p{L}\p{Nd}_.-]+)\s*\}\}/u

  @doc "What a field in a text looks like, with its path as the first capture."
  def placeholder, do: @placeholder

  @doc "The text with its fields put in from `data`, without the spaces around it."
  def render(text, data) do
    @placeholder
    |> Regex.replace(text, fn _whole, field -> field_text(field(data, field)) end)
    |> String.trim()
  end

  @doc "Whether the condition holds on `data`."
  def holds?(%{"op" => "empty", "field" => field}, data),
    do: field(data, field) in [nil, "", [], %{}] or blank?(field(data, field))

  def holds?(%{"op" => op, "field" => field, "value" => expected}, data) do
    actual = field(data, field)

    case op do
      "=" -> same?(actual, expected)
      "!=" -> not same?(actual, expected)
      "<" -> compare(actual, expected) == :lt
      ">" -> compare(actual, expected) == :gt
    end
  end

  defp field(data, path) do
    path
    |> String.split(".")
    |> Enum.reduce(data, fn key, acc -> if is_map(acc), do: Map.get(acc, key) end)
  end

  defp field_text(value) when is_binary(value), do: value
  defp field_text(value) when is_number(value) or is_boolean(value), do: to_string(value)
  defp field_text(_value), do: ""

  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp same?(actual, expected) do
    case {number(actual), number(expected)} do
      {a, b} when is_number(a) and is_number(b) -> a == b
      _otherwise -> field_text(actual) |> String.trim() == field_text(expected) |> String.trim()
    end
  end

  defp compare(actual, expected) do
    case {number(actual), number(expected)} do
      {a, b} when is_number(a) and is_number(b) ->
        if(a < b, do: :lt, else: if(a > b, do: :gt, else: :eq))

      _not_numbers ->
        nil
    end
  end

  defp number(value) when is_number(value), do: value

  defp number(value) when is_binary(value) do
    case Float.parse(String.trim(value)) do
      {number, ""} -> number
      _not_a_number -> nil
    end
  end

  defp number(_value), do: nil
end
