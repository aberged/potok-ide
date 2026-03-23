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

    test "shows values first with composer at the bottom and switches tabs", %{conn: conn} do
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
      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(profile, root_group, %{
          "name" => "tabs-child-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

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
      assert has_element?(lv, "#group-value-form")
      refute has_element?(lv, "#group-tab-create-value")

      lv
      |> element("#group-tab-members")
      |> render_click()

      assert_patch(lv, ~p"/groups/#{group.id}/members")

      refute has_element?(lv, "#group-panel-values")
      assert has_element?(lv, "#group-panel-members")
    end

    test "loads the tab from the URL path", %{conn: conn} do
      owner_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "tab-path-owner",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "tab-path-invitee",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      owner_account = Accounts.get_account!(owner_account.id)
      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "tab-path-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert {:ok, invitation} =
               Social.invite_profile_to_group(owner_profile, group, invitee_profile)

      assert {:ok, _accepted_invitation} =
               Social.accept_group_invitation(invitation, invitee_profile)

      {:ok, lv, _html} =
        conn
        |> log_in_account(owner_account)
        |> live(~p"/groups/#{group.id}/members")

      assert has_element?(lv, "#group-panel-members")
      refute has_element?(lv, "#group-panel-values")
    end

    test "falls back to the default tab for invalid tab paths", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "invalid-tab-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(profile, root_group, %{
          "name" => "invalid-tab-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}/not-a-tab")

      assert has_element?(lv, "#group-panel-values")
    end

    test "clicking the member avatar summary switches to the members tab", %{conn: conn} do
      owner_account = account_fixture()
      invitee_account = account_fixture()

      {:ok, owner_profile} =
        Social.create_profile_for_account(owner_account, %{
          username: "member-summary-owner",
          profile_picture_url: "https://example.com/member-summary-owner.png",
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, invitee_profile} =
        Social.create_profile_for_account(invitee_account, %{
          username: "member-summary-invitee",
          profile_picture_url: "https://example.com/member-summary-invitee.png",
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      owner_account = Accounts.get_account!(owner_account.id)
      root_group = Social.get_root_group!()

      {:ok, group} =
        Social.create_group(owner_profile, root_group, %{
          "name" => "member-summary-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      assert {:ok, invitation} =
               Social.invite_profile_to_group(owner_profile, group, invitee_profile)

      assert {:ok, _accepted_invitation} =
               Social.accept_group_invitation(invitation, invitee_profile)

      {:ok, lv, _html} =
        conn
        |> log_in_account(owner_account)
        |> live(~p"/groups/#{group.id}")

      assert has_element?(lv, "#group-panel-values")

      lv
      |> element("#group-members-summary")
      |> render_click()

      refute has_element?(lv, "#group-panel-values")
      assert has_element?(lv, "#group-panel-members")
    end

    test "shows only sub-groups where current profile is a member", %{conn: conn} do
      account = account_fixture()
      other_account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "subgroup-member-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, other_profile} =
        Social.create_profile_for_account(other_account, %{
          username: "subgroup-other-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      root_group = Social.get_root_group!()

      {:ok, _visible_child_group} =
        Social.create_group(profile, root_group, %{
          "name" => "member-child-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, _hidden_child_group} =
        Social.create_group(other_profile, root_group, %{
          "name" => "other-child-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{root_group.id}")

      lv
      |> element("#group-tab-sub-groups")
      |> render_click()

      assert has_element?(lv, "#group-panel-sub-groups a", "member-child-group")
      refute has_element?(lv, "#group-panel-sub-groups a", "other-child-group")
    end

    test "renders group pictures in header and sub-group list", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "group-picture-member-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      root_group = Social.get_root_group!()

      {:ok, child_group} =
        Social.create_group(profile, root_group, %{
          "name" => "pictured-child-group",
          "group_picture_url" => "https://example.com/group-avatar.png",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, root_lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{root_group.id}")

      root_lv
      |> element("#group-tab-sub-groups")
      |> render_click()

      assert has_element?(
               root_lv,
               "#group-panel-sub-groups img[src='https://example.com/group-avatar.png']"
             )

      {:ok, child_lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{child_group.id}")

      assert has_element?(
               child_lv,
               "img[src='https://example.com/group-avatar.png'][alt='pictured-child-group']"
             )
    end

    test "renders values in chronological order with newest at the bottom", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "chronology-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      group = Social.get_root_group!()

      {:ok, _older_value} =
        Social.create_value(profile, group, %{
          "content" => "older value",
          "content_format" => :markdown
        })

      {:ok, _newer_value} =
        Social.create_value(profile, group, %{
          "content" => "newer value",
          "content_format" => :markdown
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}")

      html = render(lv)

      assert elem(:binary.match(html, "older value"), 0) <
               elem(:binary.match(html, "newer value"), 0)

      assert has_element?(lv, "#group-value-form")
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
          "content" => "# Heading\n\n**bold** and [link](https://example.com)",
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

      assert html =~ ~r/<h1>\s*Heading<\/h1>/
      assert html =~ "<strong>bold</strong>"
      assert html =~ "href=\"https://example.com\""
      assert html =~ ">link</a>"
      assert html =~ "<strong>html value</strong>"
    end

    test "preserves new lines in markdown values", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "newline-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      group = Social.get_root_group!()

      {:ok, _value} =
        Social.create_value(profile, group, %{
          "content" => "first line\nsecond line",
          "content_format" => :markdown
        })

      {:ok, _lv, html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}")

      assert html =~ ~r/first line\s*<br\/?/
      assert html =~ "second line"
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

    test "updates values when a new value is added externally", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "realtime-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      group = Social.get_root_group!()

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}")

      refute render(lv) =~ "realtime value"

      {:ok, _value} =
        Social.create_value(profile, group, %{
          "content" => "realtime value",
          "content_format" => :markdown
        })

      assert render(lv) =~ "realtime value"
    end

    test "allows the creator profile to delete a value", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "delete-value-live-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      group = Social.get_root_group!()

      {:ok, value} =
        Social.create_value(profile, group, %{
          "content" => "value to delete from liveview",
          "content_format" => :markdown
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}")

      assert has_element?(lv, "#value-#{value.id}")

      assert has_element?(
               lv,
               "#value-delete-#{value.id}[data-confirm='Are you sure you want to delete this value?']"
             )

      lv
      |> element("#value-delete-#{value.id}")
      |> render_click()

      refute has_element?(lv, "#value-#{value.id}")
      assert render(lv) =~ "No values yet. Start the conversation below."
    end

    test "allows the creator profile to edit a value", %{conn: conn} do
      account = account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "edit-value-live-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      account = Accounts.get_account!(account.id)
      group = Social.get_root_group!()

      {:ok, value} =
        Social.create_value(profile, group, %{
          "content" => "original liveview value",
          "content_format" => :markdown
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{group.id}")

      assert has_element?(lv, "#value-edit-#{value.id}")

      lv
      |> element("#value-edit-#{value.id}")
      |> render_click()

      assert has_element?(lv, "#edit-value-form-#{value.id}")

      lv
      |> form("#edit-value-form-#{value.id}", value: %{content: "edited liveview value"})
      |> render_submit()

      refute has_element?(lv, "#edit-value-form-#{value.id}")
      assert render(lv) =~ "edited liveview value"
      refute render(lv) =~ "original liveview value"
    end

    test "redirects when current profile changes to one without access", %{conn: conn} do
      account = account_fixture()

      {:ok, first_profile} =
        Social.create_profile_for_account(account, %{
          username: "member-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, second_profile} =
        Social.create_profile_for_account(account, %{
          username: "outsider-profile",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, account} = Accounts.set_current_profile(account, first_profile)
      account = Accounts.get_account!(account.id)
      root_group = Social.get_root_group!()

      {:ok, private_group} =
        Social.create_group(first_profile, root_group, %{
          "name" => "private-child",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, lv, _html} =
        conn
        |> log_in_account(account)
        |> live(~p"/groups/#{private_group.id}")

      {:ok, _updated_account} = Accounts.set_current_profile(account, second_profile)

      assert_redirect(lv, ~p"/groups")
    end
  end
end
