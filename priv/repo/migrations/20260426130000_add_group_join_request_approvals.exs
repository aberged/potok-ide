defmodule PotokIde.Repo.Migrations.AddGroupJoinRequestApprovals do
  use Ecto.Migration

  def change do
    create table(:group_join_request_approvals) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :requester_id, references(:profiles, on_delete: :delete_all), null: false
      add :approver_id, references(:profiles, on_delete: :delete_all), null: false
      add :approved_at, :utc_datetime, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:group_join_request_approvals, [:approver_id, :approved_at, :id],
             name: :group_join_request_approvals_approver_order_index
           )

    create index(:group_join_request_approvals, [:group_id])
    create index(:group_join_request_approvals, [:requester_id])
  end
end
