defmodule PotokIde.HostingCosts do
  @moduledoc """
  What Potok costs on Fly, for the public page `/troskovi`.

  Fly gives no API for bills, so Potok estimates them: `sample/1`
  (`PotokIde.HostingCosts.Sampler`, every 15 minutes) reads what runs (the
  machines of the apps in `FLY_COSTS_APPS`, the database's size, the stored
  files, the dedicated IPv4 addresses and the bytes sent out) and writes what
  each hour of each thing cost by the price list
  (`PotokIde.HostingCosts.Prices`) as `CostHour` rows.

  The current hour is written again on every pass, and the hour before it once
  more for the bytes sent, which Fly's metrics only have in full once the hour
  is over. Every hour of the month a pass finds missing (before Potok began
  estimating, while the app was down or Fly did not answer) is filled in, and
  at least `@backfill_hours` back: the machines and the bytes sent from Fly's
  metrics of that hour (which Fly keeps for about ten days; older hours take
  the earliest machine the metrics know), the stored files from when they
  were sent, the rest from what runs now. Such rows say so in `detail`. Each
  category is filled on its own, so a source that failed is asked again next
  time without touching the others. The rows of an hour are replaced, never
  added twice, so every node of a cluster may sample.

  What Fly actually billed is copied from the invoice by an operator
  (`PotokIde.Operators`) as an `Invoice`, and the page shows both.
  """

  import Ecto.Query, warn: false

  require Logger

  alias PotokIde.{Cache, Operators, Repo}
  alias PotokIde.HostingCosts.{CostHour, Fly, Invoice, Prices}
  alias PotokIde.Social.ValueAttachment

  @backfill_hours 72
  @cache_key {:hosting_costs, :overview}
  @cache_ttl :timer.minutes(10)
  # The bytes sent out in the next hours are guessed from this many before.
  @bandwidth_window_hours 24 * 7
  @running ~w(started starting stopping replacing updating)
  @stopped ~w(stopped suspended suspending)
  @gib 1_073_741_824

  @doc "Whether Potok can read Fly, and so estimate anything."
  def estimating?, do: Fly.token() != nil and apps() != []

  @doc "The Fly apps whose machines are counted."
  def apps, do: config()[:apps] || []

  @doc "The Managed Postgres plan the database is on."
  def postgres_plan, do: config()[:postgres_plan] || "basic"

  ## Estimating

  @doc """
  Writes the estimate of the hours that are due at `now`: the current one,
  the one before it, and those found missing. Returns how many rows it wrote.
  """
  def sample(now \\ DateTime.utc_now()) do
    current = hour_of(now)
    hours = hours_due(current)
    recorded = recorded(hours)

    due =
      for hour <- hours,
          category <- CostHour.categories(),
          write?(hour, category, current, recorded),
          do: {hour, category}

    snapshot = snapshot()
    history = history(due, current)

    count =
      due
      |> Enum.flat_map(fn {hour, category} ->
        rows(category, hour, snapshot, history, current, now)
      end)
      |> Enum.chunk_every(2_000)
      |> Enum.reduce(0, fn rows, count ->
        {written, _} =
          Repo.insert_all(CostHour, rows,
            on_conflict: {:replace, [:quantity, :amount_usd, :detail, :updated_at]},
            conflict_target: [:hour, :category, :item]
          )

        count + written
      end)

    Cache.delete(@cache_key)
    count
  end

  # The month so far, and at least `@backfill_hours` back across its start.
  defp hours_due(current) do
    month_start = DateTime.new!(month_of(current), ~T[00:00:00], "Etc/UTC")

    hours_between(
      Enum.min([month_start, add_hours(current, -@backfill_hours)], DateTime),
      current
    )
  end

  defp recorded(hours) do
    from(c in CostHour,
      where: c.hour >= ^List.first(hours) and c.hour <= ^List.last(hours),
      distinct: true,
      select: {c.hour, c.category}
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp write?(hour, _category, current, _recorded) when hour == current, do: true

  defp write?(hour, :bandwidth, current, recorded),
    do: hour == add_hours(current, -1) or not MapSet.member?(recorded, {hour, :bandwidth})

  defp write?(hour, category, _current, recorded),
    do: not MapSet.member?(recorded, {hour, category})

  # What runs now, read once per pass. A source that fails is `:error`, and its
  # category is written on a later pass.
  defp snapshot do
    %{
      machines: collect(apps(), &Fly.machines/1),
      ipv4: collect(apps(), &Fly.dedicated_ipv4_count/1),
      postgres_bytes: database_bytes(),
      storage_bytes: stored_bytes()
    }
  end

  # What the past hours that are due were like, read only for the categories
  # that have such hours: the machines and the bytes sent from Fly's metrics,
  # the stored files from when they were sent.
  defp history(due, current) do
    past = for {hour, category} <- due, hour != current, do: {category, hour}
    by_category = Enum.group_by(past, &elem(&1, 0), &elem(&1, 1))

    %{
      machines: hourly(by_category[:machines], &machine_history/2),
      bandwidth: hourly(by_category[:bandwidth], &bandwidth_history/2),
      storage: hourly(by_category[:storage], &storage_history/2)
    }
  end

  defp hourly(nil, _fun), do: :none

  defp hourly(hours, fun) do
    {first, last} = Enum.min_max_by(hours, &DateTime.to_unix/1)
    fun.(first, last)
  end

  # Each hour's running machines: how much of the hour each one ran (its
  # samples against the most any machine had), its size from the memory and
  # the processors it saw, and whether its processors are shared.
  defp machine_history(first, last) do
    with {:ok, metrics} <- Fly.machines_hourly(apps(), add_hours(first, 1), add_hours(last, 1)) do
      by_hour =
        Map.new(metrics.samples, fn {hour_end, series} ->
          full = series |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)

          machines =
            for {metric, samples} <- series, samples > 0 and full > 0 do
              instance = metric["instance"]

              %{
                instance: instance,
                app: metric["app"],
                region: metric["region"],
                fraction: min(samples / full, 1.0),
                guest:
                  guest(
                    value_of(metrics.cpus, hour_end, instance),
                    value_of(metrics.memory, hour_end, instance),
                    value_of(metrics.baseline, hour_end, instance)
                  )
              }
            end

          {DateTime.from_unix!(hour_end - 3600), with_sizes(machines)}
        end)

      # The earliest hour with a machine of known size, which stands in for
      # the hours before the metrics.
      earliest =
        by_hour
        |> Enum.reject(fn {_hour, machines} -> machines == [] end)
        |> Enum.min_by(fn {hour, _} -> DateTime.to_unix(hour) end, fn -> nil end)
        |> case do
          nil -> nil
          {hour, machines} -> {hour, Enum.max_by(machines, & &1.fraction)}
        end

      {:ok, %{by_hour: by_hour, earliest: earliest}}
    end
  end

  defp value_of(metrics, hour_end, instance) do
    metrics
    |> Map.get(hour_end, [])
    |> Enum.find_value(fn {metric, value} -> if metric["instance"] == instance, do: value end)
  end

  # A machine of a few seconds (a release command) may have no size in the
  # metrics: it gets the size of the machine that ran longest that hour.
  defp with_sizes(machines) do
    main = machines |> Enum.filter(& &1.guest) |> Enum.max_by(& &1.fraction, fn -> nil end)

    for machine <- machines,
        guest <- [machine.guest || (main && main.guest)],
        guest != nil,
        do: %{machine | guest: guest}
  end

  # Fly's machines have memory in steps of 256 MB, and the system sees a
  # little less of it; shared processors have a baseline of a sixteenth each.
  defp guest(cpus, memory_bytes, baseline)
       when is_number(cpus) and cpus >= 1 and is_number(memory_bytes) do
    cpus = round(cpus)
    memory_mb = (Float.ceil(memory_bytes / 1_048_576 / 256) |> trunc()) * 256
    kind = if is_number(baseline) and baseline / cpus > 0.5, do: "performance", else: "shared"

    %{"cpu_kind" => kind, "cpus" => cpus, "memory_mb" => max(memory_mb, 256)}
  end

  defp guest(_cpus, _memory_bytes, _baseline), do: nil

  defp bandwidth_history(first, last) do
    with {:ok, by_end} <- Fly.data_out_hourly(apps(), add_hours(first, 1), add_hours(last, 1)) do
      {:ok,
       Map.new(by_end, fn {hour_end, series} ->
         {DateTime.from_unix!(hour_end - 3600),
          Map.new(series, fn {metric, bytes} -> {Map.get(metric, "region", "?"), bytes} end)}
       end)}
    end
  end

  # The bytes stored at the end of each hour, from when the files were sent.
  # Files deleted since are not counted.
  defp storage_history(first, last) do
    until = add_hours(last, 1)

    buckets =
      from(a in ValueAttachment,
        where: a.inserted_at < ^until,
        group_by: fragment("date_trunc('hour', ?)", a.inserted_at),
        order_by: fragment("date_trunc('hour', ?)", a.inserted_at),
        select: {
          type(fragment("date_trunc('hour', ?)", a.inserted_at), :utc_datetime),
          type(sum(a.byte_size), :integer)
        }
      )
      |> Repo.all()

    {before, within} =
      Enum.split_while(buckets, fn {hour, _} -> DateTime.before?(hour, first) end)

    start = before |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    added = Map.new(within)

    {by_hour, _} =
      first
      |> hours_between(last)
      |> Enum.map_reduce(start, fn hour, total ->
        total = total + Map.get(added, hour, 0)
        {{hour, total}, total}
      end)

    {:ok, Map.new(by_hour)}
  rescue
    error ->
      Logger.warning("Stored bytes by hour unknown: #{Exception.message(error)}")
      :error
  end

  defp collect([], _fun), do: :error

  defp collect(apps, fun) do
    Enum.reduce_while(apps, {:ok, []}, fn app, {:ok, acc} ->
      case fun.(app) do
        {:ok, result} -> {:cont, {:ok, [{app, result} | acc]}}
        {:error, _reason} -> {:halt, :error}
      end
    end)
  end

  defp database_bytes do
    %{rows: [[bytes]]} = Repo.query!("SELECT pg_database_size(current_database())")
    {:ok, bytes}
  rescue
    error ->
      Logger.warning("Database size unknown: #{Exception.message(error)}")
      :error
  end

  defp stored_bytes do
    {:ok, Repo.one(from(a in ValueAttachment, select: type(sum(a.byte_size), :integer))) || 0}
  rescue
    error ->
      Logger.warning("Stored bytes unknown: #{Exception.message(error)}")
      :error
  end

  # The current hour: the machines as they run now.
  defp rows(:machines, hour, %{machines: {:ok, apps}}, _history, current, _now)
       when hour == current do
    for {app, machines} <- apps,
        %{"id" => id, "state" => state} = machine <- machines,
        not release_command?(machine),
        cost <- [machine_cost(machine, state, hour)],
        cost != nil,
        do: row(hour, :machines, id, 1.0, cost, detail(machine, app, hour, current))
  end

  # A past hour: the machines that ran as Fly's metrics saw them (before the
  # metrics, the earliest one they know, for the whole hour), and the disks of
  # those stopped now that did not run then.
  defp rows(:machines, hour, snapshot, %{machines: {:ok, history}}, current, _now)
       when hour != current do
    running = ran_in(history, hour)
    ran = MapSet.new(running, fn {machine, _assumed} -> machine.instance end)

    stopped =
      with {:ok, apps} <- snapshot.machines do
        for {app, machines} <- apps,
            %{"id" => id, "state" => state} = machine <- machines,
            state in @stopped,
            not MapSet.member?(ran, id),
            do:
              row(
                hour,
                :machines,
                id,
                1.0,
                machine_cost(machine, state, hour),
                detail(machine, app, hour, nil)
              )
      else
        _ -> []
      end

    for({machine, assumed} <- running, do: history_row(hour, machine, assumed)) ++ stopped
  end

  defp rows(:postgres, hour, %{postgres_bytes: {:ok, bytes}}, _history, current, _now) do
    month_hours = month_hours(hour)
    plan = postgres_plan()
    gb = bytes / @gib
    filled = filled(hour, current)

    [
      row(hour, :postgres, plan, 1.0, (Prices.postgres_plan(plan) || 0.0) / month_hours, filled),
      row(hour, :postgres, "data", gb, gb * Prices.get(:postgres_gb_month) / month_hours, filled)
    ]
  end

  defp rows(:storage, hour, %{storage_bytes: {:ok, bytes}}, _history, current, _now)
       when hour == current,
       do: [storage_row(hour, bytes, %{})]

  defp rows(:storage, hour, _snapshot, %{storage: {:ok, by_hour}}, current, _now)
       when hour != current,
       do: [storage_row(hour, Map.get(by_hour, hour, 0), %{"filled" => true})]

  defp rows(:ips, hour, %{ipv4: {:ok, counts}}, _history, current, _now) do
    count = counts |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    amount = count * Prices.get(:ipv4_month) / month_hours(hour)

    [row(hour, :ips, "ipv4", count * 1.0, amount, filled(hour, current))]
  end

  # The current hour so far, from Fly's metrics.
  defp rows(:bandwidth, hour, _snapshot, _history, current, now) when hour == current do
    seconds = DateTime.diff(now, hour)

    with true <- seconds >= 60,
         {:ok, by_region} <- Fly.data_out(apps(), now, seconds) do
      bandwidth_rows(hour, by_region)
    else
      _ -> []
    end
  end

  # A past hour, in full, from Fly's metrics, while they still have it.
  defp rows(:bandwidth, hour, _snapshot, %{bandwidth: {:ok, by_hour}}, current, _now)
       when hour != current do
    case Map.fetch(by_hour, hour) do
      {:ok, by_region} -> bandwidth_rows(hour, by_region)
      :error -> []
    end
  end

  defp rows(_category, _hour, _snapshot, _history, _current, _now), do: []

  defp ran_in(%{by_hour: by_hour, earliest: earliest}, hour) do
    case {Map.get(by_hour, hour, []), earliest} do
      {[_ | _] = machines, _earliest} ->
        Enum.map(machines, &{&1, false})

      {[], {first, machine}} ->
        if DateTime.before?(hour, first), do: [{%{machine | fraction: 1.0}, true}], else: []

      _none ->
        []
    end
  end

  defp history_row(hour, machine, assumed) do
    cost = Prices.machine_per_second(machine.guest, machine.region) * 3600 * machine.fraction

    detail =
      %{
        "filled" => true,
        "app" => machine.app,
        "region" => machine.region,
        "state" => "started",
        "size" => size_name(machine.guest)
      }
      |> then(&if(assumed, do: Map.put(&1, "assumed", true), else: &1))

    row(hour, :machines, machine.instance, machine.fraction, cost, detail)
  end

  defp storage_row(hour, bytes, detail) do
    gb = bytes / @gib
    billed_gb = max(gb - Prices.get(:storage_free_gb), 0.0)
    amount = billed_gb * Prices.get(:storage_gb_month) / month_hours(hour)

    row(hour, :storage, "files", gb, amount, detail)
  end

  defp bandwidth_rows(hour, by_region) do
    by_region = if by_region == %{}, do: %{"-" => 0.0}, else: by_region

    for {region, bytes} <- by_region do
      gb = bytes / @gib
      row(hour, :bandwidth, region, gb, gb * Prices.bandwidth_per_gb(region), %{})
    end
  end

  defp release_command?(machine),
    do: get_in(machine, ["config", "metadata", "fly_process_group"]) == "fly_app_release_command"

  defp machine_cost(%{"config" => %{"guest" => guest}, "region" => region}, state, _hour)
       when state in @running,
       do: Prices.machine_per_second(guest, region) * 3600

  defp machine_cost(_machine, state, hour) when state in @stopped,
    do: Prices.rootfs_per_hour(month_hours(hour))

  defp machine_cost(_machine, _state, _hour), do: nil

  defp detail(machine, app, hour, current) do
    guest = get_in(machine, ["config", "guest"]) || %{}

    Map.merge(filled(hour, current), %{
      "app" => app,
      "region" => machine["region"],
      "state" => machine["state"],
      "size" => size_name(guest)
    })
  end

  defp size_name(%{"cpu_kind" => "performance", "cpus" => cpus, "memory_mb" => mb}),
    do: "performance-#{cpus}x:#{mb}MB"

  defp size_name(%{"cpus" => cpus, "memory_mb" => mb}), do: "shared-cpu-#{cpus}x:#{mb}MB"
  defp size_name(_guest), do: nil

  defp filled(hour, current) when hour == current, do: %{}
  defp filled(_hour, _current), do: %{"filled" => true}

  defp row(hour, category, item, quantity, amount, detail) do
    now = DateTime.utc_now(:second)

    %{
      hour: hour,
      category: category,
      item: item,
      quantity: quantity,
      amount_usd: amount |> max(0.0) |> Decimal.from_float() |> Decimal.round(6),
      detail: detail,
      inserted_at: now,
      updated_at: now
    }
  end

  ## Reading

  @doc """
  Everything the page shows: the current month so far and where it is
  heading, every month with an estimate or an invoice (newest first), since
  when Potok estimates, and the date of the price list.
  """
  def overview do
    case config()[:cache_ttl] || @cache_ttl do
      0 -> overview_at(DateTime.utc_now())
      ttl -> Cache.fetch(@cache_key, ttl, fn -> overview_at(DateTime.utc_now()) end)
    end
  end

  def overview_at(now) do
    current_hour = hour_of(now)
    this_month = month_of(current_hour)
    sums = month_sums()
    invoices = Map.new(Repo.all(Invoice), &{&1.month, &1})

    months =
      [this_month | Map.keys(sums) ++ Map.keys(invoices)]
      |> Enum.uniq()
      |> Enum.sort({:desc, Date})
      |> Enum.map(&month(&1, sums, invoices, this_month))

    %{
      current: current(Enum.find(months, & &1.current?), current_hour),
      months: months,
      since: Repo.one(from(c in CostHour, select: min(c.hour))),
      updated_at: Repo.one(from(c in CostHour, select: max(c.updated_at))),
      checked_on: Prices.checked_on(),
      estimating?: estimating?()
    }
  end

  defp month_sums do
    from(c in CostHour,
      group_by: [fragment("date_trunc('month', ?)", c.hour), c.category],
      select: {fragment("date_trunc('month', ?)::date", c.hour), c.category, sum(c.amount_usd)}
    )
    |> Repo.all()
    |> Enum.group_by(&elem(&1, 0), fn {_month, category, sum} -> {category, sum} end)
  end

  defp month(month, sums, invoices, this_month) do
    by_category = by_category(Map.get(sums, month, []))

    %{
      month: month,
      current?: month == this_month,
      estimate: if(by_category != [], do: total(by_category)),
      by_category: by_category,
      invoice: Map.get(invoices, month)
    }
  end

  defp by_category(sums) do
    sums = Map.new(sums)

    for category <- CostHour.categories(),
        Map.has_key?(sums, category),
        do: {category, sums[category]}
  end

  defp total(by_category),
    do:
      Enum.reduce(by_category, Decimal.new(0), fn {_category, sum}, acc ->
        Decimal.add(acc, sum)
      end)

  # The month so far, and that plus the rate of the last hour (with the bytes
  # of the last week) for each hour of the month without an estimate: the
  # hours left, and those before Potok began estimating or while it could not,
  # so the first month heads for a whole month's sum too. Each category heads
  # for its own sum the same way (`projected_by_category`).
  defp current(%{estimate: nil} = month, _current_hour),
    do: Map.merge(month, %{projected: nil, projected_by_category: %{}})

  defp current(month, current_hour) do
    month_start = DateTime.new!(month.month, ~T[00:00:00], "Etc/UTC")
    month_hours = month_hours(month_start)

    # Each category counts its own hours: one Fly's metrics could not fill
    # (machines before they begin) takes the category's rate, not nothing.
    counted =
      from(c in CostHour,
        where: c.hour >= ^month_start and c.hour <= ^current_hour,
        group_by: c.category,
        select: {c.category, count(c.hour, :distinct)}
      )
      |> Repo.all()
      |> Map.new()

    rates = hourly_rates(current_hour)
    so_far = Map.new(month.by_category)

    by_category =
      for category <- CostHour.categories(),
          Map.has_key?(so_far, category) or Map.has_key?(rates, category),
          into: %{} do
        missing = max(month_hours - Map.get(counted, category, 0), 0)
        rate = Map.get(rates, category, Decimal.new(0))

        {category,
         Decimal.add(Map.get(so_far, category, Decimal.new(0)), Decimal.mult(rate, missing))}
      end

    projected = Enum.reduce(Map.values(by_category), Decimal.new(0), &Decimal.add/2)

    Map.merge(month, %{
      projected: Decimal.round(projected, 2),
      projected_by_category: Map.new(by_category, fn {c, sum} -> {c, Decimal.round(sum, 2)} end)
    })
  end

  # What each category costs in an hour: the last full hour, or the current
  # one for a category that has none; the bytes sent as their average of the
  # last week.
  defp hourly_rates(current_hour) do
    steady = Map.merge(steady_rates(current_hour), steady_rates(add_hours(current_hour, -1)))

    {sent, hours} =
      from(c in CostHour,
        where:
          c.category == :bandwidth and c.hour < ^current_hour and
            c.hour >= ^add_hours(current_hour, -@bandwidth_window_hours),
        select: {sum(c.amount_usd), count(c.hour, :distinct)}
      )
      |> Repo.one()

    if hours > 0, do: Map.put(steady, :bandwidth, Decimal.div(sent, hours)), else: steady
  end

  defp steady_rates(hour) do
    from(c in CostHour,
      where: c.hour == ^hour and c.category != :bandwidth,
      group_by: c.category,
      select: {c.category, sum(c.amount_usd)}
    )
    |> Repo.all()
    |> Map.new()
  end

  ## Invoices

  @doc "A changeset for the invoice of `month` (a `Date` in it), for the form."
  def change_invoice(%Date{} = month, attrs \\ %{}) do
    month = Date.beginning_of_month(month)

    (Repo.get_by(Invoice, month: month) || %Invoice{month: month})
    |> Invoice.changeset(attrs)
  end

  @doc """
  Writes what Fly billed for `month` ("2026-10"); an empty amount removes the
  invoice. Only operators may.
  """
  def save_invoice(scope, month, attrs) do
    with :ok <- authorize(scope),
         {:ok, month} <- parse_month(month) do
      changeset = change_invoice(month, attrs)

      result =
        case {blank?(attrs["amount_usd"]), changeset.data} do
          {true, %Invoice{id: nil}} -> {:ok, nil}
          {true, invoice} -> Repo.delete(invoice)
          {false, _invoice} -> Repo.insert_or_update(changeset)
        end

      Cache.delete(@cache_key)
      result
    end
  end

  defp authorize(scope) do
    if Operators.operator?(scope), do: :ok, else: {:error, :forbidden}
  end

  @doc "`{:ok, first day}` of a month written as \"2026-10\"."
  def parse_month(<<year::binary-size(4), "-", month::binary-size(2)>>) do
    with {year, ""} <- Integer.parse(year),
         {month, ""} <- Integer.parse(month),
         {:ok, date} <- Date.new(year, month, 1) do
      {:ok, date}
    else
      _ -> {:error, :invalid_month}
    end
  end

  def parse_month(_month), do: {:error, :invalid_month}

  defp blank?(value), do: value in [nil, ""] or (is_binary(value) and String.trim(value) == "")

  ## Hours

  defp hour_of(%DateTime{} = at), do: %{DateTime.truncate(at, :second) | minute: 0, second: 0}

  defp month_of(%DateTime{} = hour), do: hour |> DateTime.to_date() |> Date.beginning_of_month()

  defp month_hours(hour), do: Date.days_in_month(DateTime.to_date(hour)) * 24

  defp add_hours(hour, hours), do: DateTime.add(hour, hours * 3600, :second)

  defp hours_between(first, last) do
    count = div(DateTime.diff(last, first), 3600)
    for step <- 0..count//1, do: add_hours(first, step)
  end

  defp config, do: Application.get_env(:potok_ide, __MODULE__, [])
end
