defmodule PotokIde.Repo.Migrations.CreateRateLimitCounters do
  use Ecto.Migration

  # The counters of the limits all machines share (`PotokIde.RateLimit`).
  # `key` is a hash of the limit's name and what it counts, so no address or
  # IP is kept; `slot` is the window, by the wall clock. Unlogged: no WAL for
  # a counter, which a crash of the database may only reset.
  def up do
    execute """
    CREATE UNLOGGED TABLE rate_limit_counters (
      key bytea NOT NULL,
      slot bigint NOT NULL,
      count integer NOT NULL,
      expires_at timestamptz NOT NULL,
      PRIMARY KEY (key, slot)
    )
    """

    create index(:rate_limit_counters, [:expires_at])
  end

  def down do
    drop table(:rate_limit_counters)
  end
end
