defmodule PotokIde.HostingCostsTest do
  use PotokIde.DataCase, async: true

  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts.Scope
  alias PotokIde.HostingCosts
  alias PotokIde.HostingCosts.{CostHour, Invoice, Prices}

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

  # Fly as the three APIs answer: machines, bytes sent by region, IP addresses.
  defp stub_fly(opts \\ []) do
    machines = Keyword.get(opts, :machines, [@machine])
    bytes = Keyword.get(opts, :bytes, %{"fra" => @gib})
    ipv4 = Keyword.get(opts, :ipv4, 0)
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

        {"api.fly.io", "/graphql"} ->
          nodes = List.duplicate(%{"type" => "v4"}, ipv4) ++ [%{"type" => "v6"}]
          Req.Test.json(conn, %{"data" => %{"app" => %{"ipAddresses" => %{"nodes" => nodes}}}})
      end
    end)
  end

  defp rows(category) do
    Repo.all(from(c in CostHour, where: c.category == ^category, order_by: [c.hour, c.item]))
  end

  # The range and time of every query Prometheus received, oldest first.
  defp prometheus_queries do
    receive do
      {:prometheus, %{"query" => query, "time" => time}, _authorization} ->
        [range] = Regex.run(~r/\[(\d+)s\]/, query, capture: :all_but_first)
        [{range, time} | prometheus_queries()]
    after
      0 -> []
    end
  end

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

      assert [%CostHour{hour: ^hour, item: "m1", quantity: 1.0} = machine] = rows(:machines)
      assert machine.detail["size"] == "shared-cpu-4x:1024MB"
      assert_in_delta Decimal.to_float(machine.amount_usd), 10.13 / 720, 0.0001

      # November has 720 hours: the plan's $38 is spread over them.
      plan = Enum.find(rows(:postgres), &(&1.item == "basic"))
      assert_in_delta Decimal.to_float(plan.amount_usd), 38 / 720, 0.000001
      assert %CostHour{item: "data"} = Enum.find(rows(:postgres), &(&1.item == "data"))

      assert [%CostHour{item: "files"}] = rows(:storage)
      assert [%CostHour{item: "ipv4", quantity: 1.0} = ip] = rows(:ips)
      assert_in_delta Decimal.to_float(ip.amount_usd), 2 / 720, 0.000001

      assert [%CostHour{item: "fra", quantity: 1.0} = sent] = rows(:bandwidth)
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
      assert [%CostHour{quantity: 2.0}] = rows(:bandwidth)
    end

    test "fills in the hours it missed, and says so" do
      stub_fly()
      HostingCosts.sample(~U[2026-11-12 10:20:00Z])
      HostingCosts.sample(~U[2026-11-12 14:20:00Z])

      machines = rows(:machines)
      assert Enum.map(machines, & &1.hour.hour) == [10, 11, 12, 13, 14]

      assert Enum.map(machines, &Map.get(&1.detail, "filled", false)) == [
               false,
               true,
               true,
               true,
               false
             ]

      # The bytes sent come from Fly's metrics for each hour, a full hour each.
      assert Enum.map(rows(:bandwidth), & &1.hour.hour) == [10, 11, 12, 13, 14]

      assert {"3600", to_string(DateTime.to_unix(~U[2026-11-12 12:00:00Z]))} in prometheus_queries()
    end

    test "fills in no more than three days" do
      stub_fly()
      HostingCosts.sample(~U[2026-11-01 00:10:00Z])
      HostingCosts.sample(~U[2026-11-06 00:10:00Z])

      assert length(rows(:machines)) == 1 + 73
    end

    test "a source that fails is asked again next time, the others are written" do
      stub_fly(machines: {:status, 500})
      HostingCosts.sample(~U[2026-11-12 14:10:00Z])

      assert rows(:machines) == []
      assert [_plan, _data] = rows(:postgres)

      stub_fly()
      HostingCosts.sample(~U[2026-11-12 15:10:00Z])

      assert Enum.map(rows(:machines), & &1.hour.hour) == [14, 15]
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

      assert ["m1", "m2"] = Enum.map(rows(:machines), & &1.item)
      disk = Enum.find(rows(:machines), &(&1.item == "m2"))
      assert_in_delta Decimal.to_float(disk.amount_usd), 0.15 / 720, 0.000001
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
      assert overview.since == ~U[2026-10-31 23:00:00Z]
      assert overview.estimating?
    end

    test "heads for a whole month even when Potok began estimating in it" do
      stub_fly(bytes: %{})
      HostingCosts.sample(~U[2026-11-12 14:20:00Z])

      rate =
        Repo.one(from(c in CostHour, where: c.category != :bandwidth, select: sum(c.amount_usd)))

      overview = HostingCosts.overview_at(~U[2026-11-12 14:30:00Z])

      # One hour estimated, the other 719 of November at the same rate.
      assert_in_delta Decimal.to_float(overview.current.projected),
                      720 * Decimal.to_float(rate),
                      0.01

      assert_in_delta Decimal.to_float(overview.current.projected), 48.1, 0.5
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
