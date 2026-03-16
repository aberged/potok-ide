defmodule PotokIde.Repo.Migrations.CreateValues do
  use Ecto.Migration

  def change do
    create table(:values) do
      add :content, :text, null: false
      add :content_format, :string, null: false, default: "markdown"
      add :creator_id, references(:profiles, on_delete: :restrict), null: false
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :parent_id, references(:values, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create index(:values, [:creator_id])
    create index(:values, [:group_id])
    create index(:values, [:parent_id])

    create constraint(:values, :values_content_format_check,
             check: "content_format IN ('markdown', 'html')"
           )
  end
end
