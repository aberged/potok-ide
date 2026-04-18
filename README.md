# Potok

<div class="flex flex-row gap-2">
<img src="https://icon.icepanel.io/Technology/svg/Elixir.svg" width="50"/>
<img src="https://upload.wikimedia.org/wikipedia/en/thumb/1/1e/Phoenix_Framework_Logo.svg/1920px-Phoenix_Framework_Logo.svg.png" width="55"/>
<img src="https://tailwindcss.com/_next/static/media/tailwindcss-mark.96ee6a5a.svg" width="56"/>
<img src="https://img.daisyui.com/images/daisyui/mark-rotating.svg" alt="daisyUI logo" width="44"/>
</div>

Potok is a Phoenix 1.8 and LiveView application for account-based collaboration around profiles, groups, invitations, and posted values. The app is server-rendered, locale-aware, and organized around two states after login: profile selection and profile-scoped group activity. It also exposes browser-side Potok APIs through LiveView hooks, providing a foundation for Potok-scoped application development on top of group descriptions and values.

## Domain Model

The main concepts in the system are:

* `Account`: the authenticated identity. An account has an email, optional password login, confirmation state, many profiles, one selected `current_profile`, and one `default_profile` used as the fallback profile when no explicit current profile is set.
* `Profile`: the social identity used inside groups. A profile can be `unique` or `shared`, can be linked to one or more accounts depending on sharing rules, and can create groups and values.
* `Group`: a hierarchical collaboration container with a creator profile, memberships, child groups, optional parent relations, and a persisted `home_page` preference that controls which panel opens by default.
* `Value`: content posted by a profile in a group, optionally as part of a reply chain.
* `GroupMembership`: the join entity between profiles and groups.
* `GroupInvitation`: an invitation from one profile to another profile to join a group.
* `GroupJoinRequest`: a pending request from a non-member profile to join a public group, reviewed by the group creator.
* `AccountProfile`: the join entity between accounts and profiles.

Invitation behavior:

* Invitations are stored against the invitee profile, not against a specific account.
* If the invitee profile is shared, the pending invitation is effectively shared as well, because all linked accounts access the same profile record.
* Accepting an invitation adds the profile to the target group, so the resulting membership is also shared by every account linked to that profile.

Group access and direct-group behavior:

* Public groups support access requests from non-member profiles. Group creators review those pending requests from the members tab and can accept or reject them there.
* Groups persist a `home_page` enum with the values `description`, `chat`, and `subgroups`. The create-group and edit-group panels expose that setting so members can control the default landing panel for a group.
* Opening a group without an explicit tab uses its `home_page`: `description` opens the description panel, `chat` opens the values panel, and `subgroups` opens the sub-groups panel.
* Root groups ignore `home_page` and always open on the sub-groups panel.
* Direct groups are derived conversation groups, not a separate invitation flow. Opening `/profiles/:id/direct` finds or creates a private non-root group under the root group for exactly two profiles and then navigates to that group's values tab.
* Direct private groups ignore `home_page` and always open on the values panel.
* Because direct groups are fixed to two members, the group UI hides profile-invite actions, join-request management, and member removal controls for them.

Relationship summary:

```text
Account 1----* AccountProfile *----1 Profile
Account 1----0..1 current_profile -> Profile
Account 1----0..1 default_profile -> Profile

Profile 1----* GroupMembership *----1 Group
Profile 1----* created_groups
Profile 1----* values

Group 1----* child_groups
Group 1----* values
Group 0..1----1 parent_group
Group 0..1----1 parent_value

Value 0..1----1 parent_value
Value 1----* child_values

GroupInvitation belongs_to group, inviter(profile), invitee(profile)
GroupJoinRequest belongs_to group, requester(profile)
```

Default profile behavior:

* The first profile created for an account becomes both its `current_profile` and `default_profile`.
* Later profile creation does not overwrite either selection.
* If `current_profile` is cleared, the web layer falls back to `default_profile` for profile-scoped behavior.

## Quick Start

### Local development

Prerequisites:

* Elixir `~> 1.15` as declared in `mix.exs`
* Erlang/OTP compatible with your Elixir installation
* PostgreSQL running locally
* Node.js and npm (required because `mix assets.setup` runs `npm install` in `assets/`)

For the smoothest release parity, use an Elixir and OTP pair that is compatible with the included Docker build, which currently uses Elixir `1.18.2` and OTP `27.3.4`.

Recommended local versions:

* Node.js `20+`
* npm `10+`

Default local database settings:

