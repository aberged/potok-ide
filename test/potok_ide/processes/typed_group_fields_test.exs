defmodule PotokIde.Processes.TypedGroupFieldsTest do
  @moduledoc """
  The fields of a group have types: its editors declare them, a drawing of
  today's language is saved with those it uses, a step writes a value of
  the field's type, and a name the group does not declare is an unknown one.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Processes.{Engine, GroupField, GroupFields, ValueProcess}
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, DrawnProcesses}

  defp unique, do: System.unique_integer([:positive])

  setup do
    {_account, owner} = account_with_profile!("tf#{unique()}")
    {_member_account, member} = account_with_profile!("tf#{unique()}")
    group = group_with_members!(owner, [member])
    {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
    group = Social.get_group!(group.id)

    %{owner: owner, member: member, group: group, editor: Access.for_profile(owner, group)}
  end

  defp set(id, field, op, value),
    do: %{
      "id" => id,
      "type" => "serviceTask",
      "action" => "set",
      "field" => field,
      "op" => op,
      "value" => value
    }

  defp message(id, text),
    do: %{"id" => id, "type" => "serviceTask", "action" => "message", "text" => text}

  defp chain(steps) do
    nodes =
      [%{"id" => "start", "type" => "startEvent"}] ++
        steps ++ [%{"id" => "kraj", "type" => "endEvent"}]

    flows =
      nodes
      |> Enum.map(& &1["id"])
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [from, to] -> %{"from" => from, "to" => to} end)

    %{"v" => 2, "nodes" => nodes, "flows" => flows}
  end

  defp draw(ctx, graph),
    do:
      DrawnProcesses.create(ctx.owner, ctx.group, %{
        "trigger" => "manual",
        "name" => "Polja #{unique()}",
        "graph" => graph
      })

  defp drawn!(ctx, graph) do
    {:ok, row} = draw(ctx, graph)
    {:ok, row} = DrawnProcesses.activate(ctx.owner, ctx.group, row.id)
    row
  end

  defp run!(ctx, row) do
    {:ok, instance} = DrawnProcesses.start(ctx.owner, ctx.group, row.id, %{"title" => "Lift"})
    Engine.run(instance.id)
  end

  defp value(ctx, name), do: Repo.get_by!(GroupField, group_id: ctx.group.id, name: name).value

  test "the editors declare a field with its type, and nobody else", ctx do
    assert {:ok, %GroupField{type: "number", value: ""}} =
             GroupFields.declare(ctx.group, ctx.editor, %{"name" => "kvarova", "type" => "number"})

    assert {:error, :taken} =
             GroupFields.declare(ctx.group, ctx.editor, %{"name" => "kvarova", "type" => "text"})

    assert {:error, :invalid_name} =
             GroupFields.declare(ctx.group, ctx.editor, %{"name" => "dve reči", "type" => "text"})

    assert {:error, :invalid_options} =
             GroupFields.declare(ctx.group, ctx.editor, %{"name" => "stanje", "type" => "choice"})

    assert {:error, :not_permitted} =
             GroupFields.declare(
               ctx.group,
               Access.for_profile(ctx.member, ctx.group),
               %{"name" => "tudje", "type" => "text"}
             )
  end

  test "a step writes a value of the field's type, and adds only to a number", ctx do
    {:ok, _} =
      GroupFields.declare(ctx.group, ctx.editor, %{"name" => "kvarova", "type" => "number"})

    {:ok, _} =
      GroupFields.declare(ctx.group, ctx.editor, %{"name" => "hitno", "type" => "boolean"})

    {:ok, _} =
      GroupFields.declare(ctx.group, ctx.editor, %{
        "name" => "stanje",
        "type" => "choice",
        "options" => "otvoreno, zatvoreno"
      })

    row =
      drawn!(
        ctx,
        chain([
          set("brojac", "kvarova", "add", "1"),
          set("hitnost", "hitno", "set", "da"),
          set("status", "stanje", "set", "zatvoreno")
        ])
      )

    assert %ValueProcess{status: :done} = run!(ctx, row)
    assert %ValueProcess{status: :done} = run!(ctx, row)
    assert value(ctx, "kvarova") == "2"
    assert value(ctx, "hitno") == "true"
    assert value(ctx, "stanje") == "zatvoreno"
    assert row.graph["fields"]["kvarova"] == %{"type" => "number"}

    # A value worked out at the run that does not fit fails the run.
    wrong = drawn!(ctx, chain([set("status", "stanje", "set", "{{start.title}}")]))

    assert %ValueProcess{status: :failed, error: %{"reason" => "invalid_field"}} =
             run!(ctx, wrong)
  end

  test "a drawing is refused what no field could take", ctx do
    {:ok, _} =
      GroupFields.declare(ctx.group, ctx.editor, %{"name" => "beleska", "type" => "text"})

    {:ok, _} = GroupFields.declare(ctx.group, ctx.editor, %{"name" => "rok", "type" => "date"})

    assert {:error, {:invalid_graph, "nodes.1.op", :not_a_number_field}} =
             draw(ctx, chain([set("brojac", "beleska", "add", "1")]))

    assert {:error, {:invalid_graph, "nodes.1.value", :invalid_field_value}} =
             draw(ctx, chain([set("datum", "rok", "set", "nije datum")]))

    # A name the group does not declare is a typo, not an empty field.
    assert {:error, {:invalid_graph, "nodes.1.text", _unknown}} =
             draw(ctx, chain([message("poruka", "{{group.rokk}}")]))
  end

  test "a field a step sets comes with the drawing: a number where it adds", ctx do
    row =
      drawn!(
        ctx,
        chain([set("brojac", "zalbi", "add", "1"), set("napomena", "beleska", "set", "x")])
      )

    assert %{"zalbi" => %{"type" => "number"}, "beleska" => %{"type" => "text"}} =
             GroupFields.definitions(ctx.group)

    assert %ValueProcess{status: :done} = run!(ctx, row)
    assert value(ctx, "zalbi") == "1"
  end

  test "a field a process uses is not deleted; it is emptied, and retyped while it fits", ctx do
    {:ok, field} =
      GroupFields.declare(ctx.group, ctx.editor, %{"name" => "kvarova", "type" => "text"})

    row = drawn!(ctx, chain([set("upis", "kvarova", "set", "7")]))
    run!(ctx, row)

    assert {:error, {:in_use, [name]}} = GroupFields.delete(ctx.group, ctx.editor, field.id)
    assert name == row.name

    assert {:ok, %GroupField{type: "number"}} =
             GroupFields.retype(ctx.group, ctx.editor, field.id, %{"type" => "number"})

    assert {:error, :value_does_not_fit} =
             GroupFields.retype(ctx.group, ctx.editor, field.id, %{"type" => "date"})

    assert {:ok, %GroupField{value: ""}} = GroupFields.clear(ctx.group, ctx.editor, field.id)

    assert {:ok, %GroupField{type: "date"}} =
             GroupFields.retype(ctx.group, ctx.editor, field.id, %{"type" => "date"})
  end

  test "a drawing reads a field as its type", ctx do
    {:ok, field} =
      GroupFields.declare(ctx.group, ctx.editor, %{"name" => "kvarova", "type" => "number"})

    field |> Ecto.Changeset.change(value: "9") |> Repo.update!()

    row =
      drawn!(
        ctx,
        chain([
          message(
            "poruka",
            ~s|{{if(group.kvarova >= 9, "mnogo", "malo")}}: {{group.kvarova + 1}}|
          )
        ])
      )

    assert %ValueProcess{status: :done} = run!(ctx, row)
    assert [%{content: "mnogo: 10"}] = Social.list_group_values(ctx.group)
  end
end
