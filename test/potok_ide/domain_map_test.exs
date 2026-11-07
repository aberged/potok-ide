defmodule PotokIde.DomainMapTest do
  use PotokIde.DataCase, async: true

  alias PotokIde.DomainMap

  defp entity(id), do: Enum.find(DomainMap.graph().entities, &(&1.id == id))

  defp keys, do: Enum.filter(DomainMap.graph().edges, &(&1.kind == :key))

  test "every schema of the app is on the map" do
    {:ok, modules} = :application.get_key(:potok_ide, :modules)

    schemas =
      Enum.filter(modules, fn module ->
        Code.ensure_loaded?(module) and function_exported?(module, :__schema__, 1) and
          is_binary(module.__schema__(:source))
      end)

    assert Enum.sort(schemas) == Enum.sort(DomainMap.modules())
  end

  test "every belongs_to has its one key in the database" do
    for module <- DomainMap.modules(),
        association <- module.__schema__(:associations),
        %Ecto.Association.BelongsTo{owner_key: column} <- [
          module.__schema__(:association, association)
        ] do
      id = module |> Module.split() |> List.last()

      assert [_key] =
               Enum.filter(keys(), &(&1.from == id and hd(&1.columns) == to_string(column))),
             "#{id}.#{column}"
    end
  end

  test "there are no keys besides those of the schemas" do
    belongs_to =
      for module <- DomainMap.modules(),
          association <- module.__schema__(:associations),
          %Ecto.Association.BelongsTo{} <- [module.__schema__(:association, association)] do
        association
      end

    assert length(keys()) == length(belongs_to)
  end

  test "the database wins over the schema" do
    assert %{to: "GroupMembership", columns: ["profile_id", "group_id"], rule: :cascade} =
             Enum.find(keys(), &(&1.from == "GroupMemberRole" and "profile_id" in &1.columns))
  end

  test "composite keys start with their own column" do
    assert %{to: "GroupAltDescription", columns: ["alt_description_id", "group_id"]} =
             Enum.find(keys(), &(&1.from == "Value" and "alt_description_id" in &1.columns))
  end

  test "every link joins two entities of the map" do
    ids = Enum.map(DomainMap.graph().entities, & &1.id)

    for edge <- DomainMap.graph().edges do
      assert edge.from in ids
      assert edge.to in ids
    end
  end

  test "soft links name real columns on both sides" do
    soft = Enum.filter(DomainMap.graph().edges, &(&1.kind == :soft))
    assert length(soft) == 8

    for edge <- soft do
      assert hd(edge.columns) in field_names(edge.from), "#{edge.from}.#{hd(edge.columns)}"
      assert edge.target in field_names(edge.to), "#{edge.to}.#{edge.target}"
    end
  end

  defp field_names(id), do: Enum.map(entity(id).fields, &to_string(&1.name))

  test "marks primary and foreign keys among the fields" do
    fields = Map.new(entity("Value").fields, &{&1.name, &1})

    assert fields[:id].primary?
    assert fields[:creator_id].key?
    refute fields[:content].key?
  end

  test "reads unique indexes and checks, without enum lists" do
    assert %{columns: ["group_id", "profile_id"], where: nil} in entity("GroupMembership").unique

    assert %{columns: ["profile_id", "invitee_id"], where: "accepted_at IS NULL"} in entity(
             "ProfileInvitation"
           ).unique

    assert %{columns: ["lower(name)"], where: "owner_id IS NULL"} in entity("Tag").unique

    assert %{name: "taggings_one_target", definition: definition} =
             Enum.find(entity("Tagging").checks, &(&1.name == "taggings_one_target"))

    assert definition =~ "num_nonnulls"

    names = Enum.map(entity("Group").checks, & &1.name)
    refute "groups_home_page_check" in names
    assert "groups_root_parent_check" in names
  end

  test "points at the file of each schema" do
    for %{file: file} <- DomainMap.graph().entities do
      assert File.exists?(file), file
    end
  end

  describe "deletion/1" do
    defp columns(edges), do: Enum.map(edges, &{&1.from, hd(&1.columns)})

    test "sub-groups block deleting a group" do
      assert columns(DomainMap.deletion("Group").blocked_by) == [{"Group", "parent_id"}]
    end

    test "values and files block deleting a profile" do
      blocked_by = "Profile" |> DomainMap.deletion() |> Map.fetch!(:blocked_by) |> columns()

      assert Enum.sort(blocked_by) == [{"Value", "creator_id"}, {"ValueAttachment", "profile_id"}]
    end

    test "follows cascades through the tables they reach" do
      %{cascades: cascades} = DomainMap.deletion("Group")

      assert "GroupMembership" in cascades
      # By way of the membership and of the value.
      assert "GroupMemberRole" in cascades
      assert "ValueReaction" in cascades
      refute "Group" in cascades
      refute "Profile" in cascades
    end

    test "says which keys get cleared" do
      assert {"Event", "value_id"} in columns(DomainMap.deletion("Value").clears)
    end

    test "a table nothing points at takes nothing with it" do
      assert DomainMap.deletion("GmailRefreshToken") ==
               %{blocked_by: [], cascades: [], clears: []}
    end
  end
end
