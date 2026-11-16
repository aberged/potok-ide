defmodule PotokIde.Repo.Migrations.AddVarsToValueProcesses do
  use Ecto.Migration

  # What the variables of a run hold, by name: a process drawn in Potok
  # declares them in its graph, its steps set them, and each run keeps its
  # own (`PotokIde.Processes.Engine`).
  def change do
    alter table(:value_processes) do
      add :vars, :map, null: false, default: %{}
    end
  end
end
