defmodule PotokIdeWeb.GroupLive.TemplatesCardTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  import PotokIde.EventsFixtures,
    only: [account_with_profile!: 1, add_member!: 3, group_with_members!: 3]

  alias PotokIde.Accounts
  alias PotokIde.Social.GroupTemplates

  @attrs %{
    "name" => "Utakmica",
    "purpose" => "Rezultat.",
    "fields" => [%{"label" => "Domaćin", "kind" => "text", "required" => "true"}],
    "html" => "<h2>{{domacin}}</h2>"
  }

  setup do
    {account, owner} = account_with_profile!("tcard-owner")
    top = group_with_members!(owner, [], %{"name" => "Liga"})
    group = group_with_members!(owner, [], %{"name" => "Ekipa", parent: top})

    %{account: account, owner: owner, top: top, group: group}
  end

  defp open(conn, account, group) do
    {:ok, lv, _html} =
      conn
      |> log_in_account(Accounts.get_account!(account.id))
      |> live(~p"/groups/#{group.id}/edit_group?section=templates")

    lv
  end

  defp change(lv, values, action \\ nil) do
    extra = if action, do: %{"group_template_action" => action}, else: %{}
    lv |> form("#group-template-form", %{group_template: values}) |> render_change(extra)
  end

  test "an editor makes a template from fields, with a preview", ctx do
    lv = open(ctx.conn, ctx.account, ctx.group)

    assert has_element?(lv, "#group-edit-tab-templates")
    assert has_element?(lv, "#group-template-empty")

    lv |> element("#group-template-new") |> render_click()

    assert has_element?(lv, "#group-template-field-0-label[value=Title]")
    assert has_element?(lv, "#group-template-field-1-kind option[selected][value=textarea]")
    assert has_element?(lv, "#group-template-field-0-tag", "{{title}}")
    assert has_element?(lv, "#group-template-preview h2", "Title")

    change(lv, %{name: "Utakmica"}, "add_field")

    assert has_element?(lv, "#group-template-field-2")

    change(lv, %{name: "Utakmica", fields: %{"2" => %{label: "Strelci", kind: "items"}}})

    assert has_element?(lv, "#group-template-field-2-tag", "{{#strelci}}{{.}}{{/strelci}}")

    html = change(lv, %{name: "Utakmica"}, "html_from_fields")

    assert html =~ "{{#strelci}}"
    assert has_element?(lv, "#group-template-preview li", "Strelci 1")

    lv |> form("#group-template-form") |> render_submit()

    assert [template] = GroupTemplates.list_own(ctx.group)
    assert template.name == "Utakmica"
    assert Enum.map(template.fields, & &1["key"]) == ["title", "text", "strelci"]
    assert template.html =~ "<li>{{.}}</li>"
    refute has_element?(lv, "#group-template-form")
    assert has_element?(lv, "#group-template-#{template.id}", "Utakmica")
    assert has_element?(lv, "#flash-group", "Template saved.")
  end

  test "a field it lacks or a crossed section keeps it from saving", ctx do
    lv = open(ctx.conn, ctx.account, ctx.group)
    lv |> element("#group-template-new") |> render_click()

    change(lv, %{name: "Loš", html: "<p>{{nema}}</p>"})

    assert has_element?(lv, "#group-template-form", "has no field nema")
    refute has_element?(lv, "#group-template-preview")

    lv |> form("#group-template-form") |> render_submit()

    assert GroupTemplates.list_own(ctx.group) == []
    assert has_element?(lv, "#group-template-form")

    # Removing the field the HTML names is an error of the HTML at once.
    change(lv, %{name: "Loš", html: "<h2>{{title}}</h2>"})
    assert has_element?(lv, "#group-template-preview h2")

    change(lv, %{name: "Loš", html: "<h2>{{title}}</h2>"}, "remove:0")

    assert has_element?(lv, "#group-template-form", "has no field title")
    refute has_element?(lv, "#group-template-preview")
  end

  test "says what a description would leave out", ctx do
    lv = open(ctx.conn, ctx.account, ctx.group)
    lv |> element("#group-template-new") |> render_click()

    change(lv, %{
      name: "Stil",
      html: ~s(<div onclick="x" style="position: fixed; color: red">{{title}}</div>)
    })

    assert has_element?(lv, "#group-template-dropped", "div onclick")
    assert has_element?(lv, "#group-template-dropped", "position:fixed")
    refute has_element?(lv, "#group-template-dropped", "color:red")
  end

  test "an editor edits, orders and deletes the group's templates", ctx do
    {:ok, first} = GroupTemplates.create(ctx.owner, ctx.group, @attrs)
    {:ok, second} = GroupTemplates.create(ctx.owner, ctx.group, %{@attrs | "name" => "Turnir"})
    lv = open(ctx.conn, ctx.account, ctx.group)

    lv |> element("#group-template-#{first.id}-edit") |> render_click()

    assert has_element?(lv, "#group-template-#{first.id} #group-template-form")
    assert has_element?(lv, "#group-template-field-0-key[value=domacin]")

    change(lv, %{name: "Utakmica 2", html: "<h3>{{domacin}}</h3>"})
    lv |> form("#group-template-form") |> render_submit()

    assert [%{name: "Utakmica 2", rev: 2, html: "<h3>{{domacin}}</h3>"}, _second] =
             GroupTemplates.list_own(ctx.group)

    lv |> element("#group-template-#{second.id}-up") |> render_click()

    assert [%{id: id}, _first] = GroupTemplates.list_own(ctx.group)
    assert id == second.id

    lv |> element("#group-template-#{second.id}-delete") |> render_click()

    assert [%{id: id}] = GroupTemplates.list_own(ctx.group)
    assert id == first.id
    refute has_element?(lv, "#group-template-#{second.id}")
  end

  test "lists the templates from above, which only their group edits", ctx do
    {:ok, template} = GroupTemplates.create(ctx.owner, ctx.top, @attrs)
    lv = open(ctx.conn, ctx.account, ctx.group)

    assert has_element?(lv, "#group-template-inherited-#{template.id}", "Utakmica")
    assert has_element?(lv, "#group-template-inherited-#{template.id}", "Liga")
    refute has_element?(lv, "#group-template-#{template.id}-edit")
    refute has_element?(lv, "#group-template-empty")
  end

  test "a member who may not edit the group cannot make one", ctx do
    {member_account, member} = account_with_profile!("tcard-member")
    add_member!(ctx.owner, ctx.group, member)

    {:ok, lv, _html} =
      ctx.conn
      |> log_in_account(Accounts.get_account!(member_account.id))
      |> live(~p"/groups/#{ctx.group.id}")

    render_hook(lv, "group_template_new", %{})

    render_hook(lv, "group_template_save", %{
      "group_template" => %{"name" => "Upad", "html" => ""}
    })

    assert GroupTemplates.list_own(ctx.group) == []
  end
end
