defmodule PotokIdeWeb.ShareLiveTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Social

  setup do
    {owner_account, owner} = account_with_profile!("sp-owner")
    {member_account, member} = account_with_profile!("sp-member")
    garden = group_with_members!(owner, [member], %{"name" => "Garden club"})
    books = group_with_members!(owner, [member], %{"name" => "Books"})

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      garden: garden,
      books: books
    }
  end

  defp live_as(account, path) do
    build_conn()
    |> log_in_account(account)
    |> live(path)
  end

  defp load_share(lv, attrs \\ %{}) do
    lv
    |> element("#share-inbox")
    |> render_hook(
      "share_loaded",
      Map.merge(
        %{
          "id" => "abc123",
          "text" => "Look at this\nhttps://example.com",
          "files" => [%{"name" => "photo.jpg", "type" => "image/jpeg", "size" => 2048}]
        },
        attrs
      )
    )
  end

  test "asks the device for the share and says when there is none", ctx do
    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/share")

    assert has_element?(lv, "#share-header h1")
    assert has_element?(lv, "#share-inbox[phx-hook='SharePreview']")
    assert has_element?(lv, "#share-loading")
    refute has_element?(lv, "#share-groups")

    lv |> element("#share-inbox") |> render_hook("share_missing", %{})

    assert has_element?(lv, "#share-missing")
    refute has_element?(lv, "#share-loading")
  end

  test "shows the share and the groups that lead to their composer with it", ctx do
    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/share")
    load_share(lv)

    assert has_element?(lv, "#share-preview-text", "https://example.com")
    assert has_element?(lv, "#share-preview-file-0", "photo.jpg")
    assert has_element?(lv, "#share-group-#{ctx.garden.id}", "Garden club")
    assert has_element?(lv, "#share-group-#{ctx.books.id}", "Books")

    assert has_element?(
             lv,
             ~s(#share-group-#{ctx.garden.id} a[href="/groups/#{ctx.garden.id}/values?share=abc123"])
           )

    lv |> element("#share-group-#{ctx.garden.id} a") |> render_click()
    assert_redirect(lv, ~p"/groups/#{ctx.garden.id}/values?share=abc123")
  end

  test "searches the groups", ctx do
    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/share")
    load_share(lv)

    lv |> form("#share-search-form", share_search: %{q: "gard"}) |> render_change()

    assert has_element?(lv, "#share-group-#{ctx.garden.id}")
    refute has_element?(lv, "#share-group-#{ctx.books.id}")

    lv |> form("#share-search-form", share_search: %{q: "nothing like it"}) |> render_change()
    assert has_element?(lv, "#share-groups-empty")
  end

  test "names the other member of a direct conversation", ctx do
    {:ok, direct} = Social.get_or_create_direct_group(ctx.member, ctx.owner)
    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/share")
    load_share(lv)

    assert has_element?(lv, "#share-group-#{direct.id}", "sp-owner")
  end

  test "an empty or malformed share is nothing to share", ctx do
    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/share")

    load_share(lv, %{"text" => "  ", "files" => []})
    assert has_element?(lv, "#share-missing")

    load_share(lv, %{"id" => "../../etc"})
    assert has_element?(lv, "#share-missing")
  end

  test "cancelling goes to the groups", ctx do
    {:ok, lv, _html} = live_as(ctx.member_account, ~p"/share")
    load_share(lv)

    lv |> element("#share-inbox") |> render_hook("share_cancelled", %{})
    assert_redirect(lv, ~p"/groups")
  end

  test "logged-out visitors log in first", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/accounts/log-in"}}} = live(conn, ~p"/share")
  end

  describe "the group's composer" do
    test "takes the share named by ?share=", ctx do
      {:ok, lv, _html} =
        live_as(ctx.member_account, ~p"/groups/#{ctx.garden.id}/values?share=abc123")

      assert has_element?(
               lv,
               ~s(#group-value-share[phx-hook="ShareComposer"][data-share-id="abc123"][data-can-attach="true"])
             )

      lv |> element("#group-value-share") |> render_hook("share_done", %{})
      assert_patch(lv, ~p"/groups/#{ctx.garden.id}/values")
      refute has_element?(lv, "#group-value-share")
    end

    test "ignores a malformed share id", ctx do
      {:ok, lv, _html} =
        live_as(ctx.member_account, ~p"/groups/#{ctx.garden.id}/values?share=a%20b")

      refute has_element?(lv, "#group-value-share")
    end

    test "says which shared files were left out", ctx do
      {:ok, lv, _html} =
        live_as(ctx.member_account, ~p"/groups/#{ctx.garden.id}/values?share=abc123")

      html =
        lv
        |> element("#group-value-share")
        |> render_hook("share_files_skipped", %{
          "too_large" => ["movie.mp4"],
          "too_many" => [],
          "not_allowed" => [],
          "failed" => ["broken.pdf"]
        })

      assert html =~ "movie.mp4"
      assert html =~ "broken.pdf"
    end
  end

  describe "the share target fallback" do
    test "passes the shared text on to /share", %{conn: conn} do
      conn =
        post(conn, ~p"/share-target", %{
          "title" => "A title",
          "text" => " Some text ",
          "url" => "https://example.com/a?b=c",
          "other" => "dropped"
        })

      assert conn.status == 303
      location = redirected_to(conn, 303)
      assert %URI{path: "/share", query: query} = URI.parse(location)

      assert URI.decode_query(query) == %{
               "title" => "A title",
               "text" => "Some text",
               "url" => "https://example.com/a?b=c"
             }
    end

    test "goes to /share without a query when nothing came", %{conn: conn} do
      conn = post(conn, ~p"/share-target", %{})
      assert redirected_to(conn, 303) == "/share"
    end
  end
end
