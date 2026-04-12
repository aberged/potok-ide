defmodule PotokIde.Repo.Migrations.AddInvitedByToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :invited_by_id, references(:profiles, on_delete: :nilify_all)
    end

    create index(:accounts, [:invited_by_id])
  end
end
