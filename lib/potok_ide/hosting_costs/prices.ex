defmodule PotokIde.HostingCosts.Prices do
  @moduledoc """
  Fly's price list, in US dollars, as the estimate in `PotokIde.HostingCosts`
  uses it. Fly gives no API for prices or bills, so the numbers are copied from
  docs.fly.io/about/pricing on `checked_on`; the page shows that date.

  A started machine costs its vCPUs, each with a little RAM included, plus the
  RAM above that, per second, times the markup of its region (the formula of
  Fly's own price table: `shared-cpu-1x` with 1 GB in `fra` comes to $7.73 in
  30 days). A stopped one costs only its root filesystem.

  Monthly prices (a database plan, a dedicated IPv4, stored gigabytes) are
  spread over the hours of the month they fall in, so a whole month adds up to
  the monthly price.

  `config :potok_ide, PotokIde.HostingCosts, prices: [...]` overrides any key.
  """

  @defaults [
    checked_on: ~D[2026-11-12],
    vcpu_second: %{"shared" => 8.465e-7, "performance" => 1.2732e-5},
    included_ram_gb_per_vcpu: %{"shared" => 0.25, "performance" => 2.0},
    ram_gb_second: 2.316e-6,
    region_markup: %{
      "ams" => 1.038461538,
      "arn" => 1.038461538,
      "cdg" => 1.134615385,
      "dfw" => 1.25,
      "ewr" => 1.0,
      "fra" => 1.153846154,
      "gru" => 1.615384615,
      "iad" => 1.0,
      "jnb" => 1.302884615,
      "lax" => 1.199519231,
      "lhr" => 1.134615385,
      "nrt" => 1.307692308,
      "ord" => 1.25,
      "sin" => 1.269230769,
      "sjc" => 1.192307692,
      "syd" => 1.269230769,
      "yyz" => 1.115384615
    },
    # Fly does not say how big a stopped machine's root filesystem is.
    rootfs_gb: 1.0,
    rootfs_gb_month: 0.15,
    postgres_plans: %{
      "basic" => 38.0,
      "starter" => 72.0,
      "launch" => 282.0,
      "scale" => 962.0,
      "performance" => 1922.0
    },
    postgres_gb_month: 0.28,
    # Tigris at its list price, which Fly bills. Whether Tigris's own free
    # 5 GB count through Fly is not written anywhere, so none are assumed.
    storage_gb_month: 0.02,
    storage_free_gb: 0.0,
    # Data sent out, by the region it leaves Fly from. A region not listed is
    # priced as North America and Europe.
    bandwidth_gb: %{"na_eu" => 0.02, "apac_sa" => 0.04, "africa_india" => 0.12},
    bandwidth_zones: %{
      "apac_sa" => ~w(bog eze gig gru hkg nrt scl sin syd),
      "africa_india" => ~w(bom jnb maa)
    },
    ipv4_month: 2.0
  ]

  def get(key), do: Keyword.fetch!(config(), key)

  def checked_on, do: get(:checked_on)

  @doc """
  What a machine costs per second, from its `guest` as the Machines API gives
  it (`cpu_kind`, `cpus`, `memory_mb`) and its region.
  """
  def machine_per_second(%{"cpu_kind" => kind, "cpus" => cpus, "memory_mb" => memory_mb}, region) do
    kind = if kind == "performance", do: "performance", else: "shared"
    ram_gb = memory_mb / 1024
    extra_ram_gb = max(ram_gb - cpus * get(:included_ram_gb_per_vcpu)[kind], 0)

    (cpus * get(:vcpu_second)[kind] + extra_ram_gb * get(:ram_gb_second)) * markup(region)
  end

  @doc "What a stopped machine's root filesystem costs in one hour of `month_hours`."
  def rootfs_per_hour(month_hours), do: get(:rootfs_gb) * get(:rootfs_gb_month) / month_hours

  @doc "The monthly price of a Managed Postgres plan, or nil for a plan not on the list."
  def postgres_plan(plan), do: get(:postgres_plans)[plan]

  def bandwidth_per_gb(region) do
    zone =
      Enum.find_value(get(:bandwidth_zones), "na_eu", fn {zone, regions} ->
        if region in regions, do: zone
      end)

    get(:bandwidth_gb)[zone]
  end

  defp markup(region), do: Map.get(get(:region_markup), region, 1.0)

  defp config do
    overrides =
      :potok_ide
      |> Application.get_env(PotokIde.HostingCosts, [])
      |> Keyword.get(:prices, [])

    Keyword.merge(@defaults, overrides)
  end
end
