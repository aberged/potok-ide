#!/usr/bin/env bash
# Runs one stress-test scenario against the production release in Docker.
#
#   ./run.sh --profile fly --scale 1k --scenario mix --users 1000 --ramp 120 --hold 300
#
#   --profile fly|big   app container limits: fly = 1 CPU / 512 MB (fly.toml), big = 6 CPU / 3 GB
#   --scale 1k|10k      which seeded database to use (potok_load_1k / potok_load_10k)
#   --pool N            POOL_SIZE (default 10, as in production)
#   --reseed            drop and re-seed the scale's database first
#   anything else is passed to loadgen.exs (--think-min, --big-post-rate, ...)
#
# Output goes to results/<timestamp>-<profile>-<scale>-<scenario>-<users>/.
set -euo pipefail
cd "$(dirname "$0")"
# Git Bash would rewrite /app/... arguments into Windows paths.
export MSYS_NO_PATHCONV=1

profile=fly scale=1k scenario=mix users=1000 ramp=120 hold=300 pool=10 reseed=0
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
    --reseed) reseed=1; shift ;;
    *) extra+=("$1"); shift ;;
  esac
done

case "$profile" in
  fly) cpus=1 mem=512M ;;
  big) cpus=6 mem=3G ;;
  *) echo "unknown profile $profile" >&2; exit 1 ;;
esac

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

start_app() {
  APP_CPUS="$1" APP_MEM="$2" docker compose up -d --force-recreate --no-deps app >/dev/null
  for _ in $(seq 1 90); do
    code=$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: localhost' http://127.0.0.1:4020/accounts/log-in || true)
    [ "$code" = "200" ] && return 0
    sleep 2
  done
  echo "app did not come up" >&2
  docker compose logs --tail 50 app >&2
  exit 1
}

rpc() { docker compose exec -T app /app/bin/potok_ide rpc "$1"; }

log "profile=$profile (cpus=$cpus mem=$mem pool=$pool) db=$db scenario=$scenario users=$users ramp=${ramp}s hold=${hold}s"
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
start_app "$cpus" "$mem"
psql_db -c "SELECT pg_stat_statements_reset()" >/dev/null
rpc "Code.eval_file(\"/load_test/sampler.exs\"); LoadTest.Sampler.start(\"/load_test/$out\")" >/dev/null
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
  --users "$users" --ramp "$ramp" --hold "$hold" --scenario "$scenario" \
  --data "results/users_${seed_n}" --out "$out" "${extra[@]}" 2>&1 | tee "$out/loadgen.log"
set -e
kill $stats_pid $pg_pid 2>/dev/null || true
log "loadgen finished; collecting"

container=$(docker compose ps -aq app)
docker inspect -f 'status={{.State.Status}} oom_killed={{.State.OOMKilled}} exit={{.State.ExitCode}} restarts={{.RestartCount}}' "$container" |
  tee "$out/app_state.txt" | tee -a "$out/run.log"
docker compose logs --no-color --since "$started_at" app > "$out/app.log" 2>&1 || true
rpc "LoadTest.Sampler.stop()" >/dev/null 2>&1 || true

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
