defmodule PotokIde.Repo.Migrations.AddNativePushSubscriptions do
  use Ecto.Migration

  def change do
    alter table(:push_subscriptions) do
      add :subscription_type, :string, null: false, default: "web_push"
      add :device_token, :text
      add :device_platform, :string

      modify :endpoint, :string, null: true
      modify :p256dh, :string, null: true
      modify :auth, :string, null: true
    end

    create unique_index(:push_subscriptions, [:device_token],
             where: "device_token IS NOT NULL",
             name: :push_subscriptions_device_token_index
           )
  end
end
