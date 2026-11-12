defmodule PotokIde.Social.GuestDescriptionTest do
  @moduledoc """
  A public group that opened its description to guests, people without an
  account: the switch, the alternative descriptions marked to go with it, and
  how promoting one keeps what guests saw.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Group, GroupAltDescription}

  setup do
    {_account, owner} = account_with_profile!("guest-owner")
    {_account, member} = account_with_profile!("guest-member")

    group =
      group!(owner, "guest-group", %{
        "is_public" => true,
        "description_for_guests" => true,
        "description" => "Za sve."
      })

    %{owner: owner, member: member, group: group}
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

  defp alt!(owner, group, attrs) do
    {:ok, alt} =
      Social.create_alt_description(
        owner,
        group,
        Map.merge(%{"description" => "Tekst.", "description_format" => "markdown"}, attrs)
      )

    alt
  end

  describe "the group's switch" do
    test "opens the description of a public group only", ctx do
      assert Group.guest_description?(ctx.group)
      refute Group.guest_description?(%{ctx.group | is_public: false})
      refute Group.guest_description?(%{ctx.group | description_for_guests: false})
    end

    test "never opens the root, a direct conversation or a thread", ctx do
      {:ok, direct} = Social.get_or_create_direct_group(ctx.owner, ctx.member)
      {:ok, value} = Social.create_value(ctx.owner, ctx.group, %{"content" => "start"})

      {:ok, thread} =
        Social.get_or_create_value_thread(ctx.owner, ctx.group, value, %{"name" => "talk"})

      refute Group.guest_description?(%{direct | is_public: true, description_for_guests: true})
      refute Group.guest_description?(%{Social.get_root_group!() | description_for_guests: true})
      refute Group.guest_description?(%{thread | is_public: true, description_for_guests: true})
    end

    test "stays chosen while the group is private", ctx do
      {:ok, private} = Social.update_group(ctx.owner, ctx.group, %{"is_public" => false})
      assert private.description_for_guests
      refute Group.guest_description?(private)
      refute Social.guest_description_open?(private.id, nil)

      {:ok, public} = Social.update_group(ctx.owner, private, %{"is_public" => true})
      assert Group.guest_description?(public)
      assert Social.guest_description_open?(public.id, nil)
    end

    test "is off for a new group", ctx do
      group = group!(ctx.owner, "guest-new", %{"is_public" => true})
      refute group.description_for_guests
      refute Social.guest_description_open?(group.id, nil)
    end
  end

  describe "an alternative description" do
    test "goes to guests when marked and seen by everyone", ctx do
      marked = alt!(ctx.owner, ctx.group, %{"name" => "Za goste", "for_guests" => "true"})
      _unmarked = alt!(ctx.owner, ctx.group, %{"name" => "Za članove"})

      assert marked.for_guests

      assert [%GroupAltDescription{id: id, name: "Za goste"}] =
               Social.list_guest_alt_descriptions(ctx.group)

      assert id == marked.id
      assert Social.guest_description_open?(ctx.group.id, marked.id)
    end

    test "loses the mark when a role may see it only", ctx do
      alt =
        alt!(ctx.owner, ctx.group, %{
          "name" => "Uprava",
          "for_guests" => "true",
          "visible_role_keys" => ["everyone"]
        })

      refute alt.for_guests

      marked = alt!(ctx.owner, ctx.group, %{"name" => "Svima", "for_guests" => "true"})

      {:ok, limited} =
        Social.update_alt_description(ctx.owner, ctx.group, marked, %{
          "visible_role_keys" => ["everyone"]
        })

      refute limited.for_guests
      assert Social.list_guest_alt_descriptions(ctx.group) == []
    end

    test "never holds the mark with a role, even written past the changeset", ctx do
      alt = alt!(ctx.owner, ctx.group, %{"name" => "Uprava", "visible_role_keys" => ["everyone"]})

      assert_raise Postgrex.Error, ~r/group_alt_descriptions_for_guests_check/, fn ->
        from(d in GroupAltDescription, where: d.id == ^alt.id)
        |> Repo.update_all(set: [for_guests: true])
      end
    end

    test "is left out of the list when empty, and the list keeps the order", ctx do
      second = alt!(ctx.owner, ctx.group, %{"name" => "Drugi", "for_guests" => "true"})

      _blank =
        alt!(ctx.owner, ctx.group, %{
          "name" => "Prazan",
          "for_guests" => "true",
          "description" => " \n "
        })

      first = alt!(ctx.owner, ctx.group, %{"name" => "Prvi", "for_guests" => "true"})

      {:ok, _moved} = Social.move_alt_description(ctx.owner, ctx.group, first, :up)
      {:ok, _moved} = Social.move_alt_description(ctx.owner, ctx.group, first, :up)

      listed = Social.list_guest_alt_descriptions(ctx.group)

      assert Enum.map(listed, & &1.id) == [first.id, second.id]
      # Without its text: an app's can run to hundreds of kilobytes.
      assert Enum.all?(listed, &(&1.description == ""))
    end

    test "is not open while the group's switch is off", ctx do
      marked = alt!(ctx.owner, ctx.group, %{"name" => "Za goste", "for_guests" => "true"})

      {:ok, _closed} =
        Social.update_group(ctx.owner, ctx.group, %{"description_for_guests" => false})

      refute Social.guest_description_open?(ctx.group.id, marked.id)
    end
  end

  describe "making an alternative description the default" do
    test "keeps the old default where guests read it", ctx do
      alt = alt!(ctx.owner, ctx.group, %{"name" => "Novi"})

      {:ok, group, demoted} = Social.promote_alt_description(ctx.owner, ctx.group, alt, "Opis")

      assert group.description_for_guests
      assert group.description == "Tekst."
      assert demoted.description == "Za sve."
      assert demoted.for_guests
    end

    test "does not mark the old default when guests did not read it", ctx do
      {:ok, closed} =
        Social.update_group(ctx.owner, ctx.group, %{"description_for_guests" => false})

      alt = alt!(ctx.owner, closed, %{"name" => "Novi", "for_guests" => "true"})

      {:ok, group, demoted} = Social.promote_alt_description(ctx.owner, closed, alt, "Opis")

      refute group.description_for_guests
      refute demoted.for_guests
    end
  end
end
