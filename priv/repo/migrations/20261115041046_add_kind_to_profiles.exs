defmodule PotokIde.Repo.Migrations.AddKindToProfiles do
  use Ecto.Migration

  # A profile is a person's, or a process's: the profile that signs what an
  # app's process does (`PotokIde.Social.AppProcesses`), with no account behind
  # it. Every profile so far is a person's.
  def change do
    alter table(:profiles) do
      add :kind, :string, null: false, default: "person"
    end

    create constraint(:profiles, :profiles_kind_check, check: "kind IN ('person', 'process')")
  end
end
