defmodule PotokIdeWeb.GroupLive.JoinRuleSettingsTest do
  @moduledoc """
  How a request to join is decided, in the group's settings.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Social

  setup do
    {owner_account, owner} = account_with_profile!("jr-owner")
    {member_account, member} = account_with_profile!("jr-member")
    group = group_with_members!(owner, [member], %{"is_public" => true})

    %{owner: owner, owner_account: owner_account, member_account: member_account, group: group}
  end

  defp edit(account, group) do
    {:ok, view, _html} =
      build_conn()
      |> log_in_account(account)
      |> live(~p"/groups/#{group.id}/edit_group")

    view
  end

  test "an admin lets every request to join go to a vote", ctx do
    view = edit(ctx.owner_account, ctx.group)

    assert has_element?(
             view,
             "#group-join-rule-fields-mode-vote input[form=group-join-rule-form]"
           )

    view
    |> element("#group-join-rule-form")
    |> render_submit(%{
      rule: %{
        mode: "vote",
        poll: %{
          quorum_percent: "50",
          majority: "simple",
          hours: "72",
          unique_votes: "yes",
          shared_votes: "as_one"
        }
      }
    })

    group = Social.get_group!(ctx.group.id)
    assert group.join_mode == :vote
    assert group.join_poll.hours == 72
  end

  test "a private group has no rule of admission, as nobody asks to join it", ctx do
    {:ok, private} =
      Social.update_group(ctx.owner, ctx.group, %{"is_public" => false})

    view = edit(ctx.owner_account, private)

    refute has_element?(view, "#group-edit-join-rule")
  end
end
