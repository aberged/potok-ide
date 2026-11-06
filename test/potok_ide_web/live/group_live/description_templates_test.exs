defmodule PotokIdeWeb.GroupLive.DescriptionTemplatesTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social
  alias PotokIdeWeb.PostTemplates.Post

  setup do
    {account, owner} = account_with_profile!("tpl-owner")
    group = group!(owner, "tpl-group", %{"description" => ""})

    %{account: account, owner: owner, group: group}
  end

  defp open(ctx, group \\ nil) do
    {:ok, lv, _html} =
      ctx.conn
      |> log_in_account(Accounts.get_account!(ctx.account.id))
      |> live(~p"/groups/#{(group || ctx.group).id}/edit_group")

    lv
  end

  defp change(lv, form, template) do
    lv |> form(form) |> render_change(%{"description_template" => template})
  end

  defp submit(lv, form, template, attrs \\ %{}) do
    lv |> form(form, attrs) |> render_submit(%{"description_template" => template})
  end

  describe "the group's description" do
    test "is written through a template", ctx do
      lv = open(ctx)

      refute has_element?(lv, "#group-description-templates")
      assert has_element?(lv, "#group-description-template-current", "Free text")

      lv |> element("#group-description-template-change") |> render_click()

      assert has_element?(lv, "#group-description-templates .post-template", "News")
      assert has_element?(lv, "#group-description-templates .post-template-current", "Free")

      assert has_element?(
               lv,
               "#group-description-template-quote[name='description_template[pick]'][value=quote]"
             )

      change(lv, "#group-edit-form", %{"pick" => "quote"})

      refute has_element?(lv, "#group-description-templates")
      assert has_element?(lv, "#group-description-template-current", "Quote")
      assert has_element?(lv, "#group-description-template-fields")
      refute has_element?(lv, "#group-edit-form textarea[name='group[description]']")
      refute has_element?(lv, "#group-edit-form input[name='group[description_format]']")

      change(lv, "#group-edit-form", %{"id" => "quote", "fields" => %{"quote" => "Reka nosi."}})

      assert has_element?(lv, ".group-description-pane-preview blockquote", "Reka nosi.")
      assert has_element?(lv, "#group-edit-save-bar")

      submit(lv, "#group-edit-form", %{"id" => "quote", "fields" => %{"quote" => "Reka nosi."}})

      saved = Social.get_group!(ctx.group.id)

      assert saved.name == "tpl-group"
      assert saved.description_format == :html

      assert {:post, %{template: "quote", fields: %{"quote" => "Reka nosi."}}} =
               Post.decode(saved.description)

      refute has_element?(lv, "#group-edit-save-bar")
    end

    test "opens in the form it was made with, which saves nothing by itself", ctx do
      description =
        Post.encode("article", %{"title" => "Most", "body" => "Tekst", "kicker" => "Iz kraja"})

      group = group!(ctx.owner, "tpl-post", %{"description" => description})
      lv = open(ctx, group)

      assert has_element?(lv, "#group-description-template-current", "News")
      assert has_element?(lv, "#group-description-template-field-title[value=Most]")
      assert has_element?(lv, "#group-description-template-field-body", "Tekst")
      refute has_element?(lv, "#group-edit-save-bar")

      fields = %{"title" => "Most", "body" => "Tekst", "kicker" => "Iz kraja", "image" => ""}
      change(lv, "#group-edit-form", %{"id" => "article", "fields" => fields})

      refute has_element?(lv, "#group-edit-save-bar")

      submit(lv, "#group-edit-form", %{"id" => "article", "fields" => fields}, %{
        group: %{name: "Novo ime"}
      })

      saved = Social.get_group!(group.id)

      assert saved.name == "Novo ime"
      assert saved.description == description
    end

    test "needs the template's required fields before it saves", ctx do
      lv = open(ctx)

      change(lv, "#group-edit-form", %{"pick" => "photo"})

      assert has_element?(lv, "#group-description-template-missing", "Picture, Headline")

      lv |> element("#group-edit-tab-basics") |> render_click()
      submit(lv, "#group-edit-form", %{"id" => "photo", "fields" => %{"title" => "Jutro"}})

      refute Social.get_group!(ctx.group.id).description
      assert has_element?(lv, "#group-description-template-missing", "Picture")
      refute has_element?(lv, "#group-edit-description.hidden")
      assert has_element?(lv, "#group-edit-description-editor[open]")
    end

    test "does not stop a rename when it lacks a field since long ago", ctx do
      description = Post.encode("photo", %{"title" => "Jutro"})
      group = group!(ctx.owner, "tpl-old", %{"description" => description})
      lv = open(ctx, group)

      submit(lv, "#group-edit-form", %{"id" => "photo", "fields" => %{"title" => "Jutro"}}, %{
        group: %{name: "Novo ime"}
      })

      assert Social.get_group!(group.id).name == "Novo ime"
    end

    test "asks before a template replaces written text", ctx do
      group = group!(ctx.owner, "tpl-text", %{"description" => "Moj **tekst**"})
      lv = open(ctx, group)

      lv |> element("#group-description-template-change") |> render_click()

      assert has_element?(lv, "#group-description-template-quote[data-confirm]")
      refute has_element?(lv, "#group-description-template-text[data-confirm]")

      lv |> element("#group-description-template-change") |> render_click()
      lv = open(ctx)
      lv |> element("#group-description-template-change") |> render_click()

      refute has_element?(lv, "#group-description-template-quote[data-confirm]")
    end

    test "asks before a template replaces a text changed by hand", ctx do
      description = Post.encode("quote", %{"quote" => "Reka"}) <> "<p>rukom</p>"
      group = group!(ctx.owner, "tpl-hand-pick", %{"description" => description})
      lv = open(ctx, group)

      lv |> element("#group-description-template-change") |> render_click()

      assert has_element?(lv, "#group-description-template-article[data-confirm]")
    end

    test "goes back to free text with the HTML kept", ctx do
      group =
        group!(ctx.owner, "tpl-free", %{
          "description" => Post.encode("quote", %{"quote" => "Reka"})
        })

      lv = open(ctx, group)

      change(lv, "#group-edit-form", %{
        "id" => "quote",
        "pick" => "text",
        "fields" => %{"quote" => "Reka"}
      })

      assert has_element?(
               lv,
               "#group-edit-form textarea[name='group[description]']",
               "blockquote"
             )

      refute has_element?(lv, "#group-description-template-fields")
    end

    test "changed by hand opens as text and can go back to the template", ctx do
      description = Post.encode("quote", %{"quote" => "Reka"}) <> "<p>rukom</p>"
      group = group!(ctx.owner, "tpl-hand", %{"description" => description})
      lv = open(ctx, group)

      assert has_element?(lv, "#group-description-template-changed", "Quote")
      assert has_element?(lv, "#group-edit-form textarea[name='group[description]']", "rukom")
      refute has_element?(lv, "#group-description-template-fields")

      assert has_element?(
               lv,
               "#group-description-template-restore[name='description_template[restore]']"
             )

      change(lv, "#group-edit-form", %{"restore" => "1"})

      assert has_element?(lv, "#group-description-template-fields")
      refute has_element?(lv, "#group-description-template-changed")
      refute has_element?(lv, ".group-description-pane-preview", "rukom")
    end

    test "offers no template to an app", ctx do
      group =
        group!(ctx.owner, "tpl-app", %{
          "description" => "<script>1</script>",
          "uses_api" => true,
          "description_format" => :html
        })

      lv = open(ctx, group)

      refute has_element?(lv, "#group-description-template-change")
      assert has_element?(lv, "#group-description-template-app")

      lv = open(ctx)

      assert has_element?(lv, "#group-description-template-change")
      refute has_element?(lv, "#group-description-template-app")

      lv |> form("#group-edit-form", group: %{uses_api: true}) |> render_change()

      refute has_element?(lv, "#group-description-template-change")
      assert has_element?(lv, "#group-description-template-app")
    end

    test "edits a list row by row", ctx do
      lv = open(ctx)
      fields = %{"title" => "Vikend", "items" => ["prva"]}

      change(lv, "#group-edit-form", %{"pick" => "list"})
      change(lv, "#group-edit-form", %{"id" => "list", "fields" => fields})

      assert has_element?(
               lv,
               "#group-description-template-field-items-add[name='description_template[add_item]']"
             )

      change(lv, "#group-edit-form", %{"id" => "list", "add_item" => "1", "fields" => fields})

      assert has_element?(lv, "#group-description-template-field-items-1")
      assert has_element?(lv, "#group-description-template-field-items-1-remove")

      change(lv, "#group-edit-form", %{
        "id" => "list",
        "remove_item" => "1",
        "fields" => %{"title" => "Vikend", "items" => ["prva", ""]}
      })

      refute has_element?(lv, "#group-description-template-field-items-1")
    end
  end

  describe "alternative descriptions" do
    test "are written through a template too", ctx do
      lv = open(ctx)

      lv |> element("#alt-description-new") |> render_click()
      lv |> element("#alt-description-template-change") |> render_click()

      assert has_element?(lv, "#alt-description-templates")
      refute has_element?(lv, "#group-description-templates")

      change(lv, "#alt-description-form", %{"pick" => "notice"})

      assert has_element?(lv, "#alt-description-template-fields")
      refute has_element?(lv, "#group-description-template-fields")

      template = %{
        "id" => "notice",
        "fields" => %{"level" => "urgent", "title" => "Nema vode", "body" => ""}
      }

      submit(lv, "#alt-description-form", template, %{
        group_alt_description: %{name: "Hitno"}
      })

      refute has_element?(lv, "#alt-description-form")

      assert [alt] = Social.list_alt_descriptions(ctx.group)
      assert alt.name == "Hitno"
      assert alt.description_format == :html

      assert {:post, %{template: "notice", fields: %{"level" => "urgent"}}} =
               Post.decode(alt.description)

      lv |> element("#alt-description-#{alt.id}-edit") |> render_click()

      assert has_element?(lv, "#alt-description-template-field-title[value='Nema vode']")
      assert has_element?(lv, "#alt-description-template-current", "Notice")
    end

    test "do not save without the template's required fields", ctx do
      lv = open(ctx)

      lv |> element("#alt-description-new") |> render_click()
      change(lv, "#alt-description-form", %{"pick" => "quote"})

      submit(lv, "#alt-description-form", %{"id" => "quote", "fields" => %{"author" => "Ana"}}, %{
        group_alt_description: %{name: "Citat"}
      })

      assert Social.list_alt_descriptions(ctx.group) == []
      assert has_element?(lv, "#alt-description-template-missing", "Quote")
    end

    test "offer no template to an app", ctx do
      lv = open(ctx)

      lv |> element("#alt-description-new") |> render_click()

      lv
      |> form("#alt-description-form", group_alt_description: %{uses_api: true})
      |> render_change()

      refute has_element?(lv, "#alt-description-template-change")
      assert has_element?(lv, "#alt-description-template-app")
    end
  end

  describe "on the group's page" do
    defp page(ctx, group, query \\ "") do
      {:ok, lv, _html} =
        ctx.conn
        |> log_in_account(Accounts.get_account!(ctx.account.id))
        |> live("/groups/#{group.id}/group_home#{query}")

      lv
    end

    test "a description from a template is as wide as in Feed, with its reactions", ctx do
      description = Post.encode("quote", %{"quote" => "Reka"})
      group = group!(ctx.owner, "tpl-wide", %{"description" => description})
      lv = page(ctx, group)

      assert has_element?(lv, "#group-panel-description.max-w-2xl blockquote")
      assert has_element?(lv, "#group-reactions.max-w-2xl")
    end

    test "so is one changed by hand since", ctx do
      description = Post.encode("quote", %{"quote" => "Reka"}) <> "<p>rukom</p>"
      group = group!(ctx.owner, "tpl-wide-hand", %{"description" => description})

      assert has_element?(page(ctx, group), "#group-panel-description.max-w-2xl")
    end

    test "so is an alternative description from a template", ctx do
      {:ok, alt} =
        Social.create_alt_description(ctx.owner, ctx.group, %{
          "name" => "Citat",
          "description" => Post.encode("quote", %{"quote" => "Reka"}),
          "description_format" => :html
        })

      lv = page(ctx, ctx.group, "?d=#{alt.id}")

      assert has_element?(lv, "#group-panel-description.max-w-2xl blockquote")
    end

    test "other text keeps the whole panel", ctx do
      group = group!(ctx.owner, "tpl-plain", %{"description" => "Moj **tekst**"})
      lv = page(ctx, group)

      assert has_element?(lv, "#group-panel-description")
      refute has_element?(lv, "#group-panel-description.max-w-2xl")
      refute has_element?(lv, "#group-reactions.max-w-2xl")
    end
  end

  test "the create tab keeps its plain editor", ctx do
    {:ok, lv, _html} =
      ctx.conn
      |> log_in_account(Accounts.get_account!(ctx.account.id))
      |> live(~p"/groups/#{ctx.group.id}/create_group")

    assert has_element?(lv, "#group-create-description textarea[name='group[description]']")
    refute has_element?(lv, "#group-create-description-template-change")

    lv |> form("#group-create-form", group: %{uses_api: true}) |> render_change()

    refute has_element?(lv, "#group-create-description-template-app")
  end

  describe "a picture from the device" do
    defp pick_article(lv) do
      change(lv, "#group-edit-form", %{"pick" => "article"})
      lv
    end

    defp send_picture(lv) do
      upload =
        file_input(lv, "#description-picture-form", :description_picture, [
          %{name: "most.jpg", content: "jpeg-bytes", type: "image/jpeg"}
        ])

      render_upload(upload, "most.jpg")
    end

    test "goes to the chat as a message, and its address to the form", ctx do
      lv = ctx |> open() |> pick_article()

      assert has_element?(lv, "#group-description-template-field-image-device")

      send_picture(lv)

      assert_push_event(lv, "description_picture_ready", %{url: url})

      assert {[attachment], false} = Social.list_group_attachments(ctx.group)
      assert attachment.filename == "most.jpg"

      assert {[value], _more?} = Social.list_group_values_page(ctx.group)
      assert value.content == "Picture for the group's description"
      assert [%{id: id}] = value.attachments
      assert id == attachment.id

      assert %{scheme: "http", path: "/pictures/" <> _token} = URI.parse(url)
      assert has_element?(lv, "#group-panel-edit-group")
      refute has_element?(lv, "#group-description-template-field-image-failed")

      conn = get(build_conn(), URI.parse(url).path)
      assert response(conn, 200) == "jpeg-bytes"
    end

    # The hook writes the address into the field, and a debounce would leave it
    # there to be cleared by the next update of the page. Only a browser sees it.
    test "reaches a field that does not wait", ctx do
      lv = ctx |> open() |> pick_article()

      assert has_element?(lv, "#group-description-template-field-image")
      refute has_element?(lv, "#group-description-template-field-image[phx-debounce]")
    end

    test "is refused if it is not a picture", ctx do
      lv = ctx |> open() |> pick_article()

      upload =
        file_input(lv, "#description-picture-form", :description_picture, [
          %{name: "plan.pdf", content: "pdf", type: "application/pdf"}
        ])

      {:error, [[_ref, :not_accepted]]} = render_upload(upload, "plan.pdf")

      assert {[], false} = Social.list_group_attachments(ctx.group)
    end

    test "reports a file the browser could not read", ctx do
      lv = ctx |> open() |> pick_article()

      render_hook(lv, "description_picture_invalid", %{})

      assert has_element?(lv, "#flash-group", "image")
    end

    test "is only offered to whoever may post a file to the chat", ctx do
      {member_account, member} = account_with_profile!("tpl-member")
      {:ok, invitation} = Social.invite_profile_to_group(ctx.owner, ctx.group, member)
      {:ok, _accepted} = Social.accept_group_invitation(invitation, member)
      {:ok, _manifest} = Social.create_own_group_manifest(ctx.owner, ctx.group)

      {:ok, _role} =
        Social.set_group_role_permission(ctx.owner, ctx.group, "everyone", :edit_group, :allow)

      {:ok, _role} =
        Social.set_group_role_permission(
          ctx.owner,
          ctx.group,
          "everyone",
          :attach_files,
          :neutral
        )

      lv = %{ctx | account: member_account} |> open() |> pick_article()

      assert has_element?(lv, "#group-description-template-field-image")
      refute has_element?(lv, "#group-description-template-field-image-device")
      refute has_element?(lv, "#description-picture")
    end
  end

  defp account_with_profile!(username) do
    account = account_fixture()

    {:ok, profile} =
      Social.create_profile_for_account(account, %{
        username: username,
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    {account, profile}
  end

  defp group!(owner, name, attrs) do
    attrs =
      Map.merge(
        %{"name" => name, "description_format" => attrs_format(attrs), "is_public" => false},
        attrs
      )

    {:ok, group} = Social.create_group(owner, Social.get_root_group!(), attrs)
    group
  end

  defp attrs_format(%{"description" => "<!--potok-post" <> _rest}), do: :html
  defp attrs_format(_attrs), do: :markdown
end
