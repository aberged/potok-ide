defmodule PotokIde.Repo.Migrations.CreateValueReactions do
  use Ecto.Migration

  def change do
    create table(:value_reactions) do
      add :value_id, references(:values, on_delete: :delete_all), null: false
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false
      add :emoji, :string, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    # Leads with value_id, so it also serves loading a value's reactions.
    create unique_index(:value_reactions, [:value_id, :profile_id, :emoji],
             name: :value_reactions_value_id_profile_id_emoji_index
           )

    create index(:value_reactions, [:profile_id])
  end
end