* username: `postgres`
* password: `postgres`
* hostname: `localhost`
* development database: `potok_ide_dev`
* test database: `potok_ide_test`

If your local PostgreSQL setup differs, update `config/dev.exs` and `config/test.exs` before running setup.

1. Install dependencies, create the database, run migrations, and build assets:

 ```sh
 mix setup
 ```

   The first run may take longer because `mix assets.setup` installs npm dependencies in `assets/`.

1. Start the application:

 ```sh
 mix phx.server
 ```

1. Open `http://localhost:4000`.

`mix phx.server` starts the Phoenix endpoint together with the configured Tailwind and esbuild watchers from `config/dev.exs`.

The seed script currently only contains the default template comments, so a fresh setup gives you schema only.

### Common commands

* `mix test` runs the test suite.
* `mix ecto.reset` drops and recreates the local database.
* `mix run priv/repo/seeds.exs` runs the seed script manually.
* `mix assets.setup` installs the pinned Tailwind and esbuild binaries used by the project.
* `mix assets.build` rebuilds Tailwind and esbuild assets.
* `mix precommit` runs the main verification alias: compile with warnings as errors, unlock unused deps, format, and test.

### PWA push notifications

Potok now includes Web Push subscription support for the installable PWA.

Required environment variables:

* `WEB_PUSH_VAPID_SUBJECT`
* `WEB_PUSH_VAPID_PUBLIC_KEY`
* `WEB_PUSH_VAPID_PRIVATE_KEY`

You can generate a VAPID keypair with:

```sh
mix potok.gen.vapid_keypair
```

The account settings screen at `/accounts/settings` exposes the browser-side enable, disable, and test notification controls once those variables are configured.

### Development behavior

The default development configuration includes:

* local email delivery through `Swoosh.Adapters.Local`
* mailbox preview at `http://localhost:4000/dev/mailbox`
* LiveDashboard at `http://localhost:4000/dev/dashboard`
* live asset rebuilding through Phoenix endpoint watchers

### Production email delivery

Production mail delivery is configured at runtime through `MAILER_ADAPTER`.

If `MAILER_ADAPTER` is omitted, the app defaults to `mailgun`.

For Gmail API delivery:

* set `MAILER_ADAPTER=gmail`
* set `MAILER_FROM_EMAIL`
* optionally set `MAILER_FROM_NAME` (defaults to `Potok`)
* either set `GMAIL_API_ACCESS_TOKEN`
* or set both `GMAIL_CLIENT_ID` and `GMAIL_CLIENT_SECRET`
* optionally set `GMAIL_REFRESH_TOKEN` when needed for initial token bootstrap

If you use the refresh token flow, the application exchanges the refresh token for a short-lived access token on each email send through Google's OAuth token endpoint. You can override that endpoint with `GMAIL_TOKEN_URL` if needed.

Mailgun remains available by setting `MAILER_ADAPTER=mailgun` together with `MAILGUN_API_KEY` and `MAILGUN_DOMAIN`.

## Product Flow

The entry flow at `/` is auth-aware:

1. Guests are redirected to `/accounts/log-in`.
2. Authenticated accounts without a current or default profile are redirected to `/profiles`.
3. Authenticated accounts with either a current profile or a default profile are redirected to `/groups`.

The web layer combines three cross-cutting concerns:

* `PotokIdeWeb.AccountAuth` for authenticated account loading across controllers and LiveViews
* `PotokIdeWeb.ProfileAuth` for loading and enforcing a current profile when profile-scoped features are used
* `PotokIdeWeb.Locale` for locale resolution from params, session, and request headers in both Plug and LiveView lifecycles

Profiles also have a sharing mode:

* `unique` profiles are meant to stay attached to one account
* `shared` profiles can be linked to multiple accounts through `AccountProfile`

Group invitations are addressed to profiles, not directly to accounts. That means a shared profile carries its memberships and pending invitations with it, and any linked account can see them when that shared profile is selected as the current profile.

## Tech Stack

Backend and framework:

* `Phoenix 1.8.3`
* `Phoenix LiveView 1.1`
* `Ecto` and `ecto_sql`
* `Postgrex`
* `Bandit`

Authentication, email, and HTTP:

* `pbkdf2_elixir`
* `Swoosh`
* `Req`

Frontend and assets:

* `Tailwind CSS 4.1.12`
* `daisyUI` theme plugins loaded through `assets/css/app.css`
* `esbuild 0.25.4`
* `Heroicons`

Localization and observability:

* `Gettext`
* `telemetry_metrics`
* `telemetry_poller`

