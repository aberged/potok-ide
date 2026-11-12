defmodule PotokIdeWeb.GroupLive.GuestDescriptionSettingsTest do
  @moduledoc """
  The switches of a description open to guests in Edit group: the group's in
  Access, and each alternative description's own.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Social

  setup do
    {owner_account, owner} = account_with_profile!("gds-owner")
    group = group!(owner, "gds-group", %{"is_public" => true, "description" => "Za sve."})

    %{owner_account: owner_account, owner: owner, group: group}
  end

  defp group!(owner, name, attrs) do
    {:ok, group} =
      Social.create_group(
        owner,
        Social.get_root_group!(),
        Map.merge(
          %{"name" => name, "description" => "", "description_format" => :markdown},
          attrs
        )
      )

    group
  end

  defp edit(ctx, group) do
    {:ok, view, _html} =
      build_conn()
      |> log_in_account(ctx.owner_account)
      |> live(~p"/groups/#{group.id}/edit_group")

    view
  end

  describe "the group's switch" do
    test "opens the description to guests", ctx do
      view = edit(ctx, ctx.group)
      assert has_element?(view, "#group-edit-guest-description input[type=checkbox]")

      view
      |> form("#group-edit-form", group: %{description_for_guests: "true"})
      |> render_submit()

      assert Social.get_group!(ctx.group.id).description_for_guests

      document = build_conn() |> get(~p"/groups/#{ctx.group.id}") |> html_response(200)
      assert document =~ ~s(id="guest-description")
    end

    test "comes up with \"Public group\" and goes with it", ctx do
      private = group!(ctx.owner, "gds-private", %{"is_public" => false})
      view = edit(ctx, private)
      refute has_element?(view, "#group-edit-guest-description")

      view |> form("#group-edit-form", group: %{is_public: "true"}) |> render_change()
      assert has_element?(view, "#group-edit-guest-description")

      view |> form("#group-edit-form", group: %{is_public: "false"}) |> render_change()
      refute has_element?(view, "#group-edit-guest-description")
    end

    test "survives a save with the group private", ctx do
      {:ok, group} =
        Social.update_group(ctx.owner, ctx.group, %{"description_for_guests" => true})

      view = edit(ctx, group)

      view |> form("#group-edit-form", group: %{is_public: "false"}) |> render_submit()

      group = Social.get_group!(group.id)
      refute group.is_public
      assert group.description_for_guests
    end

    test "is not offered in a thread", ctx do
      {:ok, value} = Social.create_value(ctx.owner, ctx.group, %{"content" => "start"})

      {:ok, thread} =
        Social.get_or_create_value_thread(ctx.owner, ctx.group, value, %{"name" => "talk"})

      refute has_element?(edit(ctx, thread), "#group-edit-guest-description")
    end
  end

  describe "an alternative description's switch" do
    defp open_new(view) do
      view |> element("#group-edit-tab-alt_descriptions") |> render_click()
      view |> element("#alt-description-new") |> render_click()
      view
    end

    test "marks a description for guests", ctx do
      view = edit(ctx, ctx.group) |> open_new()
      assert has_element?(view, "#alt-description-for-guests input[type=checkbox]")
      # The group keeps its description from guests so far.
      assert has_element?(view, "#alt-description-for-guests-closed")

      view
      |> form("#alt-description-form",
        group_alt_description: %{name: "Za goste", description: "Dobrodošli.", for_guests: "true"}
      )
      |> render_submit()

      [alt] = Social.list_alt_descriptions(ctx.group)
      assert alt.for_guests
      assert has_element?(view, "#alt-description-#{alt.id}-guests")
    end

    test "is not offered once a role is picked", ctx do
      view = edit(ctx, ctx.group) |> open_new()

      view
      |> form("#alt-description-form",
        group_alt_description: %{name: "Uprava", visible_role_keys: ["", "everyone"]}
      )
      |> render_change()

      refute has_element?(view, "#alt-description-for-guests")
    end

    test "needs no note once the group's switch is on", ctx do
      {:ok, group} =
        Social.update_group(ctx.owner, ctx.group, %{"description_for_guests" => true})

      view = edit(ctx, group) |> open_new()

      assert has_element?(view, "#alt-description-for-guests")
      refute has_element?(view, "#alt-description-for-guests-closed")
    end

    test "is not offered in a private group", ctx do
      private = group!(ctx.owner, "gds-closed", %{"is_public" => false})
      view = edit(ctx, private) |> open_new()

      refute has_element?(view, "#alt-description-for-guests")
    end

    test "warns before making an unmarked one the default of an open group", ctx do
      {:ok, group} =
        Social.update_group(ctx.owner, ctx.group, %{"description_for_guests" => true})

      {:ok, unmarked} =
        Social.create_alt_description(ctx.owner, group, %{"name" => "Novi", "description" => "x"})

      {:ok, marked} =
        Social.create_alt_description(ctx.owner, group, %{
          "name" => "Za goste",
          "description" => "y",
          "for_guests" => "true"
        })

      view = edit(ctx, group)
      view |> element("#group-edit-tab-alt_descriptions") |> render_click()

      confirm = fn alt ->
        view
        |> element("#alt-description-#{alt.id}-promote")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.attribute("data-confirm")
        |> List.first()
      end

      # The same question, and one more sentence for what guests would read.
      assert String.starts_with?(confirm.(unmarked), confirm.(marked))
      assert String.length(confirm.(unmarked)) > String.length(confirm.(marked))
    end
  end
end
