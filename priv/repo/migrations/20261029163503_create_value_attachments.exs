defmodule PotokIde.Repo.Migrations.CreateValueAttachments do
  use Ecto.Migration

  def change do
    create table(:value_attachments) do
      add :value_id, references(:values, on_delete: :delete_all), null: false
      # The value's group, kept on the row so a group's files (and a tree of
      # sub-groups) are listed without joining through `values`.
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      # Same rule as `values.creator_id`: the uploader is the value's creator.
      add :profile_id, references(:profiles, on_delete: :restrict), null: false
      add :storage_key, :string, null: false
      add :filename, :string, null: false
      add :content_type, :string, null: false
      add :byte_size, :bigint, null: false

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:value_attachments, [:storage_key])
    create index(:value_attachments, [:value_id])
    # Newest files of a group first: a btree scans backwards for `ORDER BY id DESC`.
    create index(:value_attachments, [:group_id, :id])
    create index(:value_attachments, [:profile_id])

    create constraint(:value_attachments, :value_attachments_byte_size_check,
             check: "byte_size >= 0"
           )
  end
end
