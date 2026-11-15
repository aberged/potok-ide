defmodule PotokIde.Social.ProcessActionsTest do
  @moduledoc """
  What an app's process does, as the engine will call it inside a step: once,
  told only after the step commits, signed by the process, in its own groups
  and with its own permissions, and with people as the admins of what it makes.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social

  alias PotokIde.Social.{
    Access,
    AppData,
    AppProcess,
    Group,
    ProcessActions,
    ProcessStep,
    Profile,
    Value
  }

  defp unique, do: System.unique_integer([:positive])

  setup do
    {_owner_account, owner} = account_with_profile!("pa#{unique()}")
    {_member_account, member} = account_with_profile!("pa#{unique()}")

    group =
      group_with_members!(owner, [member], %{
        "uses_api" => true,
        "description" => "<p>app</p>",
        "description_format" => :html,
        "home_page" => :description
      })

    {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
    group = Social.get_group!(group.id)
    save!(owner, group, %{"tasks" => %{"process" => %{"name" => "Prijem"}}})

    row =
      AppProcess
      |> Repo.get_by!(group_id: group.id, collection: "tasks")
      |> Repo.preload(:profile)

    %{owner: owner, member: member, group: group, row: row, process: row.profile}
  end

  defp save!(editor, group, rules) do
    revision =
      case AppData.get_config(group, nil) do
        nil -> 0
        config -> config.lock_version
      end

    {:ok, _config} = AppData.save_config(editor, group, nil, %{"rules" => rules}, revision)
  end

  defp step(ctx, opts \\ []) do
    %ProcessStep{
      process: ctx.row,
      instance: 7,
      element: "Task_1",
      triggered_by: Keyword.get(opts, :triggered_by, ctx.member.id),
      groups: Keyword.get(opts, :groups, [])
    }
  end

  defp subgroup!(ctx, opts \\ [], admins \\ ProcessActions.default_admins()) do
    {:ok, sub, announce} =
      ProcessActions.create_subgroup(step(ctx, opts), ctx.group, %{"name" => "molba"}, admins)

    ProcessActions.announce([announce])
    sub
  end

  defp admin?(profile, group), do: Access.for_profile(profile, group).admin?

  describe "post_value/3" do
    test "posts as the process, keeping where the value comes from", ctx do
      assert {:ok, value, _announce} =
               ProcessActions.post_value(step(ctx), ctx.group, %{"content" => "Primljeno."})

      value = Repo.get!(Value, value.id)
      assert value.creator_id == ctx.process.id
      assert value.content == "Primljeno."

      assert value.managed == %{
               "process" => %{
                 "instance" => 7,
                 "element" => "Task_1",
                 "triggered_by" => ctx.member.id
               }
             }
    end

    test "is heard of only once the step is announced", ctx do
      Social.subscribe_group(ctx.group)

      {:ok, value, announce} =
        ProcessActions.post_value(step(ctx), ctx.group, %{"content" => "Primljeno."})

      value_id = value.id
      refute_received {:value_created, _group_id, _value}

      ProcessActions.announce([announce])
      assert_received {:value_created, _group_id, %Value{id: ^value_id}}
    end

    test "leaves nothing behind when the step rolls back, and nobody hears of it", ctx do
      Social.subscribe_group(ctx.group)

      assert {:error, :failed} =
               Repo.transaction(fn ->
                 {:ok, value, _} =
                   ProcessActions.post_value(step(ctx), ctx.group, %{"content" => "Primljeno."})

                 {:ok, sub, _} =
                   ProcessActions.create_subgroup(step(ctx), ctx.group, %{"name" => "molba"})

                 send(self(), {:written, value.id, sub.id})
                 Repo.rollback(:failed)
               end)

      assert_received {:written, value_id, sub_id}
      refute Repo.get(Value, value_id)
      refute Repo.get(Group, sub_id)
      refute_received {:value_created, _group_id, _value}
      refute_received {:child_group_changed, _group_id, _child}
    end

    test "its values come with the process, for its name where they are shown", ctx do
      {:ok, value, _announce} =
        ProcessActions.post_value(step(ctx), ctx.group, %{"content" => "Primljeno u roku."})

      shown = Social.get_value_for_display(value.id)
      assert Profile.display_name(shown.creator) == "Prijem"
      assert shown.process_trigger.id == ctx.member.id

      {:ok, {[found], false}} = Social.search_group_values(ctx.group, "roku")
      assert Profile.display_name(found.creator) == "Prijem"
    end

    test "takes only the content, its format and the value replied to", ctx do
      {:ok, value, _announce} =
        ProcessActions.post_value(step(ctx), ctx.group, %{
          content: "Primljeno.",
          is_data: true,
          data: %{"x" => 1}
        })

      value = Repo.get!(Value, value.id)
      refute value.is_data
      assert value.data == nil
    end

    test "writes nowhere but in its own groups, open chats included", ctx do
      {:ok, open} =
        Social.create_group(ctx.owner, Social.get_root_group!(), %{
          "name" => "open-#{unique()}",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => true,
          "has_public_chat" => true
        })

      assert {:error, :not_process_group} =
               ProcessActions.post_value(step(ctx), open, %{"content" => "Primljeno."})
    end

    test "may do only what its profile may do in the group", ctx do
      {:ok, _role} =
        Social.set_group_role_permission(
          ctx.owner,
          ctx.group,
          "everyone",
          :post_values,
          :neutral
        )

      assert {:error, :not_permitted} =
               ProcessActions.post_value(step(ctx), ctx.group, %{"content" => "Primljeno."})
    end

    test "does nothing once its rule is gone", ctx do
      save!(ctx.owner, ctx.group, %{})

      assert {:error, :process_inactive} =
               ProcessActions.post_value(step(ctx), ctx.group, %{"content" => "Primljeno."})
    end
  end

  describe "create_subgroup/4" do
    test "makes the process a plain member and the owner and who started the step admins",
         ctx do
      Social.subscribe_group(ctx.group)
      sub = subgroup!(ctx)
      sub_id = sub.id

      assert sub.parent_id == ctx.group.id
      assert sub.creator_id == ctx.process.id
      assert sub.external_key == nil
      assert Social.member_of_group?(ctx.process, sub)
      refute admin?(ctx.process, sub)
      assert admin?(ctx.owner, sub)
      assert admin?(ctx.member, sub)
      assert_received {:child_group_changed, _group_id, %{id: ^sub_id}}
    end

    test "takes no key, nor anything else it does not know", ctx do
      {:ok, sub, _announce} =
        ProcessActions.create_subgroup(step(ctx), ctx.group, %{
          "name" => "molba",
          "external_key" => "proc:1",
          "is_direct" => true
        })

      assert %Group{external_key: nil, is_direct: false} = Repo.get!(Group, sub.id)
    end

    test "an owner who no longer edits the app gives way to who started the step", ctx do
      # Owned by a member who does not edit the app.
      ctx.row |> Ecto.Changeset.change(owner_profile_id: ctx.member.id) |> Repo.update!()

      # A timer started it: nobody is left to run the group.
      assert {:error, :no_admin} =
               ProcessActions.create_subgroup(
                 step(ctx, triggered_by: nil),
                 ctx.group,
                 %{"name" => "molba"},
                 ["owner"]
               )

      sub = subgroup!(ctx, [triggered_by: ctx.owner.id], ["owner"])
      assert admin?(ctx.owner, sub)
      refute Social.member_of_group?(ctx.member, sub)
    end

    test "the people of a role named in the step become admins", ctx do
      {:ok, moderator} = Social.create_group_role(ctx.owner, ctx.group, %{"name" => "moderator"})

      {:ok, _role} =
        Social.assign_group_member_role(ctx.owner, ctx.group, ctx.member.id, moderator.key)

      sub = subgroup!(ctx, [triggered_by: nil], [moderator.key])

      assert admin?(ctx.member, sub)
      refute Social.member_of_group?(ctx.owner, sub)
    end

    test "needs the permission to make sub-groups", ctx do
      {:ok, _role} =
        Social.set_group_role_permission(
          ctx.owner,
          ctx.group,
          "everyone",
          :create_subgroups,
          :neutral
        )

      assert {:error, :not_permitted} =
               ProcessActions.create_subgroup(step(ctx), ctx.group, %{"name" => "molba"})
    end

    test "the process writes in a sub-group of its instance, unread for its members", ctx do
      sub = subgroup!(ctx)

      assert {:error, :not_process_group} =
               ProcessActions.post_value(step(ctx), sub, %{"content" => "Uzeto u rad."})

      {:ok, _value, announce} =
        ProcessActions.post_value(step(ctx, groups: [sub.id]), sub, %{"content" => "Uzeto u rad."})

      ProcessActions.announce([announce])

      assert %{} = counts = Social.list_group_unread_counts(ctx.member, [sub])
      assert counts[sub.id] == 1
    end
  end
end
