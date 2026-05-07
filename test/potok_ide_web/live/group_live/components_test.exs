defmodule PotokIdeWeb.GroupLive.ComponentsTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias PotokIdeWeb.GroupLive.Show.Components

  describe "formatted_content/1" do
    test "preserves valid emoji in markdown content" do
      html =
        render_component(&Components.formatted_content/1,
          content: "Hvala za paradajz, bubo ❤️🍅",
          content_format: :markdown
        )

      assert String.valid?(html)
      assert html =~ "❤️🍅"
      refute html =~ "❤️�"
    end

    test "renders malformed utf-8 markdown without crashing" do
      malformed = <<240, 159, 141, 60>>

      html =
        render_component(&Components.formatted_content/1,
          content: malformed,
          content_format: :markdown
        )

      assert String.valid?(html)
      assert html =~ "�"
    end
  end
end
