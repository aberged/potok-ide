defmodule PotokIde.Repo.Migrations.AddPresetToGroups do
  use Ecto.Migration

  # The ready setup a group was made from (`PotokIde.Social.GroupPresets`).
  # Groups made before this one stay nil: nothing is guessed for them.
  def change do
    alter table(:groups) do
      add :preset, :string
    end

    create constraint(:groups, :groups_preset_check,
             check:
               "preset IN ('chat', 'folder', 'announcements', 'feed', 'polls', 'questionnaire', 'page')"
           )
  end
end
