#!/usr/bin/env bash
# Runs one stress-test scenario against the production release in Docker.
#
#   ./run.sh --profile fly --scale 1k --scenario mix --users 1000 --ramp 120 --hold 300
#
#   --profile fly|throttled|big|cluster
#                       fly = a Fly shared-cpu-1x 512 MB machine: 1 CPU, one scheduler, and 425 MB, what
#                         the BEAM can use there (the VM sees 461 MB; hallpass, init and the kernel take
#                         the rest; measured on prod 2026-11-09). throttled = the same once Fly's CPU quota
#                         has run out: 0.0625 CPU (5 ms per 80 ms). big = 6 CPU / 3 GB. cluster = two
#                         connected nodes of 3 CPU / 1.2 GB with the users split between them.
#                         fly4 = the machine of fly.toml since v432 (shared-cpu-4x, 1 GB, 512 MB swap):
#                         4 CPUs, four schedulers, 928 MB (the VM sees 964 MiB, measured 2026-11-11) and
#                         512 MB swap. throttled4 = the same once the burst balance has run out: Fly's
#                         quota is shared by the vCPUs, 4 x 5 ms per 80 ms = 0.25 CPU for the machine
#   --cpus N, --mem M   override the profile's CPU and memory limits (e.g. --mem 512M)
#   --swap MB           override the profile's swap (0 = none)
#   --erl-flags "..."   extra VM flags for this run (e.g. "+sbwt none"), no rebuild needed
#   --scale 1k|10k      which seeded database to use (potok_load_1k / potok_load_10k)
#   --pool N            POOL_SIZE (default 10, as in production)
#   --reseed            drop and re-seed the scale's database first
#   --scenario probe    no loadgen: what one value costs between the nodes (needs --profile cluster)
#   anything else is passed to loadgen.exs (--think-min, --big-post-rate, ...)
#
# Output goes to results/<timestamp>-<profile>-<scale>-<scenario>-<users>/.
set -euo pipefail
cd "$(dirname "$0")"
# Git Bash would rewrite /app/... arguments into Windows paths.
export MSYS_NO_PATHCONV=1
# Lets every compose command see app2.
export COMPOSE_PROFILES=cluster

profile=fly scale=1k scenario=mix users=1000 ramp=120 hold=300 pool=10 reseed=0
cpus_override="" mem_override="" swap_override="" erl_extra=""
extra=()

while [ $# -gt 0 ]; do
  case "$1" in
    --profile) profile="$2"; shift 2 ;;
    --scale) scale="$2"; shift 2 ;;
    --scenario) scenario="$2"; shift 2 ;;
    --users) users="$2"; shift 2 ;;
    --ramp) ramp="$2"; shift 2 ;;
    --hold) hold="$2"; shift 2 ;;
    --pool) pool="$2"; shift 2 ;;
    --cpus) cpus_override="$2"; shift 2 ;;
    --mem) mem_override="$2"; shift 2 ;;
    --swap) swap_override="$2"; shift 2 ;;
    --erl-flags) erl_extra="$2"; shift 2 ;;
    --reseed) reseed=1; shift ;;
    *) extra+=("$1"); shift ;;
  esac
done

nodes=1 erl="" swap=0
case "$profile" in
  fly) cpus=1 mem=425M erl="+S 1:1 +SDcpu 1:1" ;;
  throttled) cpus=0.0625 mem=425M erl="+S 1:1 +SDcpu 1:1" ;;
  fly4) cpus=4 mem=928M swap=512 erl="+S 4:4 +SDcpu 4:4" ;;
  throttled4) cpus=0.25 mem=928M swap=512 erl="+S 4:4 +SDcpu 4:4" ;;
  big) cpus=6 mem=3G ;;
  cluster) cpus=3 mem=1200M nodes=2 ;;
  *) echo "unknown profile $profile" >&2; exit 1 ;;
esac
cpus=${cpus_override:-$cpus}
mem=${mem_override:-$mem}
swap=${swap_override:-$swap}
erl="$erl $erl_extra"

# Docker's memswap_limit is memory plus swap, in MB.
to_mb() {
  case "$1" in
    *G | *g) echo $((${1%[Gg]} * 1024)) ;;
    *M | *m) echo "${1%[Mm]}" ;;
    *) echo "$1" ;;
  esac
}

