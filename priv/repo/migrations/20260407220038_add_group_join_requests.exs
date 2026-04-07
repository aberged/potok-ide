defmodule PotokIde.Repo.Migrations.AddGroupJoinRequests do
  use Ecto.Migration

  def change do
    create table(:group_join_requests) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :requester_id, references(:profiles, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:group_join_requests, [:group_id])
    create index(:group_join_requests, [:requester_id])
    create unique_index(:group_join_requests, [:group_id, :requester_id])
  end
end
