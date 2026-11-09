defmodule PotokIdeWeb.GroupLive.PollFormTest do
  @moduledoc """
  The dialog of a poll: from the composer, and what it holds for a poll with votes.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures
  import PotokIde.PollsFixtures

  alias PotokIde.Polls
  alias PotokIde.Polls.Poll
  alias PotokIde.Repo
  alias PotokIde.Social

  @zone "Europe/Belgrade"

  setup do
    {owner_account, owner} = account_with_profile!("pf-owner")
    {member_account, member} = account_with_profile!("pf-member")
    group = group_with_members!(owner, [member])

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      group: group
    }
  end

  defp chat(account, group) do
    {:ok, lv, _html} =
      build_conn()
      |> log_in_account(account)
      |> put_connect_params(%{"time_zone" => @zone})
      |> live(~p"/groups/#{group.id}/values")

    lv
  end

  defp open_form(lv) do
    lv |> element("#group-value-poll") |> render_click()
    assert has_element?(lv, "#poll-form-dialog")
    lv
  end

  defp submit(lv, attrs) do
    lv |> form("#poll-form", poll: attrs) |> render_submit()
  end

  defp filled(attrs \\ %{}) do
    Map.merge(
      %{
        question: "Where to?",
        options: %{"0" => %{text: "Sea"}, "1" => %{text: "Hills"}}
      },
      attrs
    )
  end

  test "opens from the composer with two empty answers", ctx do
    lv = ctx.member_account |> chat(ctx.group) |> open_form()

    assert has_element?(lv, "input[name='poll[options][0][text]']")
    assert has_element?(lv, "input[name='poll[options][1][text]']")
    refute has_element?(lv, "input[name='poll[options][2][text]']")
  end

  test "starts a poll that shows in the chat", ctx do
    lv = ctx.member_account |> chat(ctx.group) |> open_form()

    submit(lv, filled())

    refute has_element?(lv, "#poll-form-dialog")
    assert [poll] = Repo.all(Poll)
    assert poll.creator_id == ctx.member.id
    assert has_element?(lv, "#value-poll-card-#{poll.value_id}", "Where to?")
  end

  test "shows what is wrong and stays open", ctx do
    lv = ctx.member_account |> chat(ctx.group) |> open_form()

    html = submit(lv, %{question: "", options: %{"0" => %{text: "Sea"}, "1" => %{text: "sea"}}})

    assert html =~ "has the same answer twice"
    assert has_element?(lv, "#poll-form-dialog")
    assert Repo.all(Poll) == []
  end

  test "the quick answers fill the rows", ctx do
    lv = ctx.member_account |> chat(ctx.group) |> open_form()

    lv |> element("#poll-form-for-against") |> render_click()

    assert has_element?(lv, "input[name='poll[options][0][text]'][value='For']")
    assert has_element?(lv, "input[name='poll[options][2][text]'][value='Abstain']")
  end

  test "a deadline button fills the field, and another clears it", ctx do
    lv = ctx.member_account |> chat(ctx.group) |> open_form()

    lv |> element("#poll-form-deadline-24") |> render_click()
    assert lv |> element("input[name='poll[closes_local]']") |> render() =~ ~s(value=")

    lv |> element("#poll-form-deadline-none") |> render_click()
    refute lv |> element("input[name='poll[closes_local]']") |> render() =~ ~r/value="\d/
  end

  test "a crafted button changes nothing", ctx do
    lv = ctx.member_account |> chat(ctx.group) |> open_form()

    render_click(lv, "poll_form_deadline", %{"hours" => "soon"})
    render_click(lv, "poll_form_answers", %{"set" => "other"})

    assert has_element?(lv, "#poll-form-dialog")
  end

  test "keeps what was typed when a deadline is picked", ctx do
    lv = ctx.member_account |> chat(ctx.group) |> open_form()

    lv |> form("#poll-form", poll: filled()) |> render_change()
    lv |> element("#poll-form-deadline-1") |> render_click()

    assert has_element?(lv, "input[name='poll[question]'][value='Where to?']")
  end

  test "a secret poll leaves out what it cannot do", ctx do
    lv = ctx.member_account |> chat(ctx.group) |> open_form()

    assert has_element?(lv, "input[name='poll[allow_change]']")

    lv |> form("#poll-form", poll: filled(%{secret: "true"})) |> render_change()

    refute has_element?(lv, "input[type=checkbox][name='poll[allow_change]']")
    refute has_element?(lv, "input[type=checkbox][name='poll[allow_member_options]']")
    refute has_element?(lv, "select[name='poll[results_when]']")
  end

  test "several answers leave out the decision", ctx do
    lv = ctx.member_account |> chat(ctx.group) |> open_form()

    assert has_element?(lv, "#poll-form-decision")

    lv |> form("#poll-form", poll: filled(%{kind: "multiple"})) |> render_change()

    refute has_element?(lv, "#poll-form-decision")
    assert has_element?(lv, "input[name='poll[max_choices]']")
  end

  test "only `publish_polls` offers a public poll", ctx do
    public = group_with_members!(ctx.owner, [ctx.member], %{"is_public" => true})

    member_form = ctx.member_account |> chat(public) |> open_form()
    refute has_element?(member_form, "#poll-form-public")

    owner_form = ctx.owner_account |> chat(public) |> open_form()
    assert has_element?(owner_form, "#poll-form-public")

    closed_form = ctx.owner_account |> chat(ctx.group) |> open_form()
    refute has_element?(closed_form, "#poll-form-public")
  end

  test "the composer offers it only with the rights to post it", ctx do
    {:ok, _manifest} = Social.create_own_group_manifest(ctx.owner, ctx.group)

    {:ok, _role} =
      Social.set_group_role_permission(ctx.owner, ctx.group, "everyone", :create_polls, :neutral)

    lv = chat(ctx.member_account, ctx.group)
    refute has_element?(lv, "#group-value-poll")

    assert has_element?(chat(ctx.owner_account, ctx.group), "#group-value-poll")
  end

  test "a direct conversation has no polls", ctx do
    {:ok, direct} = Social.get_or_create_direct_group(ctx.owner, ctx.member)
    lv = chat(ctx.owner_account, direct)

    # The "+" stays, with files as its only choice.
    assert has_element?(lv, "#group-value-add-toggle")
    assert has_element?(lv, "#group-value-add-menu #group-value-attach")
    refute has_element?(lv, "#group-value-poll")
  end

  describe "changing a poll" do
    test "before the first vote holds everything", ctx do
      poll = create_poll!(ctx.owner, ctx.group)

      {:ok, lv, _html} =
        build_conn()
        |> log_in_account(ctx.owner_account)
        |> put_connect_params(%{"time_zone" => @zone})
        |> live(~p"/groups/#{ctx.group.id}/polls?#{[poll: poll.id]}")

      lv |> element("#poll-edit") |> render_click()

      assert has_element?(lv, "input[name='poll[question]'][value='Where do we go?']")
      assert has_element?(lv, "input[name='poll[options][0][text]'][value='Sea']")

      lv |> form("#poll-form", poll: %{question: "New question?"}) |> render_submit()

      assert %{question: "New question?"} = Polls.get_poll(poll.id)
    end

    test "after it holds only the deadline", ctx do
      poll = create_poll!(ctx.owner, ctx.group)
      vote!(ctx.member, ctx.member_account, poll, 0)

      {:ok, lv, _html} =
        build_conn()
        |> log_in_account(ctx.owner_account)
        |> put_connect_params(%{"time_zone" => @zone})
        |> live(~p"/groups/#{ctx.group.id}/polls?#{[poll: poll.id]}")

      lv |> element("#poll-edit") |> render_click()

      assert has_element?(lv, "#poll-form-frozen")
      refute has_element?(lv, "input[name='poll[question]']")
      refute has_element?(lv, "#poll-form-more")

      lv |> form("#poll-form", poll: %{closes_local: local_in(24)}) |> render_submit()

      assert %{closes_at: %DateTime{}} = Polls.get_poll(poll.id)
    end
  end
end
