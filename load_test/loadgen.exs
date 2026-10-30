# Load generator for the Potok stress test. Started by run.sh inside the
# `loadgen` compose service:
#
#     elixir loadgen.exs --users 1000 --ramp 120 --hold 300 --scenario mix \
#       --data results/users_1000 --out results/<run>
#
# Every virtual user (VU) is one process that behaves like a browser tab: it
# loads the page with its remember-me cookie, fetches avatars once, opens the
# LiveView websocket, joins, sends heartbeats, navigates with live redirects,
# posts and reacts. Latencies go into log-bucket histograms in ETS; the reporter
# prints a line and appends JSON to loadgen.jsonl every 10 s, and summary.json is
# written at the end.
#
# Scenarios:
#   mix       realistic traffic (see LoadGen.User.pick_destination/1 and posters)
#   storm     mix, then every websocket drops and reconnects within --storm-window s
#   biggroup  everyone sits in the community-wide group (or root); posts there at --big-post-rate/s
#   smoke     short mix with probes for the two known crashes (see README.md)
Mix.install([
  {:mint, "~> 1.6"},
  {:mint_web_socket, "~> 1.0"},
  {:jason, "~> 1.4"}
])

defmodule LoadGen.Metrics do
  @tab :loadgen_metrics
  @log_base :math.log(1.1)

  def init do
    :ets.new(@tab, [
      :set,
      :public,
      :named_table,
      write_concurrency: true,
      decentralized_counters: true
    ])

    :persistent_term.put(:loadgen_phase, :ramp)
  end

  def phase, do: :persistent_term.get(:loadgen_phase)
  def set_phase(phase), do: :persistent_term.put(:loadgen_phase, phase)

  def count(name, n \\ 1) do
    key = {:c, name}
    :ets.update_counter(@tab, key, n, {key, 0})
  end

  def get(name) do
    case :ets.lookup(@tab, {:c, name}) do
      [{_, value}] -> value
      [] -> 0
    end
  end

  # `us` is microseconds; buckets are 10% wide.
  def hist(metric, us) do
    bucket = if us < 1, do: 0, else: trunc(:math.log(us) / @log_base)
    bump({:h, :i, metric, bucket})
    bump({:h, :t, metric, bucket})
    if phase() == :hold, do: bump({:h, :hold, metric, bucket})
    :ok
  end

  defp bump(key), do: :ets.update_counter(@tab, key, 1, {key, 0})

  def counters do
    :ets.select(@tab, [{{{:c, :"$1"}, :"$2"}, [], [{{:"$1", :"$2"}}]}]) |> Map.new()
  end

  # Summaries for one scope (:i interval, :t total, :hold); clears :i.
  def summaries(scope) do
    rows =
      :ets.select(@tab, [{{{:h, scope, :"$1", :"$2"}, :"$3"}, [], [{{:"$1", :"$2", :"$3"}}]}])

    if scope == :i, do: :ets.select_delete(@tab, [{{{:h, :i, :_, :_}, :_}, [], [true]}])

    rows
    |> Enum.group_by(&elem(&1, 0), fn {_, bucket, count} -> {bucket, count} end)
    |> Map.new(fn {metric, buckets} -> {metric, summarize(buckets)} end)
  end

  # Percentiles in milliseconds.
  def summarize(buckets) do
    buckets = Enum.sort(buckets)
    total = buckets |> Enum.map(&elem(&1, 1)) |> Enum.sum()
    value = fn bucket -> Float.round(:math.pow(1.1, bucket) / 1000, 1) end

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
end

defmodule LoadGen.Http do
  # One blocking GET chain on a fresh connection (passive mode), following
  # redirects like a browser. Returns {:ok, status, body, cookies, final_path, conn}.
  def get(cfg, path, cookies, redirects \\ 5) do
    case Mint.HTTP.connect(:http, cfg.host, cfg.port,
           mode: :passive,
           protocols: [:http1],
           transport_opts: [timeout: cfg.timeout]
         ) do
      {:ok, conn} -> follow(conn, cfg, path, cookies, redirects)
      {:error, error} -> {:error, connect_error(error), cookies}
    end
  end

  defp follow(conn, cfg, path, cookies, redirects) do
    case request(conn, cfg, path, cookies) do
      {:ok, conn, status, headers, body} ->
        cookies = merge_cookies(cookies, headers)

        case {status, header(headers, "location")} do
          {status, location}
          when status in [301, 302, 303] and is_binary(location) and redirects > 0 ->
            next = URI.parse(location)
            next_path = if next.query, do: "#{next.path}?#{next.query}", else: next.path
            follow(conn, cfg, next_path, cookies, redirects - 1)

          _ ->
            {:ok, status, body, cookies, path, conn}
        end

      {:error, conn, reason} ->
        Mint.HTTP.close(conn)
        {:error, reason, cookies}
    end
  end

  # GET on an open keep-alive connection.
  def request(conn, cfg, path, cookies) do
    headers = [
      {"host", cfg.host_header},
      {"user-agent", "potok-loadgen"},
      {"accept", "text/html"},
      {"cookie", cookie_header(cookies)}
    ]

    case Mint.HTTP.request(conn, "GET", path, headers, nil) do
      {:ok, conn, ref} ->
        deadline = System.monotonic_time(:millisecond) + cfg.timeout
        recv(conn, ref, deadline, nil, [], [])

      {:error, conn, error} ->
        {:error, conn, connect_error(error)}
    end
  end

  defp recv(conn, ref, deadline, status, headers, body) do
    timeout = deadline - System.monotonic_time(:millisecond)

    if timeout <= 0 do
      {:error, conn, :http_timeout}
    else
      case Mint.HTTP.recv(conn, 0, timeout) do
        {:ok, conn, responses} ->
          {status, headers, body, done?} =
            Enum.reduce(responses, {status, headers, body, false}, fn
              {:status, ^ref, s}, {_, h, b, d} -> {s, h, b, d}
              {:headers, ^ref, h}, {s, hs, b, d} -> {s, hs ++ h, b, d}
              {:data, ^ref, data}, {s, h, b, d} -> {s, h, [b | data], d}
              {:done, ^ref}, {s, h, b, _} -> {s, h, b, true}
              _, acc -> acc
            end)

          if done?,
            do: {:ok, conn, status, headers, IO.iodata_to_binary(body)},
            else: recv(conn, ref, deadline, status, headers, body)

        {:error, conn, %Mint.TransportError{reason: :timeout}, _} ->
          {:error, conn, :http_timeout}

        {:error, conn, error, _} ->
          {:error, conn, connect_error(error)}
      end
    end
  end

  def connect_error(%Mint.TransportError{reason: reason}), do: transport_reason(reason)
  def connect_error(%Mint.HTTPError{reason: reason}), do: "http_error_#{inspect(reason)}"
  def connect_error(other), do: inspect(other)

  defp transport_reason(:econnrefused), do: "econnrefused"
  defp transport_reason(:timeout), do: "connect_timeout"
  defp transport_reason(:closed), do: "closed"
  defp transport_reason(reason), do: "transport_#{inspect(reason)}"

  def header(headers, name) do
    Enum.find_value(headers, fn {k, v} -> if String.downcase(k) == name, do: v end)
  end

  def merge_cookies(cookies, headers) do
    Enum.reduce(headers, cookies, fn {k, v}, acc ->
      if String.downcase(k) == "set-cookie" do
        [pair | attrs] = String.split(v, ";")
        expired? = Enum.any?(attrs, &(String.trim(&1) |> String.downcase() == "max-age=0"))

        case String.split(pair, "=", parts: 2) do
          [name, value] when value != "" and not expired? ->
            Map.put(acc, name, :binary.copy(value))

          [name | _] ->
            Map.delete(acc, name)
        end
      else
        acc
      end
    end)
  end

  def cookie_header(cookies), do: Enum.map_join(cookies, "; ", fn {k, v} -> "#{k}=#{v}" end)
