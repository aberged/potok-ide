defmodule PotokIdeWeb.StripMetadataJsTest do
  @moduledoc """
  The metadata a photo loses in the browser before it is uploaded
  (`assets/js/strip_metadata.js`): the script's own tests in Node, and a real
  photo ImageMagick reads before and after, pixel for pixel.
  """
  use ExUnit.Case, async: true

  @moduletag :node

  @root Path.expand("../..", __DIR__)

  # Every script test of `test/js`, this one's and the others' (`site_path.js`).
  test "the scripts' tests pass in Node" do
    files = "test/js/*.test.mjs" |> Path.wildcard() |> Enum.sort()

    {output, status} =
      System.cmd("node", ["--test" | files],
        cd: @root,
        stderr_to_stdout: true,
        env: [{"NODE_NO_WARNINGS", "1"}]
      )

    assert status == 0, output
  end

  @tag :imagemagick
  @tag :tmp_dir
  test "a photo keeps its pixels and orientation and loses its GPS position", %{tmp_dir: dir} do
    # ImageMagick 7: `magick identify` and `magick compare` (the old `convert`
    # has them as separate programs, which this check does not look for).
    {magick, :magick} = PotokIde.ImageMagick.find()
    plain = Path.join(dir, "plain.jpg")
    photo = Path.join(dir, "photo.jpg")
    stripped = Path.join(dir, "stripped.jpg")

    {_, 0} = System.cmd(magick, ["-size", "64x48", "gradient:#336699-#ffcc00", "-strip", plain])
    File.write!(photo, splice_exif(File.read!(plain)))

    assert identify(magick, photo, "%[EXIF:GPSLatitudeRef]") == "N"
    assert identify(magick, photo, "%[EXIF:Orientation]") == "6"

    {output, 0} =
      System.cmd("node", ["test/js/strip_file.mjs", photo, stripped],
        cd: @root,
        env: [{"NODE_NO_WARNINGS", "1"}]
      )

    assert output =~ "stripped"

    assert identify(magick, stripped, "%[EXIF:Orientation]") == "6"
    # Nothing but the orientation is left: no GPS directory, no other tag.
    assert identify(magick, stripped, "%[EXIF:*]") =~ ~r/\Aexif:Orientation=6\s*\z/

    {difference, _} =
      System.cmd(magick, ["compare", "-metric", "AE", photo, stripped, "null:"],
        stderr_to_stdout: true
      )

    assert difference |> String.split() |> hd() == "0"
  end

  defp identify(magick, path, format) do
    {output, 0} =
      System.cmd(magick, ["identify", "-format", format, path], stderr_to_stdout: true)

    String.trim(output)
  end

  # An EXIF segment after SOI, with the orientation and a GPS directory.
  defp splice_exif(<<0xFF, 0xD8, rest::binary>>) do
    gps_at = 8 + 2 + 2 * 12 + 4

    tiff =
      <<"II", 42::little-16, 8::little-32, 2::little-16>> <>
        <<0x0112::little-16, 3::little-16, 1::little-32, 6::little-16, 0::16>> <>
        <<0x8825::little-16, 4::little-16, 1::little-32, gps_at::little-32>> <>
        <<0::32>> <>
        <<1::little-16, 0x0001::little-16, 2::little-16, 2::little-32, "N", 0, 0, 0>> <>
        <<0::32>>

    body = "Exif" <> <<0, 0>> <> tiff
    <<0xFF, 0xD8, 0xFF, 0xE1, byte_size(body) + 2::16>> <> body <> rest
  end
end
