defmodule PotokIde.Repo.Migrations.TypeGroupFields do
  use Ecto.Migration

  # A field of a group gets a type (`PotokIde.Processes.GroupFields`): its
  # value stays a text of that type. Every field so far is a text, except
  # those a drawn process of the group adds to that hold a number or nothing,
  # which become numbers.
  def up do
    alter table(:group_fields) do
      add :type, :text, null: false, default: "text"
      add :options, {:array, :text}, null: false, default: []
    end

    create constraint(:group_fields, :group_fields_type_check,
             check: "type IN ('text', 'number', 'boolean', 'date', 'datetime', 'choice')"
           )

    create constraint(:group_fields, :group_fields_options_check,
             check: "(type = 'choice' OR cardinality(options) = 0) AND cardinality(options) <= 30"
           )

    execute """
    UPDATE group_fields f
    SET type = 'number'
    WHERE (f.value = '' OR f.value ~ '^-?[0-9]+([.,][0-9]+)?$')
      AND EXISTS (
        SELECT 1 FROM app_processes p
        WHERE p.group_id = f.group_id AND p.drawn
          AND jsonb_path_exists(
            p.graph,
            '$.nodes[*] ? (@.action == "set" && @.op == "add" && @.field == $n)',
            jsonb_build_object('n', f.name)
          )
      )
    """
  end

  def down do
    drop constraint(:group_fields, :group_fields_options_check)
    drop constraint(:group_fields, :group_fields_type_check)

    alter table(:group_fields) do
      remove :options
      remove :type
    end
  end
end
