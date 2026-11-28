defmodule PotokIde.Social.SiteExample.PicturesTest do
  use ExUnit.Case, async: true

  alias PotokIde.Social.SiteExample.Pictures

  # Windows takes a command line of 32,767 characters at most, and Linux an
  # argument of 128 KB: the shapes go to ImageMagick in one argument.
  test "every drawing fits on a command line" do
    for name <- Pictures.names() do
      length =
        name |> Pictures.args("/tmp/#{name}.jpg") |> Enum.map(&(byte_size(&1) + 3)) |> Enum.sum()

      assert length < 30_000, "#{name} takes #{length} characters"
    end
  end

  test "a name always draws the same picture" do
    assert Pictures.args("pijaca", "a.jpg") == Pictures.args("pijaca", "a.jpg")
    refute Pictures.args("jesen-1", "a.jpg") == Pictures.args("jesen-2", "a.jpg")
  end
end
