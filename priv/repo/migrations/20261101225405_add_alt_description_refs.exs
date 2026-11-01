defmodule PotokIde.Repo.Migrations.AddAltDescriptionRefs do
  use Ecto.Migration

  def change do
    alter table(:groups) do
      # Label of the default description next to the alternative ones.
      add :description_name, :string
      # Opened instead of the default description; nil opens the default.
      add :home_alt_description_id,
          references(:group_alt_descriptions, on_delete: :nilify_all)
    end

    # nil: data of the default description's app, which is every row so far.
    alter table(:values) do
      add :alt_description_id,
          references(:group_alt_descriptions,
            with: [group_id: :group_id],
            on_delete: :delete_all
          )
    end
  end
end
