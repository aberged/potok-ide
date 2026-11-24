defmodule PotokIde.History.TrackedTest do
  @moduledoc """
  Every column of a followed table is either kept or named as left out, and
  the triggers hold the very lists the code has.
  """

  use PotokIde.DataCase, async: true

  alias PotokIde.History.Tracked
  alias PotokIde.Repo

  defp columns(table) do
    %{rows: rows} =
      Repo.query!(
        "SELECT column_name FROM information_schema.columns WHERE table_name = $1 " <>
          "AND table_schema = 'public'",
        [table]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  # The columns an UPDATE trigger watches, over all the history's triggers of the table.
  defp watched(table) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT DISTINCT a.attname
        FROM pg_trigger t
        JOIN pg_attribute a ON a.attrelid = t.tgrelid AND a.attnum = ANY (t.tgattr)
        WHERE t.tgrelid = $1::text::regclass AND t.tgname LIKE 'history%'
        """,
        [~s("#{table}")]
      )

    rows |> List.flatten() |> Enum.sort()
  end

  for {table, _spec} <- Tracked.tables() do
    test "#{table}: each column is kept, marked or left out, once" do
      spec = Tracked.tables()[unquote(table)]
      named = spec.kept ++ spec.marked ++ spec.left_out

      assert Enum.sort(named) == columns(unquote(table))
    end

    test "#{table}: the triggers watch what is kept" do
      spec = Tracked.tables()[unquote(table)]
      assert Enum.sort(spec.kept ++ spec.marked) == watched(unquote(table))
    end
  end

  test "votes, members, profiles and accounts are not followed" do
    %{rows: rows} =
      Repo.query!(
        "SELECT DISTINCT tgrelid::regclass::text FROM pg_trigger WHERE tgname LIKE 'history%'"
      )

    assert rows |> List.flatten() |> Enum.map(&String.trim(&1, "\"")) |> Enum.sort() ==
             Enum.sort(
               Map.keys(Tracked.tables()) ++
                 ~w(group_notices group_reactions group_shortcuts value_reactions)
             )
  end
end
