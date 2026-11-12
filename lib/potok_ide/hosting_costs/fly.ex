defmodule PotokIde.HostingCosts.Fly do
  @moduledoc """
  What `PotokIde.HostingCosts` reads from Fly, all of it read-only: the
  machines of an app (Machines API), the bytes sent out by region (Fly's
  Prometheus) and an app's IP addresses (Fly's GraphQL API).

  The token is `FLY_COSTS_TOKEN`, best made with
  `fly tokens create readonly <org>`. Such a token starts with `FlyV1 ` and is
  sent as it is; an older bare token goes to the Machines and GraphQL APIs as
  `Bearer`, and to Prometheus as `FlyV1`, which is the only scheme it takes.
  """

  require Logger

  @defaults [
    machines_url: "https://api.machines.dev/v1",
    graphql_url: "https://api.fly.io/graphql",
    prometheus_url: "https://api.fly.io/prometheus",
    org: "personal",
    req_options: []
  ]

  @doc "The machines of `app`, as the Machines API lists them."
  def machines(app) do
    request(:get, url(:machines_url) <> "/apps/#{URI.encode(app)}/machines", :bearer, [])
    |> body("machines of #{app}", &is_list/1)
  end

  @doc """
  The bytes `apps` sent out in the `seconds` before `at`, by region:
  `{:ok, %{"fra" => 1234.0}}`.
  """
  def data_out(apps, %DateTime{} = at, seconds) when is_integer(seconds) and seconds > 0 do
    query = ~s|sum by (region) (increase(fly_edge_data_out{#{selector(apps)}}[#{seconds}s]))|
    url = url(:prometheus_url) <> "/#{config()[:org]}/api/v1/query"

    request(:post, url, :flyv1, form: [query: query, time: DateTime.to_unix(at)])
    |> body("data sent out", &match?(%{"status" => "success"}, &1))
    |> case do
      {:ok, %{"data" => %{"result" => results}}} ->
        {:ok,
         Map.new(results, fn %{"metric" => metric, "value" => [_time, value]} ->
           {Map.get(metric, "region", "?"), parse_float(value)}
         end)}

      {:ok, _other} ->
        {:ok, %{}}

      error ->
        error
    end
  end

  @doc """
  The bytes `apps` sent out in each hour from the one ending at `first_end`
  to the one ending at `last_end`, by region:
  `{:ok, %{hour_end_unix => [{%{"region" => "fra"}, 1234.0}]}}`. Fly keeps
  its metrics for about ten days; older hours are not in the map.
  """
  def data_out_hourly(apps, %DateTime{} = first_end, %DateTime{} = last_end) do
    query = ~s|sum by (region) (increase(fly_edge_data_out{#{selector(apps)}}[1h]))|
    hourly(query, first_end, last_end)
  end

  @doc """
  What Fly's metrics saw of the machines of `apps` in each hour, by machine
  (`instance`): how many samples it gave (`samples`, by `app` and `region`
  too), the memory it saw (`memory`), its processors (`cpus`) and their
  baseline (`baseline`), each as `data_out_hourly/3` returns them.
  """
  def machines_hourly(apps, %DateTime{} = first_end, %DateTime{} = last_end) do
    selector = selector(apps)

    queries = [
      samples:
        "sum by (app, instance, region) (count_over_time(fly_instance_up{#{selector}}[1h]))",
      memory: "max by (instance) (max_over_time(fly_instance_memory_mem_total{#{selector}}[1h]))",
      cpus:
        ~s|count by (instance) (max_over_time(fly_instance_cpu{#{selector},mode="idle"}[1h]))|,
      baseline: "max by (instance) (max_over_time(fly_instance_cpu_baseline{#{selector}}[1h]))"
    ]

    Enum.reduce_while(queries, {:ok, %{}}, fn {key, query}, {:ok, acc} ->
      case hourly(query, first_end, last_end) do
        {:ok, by_hour} -> {:cont, {:ok, Map.put(acc, key, by_hour)}}
        error -> {:halt, error}
      end
    end)
  end

  defp hourly(query, first_end, last_end) do
    url = url(:prometheus_url) <> "/#{config()[:org]}/api/v1/query_range"

    form = [
      query: query,
      start: DateTime.to_unix(first_end),
      end: DateTime.to_unix(last_end),
      step: 3600
    ]

    request(:post, url, :flyv1, form: form)
    |> body("metrics by the hour", &match?(%{"status" => "success"}, &1))
    |> case do
      {:ok, %{"data" => %{"result" => results}}} when is_list(results) ->
        {:ok,
         for %{"metric" => metric, "values" => values} <- results,
             [time, value] <- values,
             reduce: %{} do
           acc ->
             Map.update(
               acc,
               trunc(time),
               [{metric, parse_float(value)}],
               &[{metric, parse_float(value)} | &1]
             )
         end}

      {:ok, _other} ->
        {:ok, %{}}

      error ->
        error
    end
  end

  # Fly app names are small letters, digits and dashes, none of them special
  # in a regex; anything else could break out of the query's string.
  defp selector(apps) do
    names = apps |> Enum.filter(&(&1 =~ ~r/\A[a-z0-9-]+\z/)) |> Enum.join("|")
    ~s|app=~"#{names}"|
  end

  @doc "How many dedicated IPv4 addresses `app` has; shared ones cost nothing."
  def dedicated_ipv4_count(app) do
    query = "query($name: String!) { app(name: $name) { ipAddresses { nodes { type } } } }"

    request(:post, url(:graphql_url), :bearer, json: %{query: query, variables: %{name: app}})
    |> body("IP addresses of #{app}", &match?(%{"data" => %{"app" => %{}}}, &1))
    |> case do
      {:ok, %{"data" => %{"app" => %{"ipAddresses" => %{"nodes" => nodes}}}}} ->
        {:ok, Enum.count(nodes, &(&1["type"] == "v4"))}

      {:ok, _other} ->
        {:ok, 0}

      error ->
        error
    end
  end

  def token do
    case config()[:token] do
      token when is_binary(token) and token != "" -> String.trim(token)
      _none -> nil
    end
  end

  defp request(method, url, scheme, options) do
    [
      method: method,
      url: url,
      headers: [{"authorization", authorization(scheme)}],
      retry: false,
      connect_options: [timeout: 5_000],
      receive_timeout: 15_000
    ]
    |> Keyword.merge(options)
    |> Keyword.merge(config()[:req_options])
    |> Req.request()
  end

  defp authorization(scheme) do
    case {token(), scheme} do
      {"FlyV1 " <> _ = token, _scheme} -> token
      {token, :bearer} -> "Bearer " <> to_string(token)
      {token, :flyv1} -> "FlyV1 " <> to_string(token)
    end
  end

  defp body({:ok, %Req.Response{status: 200, body: body}}, what, valid?) do
    if valid?.(body) do
      {:ok, body}
    else
      Logger.warning("Fly answered something unexpected for #{what}")
      {:error, :unexpected}
    end
  end

  defp body({:ok, %Req.Response{status: status}}, what, _valid?) do
    Logger.warning("Fly answered #{status} for #{what}")
    {:error, {:status, status}}
  end

  defp body({:error, exception}, what, _valid?) do
    Logger.warning("Fly could not be reached for #{what}: #{Exception.message(exception)}")
    {:error, :unreachable}
  end

  defp parse_float(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} when number >= 0 -> number
      _nan -> 0.0
    end
  end

  defp parse_float(_value), do: 0.0

  defp url(key), do: config()[key]

  defp config do
    Keyword.merge(@defaults, Application.get_env(:potok_ide, PotokIde.HostingCosts, []))
  end
end
