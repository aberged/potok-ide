defmodule PotokIde.Repo.Migrations.AddGuestDescriptions do
  use Ecto.Migration

  # A public group can open its description to guests, people without an
  # account who have its link (`Group.guest_description?/1`), and each of its
  # alternative descriptions can be marked to go with it. A description only
  # some roles see is never one of them.
  def change do
    alter table(:groups) do
      add :description_for_guests, :boolean, null: false, default: false
    end

    alter table(:group_alt_descriptions) do
      add :for_guests, :boolean, null: false, default: false
    end

    create constraint(:group_alt_descriptions, :group_alt_descriptions_for_guests_check,
             check: "NOT for_guests OR cardinality(visible_role_keys) = 0"
           )
  end
end
