defmodule PotokIde.History.RestoreTest do
  @moduledoc """
  Putting back what a change took away: by those who may change it anyway,
  the ways changes go, and saying so in the history.
  """

  use PotokIde.DataCase, async: true

  import Ecto.Query
  import PotokIde.EventsFixtures

  alias PotokIde.History.{Feed, GroupChange, Reader, Restore}
  alias PotokIde.Processes.{GroupField, GroupFields, ValueProcess}
  alias PotokIde.{Repo, Social}

  alias PotokIde.Social.{
    Access,
    AppData,
    AppProcess,
    DrawnProcesses,
    Group,
    GroupAltDescription,
    GroupTemplates,
    Value
  }

  defp unique, do: System.unique_integer([:positive])

  setup do
    {owner_account, owner} = account_with_profile!("hx#{unique()}")
    {member_account, member} = account_with_profile!("hx#{unique()}")

    group =
      group_with_members!(owner, [member], %{
        "name" => "Prvo ime",
        "uses_api" => true,
        "is_public" => true,
        "description" => "<p>prvi</p>",
        "description_format" => :html,
        "home_page" => :description
      })

    %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: member_account,
      group: Social.get_group!(group.id)
    }
  end

  defp reader(ctx, profile, opts \\ []) do
    group = Repo.get!(Group, ctx.group.id)
    Reader.new(group, Access.for_profile(profile, group), profile, opts)
  end

  # The last change of a kind, as the reader gets it.
  defp change(ctx, profile, type, op \\ :changed) do
    id =
      Repo.one!(
        from(c in GroupChange,
          where:
            c.group_id == ^ctx.group.id and c.subject_type == ^type and c.op == ^op and c.listed,
          order_by: [desc: c.id],
          limit: 1,
          select: c.id
        )
      )

    Feed.get(reader(ctx, profile), id)
  end

  defp offered(ctx, profile, type, op \\ :changed, opts \\ []),
    do: Restore.offered(reader(ctx, profile, opts), change(ctx, profile, type, op))

  defp restore!(ctx, profile, type, op \\ :changed) do
    Restore.run(
      profile,
      Repo.get!(Group, ctx.group.id),
      reader(ctx, profile),
      change(ctx, profile, type, op)
    )
  end

  defp config!(ctx, data, revision \\ 0) do
    {:ok, config} = AppData.save_config(ctx.owner, ctx.group, nil, data, revision)
    config
  end

  defp record!(ctx, data, collection \\ "molbe") do
    {:ok, value, _} =
      AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, collection, data)

    value
  end

  # Nothing that follows merges with what came before.
  defp apart!, do: Repo.query!("UPDATE group_changes SET at = at - interval '1 hour'")

  test "a group's name and description, and the history says it was put back", ctx do
    {:ok, _} =
      Social.update_group(ctx.owner, ctx.group, %{
        "name" => "Drugo",
        "description" => "<p>drugi</p>",
        "is_public" => false
      })

    apart!()
    was = change(ctx, ctx.owner, "group")
    assert offered(ctx, ctx.member, "group") == nil

    assert {:error, :not_permitted} =
             Restore.run(ctx.member, ctx.group, reader(ctx, ctx.member), was)

    assert {:ok, %{records: 0}} = restore!(ctx, ctx.owner, "group")
    group = Repo.get!(Group, ctx.group.id)
    assert {group.name, group.description} == {"Prvo ime", "<p>prvi</p>"}
    # Who may come in is not part of it.
    refute group.is_public

    back = change(ctx, ctx.owner, "group")
    assert back.cause == %{"restored" => was.id}
    assert back.actor_id == ctx.owner.id
    assert back.before["name"] == "Drugo"
  end

  test "a group's place, areas and all", ctx do
    ring = [[20.0, 44.0], [20.1, 44.0], [20.1, 44.1], [20.0, 44.0]]
    area = %{"type" => "Polygon", "coordinates" => [ring]}

    {:ok, _} =
      Social.update_group(ctx.owner, ctx.group, %{
        "area" => Jason.encode!(area),
        "pin_icon" => "place"
      })

    apart!()

    {:ok, _} =
      Social.update_group(ctx.owner, Repo.get!(Group, ctx.group.id), %{
        "area" => nil,
        "latitude" => nil,
        "longitude" => nil,
        "pin_icon" => nil
      })

    apart!()
    assert {:ok, _} = restore!(ctx, ctx.owner, "group")
    group = Repo.get!(Group, ctx.group.id)
    assert group.pin_icon == "place"
    assert group.latitude
    %{rows: [[size]]} = Repo.query!("SELECT area_size FROM groups WHERE id = $1", [group.id])
    assert size > 0
  end

  test "an alternative description, but not who sees it", ctx do
    {:ok, alt} =
      Social.create_alt_description(ctx.owner, ctx.group, %{
        "name" => "Pravila",
        "description" => "stara",
        "visible_role_keys" => []
      })

    {:ok, _} =
      Social.update_alt_description(ctx.owner, ctx.group, alt, %{
        "description" => "nova",
        "visible_role_keys" => ["admin"]
      })

    apart!()
    assert {:ok, _} = restore!(ctx, ctx.owner, "description")
    alt = Repo.get!(GroupAltDescription, alt.id)
    assert {alt.description, alt.visible_role_keys} == {"stara", ["admin"]}
  end

  test "a deleted description comes back under its own id, with its records", ctx do
    {:ok, alt} =
      Social.create_alt_description(ctx.owner, ctx.group, %{
        "name" => "App",
        "description" => "<p>app</p>",
        "uses_api" => true,
        "visible_role_keys" => ["admin"]
      })

    {:ok, _} =
      AppData.save_config(ctx.owner, ctx.group, alt, %{"rules" => %{"c" => %{}}}, 0)

    {:ok, value, _} =
      AppData.insert(ctx.owner, ctx.owner_account, ctx.group, alt, "c", %{"n" => 1})

    # Another app's records of the same collection are not its own.
    config!(ctx, %{"rules" => %{"c" => %{}}})
    record!(ctx, %{"n" => 2}, "c")

    {:ok, _} = Social.delete_alt_description(ctx.owner, ctx.group, alt)
    refute Repo.get(Value, value.id)
    apart!()

    assert offered(ctx, ctx.owner, "description", :deleted) == :here
    assert {:ok, %{records: 2, lost_files: 0}} = restore!(ctx, ctx.owner, "description", :deleted)

    back = Repo.get!(GroupAltDescription, alt.id)

    assert {back.name, back.description, back.visible_role_keys} ==
             {"App", "<p>app</p>", ["admin"]}

    again = Repo.get!(Value, value.id)
    assert again.data == %{"n" => 1}
    assert again.alt_description_id == alt.id
    assert again.creator_id == ctx.owner.id
    assert again.inserted_at == value.inserted_at

    # Once is enough.
    assert offered(ctx, ctx.owner, "description", :deleted) == nil
  end

  test "a name taken meanwhile is in the way, and nothing comes back", ctx do
    attrs = %{"name" => "Isti", "description" => "1"}
    {:ok, alt} = Social.create_alt_description(ctx.owner, ctx.group, attrs)
    {:ok, _} = Social.delete_alt_description(ctx.owner, ctx.group, alt)
    {:ok, _} = Social.create_alt_description(ctx.owner, ctx.group, attrs)

    assert {:error, %Ecto.Changeset{}} = restore!(ctx, ctx.owner, "description", :deleted)
    refute Repo.get(GroupAltDescription, alt.id)
  end

  test "a record, by its author and as far as the app lets them", ctx do
    config!(ctx, %{"rules" => %{"molbe" => %{"edit_own" => true, "read" => ["everyone"]}}})
    value = record!(ctx, %{"n" => 1})
    {:ok, _, _} = AppData.update(ctx.member, ctx.group, nil, value.id, %{"n" => 2}, nil)
    apart!()

    # An editor may not change what others wrote, and neither may they here.
    assert offered(ctx, ctx.owner, "record") == nil
    assert offered(ctx, ctx.member, "record") == :here
    assert offered(ctx, ctx.member, "record", :changed, own: false) == nil

    assert {:ok, _} = restore!(ctx, ctx.member, "record")
    assert Repo.get!(Value, value.id).data == %{"n" => 1}

    config!(ctx, %{"rules" => %{"molbe" => %{"edit_own" => false}}}, 0)
    apart!()

    change =
      Repo.one!(
        from(c in GroupChange,
          where: c.subject_id == ^value.id and c.op == :changed,
          order_by: [asc: c.id],
          limit: 1,
          select: c.id
        )
      )

    change = Feed.get(reader(ctx, ctx.member), change)

    assert {:error, :not_permitted} =
             Restore.run(ctx.member, ctx.group, reader(ctx, ctx.member), change)
  end

  test "a collection deleted at once comes back at once, starting nothing", ctx do
    config!(ctx, %{"rules" => %{"molbe" => %{}, "druge" => %{}}})
    values = for n <- 1..3, do: record!(ctx, %{"n" => n})
    other = record!(ctx, %{"n" => 9}, "druge")
    {:ok, 3} = AppData.delete_collection(ctx.owner, ctx.group, nil, "molbe")
    {:ok, _} = AppData.delete(ctx.owner, ctx.group, nil, other.id)
    apart!()
    runs = Repo.aggregate(ValueProcess, :count)

    change =
      Repo.one!(
        from(c in GroupChange,
          where: c.op == :deleted and c.collection == "molbe" and c.listed,
          select: c.id
        )
      )

    AppData.subscribe(ctx.group)

    assert {:ok, %{records: 3, lost_files: 0}} =
             Restore.run(
               ctx.owner,
               ctx.group,
               reader(ctx, ctx.owner),
               Feed.get(reader(ctx, ctx.owner), change)
             )

    for value <- values do
      back = Repo.get!(Value, value.id)
      assert {back.data, back.creator_id} == {value.data, ctx.member.id}
    end

    # The history tells it once.
    assert [%{cause: %{"count" => 3, "restored" => ^change}}] =
             Repo.all(
               from(c in GroupChange,
                 where: c.op == :created and c.listed and fragment("? \\? 'restored'", c.cause)
               )
             )

    # The other collection's stays where it went.
    refute Repo.get(Value, other.id)
    assert Repo.aggregate(ValueProcess, :count) == runs
    # An app that is open hears of them.
    assert_received {:app_value, _, :created, %{collection: "molbe"}}
  end

  test "a record whose files are gone says how many", ctx do
    config!(ctx, %{"rules" => %{"molbe" => %{}}})
    value = record!(ctx, %{"n" => 1})

    Repo.query!(~s|UPDATE "values" SET data = '{"slika": {"file": 999999999}}' WHERE id = $1|, [
      value.id
    ])

    {:ok, _} = AppData.delete(ctx.owner, ctx.group, nil, value.id)
    assert offered(ctx, ctx.member, "record", :deleted) == nil
    assert {:ok, %{records: 1, lost_files: 1}} = restore!(ctx, ctx.owner, "record", :deleted)
  end

  test "an app's config keeps the secret part it has now", ctx do
    secret = %{"score" => %{"molbe" => %{"p" => %{"points" => 1, "right" => "x"}}}}
    config!(ctx, %{"form" => 1, "secret" => secret})
    apart!()
    other = put_in(secret, ["score", "molbe", "p", "right"], "y")
    config!(ctx, %{"form" => 2, "secret" => other}, 0)
    apart!()

    assert offered(ctx, ctx.member, "record") == nil
    assert {:ok, _} = restore!(ctx, ctx.owner, "record")
    config = AppData.get_config(ctx.group, nil)
    assert config.data["form"] == 1
    assert config.data["secret"] == other
    assert config.lock_version == 2
  end

  test "a template changed and a template deleted", ctx do
    attrs = %{"name" => "Vest", "purpose" => "", "html" => "<p>1</p>", "fields" => []}
    {:ok, template} = GroupTemplates.create(ctx.owner, ctx.group, attrs)

    {:ok, template} =
      GroupTemplates.update(ctx.owner, ctx.group, template, %{"html" => "<p>2</p>"})

    apart!()

    assert {:ok, _} = restore!(ctx, ctx.owner, "template")
    [template] = GroupTemplates.list_own(ctx.group) |> Enum.filter(&(&1.id == template.id))
    assert template.html == "<p>1</p>"

    {:ok, _} = GroupTemplates.delete(ctx.owner, ctx.group, template)
    assert {:ok, _} = restore!(ctx, ctx.owner, "template", :deleted)
    assert [%{name: "Vest", html: "<p>1</p>"}] = GroupTemplates.list_own(ctx.group)
  end

  test "a field's value, while it fits", ctx do
    access = Access.for_profile(ctx.owner, ctx.group)

    {:ok, field} =
      GroupFields.declare(ctx.group, access, %{"name" => "broj", "type" => "number"}, ctx.owner)

    Repo.query!("UPDATE group_fields SET value = '12' WHERE id = $1", [field.id])
    apart!()
    {:ok, _} = GroupFields.clear(ctx.group, access, field.id, ctx.owner)
    apart!()
    assert {:ok, _} = restore!(ctx, ctx.owner, "field")
    assert Repo.get!(GroupField, field.id).value == "12"
  end

  describe "processes" do
    defp graph(label) do
      %{
        "v" => 2,
        "nodes" => [
          %{"id" => "start", "type" => "startEvent"},
          %{"id" => "kraj", "type" => "endEvent", "label" => label}
        ],
        "flows" => [%{"from" => "start", "to" => "kraj"}]
      }
    end

    test "an earlier drawing opens in its editor; a deleted one is drawn again, off", ctx do
      {:ok, process} =
        DrawnProcesses.create(ctx.owner, ctx.group, %{
          "name" => "P",
          "graph" => graph("prvi"),
          "trigger" => "manual",
          "trigger_config" => %{"roles" => ["everyone"]}
        })

      {:ok, process} = DrawnProcesses.activate(ctx.owner, ctx.group, process.id)
      apart!()

      {:ok, process} =
        DrawnProcesses.update(
          ctx.owner,
          ctx.group,
          process.id,
          %{"name" => "P", "graph" => graph("drugi")},
          process.lock_version
        )

      assert offered(ctx, ctx.owner, "process") == :editor
      # A member reads what was on, and may look at it.
      assert offered(ctx, ctx.member, "process") == :editor
      assert {:error, :not_permitted} = restore!(ctx, ctx.owner, "process")

      {:ok, _} = DrawnProcesses.delete(ctx.owner, ctx.group, process.id)
      assert {:ok, _} = restore!(ctx, ctx.owner, "process", :deleted)

      assert [%AppProcess{name: "P", active: false, graph: graph}] =
               Repo.all(from(p in AppProcess, where: p.group_id == ^ctx.group.id))

      assert Enum.any?(graph["nodes"], &(&1["label"] == "drugi"))
    end
  end

  test "what was emptied cannot be put back", ctx do
    {:ok, _} = Social.update_group(ctx.owner, ctx.group, %{"name" => "Drugo"})
    {:ok, 1} = PotokIde.History.empty(ctx.owner, ctx.group, change(ctx, ctx.owner, "group"))
    assert offered(ctx, ctx.owner, "group") == nil
  end
end
