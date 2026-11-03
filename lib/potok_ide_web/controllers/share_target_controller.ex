defmodule PotokIdeWeb.ShareTargetController do
  use PotokIdeWeb, :controller

  # Long enough for a shared article excerpt, short enough for a URL.
  @max_param_length 2_000

  @doc """
  The installed web app's share target when no service worker took the post:
  the shared text goes on to `/share` in the query. Files need the worker,
  which keeps them on the device, so they are dropped here.
  """
  def create(conn, params) do
    query =
      for key <- ~w(title text url),
          value = params[key],
          is_binary(value),
          value = String.slice(String.trim(value), 0, @max_param_length),
          value != "",
          do: {key, value}

    conn
    |> put_status(:see_other)
    |> redirect(to: ~p"/share?#{query}")
  end
end
