defmodule PotokIde.Repo.Migrations.TurnOffJitForRole do
  use Ecto.Migration

  # JIT off for the app's own role, where `TurnOffJit` could not reach the
  # database: on Fly Managed Postgres the role does not own it, but any role
  # may set its own defaults. A session-level SET or a startup parameter
  # would not do: PgBouncer's transaction mode hands every transaction a
  # server connection of its own. A role default holds for every server
  # connection opened from then on; those already open keep JIT until the
  # pooler renews them.
  def up, do: set("SET jit = off")

  def down, do: set("RESET jit")

  defp set(clause) do
    execute """
    DO $$
    BEGIN
      EXECUTE 'ALTER ROLE CURRENT_USER #{clause}';
    EXCEPTION WHEN insufficient_privilege THEN
      RAISE NOTICE 'jit stays as it was: no right to alter the role';
    END
    $$
    """
  end
end
