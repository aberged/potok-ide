defmodule PotokIdeWeb.StackCopyTest do
  @moduledoc """
  The page at `/stack` is prose, so most of it needs a reader. These are the
  sentences a test can hold against the code.
  """
  use ExUnit.Case, async: true

  alias PotokIdeWeb.StackCopy

  defp templates do
    "lib/potok_ide_web/**/*.{ex,heex}"
    |> Path.wildcard()
    |> Enum.reject(&String.ends_with?(&1, "stack_copy.ex"))
    |> Enum.map_join("\n", &File.read!/1)
  end

  test "names the five tools from the bottom layer up" do
    assert Enum.map(StackCopy.tools(), & &1.name) ==
             ["BEAM", "Elixir", "Phoenix", "Tailwind", "daisyUI"]
  end

  test "says for every tool what it solves and how" do
    for tool <- StackCopy.tools() do
      assert tool.kind != ""
      assert tool.part != ""
      assert tool.text != ""
      assert length(tool.points) >= 4, tool.name
      assert Enum.all?(tool.points, &(&1.title != "" and &1.text != ""))
    end
  end

  test "the daisyUI classes it names are in the templates, and the ones it leaves out are not" do
    templates = templates()

    for class <- ~w(chat-bubble drawer dropdown toast) do
      assert templates =~ ~r/["\s]#{class}["\s]/, class
    end

    refute templates =~ ~r/["\s]btn[\s"-]/
    refute templates =~ "modal-box"
    assert templates =~ "<dialog"
  end

  test "the Tailwind variants it names are defined" do
    css = File.read!("assets/css/app.css")

    for variant <- ~w(keyboard-open cramped phx-click-loading phx-submit-loading dark) do
      assert css =~ "@custom-variant #{variant}", variant
    end
  end

  test "PostGIS, which the page names, is what the areas run on" do
    deps = Enum.map(Mix.Project.config()[:deps], &elem(&1, 0))
    assert :geo_postgis in deps

    assert "priv/repo/migrations/*.exs"
           |> Path.wildcard()
           |> Enum.any?(&(File.read!(&1) =~ "CREATE EXTENSION IF NOT EXISTS postgis"))
  end

  test "there is no broker or job queue next to BEAM" do
    deps = Enum.map(Mix.Project.config()[:deps], &elem(&1, 0))

    assert :dns_cluster in deps
    assert Enum.filter([:redix, :oban, :exq, :broadway], &(&1 in deps)) == []
  end
end
