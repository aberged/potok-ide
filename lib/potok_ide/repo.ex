defmodule PotokIde.Repo do
  use Ecto.Repo,
    otp_app: :potok_ide,
    adapter: Ecto.Adapters.Postgres

  @doc """
  Runs `fun` in a transaction whose statements stop after `ms` milliseconds:
  for reads that scan as many rows as an app keeps, so that a big one fails
  instead of holding a page and a connection. `jit: false` also keeps Postgres
  from compiling them, which costs more than it saves on such reads.

  Returns `{:ok, result}`, or `{:error, :timeout}` when a statement ran out of
  time. Inside another transaction the settings last until that one ends.
  """
  def with_statement_timeout(ms, fun, opts \\ []) when is_integer(ms) and ms > 0 do
    transaction(fn ->
      query!("SET LOCAL statement_timeout = #{ms}")
      if Keyword.get(opts, :jit, true) == false, do: query!("SET LOCAL jit = off")
      fun.()
    end)
  rescue
    error in Postgrex.Error ->
      case error do
        %{postgres: %{code: :query_canceled}} -> {:error, :timeout}
        _other -> reraise error, __STACKTRACE__
      end
  end
end
