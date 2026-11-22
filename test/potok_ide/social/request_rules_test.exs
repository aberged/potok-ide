defmodule PotokIde.Social.RequestRulesTest do
  @moduledoc """
  How a role is had and how a request to join is decided, as the statute
  and the group write them down before anyone asks.
  """

  use PotokIde.DataCase

  import PotokIde.EventsFixtures

  alias PotokIde.Social
  alias PotokIde.Social.{Access, Group, GroupRole, RequestPoll}

  setup do
    {_owner_account, owner} =
      account_with_profile!("rr-owner#{System.unique_integer([:positive])}")

    {_member_account, member} =
      account_with_profile!("rr-member#{System.unique_integer([:positive])}")

    group = group_with_members!(owner, [member], %{"is_public" => true})
    {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
    {:ok, role} = Social.create_group_role(owner, group, %{"name" => "blagajnik"})

    %{owner: owner, member: member, group: group, role: role}
  end

  defp role(group, key), do: Enum.find(Access.effective_manifest(group).roles, &(&1.key == key))

  @vote %{
    "request_mode" => "vote",
    "request_poll" => %{
      "quorum_percent" => "60",
      "majority" => "two_thirds",
      "hours" => "168",
      "unique_votes" => "yes",
      "shared_votes" => "each_holder"
    }
  }

  describe "set_role_request_rule/4" do
    test "a role starts closed", %{group: group, role: role} do
      assert %GroupRole{request_mode: :closed, request_poll: nil} = role(group, role.key)
    end

    test "an admin writes how a role is had, with the rules of its vote", ctx do
      assert {:ok, _role} =
               Social.set_role_request_rule(ctx.owner, ctx.group, ctx.role.key, @vote)

      assert %GroupRole{
               request_mode: :vote,
               request_poll: %RequestPoll{
                 quorum_percent: 60,
                 majority: :two_thirds,
                 hours: 168,
                 unique_votes: :yes,
                 shared_votes: :each_holder
               }
             } = role(ctx.group, ctx.role.key)
    end

    test "a mode that does not vote keeps no rules of a vote", ctx do
      {:ok, _role} = Social.set_role_request_rule(ctx.owner, ctx.group, ctx.role.key, @vote)

      {:ok, _role} =
        Social.set_role_request_rule(ctx.owner, ctx.group, ctx.role.key, %{
          "request_mode" => "approve",
          "request_poll" => @vote["request_poll"]
        })

      assert %GroupRole{request_mode: :approve, request_poll: nil} = role(ctx.group, ctx.role.key)
    end

    test "a vote's rules are checked", ctx do
      bad = put_in(@vote, ["request_poll", "quorum_percent"], "0")

      assert {:error, changeset} =
               Social.set_role_request_rule(ctx.owner, ctx.group, ctx.role.key, bad)

      assert %{request_poll: %{quorum_percent: [_]}} = errors_on(changeset)

      nobody =
        @vote
        |> put_in(["request_poll", "unique_votes"], "no")
        |> put_in(["request_poll", "shared_votes"], "no")

      assert {:error, changeset} =
               Social.set_role_request_rule(ctx.owner, ctx.group, ctx.role.key, nobody)

      assert %{request_poll: %{shared_votes: ["somebody has to vote"]}} = errors_on(changeset)
    end

    test "everyone is never asked for", ctx do
      assert {:error, changeset} =
               Social.set_role_request_rule(ctx.owner, ctx.group, "everyone", %{
                 "request_mode" => "approve"
               })

      assert %{request_mode: ["is held by every member"]} = errors_on(changeset)
    end

    test "only an admin, in the group that holds the statute", ctx do
      assert {:error, :not_permitted} =
               Social.set_role_request_rule(ctx.member, ctx.group, ctx.role.key, @vote)

      {:ok, child} =
        Social.create_group(ctx.owner, ctx.group, %{
          "name" => "rr-child",
          "description" => "",
          "description_format" => :markdown
        })

      assert {:error, :manifest_is_inherited} =
               Social.set_role_request_rule(ctx.owner, child, ctx.role.key, @vote)
    end

    test "a group that elects its admins has Admin only by a vote", ctx do
      {:ok, group} = Social.set_elects_admins(ctx.owner, ctx.group, true)

      assert {:error, :elected_role} =
               Social.set_role_request_rule(ctx.owner, group, "admin", %{
                 "request_mode" => "approve"
               })

      assert {:ok, %GroupRole{request_mode: :vote}} =
               Social.set_role_request_rule(ctx.owner, group, "admin", @vote)
    end

    test "a copy of the statute keeps how its roles are had", ctx do
      {:ok, _role} = Social.set_role_request_rule(ctx.owner, ctx.group, ctx.role.key, @vote)

      {:ok, child} =
        Social.create_group(ctx.owner, ctx.group, %{
          "name" => "rr-copy",
          "description" => "",
          "description_format" => :markdown
        })

      assert %GroupRole{request_mode: :vote} = role(child, ctx.role.key)

      {:ok, _manifest} = Social.create_own_group_manifest(ctx.owner, child)

      assert %GroupRole{
               request_mode: :vote,
               request_poll: %RequestPoll{shared_votes: :each_holder}
             } =
               role(child, ctx.role.key)

      assert Access.effective_manifest(child).group_id == child.id
    end
  end

  describe "set_join_rule/3" do
    test "a group admits by a decision of whoever manages requests unless told otherwise", ctx do
      assert %Group{join_mode: :approve, join_poll: nil} = ctx.group
    end

    test "an admin lets every request to join go to a vote", ctx do
      assert {:ok, %Group{join_mode: :vote, join_poll: %RequestPoll{quorum_percent: 60}}} =
               Social.set_join_rule(ctx.owner, ctx.group, %{
                 "join_mode" => "vote",
                 "join_poll" => @vote["request_poll"]
               })

      assert %Group{join_mode: :vote} = Social.get_group!(ctx.group.id)

      assert {:ok, %Group{join_mode: :approve, join_poll: nil}} =
               Social.set_join_rule(ctx.owner, Social.get_group!(ctx.group.id), %{
                 "join_mode" => "approve"
               })
    end

    test "only an admin, and not at the root", ctx do
      assert {:error, :not_permitted} =
               Social.set_join_rule(ctx.member, ctx.group, %{"join_mode" => "choose"})

      assert {:error, :not_allowed} =
               Social.set_join_rule(ctx.owner, Social.get_root_group!(), %{
                 "join_mode" => "choose"
               })
    end
  end
end
