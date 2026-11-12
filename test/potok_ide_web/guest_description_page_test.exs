defmodule PotokIdeWeb.GuestDescriptionPageTest do
  @moduledoc """
  The page a guest gets at the link of a public group that opened its
  description to guests: the text with no process behind it, the alternative
  descriptions marked for guests, and the card everywhere else.
  """

  use PotokIdeWeb.ConnCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Social

  setup do
    {account, owner} = account_with_profile!("gdp-owner")

    group =
      public_group!(owner, %{
        "name" => "Mesna zajednica",
        "description" => "## Ko smo\n\nSastajemo se **utorkom**.<script>alert(1)</script>",
        "description_for_guests" => true
      })

    %{account: account, owner: owner, group: group}
  end

  defp public_group!(owner, attrs),
    do: group_with_members!(owner, [], Map.merge(%{"is_public" => true}, attrs))

  defp alt!(owner, group, attrs) do
    {:ok, alt} =
      Social.create_alt_description(
        owner,
        group,
        Map.merge(%{"description_format" => "markdown"}, attrs)
      )

    alt
  end

  defp document(conn), do: conn |> html_response(200) |> LazyHTML.from_document()

  defp found?(document, selector), do: Enum.count(LazyHTML.query(document, selector)) == 1

  defp text(document, selector), do: document |> LazyHTML.query(selector) |> LazyHTML.text()

  defp og(document, property) do
    document
    |> LazyHTML.query(~s(meta[property="og:#{property}"]))
    |> LazyHTML.attribute("content")
    |> List.first()
  end

  test "shows a guest the whole description, sanitized", %{conn: conn, group: group} do
    document = conn |> get(~p"/groups/#{group.id}") |> document()

    assert found?(document, "#guest-group")
    assert found?(document, "#guest-description .rich-content h2")
    assert text(document, "#guest-description") =~ "Sastajemo se utorkom."
    assert found?(document, "#guest-description strong")
    # Markdown shows a tag as letters, as on a member's page: nothing runs.
    refute found?(document, "#guest-description script")
    refute document |> LazyHTML.query("main script") |> Enum.any?()
    refute found?(document, "#public-group")
    assert found?(document, "#guest-group-login[href='/accounts/log-in']")
    assert found?(document, "#guest-join-login")
    assert found?(document, "#guest-join-invitation-note")
    # The text alone needs no live connection.
    refute found?(document, "[data-phx-session]")
  end

  test "keeps the card's meta tags and stays out of search engines", %{conn: conn, group: group} do
    document = conn |> get(~p"/groups/#{group.id}") |> document()

    assert og(document, "title") == "Mesna zajednica"
    assert og(document, "description") =~ "Sastajemo se utorkom."
    assert found?(document, ~s(meta[name="robots"][content="noindex"]))

    assert PotokIdeWeb.PublicPreview.link_preview(url(~p"/groups/#{group.id}")) ==
             {:ok,
              %{
                "url" => url(~p"/groups/#{group.id}"),
                "title" => "Mesna zajednica",
                "description" => og(document, "description"),
                "site_name" => "Potok",
                "image_url" => og(document, "image")
              }}
  end

  test "shows the card while the switch is off", %{conn: conn, owner: owner} do
    group =
      public_group!(owner, %{"description" => "Samo deo.", "description_for_guests" => false})

    document = conn |> get(~p"/groups/#{group.id}") |> document()

    assert found?(document, "#public-group")
    refute found?(document, "#guest-group")
  end

  test "a private group stays behind the login, switch or not", %{conn: conn, owner: owner} do
    group =
      group_with_members!(owner, [], %{
        "name" => "Tajna",
        "description" => "Tajni tekst.",
        "description_for_guests" => true
      })

    conn = get(conn, ~p"/groups/#{group.id}")

    assert redirected_to(conn) == ~p"/accounts/log-in"
    refute conn.resp_body =~ "Tajni tekst"
  end

  test "shows the marked alternative descriptions and none of the others", ctx do
    marked =
      alt!(ctx.owner, ctx.group, %{
        "name" => "Za goste",
        "description" => "Dobrodošli!",
        "for_guests" => "true"
      })

    unmarked = alt!(ctx.owner, ctx.group, %{"name" => "Za članove", "description" => "Interno."})

    limited =
      alt!(ctx.owner, ctx.group, %{
        "name" => "Uprava",
        "description" => "Samo uprava.",
        "visible_role_keys" => ["everyone"]
      })

    document = ctx.conn |> get(~p"/groups/#{ctx.group.id}") |> document()

    assert found?(document, "#guest-description-link-default[aria-current='page']")
    assert found?(document, "#guest-description-link-#{marked.id}")
    refute found?(document, "#guest-description-link-#{unmarked.id}")
    refute found?(document, "#guest-description-link-#{limited.id}")

    alt_page =
      ctx.conn |> get(~p"/groups/#{ctx.group.id}/group_home?#{[d: marked.id]}") |> document()

    assert text(alt_page, "#guest-description") =~ "Dobrodošli!"
    assert found?(alt_page, "#guest-description-link-#{marked.id}[aria-current='page']")

    for hidden <- [unmarked, limited] do
      page =
        ctx.conn |> get(~p"/groups/#{ctx.group.id}/group_home?#{[d: hidden.id]}") |> document()

      assert text(page, "#guest-description") =~ "Sastajemo se"
      refute page |> LazyHTML.to_html() |> String.contains?(hidden.description)
    end
  end

  test "opens on the group's home description when guests read it", ctx do
    home =
      alt!(ctx.owner, ctx.group, %{
        "name" => "Početna",
        "description" => "Prvo ovo.",
        "for_guests" => "true"
      })

    {:ok, group} =
      Social.update_group(ctx.owner, ctx.group, %{"home_alt_description_id" => home.id})

    assert ctx.conn |> get(~p"/groups/#{group.id}") |> document() |> text("#guest-description") =~
             "Prvo ovo."

    {:ok, _alt} =
      Social.update_alt_description(ctx.owner, group, home, %{"for_guests" => "false"})

    assert ctx.conn |> get(~p"/groups/#{group.id}") |> document() |> text("#guest-description") =~
             "Sastajemo se"
  end

  test "an empty default leaves the marked ones, and nothing at all the card", ctx do
    group = public_group!(ctx.owner, %{"description" => "  ", "description_for_guests" => true})

    assert ctx.conn |> get(~p"/groups/#{group.id}") |> document() |> found?("#public-group")

    alt =
      alt!(ctx.owner, group, %{
        "name" => "Jedini",
        "description" => "Jedini opis.",
        "for_guests" => "true"
      })

    document = ctx.conn |> get(~p"/groups/#{group.id}") |> document()

    assert text(document, "#guest-description") =~ "Jedini opis."
    # One description needs no tabs.
    refute found?(document, "#guest-descriptions")
    refute found?(document, "#guest-description-link-#{alt.id}")
  end

  test "names nobody who reacted", ctx do
    {_account, fan} = account_with_profile!("gdp-fan")
    {:ok, _reactions} = Social.toggle_group_reaction(fan, ctx.group, "👍")

    body = ctx.conn |> get(~p"/groups/#{ctx.group.id}") |> html_response(200)

    refute body =~ "gdp-fan"
    refute body =~ ctx.owner.username
  end

  test "a link into an app opens the story when the app keeps to its members", ctx do
    app =
      public_group!(ctx.owner, %{
        "name" => "Vesti",
        "description" => "<p>app</p>",
        "description_format" => :html,
        "uses_api" => true
      })

    story =
      group_with_members!(ctx.owner, [], %{
        :parent => app,
        "name" => "Most",
        "description" => "Most je otvoren.",
        "is_public" => true,
        "description_for_guests" => true
      })

    document =
      ctx.conn |> get(~p"/groups/#{app.id}/group_home?#{[at: story.id]}") |> document()

    assert og(document, "title") == "Most"
    assert text(document, "#guest-description") =~ "Most je otvoren."
  end

  test "a public event keeps its own card", ctx do
    event =
      create_event!(
        ctx.owner,
        ctx.group,
        event_attrs(Date.add(today(), 3), %{"is_public" => "true", "title" => "Zbor"})
      )

    document =
      ctx.conn |> get(~p"/groups/#{ctx.group.id}/calendar?#{[event: event.id]}") |> document()

    assert found?(document, "#public-event")
    refute found?(document, "#guest-group")
  end

  test "signed-in accounts still get the group itself", ctx do
    document =
      ctx.conn |> log_in_account(ctx.account) |> get(~p"/groups/#{ctx.group.id}") |> document()

    refute found?(document, "#guest-group")
    assert found?(document, "[data-phx-main]")
  end
end