case "$scale" in
  1k) db=potok_load_1k seed_n=1000 ;;
  10k) db=potok_load_10k seed_n=10000 ;;
  *) echo "unknown scale $scale" >&2; exit 1 ;;
esac

export DB_NAME="$db" POOL_SIZE="$pool"
run_id="$(date +%Y%m%d-%H%M%S)-${profile}-${scale}-${scenario}-${users}"
out="results/$run_id"
mkdir -p "$out"
log() { echo "[run $(date +%H:%M:%S)] $*" | tee -a "$out/run.log"; }

psql_db() { docker compose exec -T db psql -U postgres -d "$db" -At "$@"; }

start_node() {
  APP_CPUS="$1" APP_MEM="$2" APP_MEMSWAP="$(($(to_mb "$2") + swap))M" APP_ERL_AFLAGS="${5:-}" \
    docker compose up -d --force-recreate --no-deps "$3" >/dev/null
  for _ in $(seq 1 90); do
    code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: localhost' "http://127.0.0.1:$4/accounts/log-in" || true)
    [ "$code" = "200" ] && return 0
    sleep 2
  done
  echo "$3 did not come up" >&2
  docker compose logs --tail 50 "$3" >&2
  exit 1
}

start_app() { start_node "$1" "$2" app 4020 "${3:-}"; }

rpc_on() { docker compose exec -T "$1" /app/bin/potok_ide rpc "$2"; }
rpc() { rpc_on app "$1"; }

# A plain `docker compose stop` does not reach this node, so no run leaves it up.
stop_second_node() { docker compose rm -sf app2 >/dev/null 2>&1 || true; }

start_second_node() {
  start_node "$cpus" "$mem" app2 4021 "$erl"
  # DNSCluster looks for peers every 5 s.
  for _ in $(seq 1 30); do
    [ "$(rpc 'IO.puts(length(Node.list()))')" = "1" ] && return 0
    sleep 2
  done
  echo "the nodes did not connect" >&2
  exit 1
}

log "profile=$profile (nodes=$nodes cpus=$cpus mem=$mem swap=${swap}M pool=$pool erl='$erl') db=$db scenario=$scenario users=$users ramp=${ramp}s hold=${hold}s"
stop_second_node
docker compose up -d --wait db >/dev/null

if [ "$reseed" = 1 ]; then
  log "dropping $db"
  docker compose stop app >/dev/null 2>&1 || true
  docker compose exec -T db psql -U postgres -c "DROP DATABASE IF EXISTS $db WITH (FORCE)" -c "CREATE DATABASE $db" >/dev/null
  psql_db -c "CREATE EXTENSION IF NOT EXISTS pg_stat_statements" >/dev/null
  rm -f "results/users_${seed_n}.csv" "results/users_${seed_n}.json"
fi

accounts=$(psql_db -c "SELECT count(*) FROM accounts" 2>/dev/null || echo 0)
if [ "$accounts" = "0" ] || [ ! -f "results/users_${seed_n}.csv" ]; then
  # Seeding needs more memory than the Fly profile allows; measure on a fresh VM afterwards.
  log "seeding $seed_n users into $db"
  start_app 4 3G
  rpc "Code.eval_file(\"/load_test/seed.exs\"); LoadTest.Seed.run($seed_n)" | tee -a "$out/run.log"
  psql_db -c "VACUUM ANALYZE" >/dev/null
fi

log "starting app with limits"
# A throttled machine boots with its burst balance (Fly showed ~50 s left after a
# deploy), so it starts on a full CPU and is cut down once the sampler runs.
boot_cpus=$cpus
case "$profile" in
  throttled) boot_cpus=1 ;;
  throttled4) boot_cpus=4 ;;
esac
start_app "$boot_cpus" "$mem" "$erl"
[ "$nodes" = 2 ] && start_second_node
log "vm: $(rpc 'IO.write("schedulers=#{:erlang.system_info(:schedulers)} online=#{:erlang.system_info(:schedulers_online)} dirty_cpu=#{:erlang.system_info(:dirty_cpu_schedulers)} beam_mb=#{div(:erlang.memory(:total), 1048576)}")')"

