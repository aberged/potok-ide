defmodule PotokIde.Repo.Migrations.AddGmailRefreshTokens do
  use Ecto.Migration

  def change do
    create table(:gmail_refresh_tokens) do
      add :provider, :string, null: false
      add :refresh_token, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:gmail_refresh_tokens, [:provider])
  end
end
