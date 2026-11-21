defmodule PotokIde.Social.AppBuilds.Fingerprint do
  @moduledoc """
  What an app's HTML is, whatever form it came through: a hex sha256 of it
  without its `potok-app` tag, with LF line endings and no white space
  around. Its own module, as `PotokIde.Social.AppBuilds` reads the builds'
  fingerprints while it compiles.
  """

  @tag ~r/<meta\s+name="potok-app"[^>]*>\s*/i

  def of(html) when is_binary(html) do
    html
    |> String.replace(@tag, "")
    |> String.replace("\r\n", "\n")
    |> String.trim()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
