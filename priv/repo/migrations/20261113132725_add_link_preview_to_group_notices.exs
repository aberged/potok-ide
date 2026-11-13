defmodule PotokIde.Repo.Migrations.AddLinkPreviewToGroupNotices do
  use Ecto.Migration

  # The Open Graph card of a notice's first link, fetched once after the notice
  # is sent (`PotokIde.LinkPreviews`). A notice is never edited, so a removed
  # card is never fetched again and needs no mark of its own.
  def change do
    alter table(:group_notices) do
      add :link_preview, :map
    end
  end
end
