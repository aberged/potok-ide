defmodule PotokIde.Initials do
  @moduledoc """
  What stands for a profile or a group without a picture: up to two first
  letters on a colour of its own. The avatars of the app
  (`PotokIdeWeb.AvatarController`) and the mark of an app on a link card
  (`PotokIde.LinkCards`) draw the same, so a group looks alike in both.
  """

  @colors [
    {"#4f46e5", "#e0e7ff"},
    {"#0891b2", "#cffafe"},
    {"#059669", "#d1fae5"},
    {"#d97706", "#fef3c7"},
    {"#dc2626", "#fee2e2"},
    {"#7c3aed", "#ede9fe"},
    {"#db2777", "#fce7f3"},
    {"#ea580c", "#ffedd5"}
  ]

  @doc ~S'The first letters of the first two words of `name`, in capitals, or "?".'
  def of(name) do
    name
    |> to_string()
    |> String.split(~r/[\s_-]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(fn part -> part |> String.first() |> to_string() end)
    |> case do
      "" -> "?"
      initials -> String.upcase(initials)
    end
  end

  @doc """
  `{background, text}` colours of `name`, the same every time. The hash is of
  `name` as given: hashing anything else would change every avatar's colour.
  """
  def colors(name), do: Enum.at(@colors, :erlang.phash2(name, length(@colors)))
end
