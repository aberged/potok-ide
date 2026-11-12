defmodule PotokIde.HostingCostsTest do
  use PotokIde.DataCase, async: true

  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts.Scope
  alias PotokIde.HostingCosts
  alias PotokIde.HostingCosts.{CostHour, Invoice, Prices}
  alias PotokIde.Social.{Value, ValueAttachment}

  @gib 1_073_741_824

  @machine %{
    "id" => "m1",
    "state" => "started",
    "region" => "fra",
    "config" => %{
      "guest" => %{"cpu_kind" => "shared", "cpus" => 4, "memory_mb" => 1024},
      "metadata" => %{"fly_process_group" => "app"}
    }
  }

  # Fly's metrics keep hours from here on (in the stub, as on Fly, about ten days).
  @metrics_from ~U[2026-11-02 12:00:00Z]
  # In the stub's history the machine grows from 1x/512 MB to 4x/1 GB here.
  @resized_at ~U[2026-11-09 00:00:00Z]

  # Fly as its APIs answer: machines, bytes sent by region (now and by the
  # hour), what the metrics saw of the machines by the hour, IP addresses.
  # `history: :resized` has the machine grow; `:steady` keeps it 4x/1 GB;
  # `:none` (the default) has no metrics of past hours.
  defp stub_fly(opts \\ []) do
    machines = Keyword.get(opts, :machines, [@machine])
    bytes = Keyword.get(opts, :bytes, %{"fra" => @gib})
    ipv4 = Keyword.get(opts, :ipv4, 0)
    history = Keyword.get(opts, :history, :none)
    test = self()

    Req.Test.stub(HostingCosts.Fly, fn conn ->
      case {conn.host, conn.request_path} do
        {"api.machines.dev", "/v1/apps/potok-test/machines"} ->
          case machines do
            {:status, status} -> Plug.Conn.send_resp(conn, status, "")
            machines -> Req.Test.json(conn, machines)
          end

        {"api.fly.io", "/prometheus/personal/api/v1/query"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          send(
            test,
            {:prometheus, URI.decode_query(body), Plug.Conn.get_req_header(conn, "authorization")}
          )

          Req.Test.json(conn, %{
            "status" => "success",
            "data" => %{
              "resultType" => "vector",
              "result" =>
                for(
                  {region, b} <- bytes,
                  do: %{"metric" => %{"region" => region}, "value" => [0, to_string(b)]}
                )
            }
          })

        {"api.fly.io", "/prometheus/personal/api/v1/query_range"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          params = URI.decode_query(body)
          send(test, {:prometheus_range, params})

          Req.Test.json(conn, %{
            "status" => "success",
            "data" => %{
              "resultType" => "matrix",
              "result" => range_result(params, history, bytes)
            }
          })

        {"api.fly.io", "/graphql"} ->
          nodes = List.duplicate(%{"type" => "v4"}, ipv4) ++ [%{"type" => "v6"}]
          Req.Test.json(conn, %{"data" => %{"app" => %{"ipAddresses" => %{"nodes" => nodes}}}})
      end
    end)
  end

  defp range_result(_params, :none, _bytes), do: []

  defp range_result(%{"query" => query, "start" => start, "end" => finish}, history, bytes) do
    ends =
      for t <- String.to_integer(start)..String.to_integer(finish)//3600,
          t > DateTime.to_unix(@metrics_from),
          do: t

    small? = fn t -> history == :resized and t <= DateTime.to_unix(@resized_at) end
    machine = %{"app" => "potok-test", "instance" => "m1", "region" => "fra"}
    release_hour_end = DateTime.to_unix(~U[2026-11-10 11:00:00Z])

    cond do
      query =~ "fly_edge_data_out" ->
        for {region, b} <- bytes,
            do: %{
              "metric" => %{"region" => region},
              "values" => for(t <- ends, do: [t, to_string(b)])
            }

      query =~ "fly_instance_up" ->
        main = %{"metric" => machine, "values" => for(t <- ends, do: [t, "240"])}

        release = %{
          "metric" => %{machine | "instance" => "r1"},
          "values" => for(t <- ends, t == release_hour_end, do: [t, "2"])
        }

        [main, release]

      query =~ "fly_instance_memory_mem_total" ->
        [series("m1", ends, &if(small?.(&1), do: "483897344", else: "1010851840"))]

      query =~ "fly_instance_cpu_baseline" ->
        [series("m1", ends, &if(small?.(&1), do: "0.0625", else: "0.25"))]

      query =~ "fly_instance_cpu{" ->
        [series("m1", ends, &if(small?.(&1), do: "1", else: "4"))]
    end
  end

  defp series(instance, ends, value),
    do: %{"metric" => %{"instance" => instance}, "values" => for(t <- ends, do: [t, value.(t)])}

  defp rows(category) do
    Repo.all(from(c in CostHour, where: c.category == ^category, order_by: [c.hour, c.item]))
  end

  defp rows(category, hour) do
    Repo.all(
      from(c in CostHour,
        where: c.category == ^category and c.hour == ^hour,
        order_by: c.item
      )
    )
  end

  defp hours(rows), do: rows |> Enum.map(& &1.hour) |> Enum.uniq()

  # Every message the stub sent so far.
  defp flush do
    receive do
      message -> [message | flush()]
    after
      0 -> []
    end
  end

  defp hours_between(first, last),
    do:
      for(step <- 0..div(DateTime.diff(last, first), 3600), do: DateTime.add(first, step * 3600))

  defp operator_scope, do: Scope.for_account(account_fixture(%{email: "operator@example.com"}))

  describe "Prices" do
    test "a machine costs what Fly's own table says" do
      guest = %{"cpu_kind" => "shared", "cpus" => 1, "memory_mb" => 1024}

      # Fly's example: shared-cpu-1x with 1 GB in Frankfurt, $7.73 in 30 days.
      assert_in_delta Prices.machine_per_second(guest, "fra") * 2_592_000, 7.73, 0.005
      assert_in_delta Prices.machine_per_second(guest, "iad") * 2_592_000, 6.70, 0.005

      four = %{"cpu_kind" => "shared", "cpus" => 4, "memory_mb" => 1024}
      assert_in_delta Prices.machine_per_second(four, "fra") * 2_592_000, 10.13, 0.005
    end

    test "data sent out is priced by where it leaves Fly" do
      assert Prices.bandwidth_per_gb("fra") == 0.02
      assert Prices.bandwidth_per_gb("sin") == 0.04
      assert Prices.bandwidth_per_gb("jnb") == 0.12
    end
  end

  describe "sample/1" do
    test "writes what the current hour costs, by category" do
      stub_fly(ipv4: 1)
      now = ~U[2026-11-12 14:20:00Z]
      hour = ~U[2026-11-12 14:00:00Z]

      assert HostingCosts.sample(now) > 0

      assert [%CostHour{item: "m1", quantity: 1.0} = machine] = rows(:machines, hour)
      assert machine.detail["size"] == "shared-cpu-4x:1024MB"
      refute machine.detail["filled"]
      assert_in_delta Decimal.to_float(machine.amount_usd), 10.13 / 720, 0.0001

      # November has 720 hours: the plan's $38 is spread over them.
      plan = Enum.find(rows(:postgres, hour), &(&1.item == "basic"))
      assert_in_delta Decimal.to_float(plan.amount_usd), 38 / 720, 0.000001
      assert %CostHour{item: "data"} = Enum.find(rows(:postgres, hour), &(&1.item == "data"))

      assert [%CostHour{item: "files"}] = rows(:storage, hour)
      assert [%CostHour{item: "ipv4", quantity: 1.0} = ip] = rows(:ips, hour)
      assert_in_delta Decimal.to_float(ip.amount_usd), 2 / 720, 0.000001

      assert [%CostHour{item: "fra", quantity: 1.0} = sent] = rows(:bandwidth, hour)
      assert Decimal.equal?(sent.amount_usd, Decimal.new("0.020000"))

      # The hour so far: twenty minutes, up to now, with the token as FlyV1.
      assert_received {:prometheus, %{"query" => query, "time" => time}, ["FlyV1 test-token"]}
      assert query =~ ~s|fly_edge_data_out{app=~"potok-test"}[1200s]|
      assert time == to_string(DateTime.to_unix(now))
    end

    test "writes an hour again instead of adding it twice" do
      stub_fly()
      HostingCosts.sample(~U[2026-11-12 14:05:00Z])
      count = Repo.aggregate(CostHour, :count)

      stub_fly(bytes: %{"fra" => 2 * @gib})
      HostingCosts.sample(~U[2026-11-12 14:50:00Z])

      assert Repo.aggregate(CostHour, :count) == count
      assert [%CostHour{quantity: 2.0}] = rows(:bandwidth, ~U[2026-11-12 14:00:00Z])
    end

    test "fills in the month so far from Fly's metrics, and says so" do
      stub_fly(history: :resized)
      HostingCosts.sample(~U[2026-11-12 14:20:00Z])

      machines = rows(:machines)
      # Every hour of November: 11 days and 15 hours, and a release machine once.
      assert length(hours(machines)) == 11 * 24 + 15
      assert hd(machines).hour == ~U[2026-11-01 00:00:00Z]

      # Before the metrics, the earliest machine they know, for the whole hour.
      [early] = rows(:machines, ~U[2026-11-01 05:00:00Z])

      assert %{"filled" => true, "assumed" => true, "size" => "shared-cpu-1x:512MB"} =
               early.detail

      # From the metrics: the size of the time, and how long it ran.
      [small] = rows(:machines, ~U[2026-11-05 10:00:00Z])
      assert small.detail["size"] == "shared-cpu-1x:512MB"
      refute small.detail["assumed"]
      assert small.quantity == 1.0

      assert [big, release] = rows(:machines, ~U[2026-11-10 10:00:00Z])
      assert big.detail["size"] == "shared-cpu-4x:1024MB"
      assert release.item == "r1"
      assert_in_delta release.quantity, 2 / 240, 0.0001
      assert_in_delta Decimal.to_float(release.amount_usd), 10.13 / 720 * 2 / 240, 0.00001

      # The current hour is what runs now.
      [now] = rows(:machines, ~U[2026-11-12 14:00:00Z])
      refute now.detail["filled"]

      # The bytes sent come from the metrics of each hour while they have it.
      sent = rows(:bandwidth)
      assert hd(sent).hour == ~U[2026-11-02 12:00:00Z]

      assert length(hours(sent)) ==
               length(hours_between(~U[2026-11-02 12:00:00Z], ~U[2026-11-12 14:00:00Z]))

      # One question per kind of metric, not one per hour.
      ranges = for {:prometheus_range, params} <- flush(), do: params
      assert length(ranges) == 5
      assert Enum.all?(ranges, &(&1["step"] == "3600"))
    end

    test "fills in the month and at least three days back, never more" do
      stub_fly()
      HostingCosts.sample(~U[2026-11-02 05:10:00Z])

      # From October 30, 05:00: three days back across the month's start.
      plans = for row <- rows(:postgres), row.item == "basic", do: row.hour
      assert hd(plans) == ~U[2026-10-30 05:00:00Z]
      assert length(plans) == 73
    end

    test "a source that fails is asked again next time, the others are written" do
      stub_fly(machines: {:status, 500})
      HostingCosts.sample(~U[2026-11-12 14:10:00Z])

      assert rows(:machines) == []
      assert [_plan, _data] = rows(:postgres, ~U[2026-11-12 14:00:00Z])

      stub_fly(history: :steady)
      HostingCosts.sample(~U[2026-11-12 15:10:00Z])

      assert [%{detail: %{"filled" => true}}] = rows(:machines, ~U[2026-11-12 14:00:00Z])
      assert [now] = rows(:machines, ~U[2026-11-12 15:00:00Z])
      refute now.detail["filled"]
    end

    test "a stopped machine costs its disk, a release machine is left out" do
      stopped = %{@machine | "id" => "m2", "state" => "stopped"}

      release = %{
        @machine
        | "id" => "m3",
          "config" =>
            put_in(
              @machine["config"],
              ["metadata", "fly_process_group"],
              "fly_app_release_command"
            )
      }

      stub_fly(machines: [@machine, stopped, release])
      HostingCosts.sample(~U[2026-11-12 14:10:00Z])

      now = rows(:machines, ~U[2026-11-12 14:00:00Z])
      assert ["m1", "m2"] = Enum.map(now, & &1.item)
      disk = Enum.find(now, &(&1.item == "m2"))
      assert_in_delta Decimal.to_float(disk.amount_usd), 0.15 / 720, 0.000001

      # In past hours without metrics, the stopped machine still has its disk.
      assert ["m2"] = Enum.map(rows(:machines, ~U[2026-11-05 10:00:00Z]), & &1.item)
    end

    test "the stored files of a past hour are those sent before it ended" do
      {_account, profile} = PotokIde.EventsFixtures.account_with_profile!("costs-files")
      group = PotokIde.EventsFixtures.group_with_members!(profile, [])

      value =
        Repo.insert!(%Value{
          group_id: group.id,
          creator_id: profile.id,
          content: "files",
          content_format: :markdown
        })

      for {name, at} <- [{"a.pdf", ~U[2026-11-03 10:30:00Z]}, {"b.pdf", ~U[2026-11-08 00:30:00Z]}] do
        Repo.insert!(%ValueAttachment{
          value_id: value.id,
          group_id: group.id,
          profile_id: profile.id,
          storage_key: "costs/#{name}",
          filename: name,
          content_type: "application/pdf",
          byte_size: @gib,
          inserted_at: at
        })
      end

      stub_fly()
      HostingCosts.sample(~U[2026-11-12 14:10:00Z])

      stored = fn hour -> hour |> then(&rows(:storage, &1)) |> hd() |> Map.get(:quantity) end
      assert stored.(~U[2026-11-03 09:00:00Z]) == 0.0
      assert stored.(~U[2026-11-03 10:00:00Z]) == 1.0
      assert stored.(~U[2026-11-08 00:00:00Z]) == 2.0
      assert stored.(~U[2026-11-12 14:00:00Z]) == 2.0
      assert length(hours(rows(:storage))) == 11 * 24 + 15
    end
  end

  describe "overview_at/1" do
    test "shows every month with an estimate or an invoice, and where this one is heading" do
      stub_fly()
      HostingCosts.sample(~U[2026-10-31 23:10:00Z])
      HostingCosts.sample(~U[2026-11-01 00:10:00Z])

      Repo.insert!(%Invoice{month: ~D[2026-10-01], amount_usd: Decimal.new("47.50")})
      Repo.insert!(%Invoice{month: ~D[2026-08-01], amount_usd: Decimal.new("12.00")})

      overview = HostingCosts.overview_at(~U[2026-11-01 00:30:00Z])

      assert Enum.map(overview.months, & &1.month) == [
               ~D[2026-11-01],
               ~D[2026-10-01],
               ~D[2026-08-01]
             ]

      assert [%{current?: true}, october, august] = overview.months
      assert october.estimate && Decimal.equal?(october.invoice.amount_usd, Decimal.new("47.50"))
      assert august.estimate == nil

      current = overview.current
      assert current.month == ~D[2026-11-01]
      assert Keyword.has_key?(current.by_category, :machines)
      # The last full hour's rate for each of the 719 hours left.
      assert Decimal.gt?(current.projected, Decimal.mult(current.estimate, 100))
      # October is filled in from its first hour, as the first pass came in it.
      assert overview.since == ~U[2026-10-01 00:00:00Z]
      assert overview.estimating?
    end

    test "heads for a whole month, each row too" do
      stub_fly(bytes: %{}, history: :steady)
      HostingCosts.sample(~U[2026-11-12 14:20:00Z])
      overview = HostingCosts.overview_at(~U[2026-11-12 14:30:00Z])

      # The month so far is filled in, so it is no longer one hour.
      assert Decimal.gt?(overview.current.estimate, Decimal.new(15))
      assert_in_delta Decimal.to_float(overview.current.projected), 48.1, 0.5

      # Each row heads for its own month: the machine about $10, the plan $38.
      by_category = overview.current.projected_by_category
      assert_in_delta Decimal.to_float(by_category.machines), 10.13, 0.05
      assert_in_delta Decimal.to_float(by_category.postgres), 38.0, 0.5

      assert_in_delta by_category |> Map.values() |> Enum.map(&Decimal.to_float/1) |> Enum.sum(),
                      Decimal.to_float(overview.current.projected),
                      0.05
    end

    test "heads for a whole month even with hours it could not fill" do
      stub_fly(bytes: %{})
      HostingCosts.sample(~U[2026-11-12 14:20:00Z])
      overview = HostingCosts.overview_at(~U[2026-11-12 14:30:00Z])

      # Without metrics only the current hour has the machine; the rest of the
      # month takes its rate.
      assert_in_delta Decimal.to_float(overview.current.projected_by_category.machines),
                      10.13,
                      0.05
    end

    test "has nothing to show before the first estimate" do
      overview = HostingCosts.overview_at(~U[2026-11-12 10:00:00Z])

      assert [%{current?: true, estimate: nil}] = overview.months
      assert overview.current.projected == nil
      assert overview.since == nil
    end
  end

  describe "save_invoice/3" do
    test "an operator writes, changes and removes a month's invoice" do
      scope = operator_scope()

      assert {:ok, %Invoice{month: ~D[2026-10-01]}} =
               HostingCosts.save_invoice(scope, "2026-10", %{
                 "amount_usd" => "47.5",
                 "note" => " VAT "
               })

      assert {:ok, %Invoice{note: "VAT"} = invoice} =
               HostingCosts.save_invoice(scope, "2026-10", %{
                 "amount_usd" => "48.10",
                 "note" => "VAT"
               })

      assert Decimal.equal?(invoice.amount_usd, Decimal.new("48.10"))
      assert Repo.aggregate(Invoice, :count) == 1

      assert {:ok, _deleted} = HostingCosts.save_invoice(scope, "2026-10", %{"amount_usd" => ""})
      assert Repo.aggregate(Invoice, :count) == 0
    end

    test "nobody else may" do
      assert {:error, :forbidden} =
               HostingCosts.save_invoice(account_scope_fixture(), "2026-10", %{
                 "amount_usd" => "1"
               })

      unconfirmed =
        Scope.for_account(unconfirmed_account_fixture(%{email: "operator@example.com"}))

      assert {:error, :forbidden} =
               HostingCosts.save_invoice(unconfirmed, "2026-10", %{"amount_usd" => "1"})

      assert {:error, :forbidden} =
               HostingCosts.save_invoice(nil, "2026-10", %{"amount_usd" => "1"})
    end

    test "takes no negative sum and no made-up month" do
      scope = operator_scope()

      assert {:error, %Ecto.Changeset{errors: [amount_usd: _]}} =
               HostingCosts.save_invoice(scope, "2026-10", %{"amount_usd" => "-1"})

      assert {:error, :invalid_month} =
               HostingCosts.save_invoice(scope, "2026-13", %{"amount_usd" => "1"})

      assert {:error, :invalid_month} =
               HostingCosts.save_invoice(scope, nil, %{"amount_usd" => "1"})
    end
  end
end
