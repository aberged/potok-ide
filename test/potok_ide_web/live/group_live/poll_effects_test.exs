defmodule PotokIdeWeb.GroupLive.PollEffectsTest do
  @moduledoc """
  A decision that changes roles on the page: the form asks what it changes,
  the card says so before anyone votes, and a group that elects its admins
  shows it on the members and on its settings.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures
  import PotokIde.PollsFixtures

  alias PotokIde.Polls
  alias PotokIde.Polls.{Deadlines, Poll}
  alias PotokIde.Repo
  alias PotokIde.Social

  @zone "Europe/Belgrade"

  setup do
    {owner_account, owner} = account_with_profile!("pe-owner")
    {member_account, member} = account_with_profile!("pe-member")
    {third_account, third} = account_with_profile!("pe-third")
    group = group_with_members!(owner, [member, third])

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      third_account: third_account,
      third: third,
      group: group
    }
  end

  defp page(account, path) do
    {:ok, lv, _html} =
      build_conn()
      |> log_in_account(account)
      |> put_connect_params(%{"time_zone" => @zone})
      |> live(path)

    lv
  end

  defp open_form(lv) do
    lv |> element("#group-value-poll") |> render_click()
    assert has_element?(lv, "#poll-form-dialog")
    lv
  end

  defp change(lv, attrs), do: lv |> form("#poll-form", poll: attrs) |> render_change()

  test "an admin names a member and a role, and the card says what it changes", ctx do
    lv = page(ctx.owner_account, ~p"/groups/#{ctx.group.id}/values") |> open_form()

    assert has_element?(lv, "#poll-form-effect")
    assert has_element?(lv, "#poll-form-options")

    change(lv, %{question: "Ana for admin?", effect: "grant"})

    refute has_element?(lv, "#poll-form-options")
    assert has_element?(lv, "#poll-form-effect-answers")
    refute has_element?(lv, "#poll-form-deadline-none")

    change(lv, %{effect: "grant", effect_role_key: "admin", effect_query: "pe-mem"})
    lv |> element("#poll-form-effect-suggest-#{ctx.member.id}") |> render_click()
    assert has_element?(lv, "#poll-form-effect-picked-#{ctx.member.id}")

    lv
    |> form("#poll-form",
      poll: %{question: "Ana for admin?", effect: "grant", effect_role_key: "admin"}
    )
    |> render_submit()

    refute has_element?(lv, "#poll-form-dialog")
    assert [poll] = Repo.all(Poll)
    assert poll.effect == :grant
    assert poll.effect_profile_id == ctx.member.id
    assert poll.majority == :simple
    assert poll.quorum_percent == 50
    assert poll.closes_at

    assert has_element?(lv, "#value-poll-card-#{poll.value_id}-effect", "pe-member")
  end

  test "a member of a group of its founders is not asked what a decision changes", ctx do
    lv = page(ctx.member_account, ~p"/groups/#{ctx.group.id}/values") |> open_form()

    refute has_element?(lv, "#poll-form-effect")
    assert has_element?(lv, "#poll-form-options")
  end

  test "the card tells what came of a decision", ctx do
    poll =
      create_poll!(
        ctx.owner,
        ctx.group,
        %{
          "question" => "Member for admin?",
          "effect" => "grant",
          "effect_role_key" => "admin",
          "effect_profile_id" => Integer.to_string(ctx.member.id),
          "majority" => "simple",
          "quorum_percent" => "50",
          "closes_local" => local_in(1)
        },
        announce: true
      )

    vote!(ctx.owner, ctx.owner_account, poll, 0)
    vote!(ctx.member, ctx.member_account, poll, 0)

    Repo.update_all(from(p in Poll, where: p.id == ^poll.id),
      set: [closes_at: DateTime.add(DateTime.utc_now(:second), -5, :second)]
    )

    Deadlines.close_due(DateTime.utc_now(:second))

    lv =
      page(ctx.owner_account, ~p"/groups/#{ctx.group.id}/polls?#{[poll: poll.id]}")

    assert has_element?(lv, "[id$='-effect-status']")
    refute has_element?(lv, "#poll-close")
    refute has_element?(lv, "#poll-reopen")
    refute has_element?(lv, "#poll-delete")

    members = page(ctx.owner_account, ~p"/groups/#{ctx.group.id}/members")
    assert has_element?(members, "#member-#{ctx.member.id}-role-decided-admin")
  end

  describe "a group that elects its admins" do
    setup ctx do
      {:ok, group} = Social.set_elects_admins(ctx.owner, ctx.group, true)
      %{group: group}
    end

    test "shows its admins for now, and keeps Admin out of hands", ctx do
      lv = page(ctx.owner_account, ~p"/groups/#{ctx.group.id}/members")

      assert has_element?(lv, "#group-members-elected")
      assert has_element?(lv, "#member-#{ctx.owner.id}-role-interim-admin")
      assert has_element?(lv, "#member-#{ctx.member.id}-role-admin[disabled]")
    end

    test "any member calls an election, and members stand in it", ctx do
      lv = page(ctx.member_account, ~p"/groups/#{ctx.group.id}/members")

      lv |> element("#group-members-call-election") |> render_click()
      assert has_element?(lv, "#poll-form-effect-candidates")

      for person <- [ctx.member, ctx.third] do
        change(lv, %{effect: "elect", effect_query: person.username})
        lv |> element("#poll-form-effect-suggest-#{person.id}") |> render_click()
      end

      lv |> form("#poll-form", poll: %{effect: "elect"}) |> render_submit()

      assert [poll] = Repo.all(Poll)
      assert poll.effect == :elect
      assert poll.effect_replace
      assert poll.allow_member_options
      assert poll.majority == :plurality

      chat = page(ctx.owner_account, ~p"/groups/#{ctx.group.id}/values")
      card = "#value-poll-card-#{poll.value_id}"
      assert has_element?(chat, "#{card}-effect")
      chat |> element("#{card}-stand") |> render_submit()

      assert Enum.any?(Polls.get_poll(poll.id).options, &(&1.profile_id == ctx.owner.id))
    end

    test "says so on its settings, where it is ended only by a decision", ctx do
      lv = page(ctx.member_account, ~p"/groups/#{ctx.group.id}/members")

      refute has_element?(lv, "#group-edit-elections-on")

      settings =
        page(ctx.owner_account, ~p"/groups/#{ctx.group.id}/edit_group?#{[section: "access"]}")

      assert has_element?(settings, "#group-edit-elections-on-badge")
      refute has_element?(settings, "#group-edit-elections-on")
      settings |> element("#group-edit-elections-end") |> render_click()
      assert has_element?(settings, "#poll-form-effect-answers")
    end
  end

  test "an admin lets the group elect its admins", ctx do
    lv =
      page(ctx.owner_account, ~p"/groups/#{ctx.group.id}/edit_group?#{[section: "access"]}")

    lv |> element("#group-edit-elections-on") |> render_click()
    assert Social.elects_admins?(ctx.group)
  end
end
