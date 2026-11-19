defmodule PotokIde.Repo.Migrations.AddDeletedKindToProfiles do
  use Ecto.Migration

  # A profile whose person deleted their account stays, so what they wrote
  # stays in the groups (`PotokIde.Accounts.Deletion`): it becomes "deleted",
  # with no name, picture or description of theirs.
  def up do
    drop constraint(:profiles, :profiles_kind_check)

    create constraint(:profiles, :profiles_kind_check,
             check: "kind IN ('person', 'process', 'deleted')"
           )
  end

  def down do
    drop constraint(:profiles, :profiles_kind_check)
    create constraint(:profiles, :profiles_kind_check, check: "kind IN ('person', 'process')")
  end
end
