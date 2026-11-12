defmodule PotokIdeWeb.HostingCostHTML do
  @moduledoc """
  The page `/troskovi` (`PotokIdeWeb.HostingCostController`), in the look of
  `/stack`, with its words in the `costs` Gettext domain.
  """

  use PotokIdeWeb, :html

  alias PotokIde.Events.Format

  embed_templates "hosting_cost_html/*"

  def lead do
    dgettext(
      "costs",
      "Potok runs on Fly.io and pays for it every month, in US dollars. Fly gives no way to read its bills, so Potok estimates them itself every quarter of an hour, from what runs and Fly's price list. Once a month is billed, the real sum stands next to the estimate."
    )
  end

  def category_name(:machines), do: dgettext("costs", "Machines")
  def category_name(:postgres), do: dgettext("costs", "Database")
  def category_name(:storage), do: dgettext("costs", "Stored files")
  def category_name(:bandwidth), do: dgettext("costs", "Data sent")
  def category_name(:ips), do: dgettext("costs", "IP addresses")

  def category_text(:machines), do: dgettext("costs", "the app's server")
  def category_text(:postgres), do: dgettext("costs", "Managed Postgres, plan and data")
  def category_text(:storage), do: dgettext("costs", "pictures and files, in Tigris")
  def category_text(:bandwidth), do: dgettext("costs", "pages and files sent out")
  def category_text(:ips), do: dgettext("costs", "dedicated IPv4 addresses")

  @doc "A sum in US dollars, written the way the page's language writes numbers."
  def usd(nil, _locale), do: "—"

  def usd(%Decimal{} = amount, locale) do
    cents = amount |> Decimal.round(2) |> Decimal.to_string(:normal)
    [whole, fraction] = String.split(cents <> if(cents =~ ".", do: "", else: ".00"), ".")

    {sign, whole} =
      if String.starts_with?(whole, "-"),
        do: {"−", String.trim_leading(whole, "-")},
        else: {"", whole}

    fraction = String.pad_trailing(fraction, 2, "0")

    case locale do
      "en" -> "#{sign}$#{group(whole, ",")}.#{fraction}"
      _serbian -> "#{sign}#{group(whole, ".")},#{fraction} $"
    end
  end

  defp group(digits, separator) do
    digits
    |> String.reverse()
    |> String.graphemes()
    |> Enum.chunk_every(3)
    |> Enum.map_join(separator, &Enum.join/1)
    |> String.reverse()
  end

  def month_name(%Date{month: month, year: year}), do: "#{Format.month_name(month)} #{year}"

  def month_key(%Date{} = month), do: Calendar.strftime(month, "%Y-%m")

  def date_text(%Date{} = date, "en"),
    do: "#{date.day} #{Format.month_name(date.month)} #{date.year}"

  def date_text(%Date{} = date, _serbian),
    do: "#{date.day}. #{Format.month_name(date.month)} #{date.year}"

  def date_text(%DateTime{} = at, locale), do: date_text(DateTime.to_date(at), locale)

  def time_text(%DateTime{} = at), do: Calendar.strftime(at, "%H:%M") <> " UTC"

  @doc "How wide a bar is, in percent of `max`; a sum above zero is never invisible."
  def share(nil, _max), do: 0

  def share(%Decimal{} = amount, %Decimal{} = max) do
    if Decimal.gt?(max, 0) do
      percent = amount |> Decimal.div(max) |> Decimal.mult(100) |> Decimal.to_float()
      if percent > 0, do: max(Float.round(percent, 2), 0.8), else: 0
    else
      0
    end
  end

  @doc "The biggest sum the bars of `entries` compare against."
  def max_of(sums) do
    sums
    |> Enum.reject(&is_nil/1)
    |> Enum.reduce(Decimal.new(0), &Decimal.max/2)
  end

  def months_max(months),
    do: max_of(Enum.flat_map(months, &[&1.estimate, &1.invoice && &1.invoice.amount_usd]))

  @doc "What the invoice differs from the estimate by, and by how many percent of the invoice."
  def difference(%{estimate: %Decimal{} = estimate, invoice: %{amount_usd: billed}}, locale) do
    diff = Decimal.sub(estimate, billed)

    percent =
      if Decimal.gt?(billed, 0) do
        diff
        |> Decimal.div(billed)
        |> Decimal.mult(100)
        |> Decimal.round(0)
        |> Decimal.to_integer()
      end

    sign = if Decimal.gt?(diff, 0), do: "+", else: ""
    text = sign <> usd(diff, locale)

    case percent do
      nil -> text
      percent -> "#{text} (#{percent_text(percent, locale)})"
    end
  end

  def difference(_month, _locale), do: nil

  defp percent_text(percent, locale) do
    number =
      cond do
        percent > 0 -> "+#{percent}"
        percent < 0 -> "−#{-percent}"
        true -> "0"
      end

    if locale == "en", do: number <> "%", else: number <> " %"
  end
end
