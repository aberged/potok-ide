defmodule PotokIde.Repo.Migrations.AddIsPublicToAppProcesses do
  use Ecto.Migration

  # A drawn process that others call is private, for the processes of its own
  # group, or public: then the processes drawn in the groups above and below
  # its group may call it too. The index finds the public ones without
  # reading the rest, as those who may call them are looked up from them.
  def change do
    alter table(:app_processes) do
      add :is_public, :boolean, null: false, default: false
    end

    create constraint(:app_processes, :app_processes_public_check,
             check: "NOT is_public OR (drawn AND trigger = 'process')"
           )

    create index(:app_processes, [:group_id],
             where: "is_public",
             name: :app_processes_public_index
           )
  end
end
