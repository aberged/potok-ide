defmodule PotokIde.Repo.Migrations.FixProfileInvitationsToUseProfiles do
  use Ecto.Migration

  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM information_schema.columns
        WHERE table_name = 'profile_invitations' AND column_name = 'inviter_account_id'
      ) THEN
        DROP TABLE profile_invitations;

        CREATE TABLE profile_invitations (
          id bigserial PRIMARY KEY,
          profile_id bigint NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
          inviter_id bigint NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
          invitee_id bigint NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
          accepted_at timestamp(0) with time zone,
          inserted_at timestamp(0) with time zone NOT NULL,
          updated_at timestamp(0) with time zone NOT NULL
        );

        CREATE INDEX profile_invitations_profile_id_index ON profile_invitations (profile_id);
        CREATE INDEX profile_invitations_inviter_id_index ON profile_invitations (inviter_id);
        CREATE INDEX profile_invitations_invitee_id_index ON profile_invitations (invitee_id);

        CREATE UNIQUE INDEX profile_invitations_profile_id_invitee_id_pending_index
          ON profile_invitations (profile_id, invitee_id)
          WHERE accepted_at IS NULL;
      END IF;
    END
    $$;
    """)
  end

  def down, do: :ok
end
