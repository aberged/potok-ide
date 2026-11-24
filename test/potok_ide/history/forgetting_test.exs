defmodule PotokIde.History.ForgettingTest do
  @moduledoc """
  What goes from the history and what stays: when an account is deleted, when
  someone empties old versions, and when a thing has too many of them.
  """

  use PotokIde.DataCase, async: true

  import Ecto.Query
  import PotokIde.EventsFixtures

  alias PotokIde.Accounts.Deletion
  alias PotokIde.{History, Repo, Social}
  alias PotokIde.History.GroupChange
  alias PotokIde.Social.{AppData, Group, Profile}

  defp unique, do: System.unique_integer([:positive])

  setup do
    {owner_account, owner} = account_with_profile!("hf#{unique()}")
    {member_account, member} = account_with_profile!("hf#{unique()}")
    {_, other} = account_with_profile!("hf#{unique()}")

    group =
      group_with_members!(owner, [member, other], %{
        "uses_api" => true,
        "description" => "<p>prvi</p>",
        "description_format" => :html,
        "home_page" => :description
      })

    group = Social.get_group!(group.id)

    {:ok, _} =
      AppData.save_config(
        owner,
        group,
        nil,
        %{"rules" => %{"molbe" => %{"edit_own" => true}}},
        0
      )

    {:ok, value, _} =
      AppData.insert(member, member_account, group, nil, "molbe", %{"ime" => "Petar"})

    {:ok, _, _} = AppData.update(member, group, nil, value.id, %{"ime" => "Pera"}, nil)

    %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: member_account,
      other: other,
      group: group,
      value: value
    }
  end

  defp changes(query) do
    Repo.all(from(c in query, order_by: c.id, select_merge: %{before: c.before}))
  end

  defp of(type, id),
    do: changes(from(c in GroupChange, where: c.subject_type == ^type and c.subject_id == ^id))

  defp changed(type, id), do: type |> of(id) |> Enum.find(&(&1.op == :changed))

  describe "a deleted account" do
    test "leaves that it changed things, and nothing of what it wrote", ctx do
      {:ok, message} = Social.create_value(ctx.owner, ctx.group, %{"content" => "x"})
      {:ok, _} = Social.toggle_value_reaction(ctx.member, ctx.group, message, "👍")
      {:ok, _} = Social.assign_group_member_role(ctx.owner, ctx.group, ctx.member.id, "admin")

      {:ok, _} =
        Social.update_group_description(ctx.member, Repo.get!(Group, ctx.group.id), %{
          "description" => "<p>drugi</p>"
        })

      before = Repo.aggregate(GroupChange, :count)
      {:ok, _} = Deletion.delete(ctx.member_account)

      assert of("reaction", message.id) == []
      assert Repo.aggregate(GroupChange, :count) == before - 1

      assert [created, changed] = of("record", ctx.value.id)
      assert changed.before == nil
      assert changed.purged_at
      assert changed.purged_by_id == nil
      assert {created.actor_id, changed.actor_id} == {ctx.member.id, ctx.member.id}
      assert %Profile{kind: :deleted} = Repo.get!(Profile, ctx.member.id)

      # The group's own description is the group's.
      assert %{before: %{"description" => "<p>prvi</p>"}} = changed("group", ctx.group.id)

      %{rows: rows} = Repo.query!("SELECT c::text FROM group_changes c")
      text = rows |> List.flatten() |> Enum.join()
      refute text =~ "Petar"
      refute text =~ ctx.member.username
    end

    test "a group that goes with it leaves nothing in the one above", ctx do
      alone =
        group_with_members!(ctx.member, [], %{:parent => ctx.group, "is_public" => true})

      assert [%{op: :created}] = of("sub_group", alone.id)
      {:ok, _} = Deletion.delete(ctx.member_account)

      refute Repo.get(Group, alone.id)
      assert [%{op: :created}] = of("sub_group", alone.id)
    end
  end

  describe "emptying old versions" do
    test "an admin empties any; a member only their own records", ctx do
      {:ok, _} =
        Social.update_group_description(ctx.owner, ctx.group, %{"description" => "<p>2</p>"})

      description = changed("group", ctx.group.id)
      record = changed("record", ctx.value.id)

      assert {:error, :not_permitted} = History.empty(ctx.member, ctx.group, description)
      assert {:error, :not_permitted} = History.empty(ctx.other, ctx.group, record)
      assert {:ok, 1} = History.empty(ctx.member, ctx.group, record)
      assert {:ok, 1} = History.empty(ctx.owner, ctx.group, description)

      for {type, id, who} <- [
            {"record", ctx.value.id, ctx.member},
            {"group", ctx.group.id, ctx.owner}
          ] do
        emptied = changed(type, id)
        assert emptied.before == nil
        assert emptied.purged_by_id == who.id
        # The fact stays.
        assert emptied.actor_id
        assert emptied.fields != []
      end
    end

    test "a change of another group is not reached through one's own", ctx do
      {_, stranger} = account_with_profile!("hf#{unique()}")
      own = group_with_members!(stranger, [])

      assert {:error, :not_permitted} =
               History.empty(stranger, own, changed("record", ctx.value.id))
    end

    test "records deleted at once are emptied at once, whatever else was kept of them", ctx do
      {:ok, other, _} =
        AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, "molbe", %{
          "ime" => "Drugi"
        })

      {:ok, 2} = AppData.delete_collection(ctx.owner, ctx.group, nil, "molbe")

      listed =
        Repo.one!(
          from(c in GroupChange,
            where: c.op == :deleted and c.subject_type == "record" and c.listed
          )
        )

      # Two deletions, and the change the first record had before it.
      assert {:ok, 3} = History.empty(ctx.owner, ctx.group, listed)
      %{rows: rows} = Repo.query!("SELECT c::text FROM group_changes c")
      text = rows |> List.flatten() |> Enum.join()
      refute text =~ "Petar"
      refute text =~ "Drugi"
      assert length(of("record", other.id)) == 2
    end

    test "a burst goes on as a new row once it was emptied", ctx do
      update = fn text ->
        {:ok, _} =
          Social.update_group_description(ctx.owner, Repo.get!(Group, ctx.group.id), %{
            "description" => text
          })
      end

      update.("<p>2</p>")
      {:ok, 1} = History.empty(ctx.owner, ctx.group, changed("group", ctx.group.id))
      update.("<p>3</p>")

      assert [%{before: nil}, %{before: %{"description" => "<p>2</p>"}}] =
               of("group", ctx.group.id)
    end
  end

  test "only so many versions of one thing are kept, the newest", ctx do
    versions = History.versions()

    for n <- 1..(versions + 5) do
      {:ok, _, _} =
        AppData.update(ctx.member, ctx.group, nil, ctx.value.id, %{"n" => n}, nil)
    end

    assert History.thin() == 6
    assert History.thin() == 0

    changed = Enum.filter(of("record", ctx.value.id), &(&1.op == :changed))
    assert length(changed) == versions + 6
    {old, kept} = Enum.split(changed, 6)
    assert Enum.all?(old, &(is_nil(&1.before) and not is_nil(&1.purged_at)))
    assert Enum.all?(kept, &(not is_nil(&1.before)))
  end
end
