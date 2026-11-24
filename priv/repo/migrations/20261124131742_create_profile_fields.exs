defmodule PotokIde.Repo.Migrations.CreateProfileFields do
  use Ecto.Migration

  # A profile's details (`PotokIde.Social.ProfileField`): first and last name,
  # phone, contact email, place, links, occupation. A row only for a filled
  # field, each with who sees it: only the profile's own accounts, members of
  # picked groups, members of any group shared with the profile, or anyone
  # signed in (`PotokIde.Social.ProfileDetails`). Kept apart from `profiles`,
  # so no query of profiles carries them by chance.
  #
  # The description (about me) stays on `profiles` and gets the same choice;
  # existing descriptions stay seen only by the profile's own accounts, as
  # they were.
  def change do
    create table(:profile_fields) do
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :value, :text, null: false
      add :audience, :string, null: false, default: "only_me"
      # The picked groups, for `audience = 'groups'`. Ids of groups the
      # profile left or that are gone are only ignored.
      add :group_ids, {:array, :bigint}, null: false, default: []

      timestamps(type: :utc_datetime)
    end

    create unique_index(:profile_fields, [:profile_id, :key])

    create constraint(:profile_fields, :profile_fields_key_check,
             check:
               "key IN ('first_name', 'last_name', 'phone', 'email', 'place', 'website', 'occupation')"
           )

    create constraint(:profile_fields, :profile_fields_value_check,
             check: "char_length(value) BETWEEN 1 AND 500"
           )

    create constraint(:profile_fields, :profile_fields_audience_check,
             check: "audience IN ('only_me', 'groups', 'shared_groups', 'signed_in')"
           )

    create constraint(:profile_fields, :profile_fields_group_ids_check,
             check: "audience = 'groups' OR group_ids = '{}'"
           )

    alter table(:profiles) do
      add :description_audience, :string, null: false, default: "only_me"
      add :description_group_ids, {:array, :bigint}, null: false, default: []
    end

    create constraint(:profiles, :profiles_description_audience_check,
             check: "description_audience IN ('only_me', 'groups', 'shared_groups', 'signed_in')"
           )

    create constraint(:profiles, :profiles_description_group_ids_check,
             check: "description_audience = 'groups' OR description_group_ids = '{}'"
           )
  end
end
