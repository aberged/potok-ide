defmodule PotokIde.Repo.Migrations.AddPushSubscriptions do
  use Ecto.Migration

  def change do
    create table(:push_subscriptions) do
      add :account_id, references(:accounts, on_delete: :delete_all), null: false
      add :endpoint, :string, null: false
      add :p256dh, :string, null: false
      add :auth, :string, null: false
      add :expires_at, :utc_datetime
      add :user_agent, :string
      add :last_success_at, :utc_datetime
      add :last_failure_at, :utc_datetime
      add :failure_reason, :string

      timestamps(type: :utc_datetime)
    end

    create index(:push_subscriptions, [:account_id])
    create unique_index(:push_subscriptions, [:endpoint])
  end
end
