defmodule PotokIde.Social.AltDescriptionsTest do
  use PotokIde.DataCase

  import PotokIde.AccountsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, Group, GroupAltDescription, Value}

  describe "create_alt_description/3" do
    test "adds descriptions in order and notifies the group" do
      owner = profile!("alt-owner")
      group = group!(owner, "alt-group")
      Social.subscribe_group(group)

      assert {:ok, first} = Social.create_alt_description(owner, group, %{"name" => " Poll "})
      assert {:ok, second} = Social.create_alt_description(owner, group, %{"name" => "Board"})

      assert first.name == "Poll"
      assert first.description == ""
      assert first.creator_id == owner.id
      assert Enum.map(Social.list_alt_descriptions(group), & &1.id) == [first.id, second.id]

      group_id = group.id
      assert_receive {:alt_descriptions_updated, ^group_id}
    end

    test "forces html for apps and validates the name" do
      owner = profile!("alt-valid-owner")
      group = group!(owner, "alt-valid-group")

      assert {:ok, app} =
               Social.create_alt_description(owner, group, %{
                 "name" => "App",
                 "uses_api" => "true",
                 "description_format" => "markdown"
               })

      assert app.description_format == :html

      assert {:error, changeset} = Social.create_alt_description(owner, group, %{"name" => " "})
      assert "can't be blank" in errors_on(changeset).name

      assert {:error, changeset} = Social.create_alt_description(owner, group, %{"name" => "app"})
      assert "is already used by another description" in errors_on(changeset).name
    end

    test "caps the number of descriptions" do
      owner = profile!("alt-cap-owner")
      group = group!(owner, "alt-cap-group")

      for n <- 1..Social.max_alt_descriptions() do
        {:ok, _alt} = Social.create_alt_description(owner, group, %{"name" => "d#{n}"})
      end

      assert {:error, :too_many_alt_descriptions} =
               Social.create_alt_description(owner, group, %{"name" => "one too many"})
    end

    test "needs the edit_group permission" do
      owner = profile!("alt-perm-owner")
      member = profile!("alt-perm-member")
      group = group!(owner, "alt-perm-group")
      add_member!(owner, group, member)

      assert {:error, :not_permitted} =
               Social.create_alt_description(member, group, %{"name" => "Nope"})

      {:ok, alt} = Social.create_alt_description(owner, group, %{"name" => "Mine"})

      assert {:error, :not_permitted} =
               Social.update_alt_description(member, group, alt, %{"name" => "Theirs"})

      assert {:error, :not_permitted} = Social.delete_alt_description(member, group, alt)
      assert {:error, :not_permitted} = Social.move_alt_description(member, group, alt, :up)

      assert {:error, :not_permitted} =
               Social.promote_alt_description(member, group, alt, "Description")
    end

    test "refuses descriptions of another group" do
      owner = profile!("alt-other-owner")
      group = group!(owner, "alt-other-group")
      other_group = group!(owner, "alt-other-group-2")
      {:ok, alt} = Social.create_alt_description(owner, other_group, %{"name" => "Elsewhere"})

      assert {:error, :not_found} =
               Social.update_alt_description(owner, group, alt, %{"name" => "Moved"})

      assert {:error, :not_found} = Social.delete_alt_description(owner, group, alt)

      assert {:error, :not_found} =
               Social.create_data_value(owner, group, %{"data" => ~s({"n": 1})}, alt)
    end
  end

  describe "move_alt_description/4" do
    test "swaps a description with its neighbour" do
      owner = profile!("alt-move-owner")
      group = group!(owner, "alt-move-group")
      [a, b, c] = for name <- ~w(a b c), do: alt!(owner, group, %{"name" => name})

      assert {:ok, :moved} = Social.move_alt_description(owner, group, c, :up)
      assert names(group) == ~w(a c b)

      assert {:ok, :moved} = Social.move_alt_description(owner, group, a, :down)
      assert names(group) == ~w(c a b)

      assert {:ok, :unchanged} = Social.move_alt_description(owner, group, c, :up)
      assert {:ok, :unchanged} = Social.move_alt_description(owner, group, b, :down)
      assert names(group) == ~w(c a b)
    end
  end

  describe "app data values" do
    setup do
      owner = profile!("alt-data-owner")
      member = profile!("alt-data-member")
      group = group!(owner, "alt-data-group", %{"uses_api" => true})
      add_member!(owner, group, member)
      poll = alt!(owner, group, %{"name" => "Poll", "uses_api" => true})
      board = alt!(owner, group, %{"name" => "Board", "uses_api" => true})

      {:ok, default_value} = data_value!(member, group, nil, 1)
      {:ok, poll_value} = data_value!(member, group, poll, 2)
      {:ok, board_value} = data_value!(member, group, board, 3)

      %{
        owner: owner,
        group: group,
        poll: poll,
        board: board,
        default_value: default_value,
        poll_value: poll_value,
        board_value: board_value
      }
    end

    test "each app lists its own values unless it asks for the group's", ctx do
      assert ids(ctx.group, []) == [ctx.default_value.id]
      assert ids(ctx.group, scope: {:app, nil}) == [ctx.default_value.id]
      assert ids(ctx.group, scope: {:app, ctx.poll.id}) == [ctx.poll_value.id]

      assert ids(ctx.group, scope: {:group, [ctx.poll.id]}) ==
               [ctx.default_value.id, ctx.poll_value.id]

      {[row], false} =
        Social.list_group_data_value_rows(ctx.group, scope: {:app, ctx.poll.id})

      assert row.description_id == ctx.poll.id
    end

    test "deleting data values only deletes the chosen app's", ctx do
      assert {:ok, 1} = Social.delete_group_data_values(ctx.owner, ctx.group, ctx.poll)
      assert {:ok, 1} = Social.delete_group_data_values(ctx.owner, ctx.group)

      assert ids(ctx.group, scope: {:group, [ctx.poll.id, ctx.board.id]}) == [
               ctx.board_value.id
             ]
    end

    test "deleting a description deletes its app's values and clears the home pointer", ctx do
      {:ok, group} =
        Social.update_group(ctx.owner, ctx.group, %{"home_alt_description_id" => ctx.poll.id})

      assert group.home_alt_description_id == ctx.poll.id

      assert {:ok, _deleted} = Social.delete_alt_description(ctx.owner, group, ctx.poll)

      refute Repo.get(Value, ctx.poll_value.id)
      assert Repo.get(Value, ctx.board_value.id)
      assert Social.get_group!(group.id).home_alt_description_id == nil
    end

    test "promoting swaps the contents and each app keeps its values", ctx do
      {:ok, group} =
        Social.update_group(ctx.owner, ctx.group, %{
          "description" => "<p>default app</p>",
          "home_alt_description_id" => ctx.poll.id
        })

      {:ok, poll} =
        Social.update_alt_description(ctx.owner, group, ctx.poll, %{
          "description" => "<p>poll app</p>"
        })

      Social.subscribe_group(group)

      assert {:ok, promoted_group, demoted} =
               Social.promote_alt_description(ctx.owner, group, poll, "Description")

      assert promoted_group.description == "<p>poll app</p>"
      assert promoted_group.description_name == "Poll"
      assert promoted_group.uses_api
      assert promoted_group.home_alt_description_id == nil

      assert demoted.id == poll.id
      assert demoted.name == "Description"
      assert demoted.description == "<p>default app</p>"

      assert Repo.get!(Value, ctx.poll_value.id).alt_description_id == nil
      assert Repo.get!(Value, ctx.default_value.id).alt_description_id == poll.id
      assert Repo.get!(Value, ctx.board_value.id).alt_description_id == ctx.board.id

      group_id = group.id
      assert_receive {:alt_descriptions_updated, ^group_id}
    end

    test "promoting refuses a description limited to roles", ctx do
      {:ok, poll} =
        Social.update_alt_description(ctx.owner, ctx.group, ctx.poll, %{
          "visible_role_keys" => ["everyone"]
        })

      assert {:error, :alt_description_restricted} =
               Social.promote_alt_description(ctx.owner, ctx.group, poll, "Description")
    end

    test "promoting reports a name the old default cannot take", ctx do
      {:ok, _named} =
        Social.update_alt_description(ctx.owner, ctx.group, ctx.board, %{
          "name" => "Description"
        })

      assert {:error, %Ecto.Changeset{}} =
               Social.promote_alt_description(ctx.owner, ctx.group, ctx.poll, "Description")

      assert Social.get_group!(ctx.group.id).description_name == nil
    end
  end

  describe "update_group/3" do
    test "only takes a home description of the same group" do
      owner = profile!("alt-home-owner")
      group = group!(owner, "alt-home-group")
      other_group = group!(owner, "alt-home-group-2")
      own = alt!(owner, group, %{"name" => "Own"})
      foreign = alt!(owner, other_group, %{"name" => "Foreign"})

      assert {:error, changeset} =
               Social.update_group(owner, group, %{"home_alt_description_id" => foreign.id})

      assert "is not a description of this group" in errors_on(changeset).home_alt_description_id

      assert {:ok, %Group{home_alt_description_id: home_id}} =
               Social.update_group(owner, group, %{"home_alt_description_id" => own.id})

      assert home_id == own.id

      assert {:ok, %Group{home_alt_description_id: nil}} =
               Social.update_group(owner, group, %{"home_alt_description_id" => ""})
    end

    test "deleting a group deletes its descriptions" do
      owner = profile!("alt-delete-owner")
      group = group!(owner, "alt-delete-group")
      alt = alt!(owner, group, %{"name" => "Gone", "uses_api" => true})
      {:ok, group} = Social.update_group(owner, group, %{"home_alt_description_id" => alt.id})
      {:ok, _value} = data_value!(owner, group, alt, 1)

      assert {:ok, _deleted} = Social.delete_group(owner, group)
      refute Repo.get(GroupAltDescription, alt.id)
    end
  end

  describe "Access.sees_alt_description?/2" do
    test "follows the roles, and editors see every description" do
      owner = profile!("alt-see-owner")
      member = profile!("alt-see-member")
      helper = profile!("alt-see-helper")
      outsider = profile!("alt-see-outsider")
      group = group!(owner, "alt-see-group", %{"is_public" => true})
      add_member!(owner, group, member)
      add_member!(owner, group, helper)

      {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
      {:ok, helpers} = Social.create_group_role(owner, group, %{"name" => "helpers"})
      {:ok, _} = Social.assign_group_member_role(owner, group, helper.id, helpers.key)

      everyone = %GroupAltDescription{visible_role_keys: []}
      members_only = %GroupAltDescription{visible_role_keys: ["everyone"]}
      helpers_only = %GroupAltDescription{visible_role_keys: [helpers.key]}
      deleted_role = %GroupAltDescription{visible_role_keys: ["gone"]}

      sees? = fn profile, alt ->
        Access.sees_alt_description?(Access.for_profile(profile, group), alt)
      end

      assert sees?.(outsider, everyone)
      refute sees?.(outsider, members_only)
      assert sees?.(member, members_only)
      refute sees?.(member, helpers_only)
      assert sees?.(helper, helpers_only)
      assert sees?.(owner, helpers_only)
      assert sees?.(owner, deleted_role)
      refute sees?.(helper, deleted_role)
    end
  end

  defp names(group), do: group |> Social.list_alt_descriptions() |> Enum.map(& &1.name)

  defp ids(group, opts) do
    {rows, _has_more?} = Social.list_group_data_value_rows(group, opts)
    rows |> Enum.map(& &1.id) |> Enum.sort()
  end

  defp data_value!(profile, group, alt, n) do
    Social.create_data_value(profile, group, %{"content" => "data:", "data" => %{"n" => n}}, alt)
  end

  defp profile!(username) do
    {:ok, profile} =
      Social.create_profile_for_account(account_fixture(), %{
        username: username,
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    profile
  end

  defp group!(owner, name, attrs \\ %{}) do
    attrs =
      Map.merge(%{"name" => name, "description" => "", "description_format" => :markdown}, attrs)

    {:ok, group} = Social.create_group(owner, Social.get_root_group!(), attrs)
    group
  end

  defp alt!(owner, group, attrs) do
    {:ok, alt} = Social.create_alt_description(owner, group, attrs)
    alt
  end

  defp add_member!(owner, group, profile) do
    {:ok, invitation} = Social.invite_profile_to_group(owner, group, profile)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, profile)
    :ok
  end
end
