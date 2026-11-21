defmodule PotokIdeWeb.GroupLive.CustomTemplatesTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures, only: [account_with_profile!: 1, group_with_members!: 3]

  alias PotokIde.Accounts
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.GroupTemplates
  alias PotokIdeWeb.PostTemplates.{Custom, Post}

  @attrs %{
    "name" => "Utakmica",
    "purpose" => "Rezultat i strelci.",
    "fields" => [
      %{"label" => "Domaćin", "kind" => "text", "required" => "true"},
      %{"label" => "Strelci", "kind" => "items"},
      %{"label" => "Ishod", "kind" => "choice", "options" => "pobeda\nnerešeno\nporaz"},
      %{"label" => "Snimak", "kind" => "video"}
    ],
    "html" =>
      "<h2>{{domacin}}</h2>{{#strelci}}<p>{{.}}</p>{{/strelci}}<p>{{ishod}}</p>" <>
        "{{#snimak}}<video src=\"{{snimak|video}}\" controls></video>{{/snimak}}"
  }

  setup do
    {account, owner} = account_with_profile!("ctpl-owner")
    top = group_with_members!(owner, [], %{"name" => "Liga"})
    group = group_with_members!(owner, [], %{"name" => "Ekipa", parent: top})
    {:ok, template} = GroupTemplates.create(owner, top, @attrs)

    %{account: account, owner: owner, top: top, group: group, template: template}
  end

  defp open(ctx, group) do
    {:ok, lv, _html} =
      ctx.conn
      |> log_in_account(Accounts.get_account!(ctx.account.id))
      |> live(~p"/groups/#{group.id}/edit_group")

    lv
  end

  defp change(lv, form, template) do
    lv |> form(form) |> render_change(%{"description_template" => template})
  end

  defp submit(lv, form, template, attrs \\ %{}) do
    lv |> form(form, attrs) |> render_submit(%{"description_template" => template})
  end

  test "a group below picks the template of the group above, named by its group", ctx do
    lv = open(ctx, ctx.group)
    id = "custom:#{ctx.template.id}"
    card = "#group-description-template-custom-#{ctx.template.id}"

    lv |> element("#group-description-template-change") |> render_click()

    assert has_element?(lv, "#{card}[value='#{id}']", "Utakmica")
    assert has_element?(lv, card, "Liga")
    assert has_element?(lv, "#{card} .post-template-page h2")

    change(lv, "#group-edit-form", %{"pick" => id})

    assert has_element?(lv, "#group-description-template-current", "Utakmica")
    assert has_element?(lv, "#group-description-template-field-domacin")
    assert has_element?(lv, "#group-description-template-field-strelci-add[value=strelci]")
    assert has_element?(lv, "select#group-description-template-field-ishod option", "nerešeno")
    assert has_element?(lv, "#group-description-template-field-snimak")
    assert has_element?(lv, "#group-description-template-missing", "Domaćin")

    fields = %{"domacin" => "Zvezda", "strelci" => ["Pera"], "ishod" => "pobeda"}
    change(lv, "#group-edit-form", %{"id" => id, "add_item" => "strelci", "fields" => fields})

    assert has_element?(lv, "#group-description-template-field-strelci-1")

    fields = %{
      "domacin" => "Zvezda",
      "strelci" => ["Pera", "Mika"],
      "ishod" => "pobeda",
      "snimak" => "https://video.example/gol.mp4"
    }

    change(lv, "#group-edit-form", %{"id" => id, "fields" => fields})

    assert has_element?(lv, ".group-description-pane-preview h2", "Zvezda")
    assert has_element?(lv, ".group-description-pane-preview video[controls]")
    assert has_element?(lv, "#group-description-template-field-snimak-clear[value=snimak]")

    submit(lv, "#group-edit-form", %{"id" => id, "fields" => fields})

    saved = Social.get_group!(ctx.group.id)
    assert saved.description_format == :html
    assert {:post, %{template: ^id, fields: saved_fields}} = Post.decode(saved.description)
    assert saved_fields["strelci"] == ["Pera", "Mika"]
    assert saved.description =~ ~s("rev":1)
    assert saved.description =~ "<h2>Zvezda</h2><p>Pera</p><p>Mika</p><p>pobeda</p>"
    assert saved.description =~ ~s(<video src="https://video.example/gol.mp4" controls>)
  end

  test "the group's own templates carry no group's name", ctx do
    lv = open(ctx, ctx.top)

    lv |> element("#group-description-template-change") |> render_click()

    card = "#group-description-template-custom-#{ctx.template.id}"
    assert has_element?(lv, card, "Utakmica")
    refute has_element?(lv, card, "Liga")
  end

  test "a group elsewhere is not offered the template", ctx do
    other = group_with_members!(ctx.owner, [], %{"name" => "Drugde"})
    lv = open(ctx, other)

    lv |> element("#group-description-template-change") |> render_click()

    refute has_element?(lv, "#group-description-template-custom-#{ctx.template.id}")
  end

  test "an alternative description takes the template too", ctx do
    lv = open(ctx, ctx.group)
    id = "custom:#{ctx.template.id}"

    lv |> element("#alt-description-new") |> render_click()
    change(lv, "#alt-description-form", %{"pick" => id})

    assert has_element?(lv, "#alt-description-template-field-domacin")

    submit(lv, "#alt-description-form", %{"id" => id, "fields" => %{"domacin" => "Partizan"}}, %{
      group_alt_description: %{name: "Gosti"}
    })

    assert [alt] = Social.list_alt_descriptions(ctx.group)
    assert {:post, %{template: ^id}} = Post.decode(alt.description)
    assert alt.description =~ "<h2>Partizan</h2>"
  end

  test "a description of a template since deleted opens as text and stays", ctx do
    description =
      Post.encode(
        "custom:#{ctx.template.id}",
        %{"domacin" => "Zvezda"},
        [Custom.form_template(ctx.template)]
      )

    {:ok, group} =
      ctx.group
      |> Ecto.Changeset.change(description: description, description_format: :html)
      |> Repo.update()

    {:ok, _deleted} = GroupTemplates.delete(ctx.owner, ctx.top, ctx.template)

    lv = open(ctx, group)

    assert has_element?(lv, "#group-description-template-gone")
    assert has_element?(lv, "#group-description-template-current", "Free text")
    refute has_element?(lv, "#group-description-template-fields")
    assert has_element?(lv, "#group-edit-form textarea[name='group[description]']")

    lv |> form("#group-edit-form", %{group: %{name: "Ekipa 2"}}) |> render_submit()

    saved = Social.get_group!(group.id)
    assert saved.name == "Ekipa 2"
    assert saved.description == description
  end

  test "a template changed above serves the next save in its new version", ctx do
    {:ok, template} =
      GroupTemplates.update(ctx.owner, ctx.top, ctx.template, %{
        "html" => "<h3>{{domacin}}</h3>"
      })

    lv = open(ctx, ctx.group)
    id = "custom:#{template.id}"

    change(lv, "#group-edit-form", %{"pick" => id})
    submit(lv, "#group-edit-form", %{"id" => id, "fields" => %{"domacin" => "Zvezda"}})

    saved = Social.get_group!(ctx.group.id)
    assert saved.description =~ ~s("rev":2)
    assert saved.description =~ "<h3>Zvezda</h3>"
  end
end
