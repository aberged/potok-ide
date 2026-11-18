defmodule PotokIde.Repo.Migrations.AddCleanupIndexes do
  use Ecto.Migration

  # For the hourly pass (`Social.AppFileSweeper`): the ended runs not yet
  # slimmed (`Processes.slim_ended/1`), an index that empties itself as they
  # are, and the tokens by age (`Accounts.delete_expired_tokens/0`).
  def change do
    create index(:value_processes, [:updated_at],
             where: "status IN ('done', 'cancelled') AND graph <> '{}'::jsonb",
             name: :value_processes_ended_unslimmed_index
           )

    create index(:accounts_tokens, [:inserted_at])
  end
end