if [ "$scenario" = probe ]; then
  rpc 'Code.eval_file("/load_test/dist_probe.exs"); LoadTest.DistProbe.run()' | tee "$out/dist_probe.txt"
  stop_second_node
  log "done: $out"
  exit 0
fi

psql_db -c "SELECT pg_stat_statements_reset()" >/dev/null
rpc "Code.eval_file(\"/load_test/sampler.exs\"); LoadTest.Sampler.start(\"/load_test/$out\")" >/dev/null
if [ "$boot_cpus" != "$cpus" ]; then
  docker update --cpus "$cpus" "$(docker compose ps -q app)" >/dev/null
  log "cpu limit now $cpus"
fi
hosts=app
if [ "$nodes" = 2 ]; then
  hosts=app,app2
  mkdir -p "$out/app2"
  rpc_on app2 "Code.eval_file(\"/load_test/sampler.exs\"); LoadTest.Sampler.start(\"/load_test/$out/app2\")" >/dev/null
fi
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Container CPU/memory every ~3 s and Postgres connection states every 5 s.
(
  while true; do
    now=$(date +%s)
    docker stats --no-stream --format '{{.Name}},{{.CPUPerc}},{{.MemUsage}},{{.NetIO}}' |
      grep potok_load | sed "s/^/$now,/" >> "$out/docker.csv" || true
    sleep 1
  done
) &
stats_pid=$!
(
  while true; do
    psql_db -F, -c "SELECT extract(epoch FROM now())::int, coalesce(state, '-'), coalesce(wait_event_type, '-'), count(*)
                    FROM pg_stat_activity WHERE datname = '$db' GROUP BY 2, 3" >> "$out/pg_activity.csv" 2>/dev/null || true
    sleep 5
  done
) &
pg_pid=$!
trap 'kill $stats_pid $pg_pid 2>/dev/null || true' EXIT

log "loadgen starting"
set +e
docker compose run --rm -T loadgen \
  --users "$users" --ramp "$ramp" --hold "$hold" --scenario "$scenario" --host "$hosts" \
  --data "results/users_${seed_n}" --out "$out" "${extra[@]}" 2>&1 | tee "$out/loadgen.log"
set -e
kill $stats_pid $pg_pid 2>/dev/null || true
log "loadgen finished; collecting"

container=$(docker compose ps -aq app)
docker inspect -f 'status={{.State.Status}} oom_killed={{.State.OOMKilled}} exit={{.State.ExitCode}} restarts={{.RestartCount}}' "$container" |
  tee "$out/app_state.txt" | tee -a "$out/run.log"
docker compose logs --no-color --since "$started_at" app > "$out/app.log" 2>&1 || true
rpc "LoadTest.Sampler.stop()" >/dev/null 2>&1 || true
if [ "$nodes" = 2 ]; then
  docker compose logs --no-color --since "$started_at" app2 > "$out/app2/app.log" 2>&1 || true
  stop_second_node
fi

psql_db -F' | ' -c "
  SELECT round(total_exec_time)::bigint AS total_ms, calls, round(mean_exec_time::numeric, 2) AS mean_ms,
         round(max_exec_time::numeric, 1) AS max_ms, rows,
         left(regexp_replace(query, '\s+', ' ', 'g'), 300) AS query
  FROM pg_stat_statements
  WHERE dbid = (SELECT oid FROM pg_database WHERE datname = current_database())
  ORDER BY total_exec_time DESC LIMIT 30" > "$out/pg_top.txt" || true

# Errors from the app log, grouped with numbers and pids masked.
{
  echo "== [error] lines"
  grep -E '\[error\]' "$out/app.log" | sed -E 's/^[^[]*\[error\] //; s/#PID<[0-9.]+>/#PID/g; s/[0-9]+/N/g' |
    cut -c1-200 | sort | uniq -c | sort -rn | head -40
  echo "== exceptions"
  grep -oE '\*\* \([A-Za-z.]+\) .{0,160}' "$out/app.log" | sed -E 's/#PID<[0-9.]+>/#PID/g; s/[0-9]+/N/g' |
    sort | uniq -c | sort -rn | head -40
} > "$out/errors.txt" || true

log "done: $out"
