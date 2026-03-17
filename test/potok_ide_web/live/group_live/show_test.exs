defmodule PotokIdeWeb.GroupLive.ShowTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  describe "group page" do
    test "shows parent link only for non-root groups", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "parent-link-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      root_group = Social.get_root_group!()

      {:ok, child_group} =
        Social.create_group(profile, root_group, %{
          "name" => "child-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, root_lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{root_group.id}")

      refute has_element?(root_lv, "a", "Back to Parent Group")

      {:ok, child_lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{child_group.id}")

      assert has_element?(
               child_lv,
               "a[href='/groups/#{root_group.id}']",
               "❮"
             )
    end

    test "shows values first and switches tabs", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "tabs-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      group = Social.get_root_group!()

      {:ok, _value} =
        Social.create_value(profile, group, %{
          "content" => "tabbed value",
          "content_format" => :markdown
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}")

      assert has_element?(lv, "#group-panel-values")
      refute has_element?(lv, "#group-panel-create-value")

      lv
      |> element("#group-tab-create-value")
      |> render_click()

      assert has_element?(lv, "#group-panel-create-value")
      refute has_element?(lv, "#group-panel-values")
    end

    test "renders value content as markdown and html", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "group-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      group = Social.get_root_group!()

      {:ok, _markdown_value} =
        Social.create_value(profile, group, %{
          "content" => "**bold** and [link](https://example.com)",
          "content_format" => :markdown
        })

      {:ok, _html_value} =
        Social.create_value(profile, group, %{
          "content" => "<strong>html value</strong>",
          "content_format" => :html
        })

      {:ok, _lv, html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}")

      assert html =~ "<strong>bold</strong>"
      assert html =~ "href=\"https://example.com\""
      assert html =~ ">link</a>"
      assert html =~ "<strong>html value</strong>"
    end

    test "toggles long value content between collapsed and expanded", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "toggle-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      group = Social.get_root_group!()

      long_content = Enum.map_join(1..7, "\n", fn line -> "line #{line}" end)

      {:ok, value} =
        Social.create_value(profile, group, %{
          "content" => long_content,
          "content_format" => :markdown
        })

      {:ok, lv, html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}")

      assert html =~ "See more"

      expanded_html =
        lv
        |> element("button[phx-click=toggle_value_expansion][phx-value-id='#{value.id}']")
        |> render_click()

      assert expanded_html =~ "See less"

      collapsed_html =
        lv
        |> element("button[phx-click=toggle_value_expansion][phx-value-id='#{value.id}']")
        |> render_click()

      assert collapsed_html =~ "See more"
    end
  end
end
