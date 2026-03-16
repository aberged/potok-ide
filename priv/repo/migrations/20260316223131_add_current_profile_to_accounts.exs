defmodule PotokIde.Repo.Migrations.AddCurrentProfileToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :current_profile_id, references(:profiles, on_delete: :nilify_all)
    end

    create index(:accounts, [:current_profile_id])
  end
end
