defmodule PotokIde.Repo.Migrations.TurnOffJit do
  use Ecto.Migration

  # Postgres compiles a query it thinks costly to machine code, which takes
  # longer than the short queries of a page run (seen in the list and tree
  # queries; `Repo.with_statement_timeout/3` turned it off for those). Off
  # for the whole database, for new connections. A role without the right to
  # alter the database leaves it as it was, without failing the deploy.
  def up, do: set("SET jit = off")

  def down, do: set("RESET jit")

  defp set(clause) do
    execute """
    DO $$
    BEGIN
      EXECUTE format('ALTER DATABASE %I #{clause}', current_database());
    EXCEPTION WHEN insufficient_privilege THEN
      RAISE NOTICE 'jit stays as it was: no right to alter the database';
    END
    $$
    """
  end
end
