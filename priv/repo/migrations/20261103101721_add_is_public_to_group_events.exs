defmodule PotokIde.Repo.Migrations.AddIsPublicToGroupEvents do
  use Ecto.Migration

  def change do
    # Every profile sees a public event in its calendar, not only members.
    alter table(:group_events) do
      add :is_public, :boolean, null: false, default: false
    end

    # The root calendar's "public events" filter.
    create index(:group_events, [:starts_at], where: "is_public AND cancelled_at IS NULL")
  end
end
