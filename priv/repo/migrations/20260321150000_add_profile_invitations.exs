defmodule PotokIde.Repo.Migrations.AddProfileInvitations do
  use Ecto.Migration

  def change do
    create table(:profile_invitations) do
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false
      add :inviter_id, references(:profiles, on_delete: :delete_all), null: false
      add :invitee_id, references(:profiles, on_delete: :delete_all), null: false
      add :accepted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:profile_invitations, [:profile_id])
    create index(:profile_invitations, [:inviter_id])
    create index(:profile_invitations, [:invitee_id])

    create unique_index(:profile_invitations, [:profile_id, :invitee_id],
             where: "accepted_at IS NULL",
             name: :profile_invitations_profile_id_invitee_id_pending_index
           )
  end
end
