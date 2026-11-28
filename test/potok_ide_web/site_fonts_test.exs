defmodule PotokIdeWeb.SiteFontsTest do
  @moduledoc """
  The fonts Potok serves for sites (`priv/static/fonts/site`): every file
  `fonts.css` names is there, with its family's licence, and app frames,
  whose origin is opaque, may load them.
  """

  use PotokIdeWeb.ConnCase, async: true

  @dir Path.expand("../../priv/static/fonts/site", __DIR__)

  test "every file fonts.css names is there, next to its family's licence" do
    css = File.read!(Path.join(@dir, "fonts.css"))
    urls = Regex.scan(~r{url\(/fonts/site/([^)]+)\)}, css, capture: :all_but_first)

    assert length(urls) > 20

    for [path] <- urls do
      assert File.regular?(Path.join(@dir, path)), path
      assert File.regular?(Path.join([@dir, Path.dirname(path), "LICENSE.txt"])), path
    end

    # Latin, its extension and Cyrillic, for both scripts of Serbian.
    for subset <- ~w(latin latin-ext cyrillic) do
      assert css =~ "-#{subset}-wght-normal.woff2"
    end
  end

  test "an app frame may load them", %{conn: conn} do
    conn = get(conn, "/fonts/site/inter/inter-cyrillic-wght-normal.woff2")

    assert conn.status == 200
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end
end
