defmodule PotokIde.Repo.Migrations.AddValuesLinkPreview do
  use Ecto.Migration

  # The Open Graph card of a chat value's first link, fetched after the value
  # is posted (`PotokIde.LinkPreviews`). A dismissed preview is never fetched
  # again for that value.
  def change do
    alter table(:values) do
      add :link_preview, :map
      add :link_preview_dismissed, :boolean, null: false, default: false
    end
  end
end
