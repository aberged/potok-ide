defmodule PotokIde.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :potok_ide

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Switches the triggers that keep the history of groups (`PotokIde.History`)
  off, or on again, should one of them ever stand in the way of a write:
  `bin/potok_ide eval 'PotokIde.Release.history_triggers(:off)'`. What changes
  while they are off is missing from the history for good.
  """
  def history_triggers(state) when state in [:on, :off] do
    load_app()

    for repo <- repos() do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          for [table, trigger] <- history_trigger_names(repo) do
            verb = if state == :on, do: "ENABLE", else: "DISABLE"
            repo.query!("ALTER TABLE #{table} #{verb} TRIGGER #{trigger}")
          end
        end)
    end
  end

  defp history_trigger_names(repo) do
    repo.query!(
      "SELECT tgrelid::regclass::text, quote_ident(tgname) FROM pg_trigger " <>
        "WHERE tgname LIKE 'history%' AND NOT tgisinternal ORDER BY 1, 2"
    ).rows
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    # Many platforms require SSL when connecting to the database
    Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
