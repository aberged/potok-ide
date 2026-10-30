# Stress test

Runs the production release (built from the repo `Dockerfile`) in Docker with Fly's machine size,
seeds thousands of users, and drives them through the real LiveView websocket protocol.
Production is never touched.

| File | What it does |
|---|---|
| `docker-compose.yml` | `db` (Postgres 16 + `pg_stat_statements`), `app` (the release; limits from `APP_CPUS`/`APP_MEM`), `loadgen` |
| `seed.exs` | Bulk-inserts N users, groups (one with everyone, Zipf-sized others, nesting), direct groups, threads, messages and read markers; writes `results/users_<N>.csv` with signed remember-me cookies |
| `sampler.exs` | Injected into the running app over `rpc`; writes `server.jsonl` every 5 s (BEAM memory, run queue, scheduler use, busiest mailboxes, LiveViews per view, Repo queue/query time, per-table DB time, LiveView mount/event times) |
| `loadgen.exs` | One Erlang process per virtual user: page load with cookie, avatars, websocket, `phx_join`, heartbeats, live navigation, posts, reactions; writes `loadgen.jsonl` every 10 s and `summary.json` |
| `run.sh` | Starts the stack with a profile, seeds if needed, starts the samplers, runs loadgen and collects everything into `results/<run>/` |
| `inspect_lv.exs` | Over `rpc` during a run: what a `GroupLive.Show` process holds, assign by assign |
| `inspect_ws.exs` | Over `rpc` during a run: memory of the websocket transport (Bandit handler) and LiveView processes, before and after a garbage collection of a sample |
| `profile_requests.exs` | Over `rpc` during a run: samples the stacks of running processes for `PROFILE_SECONDS` and prints the hottest frames (the release has no `:tools`, so no tprof) |

## Running

Docker Desktop must be running. From Git Bash:

```sh
cd load_test
docker compose build app        # after app code changes
./run.sh --profile fly --scale 1k --scenario smoke --users 50 --ramp 10 --hold 60
./run.sh --profile fly --scale 1k --scenario mix --users 1000 --ramp 120 --hold 300
./run.sh --profile fly --scale 1k --scenario storm --users 1000 --ramp 120 --hold 180
./run.sh --profile fly --scale 1k --scenario biggroup --users 1000 --ramp 120 --hold 180
./run.sh --profile fly --scale 10k --scenario mix --users 10000 --ramp 600 --hold 300
./run.sh --profile big --scale 10k --scenario mix --users 10000 --ramp 600 --hold 300 --pool 40
```

The run options:

- **Profiles.** `fly` is 1 CPU / 512 MB, like `fly.toml`. `big` is 6 CPU / 3 GB.
- **Scales.** `1k` and `10k` use separate databases. Each is seeded on first use. `--reseed` starts over.
- **Loadgen options.** Anything else is passed to `loadgen.exs`: `--think-min`, `--think-max`, `--poster-share`, `--post-min`, `--post-max`, `--big-post-share`, `--big-post-rate`, `--storm-window`.

Scenarios:

- **`mix`.** Everyone lands on the root group. After 20–60 s of thinking, a user then picks:
  - 45%: stay on root;
  - 40%: one of their groups or direct chats;
  - 10%: `/invitations` or `/requests`;
  - 5%: `/profiles`.

  10% of users post every 30–90 s, 5% of those posts in the group that has everyone. Readers react now and then.
- **`storm`.** `mix`, then every websocket drops and reconnects within 5 s, as after a deploy.
- **`biggroup`.** Everyone sits in the group that has everyone (or on root). Posts go there at `--big-post-rate` per second.
- **`smoke`.** A short `mix` with probes for two known crashes:
  - VUs 1–3 sit on `/profiles` while others post. `ProfileLive.Index` used to crash on `:group_unread_counts_updated`.
  - VU 0 edits the profile of VU 4's user while VU 4 sits in a group. `GroupLive.Show` has no `:profile_updated` clause.

## Reading the results

Each `results/<run>/` holds:

| File | Contents |
|---|---|
| `loadgen.log` | 10 s lines: VUs started, connected and failing; join, nav, post and delivery p95; received MB; errors |
| `summary.json` | Totals and hold-phase percentiles per metric (ms), and every counter |
| `server.jsonl` | The sampler lines (see above) |
| `docker.csv` | Container CPU %, memory and network |
| `pg_activity.csv` | Postgres connections by state and wait type |
| `pg_top.txt` | Top 30 statements by total time |
| `app.log`, `errors.txt` | The app log and its errors, grouped |
| `app_state.txt` | Whether the app was OOM-killed or exited |

The metrics:

- **`join`.** First mount after a page load, from `phx_join` to the reply.
- **`nav_join`.** Live navigation.
- **`rejoin`.** A join after a reconnect.
- **`event_*`.** Event round trips.
- **`delivery_chat`.** Time from a post until another user viewing that group sees it.
- **`delivery_root`.** The same for the root page, through the unread refresh.
- **`heartbeat`.** Socket round trip, without a LiveView.

The run behaves as follows:

- Loadgen stops early when more than half of the VUs have failed for 60 s.
- `loadgen.vu_crash` means a harness bug, not a server error.
- The app is recreated before every run, so memory starts fresh.

## Comparing two builds

The host's speed drifts (the same build held 284 users one night and 111 the next morning), so
numbers from different sessions do not compare. Run both builds back to back instead:

```sh
git -c core.autocrlf=false worktree add --detach ../potok-ide-base <old-commit>
docker build -t potok_load_app_base ../potok-ide-base
docker compose build app && docker tag potok_load_app potok_load_app_new

docker tag potok_load_app_base potok_load_app && ./run.sh ...   # old
docker tag potok_load_app_new potok_load_app && ./run.sh ...    # new, same options
```

`core.autocrlf=false` keeps the release scripts LF. Past the breaking point a run is chaotic (the
first burst decides how it goes), so tests just below it tell more.