end

defmodule LoadGen.User do
  alias LoadGen.{Http, Metrics}

  @header ~r/\A\[(null|"[^"]*"),(null|"[^"]*"),"([^"]*)","([^"]*)",/
  @nonce ~r/ltk(\d+)x(\d+)x(\d+)/
  @heartbeat_ms 30_000
  @reply_timeout_us 30_000_000
  @backoff_ms [1_000, 2_000, 5_000, 10_000, 20_000, 30_000]

  def start(id, user, cfg) do
    Process.spawn(fn -> init(id, user, cfg) end, [:monitor, fullsweep_after: 10])
  end

  defp init(id, user, cfg) do
    :rand.seed(:exsss, {cfg.seed, id, 7})
    role = role(id, cfg)

    state = %{
      id: id,
      user: user,
      cfg: cfg,
      role: role,
      poster?: poster?(role, cfg),
      cookies: %{"_potok_ide_web_account_remember_me" => user.cookie},
      csrf: nil,
      session: nil,
      static: nil,
      topic: nil,
      page: nil,
      live_session: nil,
      conn: nil,
      websocket: nil,
      ws_ref: nil,
      join_ref: nil,
      ref: 0,
      pending: %{},
      joined?: false,
      joined_at_ms: 0,
      failing?: false,
      failures: 0,
      mounts: 0,
      value_ids: [],
      seen: MapSet.new(),
      avatars: MapSet.new(),
      seq: 0,
      url: nil,
      # The page was reached by live navigation; rejoins then send `redirect`, like the JS client.
      redirected?: false,
      closing?: false,
      heartbeat?: false,
      posting?: false,
      parked?: false
    }

    Metrics.count("vu.started")
    Process.send_after(self(), :check_timeouts, 5_000)
    state |> start_session(first_destination(state)) |> schedule_activity() |> loop()
  end

  # Probes (smoke): VUs 1-3 sit on /profiles; VU 4 sits in the big group while
  # VU 0 (a second tab of the same user) edits that user's profile.
  defp role(id, %{scenario: "smoke"}) when id in 1..3, do: :profiles_probe
  defp role(4, %{scenario: "smoke"}), do: :edit_victim
  defp role(0, %{scenario: "smoke"}), do: :profile_editor

  defp role(_id, cfg) do
    if :rand.uniform() < cfg.poster_share, do: :poster, else: :reader
  end

  defp poster?(:poster, _cfg), do: true
  defp poster?(:reader, %{scenario: "biggroup"}), do: true
  defp poster?(:reader, %{scenario: "smoke"}), do: :rand.uniform() < 0.5
  defp poster?(_role, _cfg), do: false

  defp first_destination(%{role: :profiles_probe}), do: :profiles
  defp first_destination(%{role: :profile_editor} = s), do: {:profile_edit, s.user.profile_id}
  defp first_destination(_state), do: :landing

  defp loop(state) do
    receive do
      :stop ->
        close_ws(state)
        exit(:normal)

      message ->
        state |> handle(message) |> loop()
    end
  end

  defp handle(state, :act) do
    state |> act() |> schedule_activity()
  end

  defp handle(state, :post) do
    target = pick_post_target(state)
    state = schedule_post(state)

    cond do
      not state.joined? ->
        state

      state.page == {:group, target} ->
        post(state)

      true ->
        Process.send_after(self(), {:post_in, target}, 2_000 + :rand.uniform(3_000))
        navigate(state, {:group, target})
    end
  end

  defp handle(state, {:post_in, target}) do
    if state.page == {:group, target} and state.joined?, do: post(state), else: state
  end

  defp handle(state, :edit_profile) do
    if state.joined? do
      value =
        URI.encode_query(%{
          "profile[username]" => state.user.username,
          "profile[description]" => "Izmenjeno u load testu #{System.system_time(:second)}"
        })

      Metrics.count("probe.profile_edit_sent")
      push_event(state, "form", "save", value, :event_profile_save)
    else
      Process.send_after(self(), :edit_profile, 5_000)
      state
    end
  end

  defp handle(state, :heartbeat) do
    Process.send_after(self(), :heartbeat, @heartbeat_ms)

    if state.websocket do
      {state, ref} = next_ref(state)
      state = send_frame(state, [nil, ref, "phoenix", "heartbeat", %{}])
      put_pending(state, ref, :heartbeat)
    else
      state
    end
  end

  defp handle(state, :check_timeouts) do
    Process.send_after(self(), :check_timeouts, 5_000)
    now = System.monotonic_time(:microsecond)

    {expired, pending} =
      Enum.split_with(state.pending, fn {_ref, {_kind, t0, _}} -> now - t0 > @reply_timeout_us end)

    state = %{state | pending: Map.new(pending)}

    Enum.reduce(expired, state, fn {_ref, {kind, _, _}}, state ->
      if kind in [:join, :nav_join, :rejoin] do
        state |> close_ws() |> fail("timeout_#{kind}")
      else
        Metrics.count("timeout.#{kind}")
        state
      end
    end)
  end

  defp handle(state, :storm) do
    Metrics.count("storm.dropped")
    state = close_ws(state)
    Process.send_after(self(), :reconnect, :rand.uniform(state.cfg.storm_window * 1000))
    state
  end

  defp handle(state, :reconnect), do: reconnect(state)
  defp handle(state, {:retry, destination}), do: start_session(state, destination)

  defp handle(state, {:rejoin, join_ref}) when join_ref == state.join_ref,
    do: join(state, :rejoin)

  defp handle(state, {:rejoin, _stale}), do: state

  defp handle(%{conn: conn} = state, message) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        Enum.reduce(responses, state, &ws_response/2)

      {:error, conn, _error, _responses} ->
        %{state | conn: conn} |> ws_lost("ws_error")

      :unknown ->
        state
    end
  end

  defp handle(state, _message), do: state

  defp ws_response({:data, ref, data}, %{ws_ref: ref, websocket: ws} = state) when ws != nil do
    case Mint.WebSocket.decode(ws, data) do
      {:ok, ws, frames} -> Enum.reduce(frames, %{state | websocket: ws}, &ws_frame/2)
      {:error, ws, _reason} -> %{state | websocket: ws} |> ws_lost("ws_decode")
    end
  end

  defp ws_response({:done, ref}, %{ws_ref: ref} = state), do: ws_lost(state, "ws_done")
  defp ws_response(_response, state), do: state

  defp ws_frame({:text, frame}, state) do
    Metrics.count("bytes.recv", byte_size(frame))
    Metrics.count("frames.recv")

    case Regex.run(@header, frame, capture: :all_but_first) do
      [_join_ref, ref, topic, "phx_reply"] ->
        reply(state, unquote_ref(ref), topic, frame)

      [_join_ref, _ref, topic, "diff"] when topic == state.topic ->
        scan_nonces(state, frame)

      [join_ref, _ref, topic, "phx_error"] when topic == state.topic ->
        lv_error(state, unquote_ref(join_ref))

      [_join_ref, _ref, topic, "phx_close"] when topic == state.topic ->
        state

      [_join_ref, _ref, topic, event]
      when topic == state.topic and event in ["live_redirect", "redirect"] ->
        server_redirect(state, event, frame)

      _ ->
        state
    end
  end

  defp ws_frame({:ping, data}, state), do: send_ws(state, {:pong, data})
  defp ws_frame({:close, code, _reason}, state), do: ws_lost(state, "ws_close_#{code}")
  defp ws_frame(_frame, state), do: state

  defp unquote_ref("null"), do: nil
  defp unquote_ref(quoted), do: String.trim(quoted, "\"")

  defp reply(state, ref, _topic, frame) do
    case Map.pop(state.pending, ref) do
      {nil, _} ->
        state

      {{kind, t0, meta}, pending} ->
        state = %{state | pending: pending}
        Metrics.hist(kind, System.monotonic_time(:microsecond) - t0)
        payload = frame |> Jason.decode!() |> Enum.at(4)
        handle_reply(state, kind, meta, payload, frame)
    end
  end

  defp handle_reply(state, kind, join_ref, %{"status" => "ok"}, frame)
       when kind in [:join, :nav_join, :rejoin] do
    if join_ref == state.join_ref do
      Metrics.count("join.ok.#{kind}")
      debug(state, "joined #{kind} #{inspect(state.page)}")
      ids = Regex.scan(~r/"value-(\d+)"/, frame, capture: :all_but_first)

      %{
        state
        | value_ids:
            ids |> Enum.map(fn [id] -> String.to_integer(id) end) |> Enum.uniq() |> Enum.take(-20),
          joined_at_ms: System.system_time(:millisecond),
          mounts: state.mounts + 1,
          failures: 0,
          redirected?: kind == :nav_join or (kind == :rejoin and state.redirected?)
      }
      |> set_joined(true)
      |> set_failing(false)
    else
      state
    end
  end

  defp handle_reply(state, kind, join_ref, %{"status" => "error", "response" => response}, _frame)
       when kind in [:join, :nav_join, :rejoin] do
    if join_ref == state.join_ref do
      case response do
        %{"live_redirect" => %{"to" => to}} ->
          Metrics.count("join.live_redirect")
          live_navigate(state, to)

        %{"redirect" => %{"to" => to}} ->
          Metrics.count("join.redirect")
          full_load(state, to)

        %{"reason" => reason} ->
          state |> close_ws() |> fail("join_#{reason}")

        other ->
          IO.puts("[vu #{state.id}] join error #{inspect(other) |> String.slice(0, 200)}")
          state |> close_ws() |> fail("join_other")
      end
    else
      state
    end
  end

  defp handle_reply(state, :heartbeat, _meta, _payload, _frame), do: state

  defp handle_reply(state, kind, _meta, %{"status" => "ok"} = payload, _frame) do
    Metrics.count("event.ok.#{kind}")
    debug(state, "#{kind} ok on #{inspect(state.page)}")

    case payload do
      %{"response" => %{"live_redirect" => %{"to" => to}}} -> live_navigate(state, to)
      %{"response" => %{"redirect" => %{"to" => to}}} -> full_load(state, to)
      _ -> state
    end
  end

  defp handle_reply(state, kind, _meta, payload, _frame) do
    Metrics.count("err.event_#{kind}_#{payload["status"]}")
    state
  end

  # The LiveView process died (crash or server-side stop). The JS client
  # rejoins after a backoff; do the same.
  defp lv_error(state, join_ref) do
    debug(
      state,
      "phx_error on #{inspect(state.page)} (current join? #{join_ref == state.join_ref})"
    )

    if join_ref == state.join_ref and state.joined? do
      Metrics.count("err.lv_crash.#{page_kind(state.page)}")
      if state.role == :edit_victim, do: Metrics.count("probe.edit_victim_crash")
      if state.role == :profiles_probe, do: Metrics.count("probe.profiles_crash")
      Process.send_after(self(), {:rejoin, state.join_ref}, 1_000 + :rand.uniform(1_000))
      set_joined(state, false)
    else
      state
    end
  end

  defp server_redirect(state, event, frame) do
    debug(state, "server #{event}: #{String.slice(frame, 0, 200)}")

    case frame |> Jason.decode!() |> Enum.at(4) do
      %{"to" => to} when event == "live_redirect" -> live_navigate(state, to)
      %{"to" => to} -> full_load(state, to)
      _ -> state
    end
  end

  # Delivery latency: posts carry "ltk<ms>x<vu>x<seq>". Count each foreign
  # nonce once, and only for posts made after this page was joined.
  defp scan_nonces(state, frame) do
    if :binary.match(frame, "ltk") == :nomatch do
      state
    else
      now = System.system_time(:millisecond)

      Regex.scan(@nonce, frame, capture: :all_but_first)
      |> Enum.reduce(state, fn [ms, vu, seq], state ->
        key = {vu, seq}
        ms = String.to_integer(ms)

        cond do
          vu == Integer.to_string(state.id) ->
            state

          ms < state.joined_at_ms ->
            state

          MapSet.member?(state.seen, key) ->
            state

          true ->
            Metrics.hist(delivery_metric(state.page), (now - ms) * 1000)
            seen = if MapSet.size(state.seen) > 500, do: MapSet.new(), else: state.seen
            %{state | seen: MapSet.put(seen, key)}
        end
      end)
    end
  end

  defp delivery_metric({:group, _}), do: :delivery_chat
  defp delivery_metric(:root), do: :delivery_root
  defp delivery_metric(_), do: :delivery_other

  # ---- activity ----

  defp schedule_activity(%{role: :profiles_probe} = state), do: state

  # Goes to the big group once and stays there.
  defp schedule_activity(%{role: :edit_victim, parked?: false} = state) do
    Process.send_after(self(), :act, 3_000)
    %{state | parked?: true}
  end

  defp schedule_activity(%{role: :edit_victim} = state), do: state

  defp schedule_activity(%{role: :profile_editor} = state) do
    Process.send_after(self(), :edit_profile, 20_000)
    state
  end

  defp schedule_activity(state) do
    cfg = state.cfg
    Process.send_after(self(), :act, think_ms(cfg.think_min, cfg.think_max))

    if state.poster? and not state.posting?,
      do: schedule_post(%{state | posting?: true}),
      else: state
  end

  defp schedule_post(%{cfg: %{scenario: "biggroup"} = cfg} = state) do
    # Exponential gaps so all VUs together post about --big-post-rate per second.
    mean_ms = cfg.users * 1000 / cfg.big_post_rate
    Process.send_after(self(), :post, round(-:math.log(:rand.uniform()) * mean_ms) + 1)
    state
  end

  defp schedule_post(state) do
    Process.send_after(self(), :post, think_ms(state.cfg.post_min, state.cfg.post_max))
    state
  end

  defp think_ms(min_s, max_s), do: round((min_s + :rand.uniform() * (max_s - min_s)) * 1000)

  defp act(%{role: :edit_victim} = state), do: navigate(state, {:group, state.cfg.big_group_id})

  defp act(%{cfg: %{scenario: "biggroup"}} = state) do
    destination = if :rand.uniform() < 0.7, do: {:group, state.cfg.big_group_id}, else: :root
    if state.page == destination, do: state, else: navigate(state, destination)
  end

  defp act(state) do
    cond do
      not state.joined? ->
        state

      state.page == :landing or :rand.uniform() < 0.3 ->
        navigate(state, pick_destination(state))

      match?({:group, _}, state.page) and state.value_ids != [] and :rand.uniform() < 0.15 ->
        react(state)

      true ->
        state
    end
  end

  # Where a reader goes next: root (the landing page), one of their groups or
  # DMs, invitations/requests, or the profile list (another live_session).
  defp pick_destination(state) do
    r = :rand.uniform()
    places = state.user.groups ++ state.user.dms

    cond do
      r < 0.45 or places == [] -> :root
      r < 0.85 -> {:group, Enum.random(places)}
      r < 0.90 -> :invitations
      r < 0.95 -> :requests
      true -> :profiles
    end
  end

  defp pick_post_target(%{cfg: %{scenario: "biggroup"} = cfg}), do: cfg.big_group_id

  defp pick_post_target(state) do
    others = (state.user.groups -- [state.cfg.big_group_id]) ++ state.user.dms

    if others == [] or :rand.uniform() < state.cfg.big_post_share,
      do: state.cfg.big_group_id,
      else: Enum.random(others)
  end

  defp post(state) do
    seq = state.seq + 1

    text =
      "ltk#{System.system_time(:millisecond)}x#{state.id}x#{seq} Poruka iz load testa, #{seq}."

    field = URI.encode_www_form("value[content]")
    body = "#{field}=#{URI.encode_www_form(text)}"

    %{state | seq: seq}
    |> push_event("form", "validate_value", "#{body}&_target=#{field}", :event_validate)
    |> push_event("form", "create_value", body, :event_post)
    |> tap(fn _ -> Metrics.count("posts.sent") end)
  end

  defp react(state) do
    value = %{"id" => Integer.to_string(Enum.random(state.value_ids)), "emoji" => "👍"}
    push_event(state, "click", "toggle_reaction", value, :event_react)
  end

  defp push_event(%{joined?: false} = state, _type, _event, _value, _kind), do: state

  defp push_event(state, type, event, value, kind) do
    {state, ref} = next_ref(state)

    state =
      send_frame(state, [
        state.join_ref,
        ref,
        state.topic,
        "event",
        %{type: type, event: event, value: value}
      ])

    put_pending(state, ref, kind)
  end

  # ---- navigation ----

  defp path_for(:landing, _state), do: "/groups"
  defp path_for(:root, state), do: "/groups/#{state.cfg.root_id}"
  defp path_for({:group, id}, _state), do: "/groups/#{id}"
  defp path_for(:invitations, _state), do: "/invitations"
  defp path_for(:requests, _state), do: "/requests"
  defp path_for(:profiles, _state), do: "/profiles"
  defp path_for({:profile_edit, id}, _state), do: "/profiles/#{id}/edit"

  defp live_session_for(:profiles), do: :authenticated
  defp live_session_for({:profile_edit, _id}), do: :authenticated
  defp live_session_for(_dest), do: :profile_required

  defp page_kind({:group, _}), do: "group"
  defp page_kind({:profile_edit, _}), do: "profile_edit"
  defp page_kind(page), do: to_string(page)

  defp page_for_path(path, state) do
    root = "/groups/#{state.cfg.root_id}"

    case String.split(path, ["?", "#"]) |> hd() do
      ^root ->
        :root

      "/groups" ->
        :landing

      "/groups/" <> rest ->
        {:group, rest |> String.split("/") |> hd() |> String.to_integer()}

      "/invitations" ->
        :invitations

      "/requests" ->
        :requests

      "/profiles" ->
        :profiles

      "/profiles/" <> rest ->
        {:profile_edit, rest |> String.split("/") |> hd() |> String.to_integer()}

      other ->
        {:other, other}
    end
  rescue
    _ -> {:other, path}
  end

  defp navigate(state, destination) do
    cond do
      state.page == destination ->
        state

      state.joined? and live_session_for(destination) == state.live_session ->
        Metrics.count("nav.live")
        do_live_navigate(state, destination, path_for(destination, state))

      true ->
        Metrics.count("nav.full")
        state |> close_ws() |> start_session(destination)
    end
  end

  defp live_navigate(state, to) do
    path = URI.parse(to).path
    destination = page_for_path(path, state)

    if state.websocket && live_session_for(destination) == state.live_session,
      do: do_live_navigate(state, destination, path),
      else: full_load(state, path)
  end

  # Like the JS client: leave the old channel, join the same topic again
  # with `redirect` set; the session and static tokens stay the same.
  defp do_live_navigate(state, destination, path) do
    {state, ref} = next_ref(state)
    state = send_frame(state, [state.join_ref, ref, state.topic, "phx_leave", %{}])
    %{state | page: destination, url: url(path)} |> set_joined(false) |> join(:nav_join)
  end

  defp full_load(state, path) do
    state |> close_ws() |> start_session({:path, path})
  end

  # ---- sessions: page load, websocket, join ----

  defp start_session(state, destination) do
    path =
      case destination do
        {:path, path} -> path
        destination -> path_for(destination, state)
      end

    t0 = System.monotonic_time(:microsecond)

    case Http.get(state.cfg, path, state.cookies) do
      {:ok, 200, body, cookies, final_path, conn} ->
        Metrics.hist(:page, System.monotonic_time(:microsecond) - t0)
        Metrics.count("http.200")
        state = %{state | cookies: cookies}
        page = page_for_path(final_path, state)

        with {:ok, csrf, session, static, lv_id} <- parse_page(body) do
          state = fetch_avatars(state, conn, body)

          %{
            state
            | csrf: csrf,
              session: session,
              static: static,
              topic: "lv:" <> lv_id,
              page: page,
              live_session: live_session_for(page),
              mounts: 0
          }
          |> Map.put(:url, url(final_path))
          |> connect_and_join(:join)
        else
          :error ->
            Mint.HTTP.close(conn)

            if String.starts_with?(final_path, "/accounts/log-in"),
              do: fail(state, "auth_redirect"),
              else: fail(state, "page_parse")
        end

      {:ok, status, _body, _cookies, final_path, conn} ->
        Mint.HTTP.close(conn)
        Metrics.hist(:page, System.monotonic_time(:microsecond) - t0)
        Metrics.count("http.#{status}")
        IO.puts("[vu #{state.id}] GET #{final_path} -> #{status}")
        fail(state, "http_#{status}", destination)

      {:error, reason, _cookies} ->
        fail(state, reason, destination)
    end
  end

  defp parse_page(body) do
    with [_, csrf] <- Regex.run(~r/<meta name="csrf-token" content="([^"]+)"/, body),
         [tag] <- Regex.run(~r/<[a-z]+[^>]*data-phx-main[^>]*>/, body),
         [_, session] <- Regex.run(~r/data-phx-session="([^"]+)"/, tag),
         [_, static] <- Regex.run(~r/data-phx-static="([^"]*)"/, tag),
         [_, lv_id] <- Regex.run(~r/\bid="(phx-[^"]+)"/, tag) do
      {:ok, :binary.copy(csrf), :binary.copy(session), :binary.copy(static), :binary.copy(lv_id)}
    else
      _ -> :error
    end
  end

  # Avatars are generated by ImageMagick on a cache miss; a browser loads
  # each one once (then caches it), in parallel with the websocket. With
  # --no-avatars every browser already has them cached.
  defp fetch_avatars(%{cfg: %{avatars: false}} = state, conn, _body) do
    Mint.HTTP.close(conn)
    state
  end

  defp fetch_avatars(state, conn, body) do
    new =
      Regex.scan(~r{/avatar/(?:profile|group)/\d+[^"'\s)&]*}, body)
      |> Enum.map(&hd/1)
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(state.avatars, &1))
      |> Enum.take(10)
      |> Enum.map(&:binary.copy/1)

    Mint.HTTP.close(conn)
    %{cfg: cfg, cookies: cookies} = state

    # Its own connection, like a browser's parallel image requests.
    if new != [] do
      spawn(fn ->
        case Mint.HTTP.connect(:http, cfg.host, cfg.port, mode: :passive, protocols: [:http1]) do
          {:ok, conn} -> fetch_avatar_paths(conn, cfg, cookies, new)
          {:error, error} -> Metrics.count("err.avatar_#{Http.connect_error(error)}")
        end
      end)
    end

    %{state | avatars: Enum.into(new, state.avatars)}
  end

  defp fetch_avatar_paths(conn, _cfg, _cookies, []), do: Mint.HTTP.close(conn)

  defp fetch_avatar_paths(conn, cfg, cookies, [path | rest]) do
    t0 = System.monotonic_time(:microsecond)

    case Http.request(conn, cfg, path, cookies) do
      {:ok, conn, status, _headers, _body} ->
        Metrics.hist(:avatar, System.monotonic_time(:microsecond) - t0)
        if status != 200, do: Metrics.count("err.avatar_#{status}")
        fetch_avatar_paths(conn, cfg, cookies, rest)

      {:error, conn, reason} ->
        Metrics.count("err.avatar_#{reason}")
        Mint.HTTP.close(conn)
    end
  end

  defp connect_and_join(state, kind) do
    cfg = state.cfg
    t0 = System.monotonic_time(:microsecond)

    with {:ok, conn} <-
           Mint.HTTP.connect(:http, cfg.host, cfg.port,
             protocols: [:http1],
             transport_opts: [timeout: cfg.timeout]
           ),
         path =
           "/live/websocket?" <>
             URI.encode_query(%{"_csrf_token" => state.csrf, "vsn" => "2.0.0"}),
         headers = [
           {"host", cfg.host_header},
           {"origin", cfg.origin},
           {"user-agent", "potok-loadgen"},
           {"cookie", Http.cookie_header(state.cookies)}
         ],
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(:ws, conn, path, headers),
         {:ok, conn, websocket} <-
           await_upgrade(conn, ref, System.monotonic_time(:millisecond) + cfg.timeout) do
      Metrics.hist(:ws_open, System.monotonic_time(:microsecond) - t0)

      if not state.heartbeat?, do: Process.send_after(self(), :heartbeat, @heartbeat_ms)

      %{state | conn: conn, websocket: websocket, ws_ref: ref, closing?: false, heartbeat?: true}
      |> join(kind)
    else
      {:error, %Mint.TransportError{} = error} ->
        fail(state, Http.connect_error(error))

      {:error, conn, error} ->
        Mint.HTTP.close(conn)
        fail(state, "ws_upgrade_#{upgrade_error(error)}")

      {:error, error} ->
        fail(state, "ws_upgrade_#{upgrade_error(error)}")
    end
  end

  defp upgrade_error(%Mint.WebSocket.UpgradeFailureError{status_code: status}), do: status
  defp upgrade_error(%Mint.TransportError{reason: reason}), do: reason
  defp upgrade_error(other), do: other |> inspect() |> String.slice(0, 40)

  defp await_upgrade(conn, ref, deadline, acc \\ %{}) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      message when elem(message, 0) in [:tcp, :tcp_closed, :tcp_error] ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            acc =
              Enum.reduce(responses, acc, fn
                {:status, ^ref, status}, acc -> Map.put(acc, :status, status)
                {:headers, ^ref, headers}, acc -> Map.put(acc, :headers, headers)
                {:done, ^ref}, acc -> Map.put(acc, :done, true)
                _, acc -> acc
              end)

            if acc[:done],
              do: Mint.WebSocket.new(conn, ref, acc.status, acc.headers),
              else: await_upgrade(conn, ref, deadline, acc)

          {:error, conn, error, _} ->
            {:error, conn, error}

          :unknown ->
            await_upgrade(conn, ref, deadline, acc)
        end
    after
      timeout -> {:error, conn, %Mint.TransportError{reason: :timeout}}
    end
  end

  defp join(state, kind) do
    {state, ref} = next_ref(state)
    join_ref = ref

    params = %{
      "_csrf_token" => state.csrf,
      "_mounts" => state.mounts,
      "_mount_attempts" => 0,
      "_live_referer" => nil
    }

    payload =
      if kind == :nav_join or (kind == :rejoin and state.redirected?),
        do: %{
          redirect: state.url,
          params: params,
          session: state.session,
          static: state.static,
          sticky: false
        },
        else: %{
          url: state.url,
          params: params,
          session: state.session,
          static: state.static,
          sticky: false
        }

    state = %{state | join_ref: join_ref}
    state = send_frame(state, [join_ref, ref, state.topic, "phx_join", payload])
    put_pending(state, ref, kind, join_ref)
  end

  # Socket reconnect after a drop (storm or server close): new websocket,
  # rejoin the same page with the same session, like the JS client.
  defp reconnect(%{session: nil} = state), do: start_session(state, :landing)

  defp reconnect(state) do
    Metrics.count("ws.reconnect")
    state |> close_ws() |> connect_and_join(:rejoin)
  end

  defp ws_lost(state, reason) do
    if state.closing?,
      do: state,
      else: state |> close_ws() |> fail(reason, :reconnect)
  end

  defp close_ws(%{conn: nil} = state), do: set_joined(state, false)

  defp close_ws(state) do
    Mint.HTTP.close(state.conn)

    %{state | conn: nil, websocket: nil, ws_ref: nil, pending: %{}, closing?: true}
    |> set_joined(false)
  end

  # Errors put the VU into backoff, then it retries (a browser would reload).
  defp fail(state, reason, retry \\ nil) do
    Metrics.count("err.#{reason}")
    debug(state, "fail #{reason} on #{inspect(state.page)}")
    attempt = state.failures
    delay = Enum.at(@backoff_ms, attempt, List.last(@backoff_ms))
    jitter = :rand.uniform(div(delay, 2) + 1)

    message =
      case retry do
        :reconnect -> :reconnect
        nil -> {:retry, state.page || :landing}
        destination -> {:retry, destination}
      end

    Process.send_after(self(), message, delay + jitter)
    %{state | failures: attempt + 1} |> set_failing(true)
  end

  defp set_joined(%{joined?: same} = state, same), do: state

  defp set_joined(state, joined?) do
    Metrics.count("vu.connected", if(joined?, do: 1, else: -1))
    %{state | joined?: joined?}
  end

  defp set_failing(%{failing?: same} = state, same), do: state

  defp set_failing(state, failing?) do
    Metrics.count("vu.failing", if(failing?, do: 1, else: -1))
    %{state | failing?: failing?}
  end

  defp next_ref(state) do
    ref = state.ref + 1
    {%{state | ref: ref}, Integer.to_string(ref)}
  end

  defp put_pending(state, ref, kind, meta \\ nil) do
    %{
      state
      | pending: Map.put(state.pending, ref, {kind, System.monotonic_time(:microsecond), meta})
    }
  end

  defp send_frame(state, message), do: send_ws(state, {:text, Jason.encode!(message)})

  defp send_ws(%{websocket: nil} = state, _frame), do: state

  defp send_ws(state, frame) do
    with {:ok, websocket, data} <- Mint.WebSocket.encode(state.websocket, frame),
         {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ws_ref, data) do
      %{state | websocket: websocket, conn: conn}
    else
      {:error, %Mint.HTTP1{} = conn, _reason} -> %{state | conn: conn} |> ws_lost("ws_send")
      {:error, _websocket_or_conn, _reason} -> ws_lost(state, "ws_send")
    end
  end

  defp url(path), do: "https://localhost" <> path

  defp debug(state, message) do
    if state.id in state.cfg.debug, do: IO.puts("[vu #{state.id}] #{message}")
  end
end

defmodule LoadGen.Main do
  alias LoadGen.{Metrics, User}

  @report_ms 10_000

  def run(argv) do
    {opts, _, _} =
      OptionParser.parse(argv,
        strict: [
          users: :integer,
          ramp: :integer,
          hold: :integer,
          scenario: :string,
          data: :string,
          out: :string,
          host: :string,
          port: :integer,
          think_min: :float,
          think_max: :float,
          poster_share: :float,
          post_min: :float,
          post_max: :float,
          big_post_share: :float,
          big_post_rate: :float,
          storm_window: :integer,
          seed: :integer,
          debug: :string,
          avatars: :boolean
        ]
      )

    scenario = Keyword.get(opts, :scenario, "mix")
    smoke? = scenario == "smoke"
    data = Keyword.fetch!(opts, :data)
    meta = data |> Kernel.<>(".json") |> File.read!() |> Jason.decode!()
    users = load_users(data <> ".csv")
    count = Keyword.fetch!(opts, :users)
    if count > length(users), do: raise("#{data}.csv has only #{length(users)} users")

    cfg = %{
      users: count,
      ramp: Keyword.get(opts, :ramp, 60),
      hold: Keyword.get(opts, :hold, 120),
      scenario: scenario,
      out: Keyword.fetch!(opts, :out),
      host: Keyword.get(opts, :host, "app"),
      port: Keyword.get(opts, :port, 8080),
      host_header: "localhost",
      origin: "https://potok.rs",
      timeout: 30_000,
      think_min: Keyword.get(opts, :think_min, if(smoke?, do: 5.0, else: 20.0)),
      think_max: Keyword.get(opts, :think_max, if(smoke?, do: 15.0, else: 60.0)),
      poster_share: Keyword.get(opts, :poster_share, 0.1),
      post_min: Keyword.get(opts, :post_min, if(smoke?, do: 5.0, else: 30.0)),
      post_max: Keyword.get(opts, :post_max, if(smoke?, do: 15.0, else: 90.0)),
      big_post_share: Keyword.get(opts, :big_post_share, if(smoke?, do: 0.5, else: 0.05)),
      big_post_rate: Keyword.get(opts, :big_post_rate, 1.0),
      storm_window: Keyword.get(opts, :storm_window, 5),
      seed: Keyword.get(opts, :seed, 1),
      # Comma-separated VU ids whose joins and errors are printed.
      avatars: Keyword.get(opts, :avatars, true),
      debug:
        opts
        |> Keyword.get(:debug, "")
        |> String.split(",", trim: true)
        |> Enum.map(&String.to_integer/1),
      root_id: meta["root_id"],
      big_group_id: meta["big_group_id"]
    }

    File.mkdir_p!(cfg.out)
    File.write!(Path.join(cfg.out, "loadgen_config.json"), Jason.encode!(cfg, pretty: true))
    Metrics.init()
    :persistent_term.put(:loadgen_abort, nil)
    reporter = spawn_link(fn -> reporter(cfg) end)
    IO.puts("[loadgen] #{scenario}: #{count} users, ramp #{cfg.ramp}s, hold #{cfg.hold}s")

    users = Enum.take(users, count)
    interval = cfg.ramp * 1000 / max(count, 1)
    started_at = System.monotonic_time(:millisecond)

    vus =
      users
      |> Enum.with_index(1)
      |> Enum.reduce_while([], fn {user, id}, acc ->
        wait_until(started_at + round((id - 1) * interval))

        if aborted?(),
          do: {:halt, acc},
          else: {:cont, [User.start(id, user, cfg) | acc]}
      end)

    # Smoke: a second tab of VU 4's user, which edits the profile.
    vus = if smoke? and count >= 4, do: [User.start(0, Enum.at(users, 3), cfg) | vus], else: vus

    Metrics.set_phase(:hold)
    IO.puts("[loadgen] ramp done (#{length(vus)} VUs), holding #{cfg.hold}s")

    if scenario == "storm" do
      Process.send_after(self(), :storm, div(cfg.hold * 1000, 3))
    end

    hold_until = System.monotonic_time(:millisecond) + cfg.hold * 1000
    hold(vus, hold_until)

    Metrics.set_phase(:stop)
    Enum.each(vus, fn {pid, _ref} -> send(pid, :stop) end)
    wait_down(vus, System.monotonic_time(:millisecond) + 15_000)
    send(reporter, {:final, self()})

    receive do
      :reported -> :ok
    after
      15_000 -> :ok
    end

    summary(cfg, length(vus))
  end

  defp load_users(path) do
    path
    |> File.stream!()
    |> Stream.drop(1)
    |> Stream.map(&String.trim_trailing/1)
    |> Stream.reject(&(&1 == ""))
    |> Enum.map(fn line ->
      [profile_id, username, cookie, groups, dms] = String.split(line, ",")

      %{
        profile_id: String.to_integer(profile_id),
        username: username,
        cookie: cookie,
        groups: ids(groups),
        dms: ids(dms)
      }
    end)
  end

  defp ids(""), do: []
  defp ids(list), do: list |> String.split(" ") |> Enum.map(&String.to_integer/1)

  defp wait_until(at) do
    delay = at - System.monotonic_time(:millisecond)
    if delay > 0, do: Process.sleep(delay)
  end

  defp hold(vus, until) do
    timeout = max(until - System.monotonic_time(:millisecond), 0)

    receive do
      :storm ->
        IO.puts("[loadgen] storm: dropping every websocket")
        Enum.each(vus, fn {pid, _ref} -> send(pid, :storm) end)
        hold(vus, until)

      # A VU process crashed: a loadgen bug, not a server error. Log it so a
      # broken harness does not pass for a healthy server.
      {:DOWN, ref, :process, _pid, reason} ->
        Metrics.count("loadgen.vu_crash")
        IO.puts("[loadgen] VU crashed: #{inspect(reason) |> String.slice(0, 600)}")
        hold(List.keydelete(vus, ref, 1), until)
    after
      min(timeout, 1_000) ->
        cond do
          aborted?() -> :aborted
          timeout <= 1_000 -> :done
          true -> hold(vus, until)
        end
    end
  end

  defp wait_down([], _deadline), do: :ok

  defp wait_down(vus, deadline) do
    timeout = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:DOWN, ref, :process, _pid, _reason} -> wait_down(List.keydelete(vus, ref, 1), deadline)
    after
      timeout -> :ok
    end
  end

  defp aborted?, do: :persistent_term.get(:loadgen_abort) != nil

  # ---- reporting ----

  defp reporter(cfg) do
    state = %{
      cfg: cfg,
      started: System.monotonic_time(:millisecond),
      last: %{},
      sched: :scheduler.sample_all(),
      bad_intervals: 0,
      peak_connected: 0
    }

    Process.send_after(self(), :report, @report_ms)
    reporter_loop(state)
  end

  defp reporter_loop(state) do
    receive do
      :report ->
        Process.send_after(self(), :report, @report_ms)
        state |> report() |> reporter_loop()

      {:final, from} ->
        state = report(state)
        :persistent_term.put(:loadgen_peak_connected, state.peak_connected)
        send(from, :reported)
    end
  end

  defp report(state) do
    counters = Metrics.counters()
    hist = Metrics.summaries(:i)
    sched = :scheduler.sample_all()
    # Normal schedulers only; `:total` also averages in the idle dirty IO ones.
    normal = for {:normal, _id, value, _} <- :scheduler.utilization(state.sched, sched), do: value
    util = Float.round(Enum.sum(normal) / max(length(normal), 1) * 100, 1)

    delta = Map.new(counters, fn {k, v} -> {k, v - Map.get(state.last, k, 0)} end)
    started = Map.get(counters, "vu.started", 0)
    connected = Map.get(counters, "vu.connected", 0)
    failing = Map.get(counters, "vu.failing", 0)
    elapsed = div(System.monotonic_time(:millisecond) - state.started, 1000)

    errors =
      delta
      |> Enum.filter(fn {k, v} -> String.starts_with?(k, ["err.", "timeout."]) and v > 0 end)
      |> Map.new()

    line = %{
      t: elapsed,
      phase: Metrics.phase(),
      started: started,
      connected: connected,
      failing: failing,
      counters: delta,
      hist: hist,
      loadgen_cpu_pct: util,
      loadgen_mem_mb: div(:erlang.memory(:total), 1_048_576)
    }

    File.write!(Path.join(state.cfg.out, "loadgen.jsonl"), [Jason.encode!(line), "\n"], [:append])

    p = fn metric, key -> get_in(hist, [metric, key]) || "-" end

    IO.puts(
      "[#{elapsed}s #{Metrics.phase()}] vu=#{started} conn=#{connected} failing=#{failing} " <>
        "join p50/p95=#{p.(:join, :p50)}/#{p.(:join, :p95)}ms nav p95=#{p.(:nav_join, :p95)} " <>
        "post p95=#{p.(:event_post, :p95)} deliv p95=#{p.(:delivery_chat, :p95)} " <>
        "hb p95=#{p.(:heartbeat, :p95)} rx=#{div(Map.get(delta, "bytes.recv", 0), 1_048_576)}MB " <>
        "lg_cpu=#{util}% errs=#{inspect(errors)}"
    )

    # Abort when more than half the VUs have been failing for a minute.
    bad = started > 20 and failing > started / 2
    bad_intervals = if bad, do: state.bad_intervals + 1, else: 0

    if bad_intervals >= 6 and :persistent_term.get(:loadgen_abort) == nil do
      reason = "#{failing}/#{started} VUs failing for 60 s"
      IO.puts("[loadgen] ABORT: #{reason}")
      :persistent_term.put(:loadgen_abort, reason)
    end

    %{
      state
      | last: counters,
        sched: sched,
        bad_intervals: bad_intervals,
        peak_connected: max(state.peak_connected, connected)
    }
  end

  defp summary(cfg, vus) do
    summary = %{
      scenario: cfg.scenario,
      users: cfg.users,
      vus_started: vus,
      peak_connected: :persistent_term.get(:loadgen_peak_connected, 0),
      aborted: :persistent_term.get(:loadgen_abort),
      counters: Metrics.counters(),
      total: Metrics.summaries(:t),
      hold: Metrics.summaries(:hold)
    }

    File.write!(Path.join(cfg.out, "summary.json"), Jason.encode!(summary, pretty: true))
    IO.puts("\n[loadgen] summary (hold phase, ms):")

    for {metric, s} <- Enum.sort(summary.hold) do
      IO.puts(
        "  #{String.pad_trailing(to_string(metric), 18)} n=#{s.n} p50=#{s.p50} p95=#{s.p95} p99=#{s.p99} max=#{s.max}"
      )
    end

    IO.puts(
      "[loadgen] peak connected #{summary.peak_connected}/#{cfg.users}, aborted: #{inspect(summary.aborted)}"
    )

    errors =
      summary.counters
      |> Enum.filter(fn {k, v} ->
        String.starts_with?(k, ["err.", "timeout.", "probe."]) and v > 0
      end)
      |> Enum.sort_by(&elem(&1, 1), :desc)

    IO.puts("[loadgen] errors/probes: #{inspect(errors)}")
  end
end

LoadGen.Main.run(System.argv())
