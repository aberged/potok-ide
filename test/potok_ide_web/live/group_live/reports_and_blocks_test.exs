defmodule PotokIdeWeb.GroupLive.ReportsAndBlocksTest do
  @moduledoc """
  Reporting a message to the group's admins from its menu, handling the
  report under Requests, and a block that closes a direct conversation from
  the profile's card or from the conversation itself.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{ProfileBlocks, Value, ValueReport, ValueReports}

  defp unique(name), do: "#{name}#{System.unique_integer([:positive])}"

  defp live_as(conn, account, path) do
    conn
    |> log_in_account(Accounts.get_account!(account.id))
    |> live(path)
  end

  defp say(profile, group, text) do
    {:ok, value} =
      Social.create_value(profile, group, %{"content" => text, "content_format" => "markdown"})

    value
  end

  setup do
    {admin_account, admin} = account_with_profile!(unique("admin"))
    {author_account, author} = account_with_profile!(unique("autor"))
    {reporter_account, reporter} = account_with_profile!(unique("prijava"))
    group = group_with_members!(admin, [author, reporter])

    %{
      admin: admin,
      admin_account: admin_account,
      author: author,
      author_account: author_account,
      reporter: reporter,
      reporter_account: reporter_account,
      group: group
    }
  end

  describe "reporting a message" do
    test "is offered on others' messages and sends the report to the admins",
         %{conn: conn} = ctx do
      theirs = say(ctx.author, ctx.group, "ružno")
      mine = say(ctx.reporter, ctx.group, "moje")

      {:ok, lv, _html} = live_as(conn, ctx.reporter_account, ~p"/groups/#{ctx.group.id}/values")

      assert has_element?(lv, "#value-report-#{theirs.id}")
      refute has_element?(lv, "#value-report-#{mine.id}")

      lv |> element("#value-report-#{theirs.id}") |> render_click()
      assert has_element?(lv, "#report-value-dialog #report-value-quote", "ružno")

      lv
      |> form("#report-value-form", report: %{reason: "spam", note: "reklama"})
      |> render_submit()

      refute has_element?(lv, "#report-value-dialog")
      assert [%ValueReport{reason: :spam, note: "reklama"}] = Repo.all(ValueReport)

      # A second try only says it is with the admins already.
      lv |> element("#value-report-#{theirs.id}") |> render_click()
      refute has_element?(lv, "#report-value-dialog")
    end

    test "is not offered in a direct conversation, where a block is", %{conn: conn} = ctx do
      {:ok, direct} = Social.get_or_create_direct_group(ctx.author, ctx.reporter)
      value = say(ctx.author, direct, "samo nama")

      {:ok, lv, _html} = live_as(conn, ctx.reporter_account, ~p"/groups/#{direct.id}/values")

      refute has_element?(lv, "#value-report-#{value.id}")
      assert has_element?(lv, "#value-block-profile-#{value.id}")
    end
  end

  describe "the reports under Requests" do
    setup ctx do
      value = say(ctx.author, ctx.group, "ružno")
      {:ok, report} = ValueReports.report(ctx.reporter, value, %{"reason" => "abuse"})
      %{value: value, report: report}
    end

    test "an admin sees them on their own tab and dismisses one", %{conn: conn} = ctx do
      {:ok, lv, _html} = live_as(conn, ctx.admin_account, ~p"/requests")

      # Nothing else waits, so the page opens on the reports.
      assert has_element?(lv, "#requests-tab-reports")
      assert has_element?(lv, "#report-#{ctx.report.id}", "ružno")
      assert has_element?(lv, "#report-#{ctx.report.id}", ctx.reporter.username)

      lv |> element("#report-#{ctx.report.id}-dismiss") |> render_click()

      refute has_element?(lv, "#report-#{ctx.report.id}")
      assert has_element?(lv, "#requests-reports-empty")
      assert Repo.get(Value, ctx.value.id)
    end

    test "an admin deletes the reported message", %{conn: conn} = ctx do
      {:ok, lv, _html} = live_as(conn, ctx.admin_account, ~p"/requests?section=reports")

      lv |> element("#report-#{ctx.report.id}-delete") |> render_click()

      refute has_element?(lv, "#report-#{ctx.report.id}")
      refute Repo.get(Value, ctx.value.id)
    end

    test "someone who is no admin has no reports tab", %{conn: conn} = ctx do
      {:ok, lv, _html} = live_as(conn, ctx.author_account, ~p"/requests")
      refute has_element?(lv, "#requests-tab-reports")
    end
  end

  describe "a block" do
    test "from the card closes the direct conversation, and lifts from it", %{conn: conn} = ctx do
      {:ok, direct} = Social.get_or_create_direct_group(ctx.author, ctx.reporter)
      say(ctx.author, direct, "zdravo")

      {:ok, card, _html} =
        live_as(conn, ctx.reporter_account, ~p"/u/#{ctx.author.username}")

      card |> element("#profile-card-block") |> render_click()
      assert has_element?(card, "#profile-card-unblock")
      assert has_element?(card, "#profile-card-blocked-note")
      assert ProfileBlocks.blocked?(ctx.reporter.id, ctx.author.id)

      # Both see a closed conversation; only the one who blocked may lift it.
      {:ok, blocker, _html} =
        live_as(build_conn(), ctx.reporter_account, ~p"/groups/#{direct.id}/values")

      {:ok, blocked, _html} =
        live_as(build_conn(), ctx.author_account, ~p"/groups/#{direct.id}/values")

      for lv <- [blocker, blocked] do
        refute has_element?(lv, "#group-value-form")
        assert has_element?(lv, "#group-value-composer-disabled")
      end

      assert has_element?(blocker, "#direct-unblock")
      refute has_element?(blocked, "#direct-unblock")

      blocker |> element("#direct-unblock") |> render_click()

      for lv <- [blocker, blocked] do
        render(lv)
        _ = :sys.get_state(lv.pid)
        assert has_element?(lv, "#group-value-form")
      end
    end

    test "from a message of the conversation closes it at once", %{conn: conn} = ctx do
      {:ok, direct} = Social.get_or_create_direct_group(ctx.author, ctx.reporter)
      value = say(ctx.author, direct, "zdravo")

      {:ok, lv, _html} = live_as(conn, ctx.reporter_account, ~p"/groups/#{direct.id}/values")
      lv |> element("#value-block-profile-#{value.id}") |> render_click()

      render(lv)
      _ = :sys.get_state(lv.pid)
      refute has_element?(lv, "#group-value-form")
      assert has_element?(lv, "#direct-unblock")
    end

    test "leaves the card without a button to write while no conversation exists",
         %{conn: conn} = ctx do
      :ok = ProfileBlocks.block(ctx.author, ctx.reporter)

      {:ok, card, _html} =
        live_as(conn, ctx.reporter_account, ~p"/u/#{ctx.author.username}")

      refute has_element?(card, "#profile-card-message")
      assert has_element?(card, "#profile-card-block")
    end
  end
end
