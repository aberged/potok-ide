# Server-side sampler, injected into the running release by run.sh:
#
#     bin/potok_ide rpc 'Code.eval_file("/load_test/sampler.exs"); LoadTest.Sampler.start("/load_test/results/<run>")'
#
# Every 5 s it appends one JSON line to server.jsonl: BEAM memory, run queue,
# scheduler utilization, the busiest mailboxes, LiveView processes per view,
# root presence size, and telemetry histograms for Repo queries (queue and
# query time, time per table), LiveView mount/handle_params/handle_event/render
# and router dispatch. Histograms are log buckets (10% wide) kept in ETS
# counters, so the overhead stays flat however much traffic comes in.
#
# It also writes where the schedulers spend their time (`msacc`: emulator, gc,
# port, check_io, sleep... as % of the online schedulers' time) and memory as
# the OS sees it (`rss_mb`) next to each allocator's blocks and carriers
# (`alloc`, MB), which shows how much sits in allocator overhead.
defmodule LoadTest.Sampler do
  @interval 5_000
  @handler "load-test-sampler"
  @log_base :math.log(1.1)

  @events [
    [:potok_ide, :repo, :query],
    [:phoenix, :live_view, :mount, :stop],
    [:phoenix, :live_view, :handle_params, :stop],
    [:phoenix, :live_view, :handle_event, :stop],
    [:phoenix, :live_view, :render, :stop],
    [:phoenix, :live_view, :mount, :exception],
    [:phoenix, :live_view, :handle_params, :exception],
    [:phoenix, :live_view, :handle_event, :exception],
    [:phoenix, :router_dispatch, :stop],
    [:phoenix, :router_dispatch, :exception],
    [:phoenix, :socket_connected]
  ]

  def start(out_dir) do
    stop()
    File.mkdir_p!(out_dir)
    caller = self()
    # Not linked: the rpc process that starts it exits right away.
    pid = spawn(fn -> init(out_dir, caller) end)

    receive do
      {:sampler_started, ^pid} -> {:ok, pid}
    after
      10_000 -> {:error, :timeout}
    end
  end

  def stop do
    :telemetry.detach(@handler)
    :msacc.stop()

    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> Process.exit(pid, :kill)
    end

    :ok
  end

  defp init(out_dir, caller) do
    Process.register(self(), __MODULE__)

    tab =
      :ets.new(__MODULE__, [:set, :public, write_concurrency: true, decentralized_counters: true])

    :ok = :telemetry.attach_many(@handler, @events, &__MODULE__.handle_event/4, tab)
    _previously_on? = :msacc.start()
    root = PotokIde.Social.get_root_group!()

    state = %{
      tab: tab,
      path: Path.join(out_dir, "server.jsonl"),
      presence_topic: PotokIde.Social.group_presence_topic(root),
      sched: :scheduler.sample_all(),
      reductions: %{}
    }

    send(caller, {:sampler_started, self()})
    Process.send_after(self(), :sample, @interval)
    loop(state)
  end

  defp loop(state) do
    receive do
      :sample ->
        Process.send_after(self(), :sample, @interval)
        loop(sample(state))
    end
  end

  def handle_event([:potok_ide, :repo, :query], m, meta, tab) do
    queue = us(m[:queue_time])
    query = us(m[:query_time])
    if queue, do: hist(tab, "db_queue", queue)
    if query, do: hist(tab, "db_query", query)
    total = (queue || 0) + (query || 0) + (us(m[:decode_time]) || 0)
    key = {:src, meta[:source] || "(none)"}
    :ets.update_counter(tab, key, [{2, 1}, {3, total}], {key, 0, 0})
  end

  def handle_event([:phoenix, :live_view, kind, :stop], m, meta, tab) do
    view = meta.socket.view |> inspect() |> String.replace_prefix("PotokIdeWeb.", "")

    name =
      case kind do
        :handle_event -> "event #{view} #{meta[:event]}"
        # The first render of a mount is forced; later ones are updates.
        :render -> "render #{view}#{if meta[:force?], do: " first", else: ""}"
        _ -> "#{kind} #{view}"
      end

    hist(tab, name, us(m.duration))
  end

  def handle_event([:phoenix, :live_view, kind, :exception], _m, meta, tab) do
    view = meta.socket.view |> inspect() |> String.replace_prefix("PotokIdeWeb.", "")
    reason = meta[:reason] |> exception_name() |> String.slice(0, 80)
    key = {:exc, "#{kind} #{view} #{meta[:event]} #{reason}"}
    :ets.update_counter(tab, key, 1, {key, 0})
  end

  def handle_event([:phoenix, :router_dispatch, :stop], m, meta, tab) do
    hist(tab, "http #{meta[:route]}", us(m.duration))
  end

  # The logger drops messages under overload, so count request crashes here.
  def handle_event([:phoenix, :router_dispatch, :exception], _m, meta, tab) do
    reason = meta[:reason] |> exception_name() |> String.slice(0, 80)
    key = {:exc, "http #{meta[:route]} #{reason}"}
    :ets.update_counter(tab, key, 1, {key, 0})
  end

  def handle_event([:phoenix, :socket_connected], m, _meta, tab) do
    hist(tab, "socket_connect", us(m.duration))
  end

  defp exception_name(%{__exception__: true} = e), do: inspect(e.__struct__)
  defp exception_name(other), do: inspect(other)

  defp us(nil), do: nil
  defp us(native), do: System.convert_time_unit(native, :native, :microsecond)

  defp hist(_tab, _name, nil), do: :ok

  defp hist(tab, name, value_us) do
    bucket = if value_us < 1, do: 0, else: trunc(:math.log(value_us) / @log_base)
    key = {:h, name, bucket}
    :ets.update_counter(tab, key, 1, {key, 0})
  end

  defp sample(state) do
    rows = :ets.tab2list(state.tab)
    :ets.delete_all_objects(state.tab)
    sched = :scheduler.sample_all()
    utilization = normal_utilization(state.sched, sched)
    procs = process_stats(state.reductions)
    msacc = msacc_shares()

    line = %{
      t: System.system_time(:millisecond),
      vm: vm_stats(utilization),
      msacc: msacc,
      rss_mb: rss_mb(),
      alloc: allocator_sizes(),
      presence_root: presence_size(state.presence_topic),
      hist: histograms(rows),
      db_sources: db_sources(rows),
      exceptions: for({{:exc, name}, count} <- rows, into: %{}, do: {name, count}),
      mailboxes: procs.mailboxes,
      top_queue: procs.top_queue,
      top_memory: procs.top_memory,
      live_views: procs.live_views,
      cpu_share: procs.cpu_share
    }

    File.write!(state.path, [Jason.encode!(line), "\n"], [:append])
    %{state | sched: sched, reductions: procs.reductions}
  rescue
    error ->
      File.write!(
        state.path,
        [
          Jason.encode!(%{t: System.system_time(:millisecond), error: Exception.message(error)}),
          "\n"
        ],
        [:append]
      )

      state
  end

  # Average over normal schedulers only: the `:total` entry also counts the
  # (mostly idle) dirty IO schedulers and reads far too low.
  # Only the online ones: in a CPU-limited container all 16 exist but one runs.
  defp normal_utilization(previous, current) do
    online = :erlang.system_info(:schedulers_online)

    values =
      for {:normal, id, value, _} <- :scheduler.utilization(previous, current),
          id <= online,
          do: value

    Float.round(Enum.sum(values) / max(length(values), 1) * 100, 1)
  end

  defp vm_stats(utilization) do
    memory = :erlang.memory()
    mb = fn key -> Float.round(memory[key] / 1_048_576, 1) end

    %{
      mem_total_mb: mb.(:total),
      mem_processes_mb: mb.(:processes),
      mem_binary_mb: mb.(:binary),
      mem_ets_mb: mb.(:ets),
      processes: :erlang.system_info(:process_count),
      ports: :erlang.system_info(:port_count),
      run_queue: :erlang.statistics(:total_run_queue_lengths_all),
      schedulers_online: :erlang.system_info(:schedulers_online),
      scheduler_util_pct: utilization
    }
  end

  # Time per state of the online normal schedulers since the last sample, as a
  # share of all their time; then the counters start over.
  defp msacc_shares do
    online = :erlang.system_info(:schedulers_online)

    counters =
      for %{type: :scheduler, id: id, counters: counters} <- :msacc.stats(),
          id <= online,
          reduce: %{} do
        acc -> Map.merge(acc, counters, fn _state, a, b -> a + b end)
      end

    :msacc.reset()
    total = counters |> Map.values() |> Enum.sum() |> max(1)
    Map.new(counters, fn {state, time} -> {state, Float.round(time * 100 / total, 1)} end)
  end

  defp rss_mb do
    with {:ok, status} <- File.read("/proc/self/status"),
         [_, kb] <- Regex.run(~r/VmRSS:\s+(\d+) kB/, status) do
      Float.round(String.to_integer(kb) / 1024, 1)
    else
      _ -> nil
    end
  end

  # Per alloc_util allocator, summed over its instances: what is handed out
  # (blocks) and what is taken from the OS for it (carriers). The difference
  # is free space inside carriers, i.e. fragmentation and headroom.
  defp allocator_sizes do
    Map.new(:erlang.system_info(:alloc_util_allocators), fn alloc ->
      instances =
        case :erlang.system_info({:allocator, alloc}) do
          instances when is_list(instances) -> instances
          _disabled -> []
        end

      {blocks, carriers} =
        for {:instance, _n, sections} <- instances,
            {section, items} <- sections,
            section in [:mbcs, :sbcs, :mbcs_pool],
            reduce: {0, 0} do
          {blocks, carriers} -> {blocks + blocks_size(items), carriers + carriers_size(items)}
        end

      {alloc,
       %{
         blocks_mb: Float.round(blocks / 1_048_576, 1),
         carriers_mb: Float.round(carriers / 1_048_576, 1)
       }}
    end)
  end

  defp blocks_size(items) do
    for {:blocks, per_alloc} <- items,
        {_alloc, stats} <- per_alloc,
        {:size, current, _max, _max_ever} <- stats,
        reduce: 0 do
      acc -> acc + current
    end
  end

  defp carriers_size(items) do
    for {:carriers_size, current, _max, _max_ever} <- items, reduce: 0, do: (acc -> acc + current)
  end

  defp presence_size(topic) do
    topic |> PotokIde.Presence.list() |> map_size()
  catch
    _, _ -> nil
  end

  defp histograms(rows) do
    rows
    |> Enum.flat_map(fn
      {{:h, name, bucket}, count} -> [{name, bucket, count}]
      _ -> []
    end)
    |> Enum.group_by(&elem(&1, 0), fn {_, bucket, count} -> {bucket, count} end)
    |> Map.new(fn {name, buckets} -> {name, summarize(buckets)} end)
  end

  # Percentiles from log buckets; values in milliseconds.
  defp summarize(buckets) do
    buckets = Enum.sort(buckets)
    total = buckets |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    value = fn bucket -> Float.round(:math.pow(1.1, bucket) / 1000, 2) end

    percentile = fn p ->
      rank = max(round(total * p), 1)

      Enum.reduce_while(buckets, 0, fn {bucket, count}, seen ->
        if seen + count >= rank, do: {:halt, value.(bucket)}, else: {:cont, seen + count}
      end)
    end

    {max_bucket, _} = List.last(buckets)

    %{
      n: total,
      p50: percentile.(0.5),
      p95: percentile.(0.95),
      p99: percentile.(0.99),
      max: value.(max_bucket)
    }
  end

  defp db_sources(rows) do
    rows
    |> Enum.flat_map(fn
      {{:src, source}, count, total_us} -> [%{source: source, n: count, ms: div(total_us, 1000)}]
      _ -> []
    end)
    |> Enum.sort_by(& &1.ms, :desc)
    |> Enum.take(12)
  end

  # `previous` maps pid => reductions at the last sample; the difference,
  # grouped by process label, shows which kinds of processes use the CPU.
  defp process_stats(previous) do
    infos =
      Enum.flat_map(Process.list(), fn pid ->
        case Process.info(pid, [
               :message_queue_len,
               :memory,
               :dictionary,
               :registered_name,
               :reductions
             ]) do
          nil -> []
          info -> [{pid, info}]
        end
      end)

    labelled = Enum.map(infos, fn {pid, info} -> {pid, label(info), info} end)

    top = fn key ->
      labelled
      |> Enum.sort_by(fn {_, _, info} -> info[key] end, :desc)
      |> Enum.take(5)
      |> Enum.map(fn {pid, label, info} ->
        %{
          pid: inspect(pid),
          label: label,
          queue: info[:message_queue_len],
          kb: div(info[:memory], 1024)
        }
      end)
    end

    live_views =
      labelled
      |> Enum.filter(fn {_, label, _} -> String.starts_with?(label, "LV ") end)
      |> Enum.group_by(fn {_, label, _} -> label end, fn {_, _, info} -> info end)
      |> Map.new(fn {label, infos} ->
        queues = Enum.map(infos, & &1[:message_queue_len])

        {label,
         %{
           count: length(infos),
           mem_mb: Float.round(Enum.sum(Enum.map(infos, & &1[:memory])) / 1_048_576, 1),
           queue_total: Enum.sum(queues),
           queue_max: Enum.max(queues, fn -> 0 end)
         }}
      end)

    queues = Enum.map(infos, fn {_, info} -> info[:message_queue_len] end)

    deltas =
      Enum.map(labelled, fn {pid, label, info} ->
        {label, info[:reductions] - Map.get(previous, pid, 0)}
      end)

    total = deltas |> Enum.map(&elem(&1, 1)) |> Enum.sum() |> max(1)

    cpu_share =
      deltas
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
      |> Enum.map(fn {label, values} ->
        {label, Float.round(Enum.sum(values) * 100 / total, 1)}
      end)
      |> Enum.sort_by(&elem(&1, 1), :desc)
      |> Enum.take(10)
      |> Map.new()

    %{
      reductions: Map.new(infos, fn {pid, info} -> {pid, info[:reductions]} end),
      cpu_share: cpu_share,
      mailboxes: %{
        total: Enum.sum(queues),
        over_100: Enum.count(queues, &(&1 > 100)),
        over_1000: Enum.count(queues, &(&1 > 1000))
      },
      top_queue: top.(:message_queue_len),
      top_memory: top.(:memory),
      live_views: live_views
    }
  end

  defp label(info) do
    dictionary = info[:dictionary] || []

    cond do
      match?({Phoenix.LiveView, _, _}, dictionary[:"$process_label"]) ->
        {_, view, _} = dictionary[:"$process_label"]
        "LV " <> (view |> inspect() |> String.replace_prefix("PotokIdeWeb.", ""))

      is_atom(info[:registered_name]) and info[:registered_name] not in [nil, []] ->
        inspect(info[:registered_name])

      initial = dictionary[:"$initial_call"] ->
        inspect(initial)

      true ->
        "other"
    end
  end
end
