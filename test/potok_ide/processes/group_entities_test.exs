defmodule PotokIde.Processes.GroupEntitiesTest do
  @moduledoc """
  The entities a group's editors define for its drawn processes: a name and
  typed attributes, which may hold another entity of the group, never in a
  circle.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Processes.{GroupEntities, GroupEntity}
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, AppData}

  defp unique, do: System.unique_integer([:positive])

  setup do
    {_owner_account, owner} = account_with_profile!("ge#{unique()}")
    {_member_account, member} = account_with_profile!("ge#{unique()}")
    group = group_with_members!(owner, [member], %{})
    {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
    group = Social.get_group!(group.id)

    %{
      group: group,
      editor: Access.for_profile(owner, group),
      member: Access.for_profile(member, group)
    }
  end

  defp attribute(name, type \\ "text", more \\ %{}),
    do: Map.merge(%{"name" => name, "type" => type}, more)

  defp create!(ctx, name, attributes) do
    {:ok, entity} =
      GroupEntities.create(ctx.group, ctx.editor, %{"name" => name, "attributes" => attributes})

    entity
  end

  defp errors(changeset, field),
    do: for({message, _opts} <- Keyword.get_values(changeset.errors, field), do: message)

  test "an editor defines an entity with typed attributes", ctx do
    assert {:ok, %GroupEntity{} = entity} =
             GroupEntities.create(ctx.group, ctx.editor, %{
               "name" => "  Prijava kvara ",
               "attributes" => [
                 attribute("naslov", "text", %{"required" => true}),
                 attribute("sprat", "number"),
                 attribute("hitno", "boolean"),
                 attribute("prijavljeno", "datetime"),
                 attribute("vrsta", "choice", %{"options" => "voda, struja,  lift ,voda"}),
                 attribute("slike", "text", %{"list" => true})
               ]
             })

    assert entity.name == "Prijava kvara"
    assert entity.group_id == ctx.group.id

    assert [
             %{name: "naslov", type: "text", required: true, list: false},
             %{name: "sprat", type: "number"},
             %{name: "hitno", type: "boolean"},
             %{name: "prijavljeno", type: "datetime"},
             %{name: "vrsta", type: "choice", options: ["voda", "struja", "lift"]},
             %{name: "slike", type: "text", list: true}
           ] = entity.attributes

    assert [%GroupEntity{id: id}] = GroupEntities.list(ctx.group)
    assert id == entity.id
    assert GroupEntities.get(ctx.group, entity.id).name == "Prijava kvara"
  end

  test "only the app's editors define, change and delete them", ctx do
    attrs = %{"name" => "Stan", "attributes" => [attribute("broj")]}
    assert {:error, :not_permitted} = GroupEntities.create(ctx.group, ctx.member, attrs)

    entity = create!(ctx, "Stan", [attribute("broj")])
    assert {:error, :not_permitted} = GroupEntities.update(ctx.group, ctx.member, entity, attrs)
    assert {:error, :not_permitted} = GroupEntities.delete(ctx.group, ctx.member, entity.id)
    assert [_still_there] = GroupEntities.list(ctx.group)
  end

  test "a name is taken once in the group, in any letter case", ctx do
    create!(ctx, "Stan", [attribute("broj")])

    assert {:error, changeset} =
             GroupEntities.create(ctx.group, ctx.editor, %{
               "name" => "STAN",
               "attributes" => [attribute("broj")]
             })

    assert errors(changeset, :name) == ["has already been taken"]
  end

  test "an entity needs a name and attributes named plainly, each once", ctx do
    assert {:error, changeset} = GroupEntities.create(ctx.group, ctx.editor, %{"name" => " "})
    assert errors(changeset, :name) == ["can't be blank"]
    assert errors(changeset, :attributes) == ["An entity needs at least one attribute."]

    assert {:error, changeset} =
             GroupEntities.create(ctx.group, ctx.editor, %{
               "name" => "Stan",
               "attributes" => [attribute("broj"), attribute("broj", "number")]
             })

    assert errors(changeset, :attributes) == ["Two attributes have the same name."]

    for name <- ["broj stana", "1a", "broj-stana", "from", "empty"] do
      assert {:error, changeset} =
               GroupEntities.create(ctx.group, ctx.editor, %{
                 "name" => "Stan",
                 "attributes" => [attribute(name)]
               })

      assert [%{valid?: false}] = changeset.changes.attributes, name
    end
  end

  test "a choice needs options, and only a choice keeps them", ctx do
    assert {:error, changeset} =
             GroupEntities.create(ctx.group, ctx.editor, %{
               "name" => "Kvar",
               "attributes" => [attribute("vrsta", "choice")]
             })

    assert [%{errors: [options: {"can't be blank", _}]}] = changeset.changes.attributes

    entity = create!(ctx, "Kvar", [attribute("vrsta", "text", %{"options" => "a, b"})])
    assert [%{options: []}] = entity.attributes
  end

  test "an attribute holds another entity of the group", ctx do
    stan = create!(ctx, "Stan", [attribute("broj", "number")])

    zgrada =
      create!(ctx, "Zgrada", [
        attribute("adresa"),
        attribute("stanovi", "entity", %{"entity_id" => stan.id, "list" => true})
      ])

    assert [_adresa, %{type: "entity", entity_id: id, list: true}] = zgrada.attributes
    assert id == stan.id
    assert GroupEntity.held(zgrada) == [stan.id]

    # One of another group is not there to hold.
    {_account, other_owner} = account_with_profile!("ge#{unique()}")
    other = group_with_members!(other_owner, [], %{})
    {:ok, _manifest} = Social.create_own_group_manifest(other_owner, other)
    other = Social.get_group!(other.id)

    assert {:error, changeset} =
             GroupEntities.create(other, Access.for_profile(other_owner, other), %{
               "name" => "Ulaz",
               "attributes" => [attribute("stan", "entity", %{"entity_id" => stan.id})]
             })

    assert [%{errors: [entity_id: {"is invalid", _}]}] = changeset.changes.attributes
  end

  test "no entity comes to hold itself, and they nest four deep at most", ctx do
    a = create!(ctx, "A", [attribute("x")])
    b = create!(ctx, "B", [attribute("a", "entity", %{"entity_id" => a.id})])

    assert {:error, changeset} =
             GroupEntities.update(ctx.group, ctx.editor, a, %{
               "attributes" => [attribute("b", "entity", %{"entity_id" => b.id})]
             })

    assert errors(changeset, :attributes) == ["An entity cannot come to hold itself."]

    # Itself is not among what it may hold.
    assert {:error, changeset} =
             GroupEntities.update(ctx.group, ctx.editor, a, %{
               "attributes" => [attribute("a", "entity", %{"entity_id" => a.id})]
             })

    assert %{errors: [entity_id: {"is invalid", _}]} =
             Enum.find(changeset.changes.attributes, &(&1.action == :insert))

    c = create!(ctx, "C", [attribute("b", "entity", %{"entity_id" => b.id})])
    d = create!(ctx, "D", [attribute("c", "entity", %{"entity_id" => c.id})])

    assert {:error, changeset} =
             GroupEntities.create(ctx.group, ctx.editor, %{
               "name" => "E",
               "attributes" => [attribute("d", "entity", %{"entity_id" => d.id})]
             })

    assert errors(changeset, :attributes) == ["Entities nest at most 4 deep."]
  end

  test "a change keeps the attributes it is given, in their order", ctx do
    entity = create!(ctx, "Stan", [attribute("broj", "number"), attribute("sprat", "number")])
    [broj, sprat] = entity.attributes

    assert {:ok, changed} =
             GroupEntities.update(ctx.group, ctx.editor, entity, %{
               "name" => "Stan u zgradi",
               "attributes" => %{
                 "0" => %{"id" => sprat.id, "name" => "sprat", "type" => "number"},
                 "1" => %{"name" => "vlasnik", "type" => "text"},
                 "2" => %{"id" => broj.id, "name" => "broj", "type" => "text"}
               },
               "attributes_sort" => ["0", "1", "2"]
             })

    assert changed.name == "Stan u zgradi"
    assert changed.lock_version == entity.lock_version + 1

    assert [%{name: "sprat", id: sprat_id}, %{name: "vlasnik"}, %{name: "broj", type: "text"}] =
             changed.attributes

    assert sprat_id == sprat.id
  end

  test "a form drops the rows it marks", ctx do
    entity = create!(ctx, "Stan", [attribute("broj", "number"), attribute("sprat", "number")])
    [broj, sprat] = entity.attributes

    assert {:ok, changed} =
             GroupEntities.update(ctx.group, ctx.editor, entity, %{
               "attributes" => %{
                 "0" => %{"id" => broj.id, "name" => "broj", "type" => "number"},
                 "1" => %{"id" => sprat.id, "name" => "sprat", "type" => "number"}
               },
               "attributes_sort" => ["0", "1"],
               "attributes_drop" => ["", "0"]
             })

    assert [%{name: "sprat"}] = changed.attributes
  end

  test "a change made from an older copy is refused", ctx do
    entity = create!(ctx, "Stan", [attribute("broj")])

    assert {:ok, _newer} =
             GroupEntities.update(ctx.group, ctx.editor, entity, %{"name" => "Stan 2"})

    assert {:error, changeset} =
             GroupEntities.update(ctx.group, ctx.editor, entity, %{"name" => "Stan 3"})

    assert Keyword.has_key?(changeset.errors, :lock_version)
    assert GroupEntities.get(ctx.group, entity.id).name == "Stan 2"
  end

  test "one that another holds cannot be deleted", ctx do
    stan = create!(ctx, "Stan", [attribute("broj")])
    zgrada = create!(ctx, "Zgrada", [attribute("stan", "entity", %{"entity_id" => stan.id})])

    assert {:error, {:in_use, ["Zgrada"]}} =
             GroupEntities.delete(ctx.group, ctx.editor, stan.id)

    assert {:ok, _deleted} = GroupEntities.delete(ctx.group, ctx.editor, zgrada.id)
    assert {:ok, _deleted} = GroupEntities.delete(ctx.group, ctx.editor, stan.id)
    assert GroupEntities.list(ctx.group) == []
    assert {:error, :not_found} = GroupEntities.delete(ctx.group, ctx.editor, stan.id)
  end

  test "a group has at most 50", ctx do
    now = DateTime.utc_now(:second)

    rows =
      for i <- 1..50 do
        %{group_id: ctx.group.id, name: "E#{i}", inserted_at: now, updated_at: now}
      end

    Repo.insert_all(GroupEntity, rows)

    assert {:error, :too_many} =
             GroupEntities.create(ctx.group, ctx.editor, %{
               "name" => "Jos jedan",
               "attributes" => [attribute("x")]
             })
  end

  test "the group's pages hear of a change", ctx do
    Phoenix.PubSub.subscribe(PotokIde.PubSub, AppData.topic(ctx.group.id))
    entity = create!(ctx, "Stan", [attribute("broj")])
    group_id = ctx.group.id
    id = entity.id

    assert_receive {:app_value, ^group_id, :entity, %{id: ^id}}
  end

  test "deleting the group takes its entities along", ctx do
    create!(ctx, "Stan", [attribute("broj")])
    Repo.delete!(ctx.group)
    assert Repo.all(GroupEntity) == []
  end
end
