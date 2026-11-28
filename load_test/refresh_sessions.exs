# Seeded sessions expire after 14 days (AccountToken @session_validity_in_days and
# the remember-me cookie's max_age). This brings an old seed back without reseeding:
# it re-signs each user's remember-me cookie in results/users_<n>.csv with today's
# time (same token). Move the tokens' dates in every database that holds the seed:
#
#   docker compose exec -T db psql -U postgres -d potok_load_1k \
#     -c "UPDATE accounts_tokens SET inserted_at = now(), authenticated_at = now() WHERE context = 'session'"
#
# Run over rpc in the app container (it has the secret_key_base the cookies use):
#   docker compose exec -T app /app/bin/potok_ide rpc \
#     'Code.eval_file("/load_test/refresh_sessions.exs"); LoadTest.RefreshSessions.run(1000)'
defmodule LoadTest.RefreshSessions do
  @salt "_potok_ide_web_account_remember_me_cookie"
  @max_age 14 * 24 * 60 * 60

  def run(n) do
    path = "/load_test/results/users_#{n}.csv"
    secret = PotokIdeWeb.Endpoint.config(:secret_key_base)
    [header | lines] = path |> File.read!() |> String.split("\n", trim: true)

    lines =
      Enum.map(lines, fn line ->
        [profile_id, username, cookie | rest] = String.split(line, ",")

        {:ok, token} =
          Plug.Crypto.verify(secret, @salt, cookie, keys: Plug.Keys, max_age: :infinity)

        fresh = Plug.Crypto.sign(secret, @salt, token, keys: Plug.Keys, max_age: @max_age)
        Enum.join([profile_id, username, fresh | rest], ",")
      end)

    File.write!(path, Enum.join([header | lines], "\n") <> "\n")
    IO.puts("re-signed #{length(lines)} cookies in #{path}")
  end
end
