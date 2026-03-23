defmodule PotokIde.Repo.Migrations.CreateGroupsAndMemberships do
  use Ecto.Migration

  def change do
    create table(:groups) do
      add :name, :string, null: false
      add :description, :text
      add :description_format, :string, null: false, default: "markdown"
      add :is_public, :boolean, null: false, default: false
      add :is_root, :boolean, null: false, default: false
      add :creator_id, references(:profiles, on_delete: :nilify_all)
      add :parent_id, references(:groups, on_delete: :restrict)

      timestamps(type: :utc_datetime)
    end

    create index(:groups, [:creator_id])
    create index(:groups, [:parent_id])
    create unique_index(:groups, [:is_root], where: "is_root")

    create constraint(:groups, :groups_description_format_check,
             check: "description_format IN ('markdown', 'html')"
           )

    create constraint(:groups, :groups_root_private_check, check: "NOT (is_root AND is_public)")

    create constraint(:groups, :groups_root_parent_check,
             check: "(is_root AND parent_id IS NULL) OR (NOT is_root AND parent_id IS NOT NULL)"
           )

    create constraint(:groups, :groups_root_creator_check,
             check: "(is_root AND creator_id IS NULL) OR (NOT is_root AND creator_id IS NOT NULL)"
           )

    execute(
      """
      INSERT INTO groups (name, description, description_format, is_public, is_root, creator_id, parent_id, inserted_at, updated_at)
      VALUES ('/', NULL, 'markdown', FALSE, TRUE, NULL, NULL, now(), now())
      """,
      "DELETE FROM groups WHERE is_root = TRUE AND name = '/'"
    )

    create table(:group_memberships, primary_key: false) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create index(:group_memberships, [:group_id])
    create index(:group_memberships, [:profile_id])
    create unique_index(:group_memberships, [:group_id, :profile_id])

    create table(:group_invitations) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :inviter_id, references(:profiles, on_delete: :delete_all), null: false
      add :invitee_id, references(:profiles, on_delete: :delete_all), null: false
      add :accepted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:group_invitations, [:group_id])
    create index(:group_invitations, [:inviter_id])
    create index(:group_invitations, [:invitee_id])

    create unique_index(:group_invitations, [:group_id, :invitee_id],
             where: "accepted_at IS NULL",
             name: :group_invitations_group_id_invitee_id_pending_index
           )
  end
end
