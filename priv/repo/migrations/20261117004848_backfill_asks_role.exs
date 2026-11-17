defmodule PotokIde.Repo.Migrations.BackfillAsksRole do
  use Ecto.Migration

  # `AddAsksToValueProcesses` filled in whom the decisions that waited then
  # ask, but the code before it ran on for a few seconds after it, and a run
  # it stopped on a decision then asks nobody: no page lists or counts it.
  # Now that every running server writes the columns on each wait, this fills
  # in those, and only those: a waiting decision that asks no one yet.
  def up do
    execute """
    UPDATE value_processes AS i
    SET asks_role =
      jsonb_path_query_first(
        i.graph,
        '$.nodes[*] ? (@.id == $e && @.type == "userTask")',
        jsonb_build_object('e', i.element)
      ) ->> 'role'
    WHERE i.status = 'waiting'
      AND i.asks_role IS NULL
      AND i.asks_profile_id IS NULL
    """
  end

  # Whom a wait asks is rewritten on the next wait anyway.
  def down, do: :ok
end
