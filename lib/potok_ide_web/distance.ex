defmodule PotokIdeWeb.Distance do
  @moduledoc """
  A distance as a person reads it, such as a route's length: "850 m",
  "1.3 km" ("1,3 km" in Serbian), "12 km". Metres to the nearest ten below a
  kilometre, one decimal below ten kilometres, whole kilometres above.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  @doc "The distance of `meters` in the current locale."
  def text(meters) when is_number(meters) and meters < 995,
    do: "#{round(meters / 10) * 10} m"

  def text(meters) when is_number(meters) and meters < 9_950 do
    kilometres = :erlang.float_to_binary(meters / 1000, decimals: 1)
    String.replace(kilometres, ".", pgettext("decimal separator", ".")) <> " km"
  end

  def text(meters) when is_number(meters), do: "#{round(meters / 1000)} km"
end
