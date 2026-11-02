defmodule PotokIde.LinkPreviewsTestResolver do
  @moduledoc """
  Stands in for DNS in tests (`PotokIde.LinkPreviews` `:resolver` config):
  `*.internal.test` hosts resolve to a private address, every other host to
  a public documentation one (TEST-NET-3).
  """

  def resolve(host) do
    if String.ends_with?(host, ".internal.test"),
      do: {:ok, [{10, 0, 0, 5}]},
      else: {:ok, [{203, 0, 113, 10}]}
  end
end
