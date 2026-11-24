defmodule PotokIdeWeb.GroupLive.HistoryTabTest do
  @moduledoc """
  The history on a group's page: what members read of it, narrowed and paged;
  what a change was; emptying old versions; and nothing for anyone else.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Ecto.Query
  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures
  import PotokIde.PollsFixtures

  alias PotokIde.History.GroupChange
  alias PotokIde.{Repo, Social}
  alias PotokIde.Social.{AppData, Group}

  defp unique, do: System.unique_integer([:positive])

  setup do
    {owner_account, owner} = account_with_profile!("ht-owner#{unique()}")
    {member_account, member} = account_with_profile!("ht-member#{unique()}")
    {visitor_account, _visitor} = account_with_profile!("ht-visitor#{unique()}")

    group =
      group_with_members!(owner, [member], %{
        "name" => "ht-group",
        "is_public" => true,
        "description" => "prvi red\ndrugi red",
        "home_page" => :chat
      })

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      visitor_account: visitor_account,
      group: Social.get_group!(group.id)
    }
  end

  defp open(account, group, query \\ "") do
    build_conn() |> log_in_account(account) |> live("/groups/#{group.id}/history#{query}")
  end

  defp describe!(ctx, text, profile \\ nil) do
    {:ok, _} =
      Social.update_group_description(profile || ctx.owner, Repo.get!(Group, ctx.group.id), %{
        "description" => text
      })
  end

  defp change!(type, op \\ :changed) do
    Repo.one!(
      from(c in GroupChange,
        where: c.subject_type == ^type and c.op == ^op,
        order_by: [desc: c.id],
        limit: 1
      )
    )
  end

  defp open_change(lv, change) do
    lv |> element("#history-change-#{change.id}-open") |> render_click()
  end

  test "a member reads who changed what, from the group's menu too", ctx do
    describe!(ctx, "novi red")
    {:ok, message} = Social.create_value(ctx.member, ctx.group, %{"content" => "x"})
    {:ok, _} = Social.delete_value(ctx.owner, message)

    {:ok, lv, _html} = open(ctx.member_account, ctx.group)
    assert has_element?(lv, "#group-panel-history")
    assert has_element?(lv, "#group-tab-history")
    assert has_element?(lv, "#history-list", "#{ctx.owner.username} changes the description.")

    assert has_element?(
             lv,
             "#history-list",
             "#{ctx.owner.username} deletes a message by #{ctx.member.username}."
           )

    assert has_element?(lv, "#history-since")
  end

  test "someone outside a public group has no history of it", ctx do
    describe!(ctx, "novi red")
    {:ok, lv, _html} = open(ctx.visitor_account, ctx.group)
    refute has_element?(lv, "#group-panel-history")
    refute has_element?(lv, "#group-tab-history")
  end

  test "a conversation and the root have none", ctx do
    {:ok, direct} = Social.get_or_create_direct_group(ctx.owner, ctx.member)
    {:ok, lv, _html} = open(ctx.owner_account, direct)
    refute has_element?(lv, "#group-panel-history")
  end

  test "a text is compared line by line", ctx do
    describe!(ctx, "prvi red\nizmenjen red")
    {:ok, lv, _html} = open(ctx.member_account, ctx.group)
    open_change(lv, change!("group"))

    assert has_element?(lv, "#history-dialog #history-side-description[data-shape='lines']")
    assert has_element?(lv, "#history-side-description .text-error", "drugi red")
    assert has_element?(lv, "#history-side-description .text-success", "izmenjen red")

    lv |> element("#history-dialog-close") |> render_click()
    refute has_element?(lv, "#history-dialog")
  end

  test "a record is compared path by path", ctx do
    {:ok, _} =
      AppData.save_config(
        ctx.owner,
        ctx.group,
        nil,
        %{"rules" => %{"molbe" => %{"edit_own" => true, "read" => ["everyone"]}}},
        0
      )

    {:ok, value, _} =
      AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, "molbe", %{
        "stan" => %{"broj" => 5},
        "ime" => "P"
      })

    {:ok, _, _} =
      AppData.update(
        ctx.member,
        ctx.group,
        nil,
        value.id,
        %{"stan" => %{"broj" => 6}, "ime" => "P"},
        nil
      )

    {:ok, lv, _html} = open(ctx.owner_account, ctx.group)
    open_change(lv, change!("record"))
    assert has_element?(lv, "#history-side-data[data-shape='paths']", "stan › broj")
    refute has_element?(lv, "#history-side-data", "ime")
  end

  test "narrowed to a kind, a person, a day and one thing", ctx do
    describe!(ctx, "novi red")
    poll = create_poll!(ctx.member, ctx.group)
    {:ok, lv, _html} = open(ctx.member_account, ctx.group)

    lv |> element("#history-filter-talk") |> render_click()
    assert has_element?(lv, "#history-list", "starts the poll")
    refute has_element?(lv, "#history-list", "changes the description")

    lv |> element("#history-filter-all") |> render_click()
    description = change!("group")

    lv
    |> element("#history-change-#{description.id} button[phx-click='history_actor']")
    |> render_click()

    assert has_element?(lv, "#history-actor", ctx.owner.username)
    refute has_element?(lv, "#history-list", "starts the poll")

    lv |> element("#history-actor-clear") |> render_click()
    assert has_element?(lv, "#history-list", "starts the poll")

    lv |> element("#history-until-form") |> render_change(%{"until" => "2026-01-01"})
    assert has_element?(lv, "#history-empty")
    lv |> element("#history-until-form") |> render_change(%{"until" => ""})

    open_change(lv, description)
    lv |> element("#history-only-this") |> render_click()
    assert has_element?(lv, "#history-subject")
    refute has_element?(lv, "#history-list", "starts the poll")
    lv |> element("#history-subject-clear") |> render_click()
    assert has_element?(lv, "#history-list", poll.question)
  end

  test "an address narrows it to one description, as the link by it does", ctx do
    {:ok, alt} =
      Social.create_alt_description(ctx.owner, ctx.group, %{
        "name" => "Pravila",
        "description" => "1"
      })

    describe!(ctx, "novi red")
    {:ok, lv, _html} = open(ctx.owner_account, ctx.group, "?of=description-#{alt.id}")
    assert has_element?(lv, "#history-subject", "Pravila")
    refute has_element?(lv, "#history-list", "changes the description.")

    {:ok, edit, _html} =
      build_conn()
      |> log_in_account(ctx.owner_account)
      |> live(~p"/groups/#{ctx.group.id}/edit_group")

    assert has_element?(
             edit,
             ~s(#alt-description-#{alt.id}-versions[href="/groups/#{ctx.group.id}/history?of=description-#{alt.id}"])
           )

    assert has_element?(
             edit,
             ~s(#group-description-versions[href="/groups/#{ctx.group.id}/history?of=group-#{ctx.group.id}"])
           )
  end

  test "older pages come in after what is there", ctx do
    for n <- 1..35 do
      {:ok, message} = Social.create_value(ctx.owner, ctx.group, %{"content" => "#{n}"})
      {:ok, _} = Social.delete_value(ctx.owner, message)
    end

    {:ok, lv, _html} = open(ctx.member_account, ctx.group)

    count = fn ->
      lv
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#history-list > li")
      |> Enum.count()
    end

    assert count.() == 30
    refute has_element?(lv, "#history-since")
    lv |> element("#history-more") |> render_click()
    assert count.() >= 35
    assert has_element?(lv, "#history-since")
    refute has_element?(lv, "#history-more")
  end

  test "old versions are emptied by an admin, and the fact stays", ctx do
    describe!(ctx, "tajna od juče")
    describe!(ctx, "bez nje")
    change = change!("group")

    {:ok, lv, _html} = open(ctx.member_account, ctx.group)
    open_change(lv, change)
    refute has_element?(lv, "#history-empty-versions")
    render_hook(lv, "history_empty", %{"id" => change.id})
    assert Repo.one(from(c in GroupChange, where: c.id == ^change.id, select: c.before))

    {:ok, lv, _html} = open(ctx.owner_account, ctx.group)
    open_change(lv, change)
    lv |> element("#history-empty-versions") |> render_click()
    assert has_element?(lv, "#history-list", "old version emptied")

    open_change(lv, change)
    assert has_element?(lv, "#history-emptied", ctx.owner.username)
    refute render(lv) =~ "prvi red"
  end

  test "a change the viewer may not read does not open", ctx do
    {:ok, _} =
      Social.create_alt_description(ctx.owner, ctx.group, %{
        "name" => "Admini",
        "description" => "1",
        "visible_role_keys" => ["admin"]
      })

    alt =
      Repo.one!(from(d in PotokIde.Social.GroupAltDescription, order_by: [desc: d.id], limit: 1))

    {:ok, _} = Social.update_alt_description(ctx.owner, ctx.group, alt, %{"description" => "2"})

    {:ok, lv, _html} = open(ctx.member_account, ctx.group)
    refute has_element?(lv, "#history-list", "Admini")
    render_hook(lv, "history_open", %{"id" => change!("description").id})
    refute has_element?(lv, "#history-dialog")
  end

  test "an admin looking as a member reads what a member would, and changes nothing", ctx do
    {:ok, alt} =
      Social.create_alt_description(ctx.owner, ctx.group, %{
        "name" => "Admini",
        "description" => "1",
        "visible_role_keys" => ["admin"]
      })

    {:ok, _} = Social.update_alt_description(ctx.owner, ctx.group, alt, %{"description" => "2"})
    describe!(ctx, "novi red")
    change = change!("group")

    {:ok, lv, _html} = open(ctx.owner_account, ctx.group, "?as=everyone")
    refute has_element?(lv, "#history-list", "Admini")
    open_change(lv, change)
    assert has_element?(lv, "#history-side-description")
    refute has_element?(lv, "#history-empty-versions")
    render_hook(lv, "history_empty", %{"id" => change.id})
    assert Repo.one(from(c in GroupChange, where: c.id == ^change.id, select: c.before))
  end

  test "a tab that is not open holds nothing", ctx do
    describe!(ctx, "novi red")
    {:ok, lv, _html} = open(ctx.member_account, ctx.group)
    assert has_element?(lv, "#history-list")
    lv |> element("#group-tab-access") |> render_click()
    refute has_element?(lv, "#group-panel-history")
    # Events that come late change nothing.
    render_hook(lv, "history_filter", %{"filter" => "talk"})
    refute has_element?(lv, "#group-panel-history")
  end
end
