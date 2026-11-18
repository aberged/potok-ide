defmodule PotokIdeWeb.GroupLive.AppDescriptionArchiveTest do
  @moduledoc """
  An app's description goes in and out as a file (`Components.app_archive`):
  the browser reads the ZIP and writes the HTML into a hidden field, which is
  all the server sees, and the format is HTML while the switch is on. The ZIP
  itself is the browser's (`assets/js/description_archive.js`).
  """
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  @app "<!doctype html><html><body><p>Moja aplikacija</p></body></html>"

  setup do
    account = account_fixture()

    {:ok, owner} =
      Social.create_profile_for_account(account, %{
        username: "zip-owner",
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    {:ok, group} =
      Social.create_group(owner, Social.get_root_group!(), %{
        "name" => "Vesti",
        "description" => "Samo **tekst**",
        "description_format" => :markdown,
        "is_public" => false
      })

    %{account: account, owner: owner, group: group}
  end

  defp open(ctx, path) do
    {:ok, lv, _html} =
      ctx.conn
      |> log_in_account(Accounts.get_account!(ctx.account.id))
      |> live(path)

    lv
  end

  defp edit(ctx, group \\ nil), do: open(ctx, ~p"/groups/#{(group || ctx.group).id}/edit_group")

  defp app_group!(ctx) do
    {:ok, group} =
      Social.create_group(ctx.owner, Social.get_root_group!(), %{
        "name" => "Mapa: kraj/okolina",
        "description" => @app,
        "description_format" => :html,
        "uses_api" => true,
        "is_public" => false
      })

    group
  end

  describe "the group's description" do
    test "is a file while it is an app", ctx do
      lv = edit(ctx, app_group!(ctx))

      refute has_element?(lv, "#group-edit-description-editor")
      refute has_element?(lv, "#group-edit-form textarea[name='group[description]']")
      refute has_element?(lv, "#group-description-layout-selector")

      assert has_element?(
               lv,
               "#group-description-app-html[type=hidden][name='group[description]']"
             )

      assert has_element?(lv, "#group-description-app-size", "#{byte_size(@app)} B")

      # The file is the browser's: no name, so the form never sends it.
      assert has_element?(
               lv,
               "#group-description-app-archive[phx-hook=DescriptionArchive][data-input=group-description-app-html]"
             )

      assert has_element?(lv, "#group-description-app-archive input[type=file]:not([name])")
      assert has_element?(lv, "#group-description-app-upload")
      assert has_element?(lv, "#group-description-app-download")

      # A name Windows refuses becomes one it takes.
      assert has_element?(
               lv,
               "#group-description-app-archive[data-file-name='Mapa kraj okolina']"
             )

      assert has_element?(lv, "#group-description-format-html[checked]:not([disabled])")
      assert has_element?(lv, "#group-description-format-markdown[disabled]:not([checked])")
      assert has_element?(lv, "#group-description-format-app")
    end

    test "takes the HTML the browser read and saves it as HTML", ctx do
      lv = edit(ctx)

      assert has_element?(lv, "#group-edit-description-editor")
      assert has_element?(lv, "#group-description-format-markdown[checked]:not([disabled])")
      refute has_element?(lv, "#group-description-app")

      # The params still say Markdown on the change that turns the switch on.
      lv
      |> form("#group-edit-form")
      |> render_change(%{group: %{uses_api: "true", description_format: "markdown"}})

      refute has_element?(lv, "#group-edit-description-editor")
      assert has_element?(lv, "#group-description-format-html[checked]")
      assert has_element?(lv, "#group-description-format-markdown[disabled]:not([checked])")
      # The text written before stays in the field until a file replaces it.
      assert has_element?(lv, "#group-description-app-html[value='Samo **tekst**']")

      lv
      |> form("#group-edit-form")
      |> render_change(%{group: %{description: @app}})

      assert has_element?(lv, "#group-description-app-size", "#{byte_size(@app)} B")
      assert has_element?(lv, "#group-edit-save-bar")

      lv |> form("#group-edit-form") |> render_submit()

      group = Social.get_group!(ctx.group.id)
      assert group.uses_api
      assert group.description == @app
      assert group.description_format == :html
    end

    test "turns back into text with HTML picked", ctx do
      lv = edit(ctx, app_group!(ctx))

      lv |> form("#group-edit-form") |> render_change(%{group: %{uses_api: "false"}})

      assert has_element?(lv, "#group-edit-description-editor")
      assert has_element?(lv, "#group-edit-form textarea[name='group[description]']")
      refute has_element?(lv, "#group-description-app")
      assert has_element?(lv, "#group-description-format-html[checked]:not([disabled])")
      assert has_element?(lv, "#group-description-format-markdown:not([disabled])")
      refute has_element?(lv, "#group-description-format-app")
    end

    test "says when there is no app yet", ctx do
      lv = edit(ctx)

      lv
      |> form("#group-edit-form")
      |> render_change(%{group: %{uses_api: "true", description: ""}})

      assert has_element?(lv, "#group-description-app-size", "No app yet")
    end
  end

  describe "an alternative description" do
    test "is a file while it is an app, named after the group and itself", ctx do
      lv = edit(ctx)

      lv |> element("#alt-description-new") |> render_click()

      assert has_element?(lv, "#alt-description-form textarea")
      refute has_element?(lv, "#alt-description-app")

      lv
      |> form("#alt-description-form")
      |> render_change(%{group_alt_description: %{name: "Mapa", uses_api: "true"}})

      refute has_element?(lv, "#alt-description-form textarea")
      assert has_element?(lv, "#alt-description-app-html[type=hidden]")
      assert has_element?(lv, "#alt-description-app-archive[data-file-name='Vesti – Mapa']")
      assert has_element?(lv, "#alt-description-format-markdown[disabled]")
      assert has_element?(lv, "#alt-description-format-html[checked]")

      lv
      |> form("#alt-description-form")
      |> render_change(%{group_alt_description: %{description: @app}})

      lv |> form("#alt-description-form") |> render_submit()

      assert [alt] = Social.list_alt_descriptions(ctx.group)
      assert alt.name == "Mapa"
      assert alt.uses_api
      assert alt.description == @app
      assert alt.description_format == :html

      lv |> element("#alt-description-#{alt.id}-edit") |> render_click()

      assert has_element?(lv, "#alt-description-app-size", "#{byte_size(@app)} B")
    end
  end

  describe "a new group" do
    test "gets its app as a file too", ctx do
      lv = open(ctx, ~p"/groups/#{ctx.group.id}/create_group")

      assert has_element?(lv, "#group-create-description textarea[name='group[description]']")

      lv
      |> form("#group-create-form")
      |> render_change(%{group: %{name: "Anketa", uses_api: "true"}})

      refute has_element?(lv, "#group-create-description textarea[name='group[description]']")
      assert has_element?(lv, "#group-create-description-app-archive[data-file-name=Anketa]")
      assert has_element?(lv, "#group-create-description-format-markdown[disabled]")
    end
  end
end
