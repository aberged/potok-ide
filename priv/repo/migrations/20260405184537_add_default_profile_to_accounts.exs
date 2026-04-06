defmodule PotokIde.Repo.Migrations.AddDefaultProfileToAccounts do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add :default_profile_id, references(:profiles, on_delete: :nilify_all)
    end

    execute(
      "UPDATE accounts SET default_profile_id = current_profile_id WHERE current_profile_id IS NOT NULL"
    )

    create index(:accounts, [:default_profile_id])
  end
end
