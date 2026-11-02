defmodule PotokIde.Repo.Migrations.CreateTags do
  use Ecto.Migration

  def change do
    # A tag without an owner is public: one shared vocabulary for the whole
    # app. A private tag belongs to the profile that made it.
    create table(:tags) do
      add :name, :string, null: false
      add :owner_id, references(:profiles, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:tags, ["lower(name)"],
             where: "owner_id IS NULL",
             name: :tags_public_lower_name_index
           )

    create unique_index(:tags, [:owner_id, "lower(name)"],
             where: "owner_id IS NOT NULL",
             name: :tags_owner_id_lower_name_index
           )

    # One tag on one item. Each item kind has its own column, so deleting the
    # item deletes its taggings.
    create table(:taggings) do
      add :tag_id, references(:tags, on_delete: :delete_all), null: false
      add :added_by_id, references(:profiles, on_delete: :nilify_all)

      add :group_id, references(:groups, on_delete: :delete_all)
      add :profile_id, references(:profiles, on_delete: :delete_all)
      add :event_id, references(:group_events, on_delete: :delete_all)
      add :value_id, references(:values, on_delete: :delete_all)
      add :attachment_id, references(:value_attachments, on_delete: :delete_all)

      timestamps(type: :utc_datetime, updated_at: false)
    end

    create constraint(:taggings, :taggings_one_target,
             check: "num_nonnulls(group_id, profile_id, event_id, value_id, attachment_id) = 1"
           )

    # Each leads with the item, so it also serves loading an item's tags.
    for column <- [:group_id, :profile_id, :event_id, :value_id, :attachment_id] do
      create unique_index(:taggings, [column, :tag_id],
               where: "#{column} IS NOT NULL",
               name: :"taggings_#{column}_tag_id_index"
             )
    end

    # The items of a tag, for the tags page.
    create index(:taggings, [:tag_id])
    create index(:taggings, [:added_by_id])
  end
end
