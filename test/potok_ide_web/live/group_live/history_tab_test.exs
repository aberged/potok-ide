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
    assert has_element?(lv, "#history-side-description .bg-rose-500\\/10", "drugi red")
    assert has_element?(lv, "#history-side-description .bg-emerald-500\\/10", "izmenjen red")

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

  describe "putting back" do
    test "an editor puts an earlier description back, a member does not", ctx do
      describe!(ctx, "novi opis")
      change = change!("group")

      {:ok, lv, _html} = open(ctx.member_account, ctx.group)
      open_change(lv, change)
      refute has_element?(lv, "#history-restore")
      render_hook(lv, "history_restore", %{"id" => change.id})
      assert Repo.get!(Group, ctx.group.id).description == "novi opis"

      {:ok, lv, _html} = open(ctx.owner_account, ctx.group, "?as=everyone")
      open_change(lv, change)
      refute has_element?(lv, "#history-restore")

      {:ok, lv, _html} = open(ctx.owner_account, ctx.group)
      open_change(lv, change)
      lv |> element("#history-restore") |> render_click()
      assert Repo.get!(Group, ctx.group.id).description == "prvi red\ndrugi red"
      refute has_element?(lv, "#history-dialog")
      assert has_element?(lv, "#history-list", "puts back an earlier version: the description")
    end

    test "an earlier drawing opens in the editor, unsaved", ctx do
      graph = fn label ->
        %{
          "v" => 2,
          "nodes" => [
            %{"id" => "start", "type" => "startEvent"},
            %{"id" => "kraj", "type" => "endEvent", "label" => label}
          ],
          "flows" => [%{"from" => "start", "to" => "kraj"}]
        }
      end

      alias PotokIde.Social.DrawnProcesses

      {:ok, process} =
        DrawnProcesses.create(ctx.owner, ctx.group, %{
          "name" => "Prijava",
          "graph" => graph.("Stari kraj"),
          "trigger" => "manual",
          "trigger_config" => %{"roles" => ["everyone"]}
        })

      {:ok, _} =
        DrawnProcesses.update(
          ctx.owner,
          ctx.group,
          process.id,
          %{"name" => "Prijava", "graph" => graph.("Novi kraj")},
          process.lock_version
        )

      change = change!("process")
      {:ok, lv, _html} = open(ctx.owner_account, ctx.group)
      open_change(lv, change)
      assert has_element?(lv, "#history-side-graph[data-shape='steps']", "Novi kraj")
      lv |> element("#history-restore-editor") |> render_click()
      path = "/groups/#{ctx.group.id}/processes?process=#{process.id}&version=#{change.id}"
      assert_patch(lv, path)
      assert has_element?(lv, "#process-editor", "Stari kraj")
      refute has_element?(lv, "#process-editor", "Novi kraj")

      # Nothing is changed until it is saved.
      kept = Repo.get!(PotokIde.Social.AppProcess, process.id).graph
      assert Enum.any?(kept["nodes"], &(&1["label"] == "Novi kraj"))

      # A change of another process says nothing of this one.
      {:ok, other} =
        DrawnProcesses.create(ctx.owner, ctx.group, %{
          "name" => "Druga",
          "graph" => graph.("Tuđi kraj"),
          "trigger" => "manual",
          "trigger_config" => %{"roles" => ["everyone"]}
        })

      {:ok, lv, _html} =
        build_conn()
        |> log_in_account(ctx.owner_account)
        |> live(
          "/groups/#{ctx.group.id}/processes?process=#{process.id}&version=#{change!("process", :created).id}"
        )

      assert other.id
      assert has_element?(lv, "#process-editor", "Novi kraj")
    end
  end

  describe "the group as it was" do
    # What happened so far moves an hour back; the minute half an hour ago
    # stands between it and what comes next.
    defp an_hour_later! do
      # The history of a test begins as its database was made.
      :persistent_term.put({PotokIde.History, :since}, ~U[2026-01-01 00:00:00Z])

      for table <- ~w(group_alt_descriptions values groups) do
        Repo.query!(~s(UPDATE "#{table}" SET inserted_at = inserted_at - interval '1 hour'))
      end

      Repo.query!("UPDATE group_changes SET at = at - interval '1 hour'")

      DateTime.utc_now()
      |> DateTime.add(-30, :minute)
      |> DateTime.to_naive()
      |> NaiveDateTime.to_iso8601()
      |> String.slice(0, 16)
    end

    test "opens at an address, each thing as it was then", ctx do
      {:ok, alt} =
        Social.create_alt_description(ctx.owner, ctx.group, %{
          "name" => "Pravila",
          "description" => "*stara* pravila"
        })

      {:ok, _} =
        AppData.save_config(
          ctx.owner,
          ctx.group,
          nil,
          %{"rules" => %{"molbe" => %{"read" => ["everyone"]}}},
          0
        )

      {:ok, record, _} =
        AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, "molbe", %{
          "ime" => "Stari zapis"
        })

      at = an_hour_later!()
      describe!(ctx, "sadašnji opis")
      {:ok, _} = Social.update_alt_description(ctx.owner, ctx.group, alt, %{"name" => "Nova"})
      {:ok, _} = AppData.delete(ctx.owner, ctx.group, nil, record.id)

      {:ok, lv, _html} = open(ctx.member_account, ctx.group, "?at=#{at}")
      assert has_element?(lv, "#history-snapshot")
      refute has_element?(lv, "#history-list")
      assert has_element?(lv, "#history-snapshot-text", "drugi red")
      refute has_element?(lv, "#history-snapshot-text", "sadašnji opis")
      assert has_element?(lv, "#history-snapshot-note")

      lv |> element("#history-thing-description-#{alt.id}", "Pravila") |> render_click()
      assert has_element?(lv, "#history-values-description em", "stara")
      refute has_element?(lv, "#history-empty-versions")
      lv |> element("#history-dialog-close") |> render_click()

      lv |> element("#history-snapshot-records button", "molbe") |> render_click()
      assert has_element?(lv, "#history-record-#{record.id}", "Stari zapis")
      lv |> element("#history-record-#{record.id}") |> render_click()
      assert has_element?(lv, "#history-value-data", "Stari zapis")
      lv |> element("#history-dialog-close") |> render_click()

      lv |> element("#history-at-clear") |> render_click()
      assert_patch(lv, "/groups/#{ctx.group.id}/history")
      assert has_element?(lv, "#history-list", "deletes a record of")
    end

    test "the form leads to the address of the moment", ctx do
      at = an_hour_later!()
      {:ok, lv, _html} = open(ctx.member_account, ctx.group)
      lv |> element("#history-at-form") |> render_change(%{"at" => at})
      assert_patch(lv, "/groups/#{ctx.group.id}/history?at=#{at}")
      assert has_element?(lv, "#history-snapshot")
    end

    test "a day from before the history says so", ctx do
      an_hour_later!()
      {:ok, lv, _html} = open(ctx.member_account, ctx.group, "?at=2020-01-01T10:00")
      assert has_element?(lv, "#history-before-since")
    end

    test "an app of that time does not run", ctx do
      {:ok, _} =
        Social.update_group(ctx.owner, ctx.group, %{
          "uses_api" => true,
          "description" => "<script>window.x = 1</script><p>app</p>"
        })

      at = an_hour_later!()
      describe!(ctx, "<p>nova</p>")
      {:ok, lv, _html} = open(ctx.member_account, ctx.group, "?at=#{at}")
      assert has_element?(lv, "#history-snapshot-text", "An app")
      refute render(lv) =~ "window.x"
    end

    test "a thing the viewer may not see does not open", ctx do
      {:ok, alt} =
        Social.create_alt_description(ctx.owner, ctx.group, %{
          "name" => "Admini",
          "description" => "1",
          "visible_role_keys" => ["admin"]
        })

      at = an_hour_later!()
      {:ok, lv, _html} = open(ctx.member_account, ctx.group, "?at=#{at}")
      refute has_element?(lv, "#history-thing-description-#{alt.id}")
      render_hook(lv, "history_thing", %{"type" => "description", "id" => alt.id})
      refute has_element?(lv, "#history-dialog")
    end
  end
end