Testing and DX:

* `ExUnit`
* `LazyHTML`
* Mix aliases for setup, asset builds, and verification

## Routes

The router is organized by authentication and profile requirements.

Public browser routes:

* `GET /` redirects based on account and profile state
* `GET /locale/:locale` updates the active locale
* `GET /accounts/log-in`
* `GET /accounts/log-in/:token`
* `POST /accounts/log-in`
* `DELETE /accounts/log-out`

Authenticated routes:

* `GET /profiles` for profile selection and setup
* `GET /profiles/new`
* `GET /profiles/:id/edit`
* `GET /accounts/settings`
* `GET /accounts/settings/confirm-email/:token`
* `POST /accounts/update-password`
* `POST /accounts/push-subscriptions`
* `DELETE /accounts/push-subscriptions`
* `POST /accounts/push-subscriptions/test`

Authenticated routes that require a current profile:

* `GET /profiles/:id/direct`
* `GET /groups`
* `GET /groups/:id`
* `GET /groups/:id/:tab`
* `GET /invitations`
* `GET /requests`
* `GET /accounts/register`

Development-only routes when `dev_routes` is enabled:

* `GET /dev/dashboard`
* `GET /dev/mailbox`

The router uses separate LiveView sessions for:

* auth-aware public pages (`:current_account`)
* authenticated account settings (`:require_authenticated_account`)
* authenticated profile selection (`:authenticated`)
* profile-required collaboration screens (`:profile_required`)

## Frontend Hook APIs

The group description panel exposes a browser API through the `GroupDescriptionActions` LiveView hook in `assets/js/app.js`.

The API is attached to the hooked DOM element as `element.potok` while the panel is mounted.

Available functions:

* `insertGroupValue(content, options)` pushes a `create_data_value` event and returns the server reply.
  * `content` is normalized to a string.
  * `options.contentFormat` / `options.content_format` controls `value.content_format` (default: `"markdown"`).
* `updateGroupDescription(description, options)` pushes an `update_group_description` event and returns the server reply.
  * `description` is normalized to a string.
  * `options.descriptionFormat` / `options.description_format` controls `description_format`.
  * If no format is provided, the hook uses `data-description-format` from the element and falls back to `"html"`.
* `getGroupDescription()` returns the current raw group description and format from hook dataset attributes.
* `getGroupDataValues()` pushes a `list_group_data_values` event and returns the server reply.
* `getCurrentProfile()` returns the parsed JSON object from `data-current-profile`, or `null` if missing/invalid.
* `setNewValueCallback(fn)` registers a callback invoked when the browser receives a `phx:new_data_value` event.

`getGroupDescription()` resolves to:

```js
{
  description: "...",
  descriptionFormat: "html"
}
```

## Internationalization

The application currently ships with:

* `en` for English
* `pl` for Polish
* `sr` for Serbian

Translations live under `priv/gettext/`. Locale switching is exposed through the UI and backed by `PotokIdeWeb.Locale` in both Plug and LiveView flows.

## Project Structure

High-level layout:

```text
.
|- assets/
|  |- css/                 # Tailwind CSS entrypoint
|  |- js/                  # Phoenix / LiveView JavaScript entrypoint
|  |- vendor/              # Bundled frontend vendor files
|- config/                 # Environment-specific configuration
|- lib/
|  |- potok_ide/           # Domain contexts, schemas, repo, mailer, release helpers
|  |  |- accounts/         # Account schema and auth-related domain code
|  |  |- social/           # Profile, group, value, membership, invitation schemas
|  |  |- accounts.ex       # Account context
|  |  |- social.ex         # Social context
|  |- potok_ide_web/       # Web interface, routing, LiveViews, components
|  |  |- components/       # Shared UI components and layouts
|  |  |- controllers/      # Controller endpoints and session actions
|  |  |- live/             # LiveViews for auth, profiles, groups, invitations
|  |  |- account_auth.ex   # Account auth helpers for Plug and LiveView
|  |  |- profile_auth.ex   # Current profile loading and enforcement
|  |  |- locale.ex         # Locale resolution and LiveView mounting
|  |  |- router.ex         # Route and live_session composition
|- priv/
|  |- gettext/             # Translation catalogs
|  |- repo/                # Migrations and seeds
|  |- static/              # Compiled static assets
|- rel/                    # Release overlays and startup scripts
|- test/                   # ExUnit tests for contexts and web layer
|- Dockerfile              # Multi-stage production image build
|- fly.toml                # Fly.io deployment configuration
|- mix.exs                 # Dependencies, aliases, and project config
```

