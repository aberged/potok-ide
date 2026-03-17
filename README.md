# PotokIde

PotokIde is a Phoenix and LiveView application centered around accounts, profiles, groups, invitations, and posted values. The application supports authenticated account flows, profile selection, multilingual UI with Gettext, and a responsive LiveView-driven interface.

## Getting Started

1. Run `mix setup` to fetch dependencies, create the database, run migrations, seed data, and build assets.
2. Start the server with `mix phx.server`.
3. Open `http://localhost:4000` in your browser.

Useful commands:

* `mix test` runs the test suite.
* `mix precommit` runs the project verification alias: compile with warnings as errors, unlock unused deps, format, and test.
* `mix ecto.reset` drops and recreates the local database.

## Project Structure

High-level layout:

```text
.
|- assets/
|  |- css/                 # Tailwind CSS entrypoint and theme setup
|  |- js/                  # Phoenix / LiveView JavaScript entrypoint
|  |- vendor/              # daisyUI, heroicons, topbar vendor assets
|- config/                 # Environment-specific Phoenix and runtime config
|- lib/
|  |- potok_ide/           # Domain contexts, schemas, repo, mailer
|  |  |- accounts/         # Account schema and auth-related domain code
|  |  |- social/           # Profile, group, value, membership, invitation schemas
|  |  |- accounts.ex       # Account context
|  |  |- social.ex         # Social context
|  |- potok_ide_web/       # Phoenix web interface
|  |  |- components/       # Shared UI components and layouts
|  |  |- controllers/      # Controller-based pages and session actions
|  |  |- live/             # LiveViews for auth, profiles, groups, invitations
|  |  |- account_auth.ex   # Shared account auth for conn and LiveView
|  |  |- profile_auth.ex   # Current profile loading / enforcement for LiveView
|  |  |- locale.ex         # Locale resolution and LiveView locale mounting
|  |  |- router.ex         # Browser, auth, and LiveView route composition
|- priv/
|  |- gettext/             # Translation catalogs for `en`, `pl`, and `sr`
|  |- repo/                # Migrations and seeds
|  |- static/              # Compiled static files
|- test/                   # ExUnit tests for contexts, controllers, and LiveViews
|- mix.exs                 # Dependencies, aliases, compilation, app config
```

## Tools Used

Core framework and backend:

* `Phoenix 1.8` for the web framework and routing.
* `Phoenix LiveView` for interactive server-rendered UI.
* `Ecto` and `ecto_sql` for persistence and database access.
* `Postgrex` as the PostgreSQL driver.
* `Bandit` as the HTTP server.

Authentication, mail, and HTTP:

* `pbkdf2_elixir` for password hashing.
* `Swoosh` for outbound email delivery.
* `Req` for HTTP client functionality.

Frontend and UI:

* `Tailwind CSS` for styling.
* `esbuild` for JavaScript bundling.
* `daisyUI` theme plugins in the asset pipeline.
* `Heroicons` for icon assets.

Internationalization and observability:

* `Gettext` for UI and validation translations.
* `telemetry_metrics` and `telemetry_poller` for app metrics.

Testing and DX:

* `ExUnit` for tests.
* `LazyHTML` for LiveView HTML assertions in tests.
* Phoenix aliases in `mix.exs` for setup, asset builds, and verification.

## Web Layer Overview

The web application is split into a small set of shared concerns:

* `PotokIdeWeb.AccountAuth` loads authenticated accounts for both controller and LiveView requests.
* `PotokIdeWeb.ProfileAuth` ensures the current profile is available where profile-scoped behavior is required.
* `PotokIdeWeb.Locale` resolves locale from params, session, and request headers, and mounts locale data into LiveViews.
* LiveViews handle the interactive screens for registration, login, confirmation, settings, profiles, groups, and invitations.
* Shared layouts provide the responsive shell, hamburger navigation, theme switching, and locale switching.

## Domain Model

The main concepts in the system are:

* `Account`: the authenticated identity. An account has an email, optional password login, confirmation state, many profiles, and one selected `current_profile`.
* `Profile`: the social identity used inside groups. A profile belongs to one or more accounts depending on its sharing mode and can create groups and values.
* `Group`: a hierarchical container for collaboration. Groups can have a parent group, an optional parent value, a creator profile, members, and child groups. One group is the root group.
* `Value`: a posted piece of content created by a profile inside a group. Values can also form reply chains through `parent_id`.
* `GroupMembership`: the join entity between profiles and groups.
* `GroupInvitation`: an invitation from one profile to another to join a group, with optional acceptance timestamp.
* `AccountProfile`: the join entity between accounts and profiles.

Relationship summary:

```text
Account 1----* AccountProfile *----1 Profile
Account 1----0..1 current_profile -> Profile

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
```

## Internationalization

The application currently supports:

* `en` for English
* `pl` for Polish
* `sr` for Serbian

Translations live in `priv/gettext/`, and locale selection is available in the application menu.

## Notes

The repository memory for this project expects `mix precommit` to be the final verification step after changes. If you extend the domain model, update both the relevant Ecto schemas and this README so the documentation stays aligned with the implementation.
