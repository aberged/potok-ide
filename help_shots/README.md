# Pictures for the help page

The help page (`/pomoc`, text in `priv/static/HELP.*.md`) shows the app as a phone
sees it. These pictures are not drawn by hand: `make.exs` builds a made-up world in a
database of its own, serves the app, and `shots.mjs` photographs it with Chrome. When a
screen changes, take its pictures again.

## Running it

You need Node, Chrome (or Edge), ImageMagick (`magick`, as for the link cards) and a
Postgres with PostGIS. On this machine that is the temporary test container (see the
test notes: `PGPORT=15432`).

```sh
cd help_shots && npm install && cd ..        # once: playwright-core, no browser download
MIX_ENV=test PGPORT=15432 mix do assets.build + run --no-start help_shots/make.exs
```

It takes a few minutes. Every picture of `shots.json` lands in
`priv/static/images/help/` as WebP, and their sizes in `manifest.json`, which the page
reads when it compiles. Options go after the script:

- `--only poruke,nit` takes only these pictures and keeps the others. The world is
  built anew all the same, so they match the rest.
- `--serve` builds the world and serves it on <http://localhost:4010> until stopped,
  to look around and to find the moment for a new picture. Log in at
  `/accounts/log-in/password` as `ana@example.com` (or marko, jelena, ...) with the
  password `hello world!`.

Look at every picture you took before you commit it: a test sees that a picture is
there, not that it shows the right thing.

## The parts

- `make.exs` drops and creates the database `potok_ide_help`, starts the app in the
  test configuration with a real connection pool, real map tiles, mail to the log and a
  push key, builds the world, runs `shots.mjs`, converts the PNGs and writes the
  manifest. It stops the app when done.
- `world.exs` is the world: twelve people (`ana` is the one who looks, in most
  pictures) and the four organizations of the help text's examples: the local community
  MZ Topolik, the faculty's plenum, the co-op Zadruga Livada and the building Zgrada
  Cvetna 12. Messages are dated yesterday and today, so the pictures always read as
  fresh. It writes `tmp/help_shots/world.json`: ids and a log-in cookie per person.
- `shots.json` lists the pictures: `name` (the file name, and the name the help text
  uses), `as` (who looks; none for a guest), `url` (where `{groups.mz}` and the like
  come from `world.json`), `steps` and `clip` (an element to cut out instead of the
  whole screen). Steps: `click`, `tap`, `fill`, `type`, `press`, `wait`, `gone`,
  `goto`, `scroll`, `show` (to the top of the screen), `top`, `longpress`,
  `frameClick` (inside an app's frame), `pause`, `eval`. `worker: true` lets the page
  have a service worker (push settings).
- `shots.mjs` runs the list: a 390 × 844 phone at twice the pixels, Serbian, Belgrade
  time, the light theme.

## Traps

- Opening a chat marks it read at once in the test configuration. A picture that shows
  unread messages comes before any other picture of the same chat in `shots.json`.
- An announcement (an event or a poll put to a chat) marks its author's read marker,
  which is why the unread line is photographed in the building's chat, not the
  assembly's.
- Fonts and emoji are the system's, so pictures taken on another system look a little
  different. Take them all on the same machine.
- A name in `shots.json` and in the help text must match: a test compares them, and
  another one compares the pictures in `HELP.sr.md`, `HELP.sr_Cyrl.md` and `HELP.en.md`.
