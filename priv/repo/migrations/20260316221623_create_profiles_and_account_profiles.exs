defmodule PotokIde.Repo.Migrations.CreateProfilesAndAccountProfiles do
  use Ecto.Migration

  def change do
    create table(:profiles) do
      add :username, :string, null: false
      add :profile_picture_url, :string
      add :description, :text
      add :description_format, :string, null: false, default: "markdown"
      add :sharing, :string, null: false, default: "unique"

      timestamps(type: :utc_datetime)
    end

    create constraint(:profiles, :profiles_description_format_check,
             check: "description_format IN ('markdown', 'html')"
           )

    create constraint(:profiles, :profiles_sharing_check,
             check: "sharing IN ('unique', 'shared')"
           )

    create table(:accounts_profiles, primary_key: false) do
      add :account_id, references(:accounts, on_delete: :delete_all), null: false
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:accounts_profiles, [:account_id])
    create index(:accounts_profiles, [:profile_id])
    create unique_index(:accounts_profiles, [:account_id, :profile_id])
  end
end
