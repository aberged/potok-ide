defmodule PotokIdeWeb.GroupLive.AppValuesTest do
  @moduledoc """
  Who gets the new values of an app live: the same people who can list them.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social

  setup do
    {owner_account, owner} = account_with_profile!("app-values-own")
    {visitor_account, visitor} = account_with_profile!("app-values-vis")

    {:ok, group} =
      Social.create_group(owner, Social.get_root_group!(), %{
        "name" => "app-values-group",
        "description" => "<p>app</p>",
        "description_format" => :html,
        "is_public" => true,
        "has_public_chat" => false,
        "uses_api" => true
      })

    %{
      owner_account: owner_account,
      owner: owner,
      visitor_account: visitor_account,
      visitor: visitor,
      group: group
    }
  end

  defp open_app(conn, account, group) do
    {:ok, view, _html} =
      conn |> log_in_account(account) |> live(~p"/groups/#{group.id}/group_home")

    view
  end

  defp save_value(profile, group) do
    {:ok, _value} =
      Social.create_data_value(profile, group, %{
        "content" => "data:",
        "data" => %{"score" => 10},
        "is_data" => true
      })
  end

  test "a member with the app open gets each new value", ctx do
    view = open_app(ctx.conn, ctx.owner_account, ctx.group)

    save_value(ctx.owner, ctx.group)

    assert_push_event view, "new_data_value", %{data: %{"score" => 10}}
  end

  test "a non-member of a public group gets none", ctx do
    refute Social.get_group_access(ctx.visitor, ctx.group).member?

    member = open_app(ctx.conn, ctx.owner_account, ctx.group)
    visitor = open_app(ctx.conn, ctx.visitor_account, ctx.group)

    save_value(ctx.owner, ctx.group)

    # The value went out, and the visitor's page has dealt with it.
    assert_push_event member, "new_data_value", %{data: %{"score" => 10}}
    render(visitor)

    refute_push_event visitor, "new_data_value", %{}
  end

  test "a visitor who joins gets them from then on", ctx do
    visitor = open_app(ctx.conn, ctx.visitor_account, ctx.group)

    {:ok, invitation} = Social.invite_profile_to_group(ctx.owner, ctx.group, ctx.visitor)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, ctx.visitor)
    render(visitor)

    save_value(ctx.owner, ctx.group)

    assert_push_event visitor, "new_data_value", %{data: %{"score" => 10}}
  end

  test "a member who is removed stops getting them", ctx do
    {:ok, invitation} = Social.invite_profile_to_group(ctx.owner, ctx.group, ctx.visitor)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, ctx.visitor)

    member = open_app(ctx.conn, ctx.owner_account, ctx.group)
    removed = open_app(ctx.conn, ctx.visitor_account, ctx.group)

    {:ok, _membership} = Social.remove_group_member(ctx.owner, ctx.group, ctx.visitor)
    render(removed)

    save_value(ctx.owner, ctx.group)

    assert_push_event member, "new_data_value", %{data: %{"score" => 10}}
    render(removed)

    refute_push_event removed, "new_data_value", %{}
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

    {Accounts.get_account!(account.id), profile}
  end
end
