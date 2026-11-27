defmodule PotokIde.Social.ValueReportsTest do
  @moduledoc """
  Messages reported to the admins of their group: who may report what, whose
  hand counts it, and what dismissing a report or deleting its message does.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Accounts.Deletion
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, Value, ValueReport, ValueReports}

  setup do
    {_account, admin} = account_with_profile!("vr-admin")
    {_account, author} = account_with_profile!("vr-author")
    {reporter_account, reporter} = account_with_profile!("vr-reporter")
    group = group_with_members!(admin, [author, reporter])
    {:ok, value} = say(author, group, "ružna poruka")

    %{
      admin: admin,
      author: author,
      reporter: reporter,
      reporter_account: reporter_account,
      group: group,
      value: value
    }
  end

  defp say(profile, group, text),
    do: Social.create_value(profile, group, %{"content" => text, "content_format" => "markdown"})

  defp report(profile, value, reason \\ "abuse"),
    do: ValueReports.report(profile, value, %{"reason" => reason, "note" => " vređa "})

  test "a member reports someone else's message to the group's admins", ctx do
    assert {:ok, report} = report(ctx.reporter, ctx.value)
    assert report.group_id == ctx.group.id
    assert report.reason == :abuse
    assert report.note == "vređa"

    assert ValueReports.open_count(ctx.admin) == 1
    assert ValueReports.open_count(ctx.author) == 0
    assert ValueReports.open_count(ctx.reporter) == 0

    assert [%{group: %{id: group_id}, reports: [listed]}] = ValueReports.list_open(ctx.admin)
    assert group_id == ctx.group.id
    assert listed.value.creator.id == ctx.author.id
    assert listed.reporter.id == ctx.reporter.id

    assert ValueReports.reported?(ctx.reporter, ctx.value.id)
    assert Social.nav_counts(ctx.admin).pending_group_join_requests == 1
  end

  test "the same message is reported once by each profile", ctx do
    assert {:ok, _report} = report(ctx.reporter, ctx.value)
    assert {:error, :already_reported} = report(ctx.reporter, ctx.value, "spam")
    assert {:ok, _report} = report(ctx.admin, ctx.value, "spam")
    assert ValueReports.open_count(ctx.admin) == 2
  end

  test "nobody reports their own message, an unknown reason or a direct conversation", ctx do
    assert {:error, :not_permitted} = report(ctx.author, ctx.value)
    assert {:error, %Ecto.Changeset{}} = report(ctx.reporter, ctx.value, "boring")

    {:ok, direct} = Social.get_or_create_direct_group(ctx.author, ctx.reporter)
    {:ok, private} = say(ctx.author, direct, "samo nama")
    assert {:error, :not_permitted} = report(ctx.reporter, private)
  end

  test "an outsider of a closed group does not report its messages", ctx do
    {_account, stranger} = account_with_profile!("vr-stranger")
    assert {:error, :not_permitted} = report(stranger, ctx.value)
  end

  test "an admin dismisses a report and the message stays; others may not", ctx do
    {:ok, report} = report(ctx.reporter, ctx.value)

    assert {:error, :not_permitted} = ValueReports.dismiss(ctx.reporter, report.id)
    assert :ok = ValueReports.dismiss(ctx.admin, report.id)

    assert ValueReports.open_count(ctx.admin) == 0
    assert Repo.get(Value, ctx.value.id)
    assert Repo.get!(ValueReport, report.id).dismissed_by_id == ctx.admin.id

    # Dismissed, it counts as reported: the same profile does not report it again.
    assert {:error, :already_reported} = report(ctx.reporter, ctx.value)
    assert {:error, :not_found} = ValueReports.dismiss(ctx.admin, report.id)
  end

  test "an admin deletes the reported message, which takes its reports along", ctx do
    {:ok, report} = report(ctx.reporter, ctx.value)

    assert {:error, :not_permitted} = ValueReports.delete_value(ctx.author, report.id)
    assert :ok = ValueReports.delete_value(ctx.admin, report.id)

    refute Repo.get(Value, ctx.value.id)
    refute Repo.get(ValueReport, report.id)
    assert ValueReports.open_count(ctx.admin) == 0
  end

  test "a message deleted by its author takes its reports along too", ctx do
    {:ok, _report} = report(ctx.reporter, ctx.value)
    {:ok, _deleted} = Social.delete_value(ctx.author, ctx.value)
    assert ValueReports.open_count(ctx.admin) == 0
  end

  test "a report from a thread goes to the admins of its group, who may delete it there", ctx do
    {:ok, thread} =
      Social.get_or_create_value_thread(ctx.author, ctx.group, ctx.value, %{"name" => "nit"})

    :ok = Social.join_thread(ctx.reporter, thread)
    {:ok, in_thread} = say(ctx.author, thread, "u niti")

    # The group's admin holds no role in the thread.
    refute Access.admin?(ctx.admin, thread)

    {:ok, report} = report(ctx.reporter, in_thread)
    assert report.group_id == ctx.group.id
    assert ValueReports.open_count(ctx.admin) == 1
    assert ValueReports.open_count(ctx.author) == 0

    assert :ok = ValueReports.delete_value(ctx.admin, report.id)
    refute Repo.get(Value, in_thread.id)
  end

  test "a group without an admin sends its reports up to the nearest one that has", ctx do
    sub = group_with_members!(ctx.admin, [ctx.author, ctx.reporter], %{parent: ctx.group})
    {:ok, value} = say(ctx.author, sub, "dole")

    Repo.delete_all(
      from(r in PotokIde.Social.GroupMemberRole,
        where: r.group_id == ^sub.id and r.role_key == "admin"
      )
    )

    Access.forget([sub.id])

    {:ok, report} = report(ctx.reporter, value)
    assert report.group_id == ctx.group.id
  end

  test "a deleted account takes its reports along", ctx do
    {:ok, _report} = report(ctx.reporter, ctx.value)
    {:ok, _deleted} = Deletion.delete(ctx.reporter_account)
    assert ValueReports.open_count(ctx.admin) == 0
  end
end
