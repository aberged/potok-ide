defmodule PotokIde.Repo.Migrations.AddPushSubscriptionLocale do
  use Ecto.Migration

  def change do
    # The language of the session that saved the subscription, so a device
    # gets notifications in the language it uses. Nil: the default language.
    alter table(:push_subscriptions) do
      add :locale, :string
    end
  end
end
