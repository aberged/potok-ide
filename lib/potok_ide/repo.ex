defmodule PotokIde.Repo do
  use Ecto.Repo,
    otp_app: :potok_ide,
    adapter: Ecto.Adapters.Postgres
end
