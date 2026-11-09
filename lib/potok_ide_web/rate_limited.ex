defmodule PotokIdeWeb.RateLimited do
  @moduledoc "The message for a request `PotokIde.RateLimit` refused."

  use Gettext, backend: PotokIdeWeb.Gettext

  @doc "Says to try again after `retry_after_ms`, in whole minutes, at least one."
  def message(retry_after_ms) when is_integer(retry_after_ms) do
    minutes = max(1, ceil(retry_after_ms / 60_000))

    gettext("Too many requests in a short time. Try again in %{minutes} min.", minutes: minutes)
  end
end
