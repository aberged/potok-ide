defmodule PotokIde.Polls.Export do
  @moduledoc """
  A poll as a table for the minutes: its results, or its voters. A secret poll has
  no answers on its ballots, so its voters' table says only who took part.

  What a voter typed can start a formula once a spreadsheet opens the file, so a
  cell that could is marked as text. The file starts with a byte order mark, as
  Excel otherwise misreads Serbian letters, and the separator follows the language,
  as Excel's list separator does.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  import Ecto.Query

  alias PotokIde.Polls.{Poll, PollBallot}
  alias PotokIde.Repo
  alias PotokIde.Social.{Access, Group, Profile}

  @bom "﻿"

  @doc "The results of `poll`, with its answers loaded: one row per answer."
  def results(%Poll{} = poll, separator) do
    header = [
      dgettext("polls", "Answer"),
      dgettext("polls", "Votes"),
      dgettext("polls", "Percent")
    ]

    rows =
      Enum.map(poll.options, fn option ->
        [option.text, option.votes_count, percent(option.votes_count, poll.voters_count)]
      end)

    render([header | rows], separator)
  end

  @doc "Who voted in `poll`, and for what unless it is secret: one row per voter."
  def voters(%Poll{} = poll, %Group{} = group, separator) do
    roles = role_names(group)
    members = Access.for_members(group)
    answers = Map.new(poll.options, &{&1.id, &1.text})

    header =
      [dgettext("polls", "Profile"), dgettext("polls", "Roles")] ++
        if(poll.secret, do: [], else: [dgettext("polls", "Answers")]) ++
        [dgettext("polls", "Voted at (UTC)")]

    rows =
      for ballot <- ballots(poll) do
        [
          username(ballot.profile),
          ballot.profile_id |> voter_roles(members, roles) |> Enum.join(", ")
        ] ++
          if(poll.secret, do: [], else: [answer_texts(ballot, answers)]) ++
          [DateTime.to_iso8601(ballot.inserted_at)]
      end

    render([header | rows], separator)
  end

  defp ballots(%Poll{id: poll_id}) do
    from(b in PollBallot,
      where: b.poll_id == ^poll_id,
      order_by: [asc: b.inserted_at, asc: b.id],
      preload: :profile
    )
    |> Repo.all()
  end

  defp username(%Profile{username: username}), do: username
  defp username(nil), do: dgettext("polls", "Deleted profile")

  defp answer_texts(%PollBallot{option_ids: option_ids}, answers) do
    option_ids |> Enum.map(&Map.get(answers, &1, "")) |> Enum.join(", ")
  end

  defp voter_roles(profile_id, members, roles) do
    case members do
      %{^profile_id => access} ->
        access.role_keys |> Enum.map(&Map.get(roles, &1)) |> Enum.reject(&is_nil/1)

      %{} ->
        []
    end
  end

  defp role_names(%Group{} = group) do
    case Access.effective_manifest(group) do
      nil -> %{}
      manifest -> Map.new(manifest.roles, &{&1.key, &1.name})
    end
  end

  defp percent(_votes, 0), do: 0
  defp percent(votes, voters), do: round(votes * 100 / voters)

  defp render(rows, separator) do
    IO.iodata_to_binary([
      @bom,
      Enum.map(rows, fn row ->
        [Enum.map_join(row, separator, &cell(&1, separator)), "\r\n"]
      end)
    ])
  end

  defp cell(value, separator) do
    value
    |> to_string()
    |> mark_as_text()
    |> quote_if_needed(separator)
  end

  # Spreadsheets run a cell that starts with one of these.
  defp mark_as_text(<<first::utf8, _rest::binary>> = text) when first in ~c"=+-@\t\r",
    do: "'" <> text

  defp mark_as_text(text), do: text

  defp quote_if_needed(text, separator) do
    if String.contains?(text, [separator, "\"", "\n", "\r"]) do
      "\"" <> String.replace(text, "\"", "\"\"") <> "\""
    else
      text
    end
  end
end
