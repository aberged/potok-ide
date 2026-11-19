defmodule PotokIde.Repo.Migrations.AddRelatedSignals do
  use Ecto.Migration

  # A signal reaches the groups above and below its group where the receiver
  # asks for it (`PotokIde.Processes.Engine`): a process that starts on a
  # signal and hears those groups (`hears_related`), or a run waiting for
  # one at a step that does (`related_signal`, the name, kept while it waits).
  # Both are found by the signal's name, never by walking down the tree.
  def change do
    alter table(:app_processes) do
      add :hears_related, :boolean, null: false, default: false
    end

    create constraint(:app_processes, :app_processes_hears_related_check,
             check: "NOT hears_related OR (drawn AND trigger = 'signal')"
           )

    create index(:app_processes, ["(trigger_config ->> 'name')"],
             name: :app_processes_hears_related_index,
             where: "hears_related"
           )

    alter table(:value_processes) do
      add :related_signal, :text
    end

    create index(:value_processes, [:related_signal],
             name: :value_processes_related_signal_index,
             where: "related_signal IS NOT NULL"
           )
  end
end
