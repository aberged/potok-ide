defmodule PotokIde.Repo.Migrations.AddGroupsLastValueAt do
  use Ecto.Migration

  # When the group's newest chat value was posted. The sub-groups list sorts
  # by it, which otherwise took one lookup in `values` per visible sub-group.
  def up do
    alter table(:groups) do
      add :last_value_at, :utc_datetime
    end

    execute """
    UPDATE groups g
    SET last_value_at = v.last_value_at
    FROM (
      SELECT group_id, MAX(inserted_at) AS last_value_at
      FROM values
      WHERE is_data = FALSE
      GROUP BY group_id
    ) v
    WHERE v.group_id = g.id
    """
  end

  def down do
    alter table(:groups) do
      remove :last_value_at
    end
  end
end
