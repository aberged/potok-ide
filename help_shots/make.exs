# Pictures of the app for the help page (`/pomoc`). See README.md.
#
#     MIX_ENV=test PGPORT=15432 mix do assets.build + run --no-start help_shots/make.exs
#
# Builds a world of made-up people and groups in a database of its own
# (`potok_ide_help`, dropped first), serves the app on port 4010, has
# `shots.mjs` photograph it as a phone would, and writes each picture as WebP to
# `priv/static/images/help/` with its size in `manifest.json`.
#
#   --only a,b   takes only these pictures and keeps the others
#   --serve      builds the world and serves it until stopped, to look around
#                (log in by opening the address it prints)

Mix.env() == :test || Mix.raise("Run with MIX_ENV=test, see help_shots/README.md")

{opts, _args} = OptionParser.parse!(System.argv(), strict: [only: :string, serve: :boolean])

root = File.cwd!()
here = Path.join(root, "help_shots")
work = Path.join(root, "tmp/help_shots")
pictures = Path.join(root, "priv/static/images/help")
port = 4010

Logger.configure(level: :warning)
File.rm_rf!(work)
File.mkdir_p!(Path.join(work, "png"))

# The test configuration, but with a real pool (the sandbox gives each process
# a connection of its own), real map tiles, mail to the log and a push key, so
# the settings page offers notifications.
put = fn key, changes ->
  Application.put_env(:potok_ide, key, Keyword.merge(Application.get_env(:potok_ide, key, []), changes))
end

put.(PotokIde.Repo, database: "potok_ide_help", pool: DBConnection.ConnectionPool, pool_size: 10)
put.(PotokIde.Storage, root: Path.join(work, "uploads"))
Application.put_env(:potok_ide, PotokIde.MapTiles, [])
Application.put_env(:potok_ide, PotokIde.Mailer, adapter: Swoosh.Adapters.Logger, level: :debug)
put.(PotokIdeWeb.Endpoint, server: true, http: [ip: {127, 0, 0, 1}, port: port])

{public_key, private_key} = :crypto.generate_key(:ecdh, :prime256v1)

Application.put_env(:potok_ide, PotokIde.PushNotifications,
  vapid_subject: "mailto:help@example.com",
  vapid_public_key: Base.url_encode64(public_key, padding: false),
  vapid_private_key: Base.url_encode64(private_key, padding: false)
)

repo_config = Application.get_env(:potok_ide, PotokIde.Repo)
_ = Ecto.Adapters.Postgres.storage_down(repo_config)
:ok = Ecto.Adapters.Postgres.storage_up(repo_config)

{:ok, _, _} =
  Ecto.Migrator.with_repo(PotokIde.Repo, &Ecto.Migrator.run(&1, :up, all: true, log: false))

{:ok, _started} = Application.ensure_all_started(:potok_ide)

Code.require_file("world.exs", here)
world = HelpShots.World.build(Path.join(work, "files"))

base_url = "http://localhost:#{port}"
world_path = Path.join(work, "world.json")
File.write!(world_path, Jason.encode!(Map.put(world, :base_url, base_url), pretty: true))

if opts[:serve] do
  IO.puts("""

  The help world is at #{base_url}. Log in as ana (and the others) by opening
    #{base_url}/accounts/log-in/password   with ana@example.com / hello world!
  Stop with Ctrl+C twice.
  """)

  Process.sleep(:infinity)
end

node = System.find_executable("node") || Mix.raise("node is not on the PATH")
only = if opts[:only], do: ["--only", opts[:only]], else: []

{_, status} =
  System.cmd(node, [Path.join(here, "shots.mjs"), world_path, Path.join(work, "png")] ++ only,
    cd: here,
    into: IO.stream(),
    stderr_to_stdout: true
  )

# A PNG's size sits in its header; the phone draws two pixels for each CSS one.
size = fn path ->
  <<_::binary-size(16), width::32, height::32, _::binary>> = File.read!(path)
  %{"w" => div(width, 2), "h" => div(height, 2)}
end

manifest_path = Path.join(pictures, "manifest.json")
File.mkdir_p!(pictures)

manifest =
  if File.exists?(manifest_path),
    do: manifest_path |> File.read!() |> Jason.decode!(),
    else: %{}

taken =
  for png <- Path.wildcard(Path.join(work, "png/*.png")), into: %{} do
    name = Path.basename(png, ".png")
    webp = Path.join(pictures, "#{name}.webp")

    {:ok, _} =
      PotokIde.ImageMagick.run([png, "-strip", "-quality", "82", "-define", "webp:method=6", webp])

    {name, size.(png)}
  end

listed = here |> Path.join("shots.json") |> File.read!() |> Jason.decode!() |> Enum.map(& &1["name"])

# A full run also clears out pictures the list no longer has.
manifest =
  manifest
  |> Map.merge(taken)
  |> Map.take(listed)

unless opts[:only] do
  for webp <- Path.wildcard(Path.join(pictures, "*.webp")),
      Path.basename(webp, ".webp") not in listed,
      do: File.rm!(webp)
end

sorted = manifest |> Enum.sort() |> Jason.OrderedObject.new()
File.write!(manifest_path, Jason.encode!(sorted, pretty: true) <> "\n")

IO.puts("\nWrote #{map_size(taken)} pictures to #{Path.relative_to(pictures, root)}.")
missing = listed -- Map.keys(manifest)
if missing != [], do: IO.puts("Still missing: #{Enum.join(missing, ", ")}")

System.halt(status)