## Running A Release With Docker

The repository includes a multi-stage `Dockerfile` that builds a production release and starts it with `/app/bin/server`.

The release image currently builds with:

* Elixir `1.18.2`
* Erlang/OTP `27.3.4`
* Debian `trixie-20260223-slim`

Build the image:

```sh
docker build -t potok-ide .
```

Run the release container by providing the required runtime configuration:

```sh
docker run --rm -p 4000:4000 \
  -e PHX_SERVER=true \
  -e PHX_HOST=localhost \
  -e PORT=4000 \
  -e SECRET_KEY_BASE=your-secret \
  -e DATABASE_URL=ecto://USER:PASS@HOST/DATABASE \
  -e MAILGUN_API_KEY=your-key \
  -e MAILGUN_DOMAIN=mg.example.com \
  -e MAILER_FROM_EMAIL=no-reply@mg.example.com \
  potok-ide
```

Notes:

* The Docker image is production-oriented. It does not provide code reloading or a local dev shell workflow.
* Your `DATABASE_URL` must point to a database reachable from inside the container.
* Asset compilation happens during image build through `mix assets.deploy`.

## Running A Release Without Docker

Build a release locally:

```sh
set MIX_ENV=prod
mix release
```

Start it with the required runtime variables available:

```sh
set PHX_SERVER=true
_build/prod/rel/potok_ide/bin/server
```

On Unix-like shells, the equivalent is:

```sh
MIX_ENV=prod mix release
PHX_SERVER=true _build/prod/rel/potok_ide/bin/server
```

## Production Configuration

Production configuration is loaded from runtime environment variables.

Required in all production setups:

* `DATABASE_URL`
* `SECRET_KEY_BASE`
* `MAILER_FROM_EMAIL`

Required when using Mailgun (`MAILER_ADAPTER=mailgun`, default):

* `MAILGUN_API_KEY`
* `MAILGUN_DOMAIN`

Required when using Gmail (`MAILER_ADAPTER=gmail`):

* either `GMAIL_API_ACCESS_TOKEN`
* or both `GMAIL_CLIENT_ID` and `GMAIL_CLIENT_SECRET`

Optional environment variables:

* `MAILER_ADAPTER` defaults to `mailgun`
* `PHX_HOST` defaults to `example.com`
* `PORT` defaults to `4000`
* `POOL_SIZE` defaults to `10`
* `ECTO_IPV6` enables IPv6 socket options when set to `true` or `1`
* `DNS_CLUSTER_QUERY` configures distributed node discovery
* `MAILER_FROM_NAME` defaults to `Potok`
* `MAILGUN_BASE_URL` can be set to `https://api.eu.mailgun.net/v3` for EU Mailgun accounts
* `GMAIL_TOKEN_URL` overrides the Gmail OAuth token endpoint
* `GMAIL_REFRESH_TOKEN` can be provided for initial Gmail token bootstrap
* `PHX_SERVER=true` enables the web server for releases if your runtime does not already set it

Operational notes:

* `PHX_HOST` is used to build endpoint URLs in production.
* `PORT` is read in all environments, not just production.
* `MAILGUN_BASE_URL` is useful for EU-region Mailgun accounts.
* `DNS_CLUSTER_QUERY` is only needed when you want DNS-based node discovery across multiple running nodes.

## Fly.io Deployment

The repository already contains `fly.toml` with these defaults:

* app name: `potok-ide`
* primary region: `fra`
* runtime host: `potok-ide.fly.dev`
* internal service port: `8080`
* release command: `/app/bin/migrate`
* preconfigured runtime env: `PHX_HOST=potok-ide.fly.dev`, `PORT=8080`, `MAILER_FROM_NAME=Potok`

Example Fly.io secrets setup:

```sh
fly secrets set SECRET_KEY_BASE=your-secret
fly secrets set DATABASE_URL=ecto://USER:PASS@HOST/DATABASE
fly secrets set MAILGUN_API_KEY=your-key MAILGUN_DOMAIN=mg.example.com MAILER_FROM_EMAIL=no-reply@mg.example.com
fly secrets set MAILER_FROM_NAME="Potok"
```

Deploy with:

```sh
fly deploy
```

`fly.toml` already enables HTTPS, exposes the app on port `8080`, and runs migrations during deployment.

## Maintenance Notes

Use `mix precommit` as the final verification step for code changes. If you change the domain model, routes, or deployment assumptions, update this README at the same time so it stays aligned with the application.
