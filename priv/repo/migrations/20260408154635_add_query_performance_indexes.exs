defmodule PotokIde.Repo.Migrations.AddQueryPerformanceIndexes do
  use Ecto.Migration

  def change do
    create unique_index(:profiles, [:username])

    create index(:groups, [:parent_id, :name], name: :groups_parent_name_index)

    create index(:values, [:group_id, :inserted_at, :id],
             where: "is_data = false",
             name: :values_group_chat_order_index
           )

    create index(:values, [:group_id, :inserted_at, :id],
             where: "is_data = true",
             name: :values_group_data_order_index
           )

    create index(:group_invitations, [:invitee_id, :inserted_at],
             where: "accepted_at IS NULL",
             name: :group_invitations_pending_invitee_index
           )

    create index(:profile_invitations, [:invitee_id, :inserted_at],
             where: "accepted_at IS NULL",
             name: :profile_invitations_pending_invitee_index
           )

    create index(:push_subscriptions, [:account_id, :updated_at],
             name: :push_subscriptions_account_updated_at_index
           )

    create index(:group_join_requests, [:group_id, :inserted_at, :id],
             name: :group_join_requests_group_order_index
           )
  end
end
