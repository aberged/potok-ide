# Potok

<div class="flex flex-row gap-2">
<img src="https://icon.icepanel.io/Technology/svg/Elixir.svg" width="50"/>
<img src="https://upload.wikimedia.org/wikipedia/en/thumb/1/1e/Phoenix_Framework_Logo.svg/1920px-Phoenix_Framework_Logo.svg.png" width="55"/>
<img src="https://www.svgrepo.com/download/374118/tailwind.svg" width="56"/>
<img src="https://img.daisyui.com/images/daisyui/mark-rotating.svg" alt="daisyUI logo" width="44"/>
</div>

Potok is a Phoenix 1.8 and LiveView application for account-based collaboration around profiles, groups, invitations, and posted values. The app is server-rendered, locale-aware, and organized around two states after login: profile selection and profile-scoped group activity. Group chats support replies, threads, reactions, @mentions, file attachments and link previews, groups keep a calendar of events with answers and reminders, and what members may do is set by per-group roles. It also exposes browser-side Potok APIs through LiveView hooks, providing a foundation for Potok-scoped application development on top of group descriptions and values.

## Domain Model

The main concepts in the system are:

* `Account`: the authenticated identity. An account has an email, optional password login, confirmation state, many profiles, one selected `current_profile`, and one `default_profile` used as the fallback profile when no explicit current profile is set.
* `Profile`: the social identity used inside groups. A profile can be `unique` or `shared`, can be linked to one or more accounts depending on sharing rules, and can create groups and values.
* `Group`: a hierarchical collaboration container with a creator profile, memberships, child groups, optional parent relations, and a persisted `home_page` preference that controls which panel opens by default.
* `GroupAltDescription`: an alternative description of a group (text or an app), shown next to the default description kept on the group. It can be limited to roles and can be the group's home description.
* `Value`: content posted by a profile in a group. A chat value can quote another value as an inline reply and carry @mentions, file attachments, reactions and a link preview. A data value (`is_data`) is written by a group app and never shows in the chat.
* `ValueReaction`: one emoji a profile put on a value.
* `ValueAttachment`: a file attached to a chat value. The bytes live in `PotokIde.Storage`.
* `GroupMembership`: the join entity between profiles and groups. A membership held only through the parent group is marked `inherited`.
* `GroupManifest`: the roles of a group. A group without its own manifest uses the one of its nearest ancestor.
* `GroupRole`: a role of a manifest that allows or denies permissions.
* `GroupMemberRole`: a role held by a member in one group.
* `GroupValueRead`: the last value a profile has read in a group, the base of unread counts.
* `GroupInvitation`: an invitation from one profile to another profile to join a group.
* `GroupAccountInvitation`: a group invitation sent by email to an account without a profile yet. It becomes a `GroupInvitation` when the account creates its first profile.
* `GroupJoinRequest`: a pending request from a non-member profile to join a public group.
* `GroupJoinRequestApproval`: the record of an accepted join request and who accepted it.
* `ProfileInvitation`: an invitation to share a `shared` profile with another profile's account. Accepting it links the profile to that account.
* `AccountProfile`: the join entity between accounts and profiles.
* `PushSubscription`: a Web Push subscription or native push token of an account, with the language of the session that saved it.
* `Event`: an event in a group's calendar, once or repeating, kept in its IANA time zone, with the organizer's reminders and the chat value that announced it.
* `Events.Response`: a member's answer (going, maybe, not going) for one occurrence of an event, named by its local start date.
* `Events.MemberSetting`: a member's own reminders for an event, in place of the organizer's.
* `Tag`: a tag for groups, profiles, events, values and files. Without an owner it is public; otherwise it is the private tag of its owner profile.
* `Tagging`: one tag on one item. Each item kind has its own column, so deleting the item deletes its taggings.

Invitation behavior:

* Invitations are stored against the invitee profile, not against a specific account.
* If the invitee profile is shared, the pending invitation is effectively shared as well, because all linked accounts access the same profile record.
* Accepting an invitation adds the profile to the target group, so the resulting membership is also shared by every account linked to that profile.

Group access and direct-group behavior:

* Public groups support access requests from non-member profiles. Members with the `manage_join_requests` permission review those pending requests from the members tab and can accept or reject them there.
* Members with `invite_members` can invite a profile by username or anyone by email. An email without an account gets a new account and a login link, and the invitation waits as a `GroupAccountInvitation` until that account creates its first profile.
* Groups persist a `home_page` enum with the values `description`, `chat`, and `subgroups`. The create-group and edit-group panels expose that setting so members can control the default landing panel for a group.
* Opening a group without an explicit tab uses its `home_page`: `description` opens the description panel, `chat` opens the values panel, and `subgroups` opens the sub-groups panel.
* Root groups ignore `home_page` and always open on the sub-groups panel.
* Besides its default description, a group can have up to 20 alternative descriptions (`GroupAltDescription`), managed in the edit-group panel. Each one is markdown, HTML or an app (`uses_api`). When a group has any, the description panel shows them as tabs after the default one, and `?d=<id>` (or `?d=default`) opens one directly.
* An alternative description with `visible_role_keys` is shown only to members holding one of those roles (`everyone` = every member) and to those who can edit the group. Without roles it is shown to everyone who sees the description.
* `home_alt_description_id` makes an alternative description open first instead of the default one. A viewer who cannot see it gets the default.
* "Make default" swaps an alternative description with the default one: their contents, names and app data values trade places. Descriptions limited to roles cannot be made the default.
* Direct groups are derived conversation groups, not a separate invitation flow. Opening `/profiles/:id/direct` finds or creates a private non-root group under the root group for exactly two profiles and then navigates to that group's values tab.
* Direct private groups ignore `home_page` and always open on the values panel.
* Because direct groups are fixed to two members, the group UI hides profile-invite actions, join-request management, and member removal controls for them.
* Groups that use the API (`uses_api`) show a 🧩 badge on the group avatar.

Roles and permissions:

* Every group uses a manifest: its own, or the one of its nearest ancestor that has one. The root group always has one, and its default manifest is fixed.
* The permissions are `post_values`, `attach_files`, `react`, `open_threads`, `create_subgroups`, `invite_members`, `mention_roles`, `manage_join_requests`, `remove_members`, `delete_values`, `create_events`, `manage_events`, `manage_tags` and `edit_group`.
* The built-in `admin` role holds every permission. Every member implicitly holds `everyone`, which by default allows `post_values`, `attach_files`, `react`, `open_threads`, `create_subgroups`, `invite_members`, `mention_roles` and `create_events`.
* For other roles a permission is granted when one of the member's roles allows it and none denies it. `everyone` can only allow.
* Creators become admins of their groups. Admins create roles, give a group its own manifest (a copy of the inherited one) or revert it to the inherited one, and assign roles per group in the members tab.

Member inheritance:

* A sub-group can be set to inherit members (`inherits_members`) when it is created or edited. It then holds every member of its parent with the roles they hold there, and follows the parent as members join or leave and as their roles change, down a whole chain of inheriting groups.
* Inherited memberships and roles are marked `inherited` and cannot be removed in the sub-group. Members and roles added in the sub-group itself stay when the parent ones go. Turning inheritance off keeps everyone as a direct member.
* Members who arrive through inheritance start with the sub-group's history read.
* Threads always inherit. Groups directly in the root group and direct groups never inherit, as they would hold every profile.

Chat values:

* A reply quotes the value it answers. Clicking the quote jumps to the original, even when it is not loaded, and quotes refresh when the original is edited or deleted.
* "Reply in thread" opens the value's thread: a chat-first sub-group of the value's group, created on first use (one per value, `groups.parent_value_id`). Its "Show original value" link opens the parent chat at that value (`?value=<id>`). Direct groups have inline replies only.
* `@username` and `@role` mentions are resolved against the group's members and its manifest's roles (roles only with `mention_roles`). Mentioned members get a mention push instead of the generic one.
* Reactions are single emoji. The value's author gets a push when someone reacts.
* The first http(s) link of a chat value gets an Open Graph preview card (title, description, site name, image), fetched after posting and cached per URL for 6 hours. The fetcher only connects to public addresses. The author can remove the card.
* The feed holds at most 200 values. Opening a value loads a window around it (ten older, twenty newer), scrolling loads pages of twenty at either end and drops as many at the other, and a button brings the feed back to the newest values.
* Unread counts come from `GroupValueRead`. A group's folder in the sub-groups tree shows the unread values of its whole subtree, and the root group's count is the sum over all groups.

Files:

* Members with `attach_files` can attach up to 10 files of up to 100 MB each to a value (limits from `ATTACHMENT_MAX_FILES` and `ATTACHMENT_MAX_FILE_SIZE_MB`). A value may carry only files.
* Images, video and audio are shown in place; other files are download rows.
* `GET /files/:id` serves a file only to members of its group, either by redirecting to a short-lived signed URL or by sending it with a sandboxing CSP.
* The Files tab lists a group's files newest first, or shows the group and its visible sub-groups as folders.
* `PotokIde.Storage.Local` keeps files in `./uploads` in dev and test. `PotokIde.Storage.S3` keeps them in an S3-compatible bucket (Tigris on Fly, R2, S3) when `BUCKET_NAME` is set; browsers upload to it directly with presigned URLs. Without an adapter attachments are off.
* Deleting a value or a group deletes its stored files.

Sub-groups:

* The sub-groups tab has a list and a folder view (`?view=tree`). The folder view shows the whole tree below the group, up to 10 levels and 500 groups.
* Thread groups are marked, and a threads toggle hides or shows them.

Tags:

* Groups, profiles, events, values and files can carry tags (`PotokIde.Tags`). The `#` button on an item opens its tags: the current ones, a field with suggestions and, for those who may, a private/public switch.
* A private tag belongs to one profile, which can put it on anything it can open (a group it sees, the values, files and events of its groups, any profile). Only that profile sees it, so every account sharing a profile sees its private tags. Private tags stay until their owner deletes them on the tags page.
* A public tag is seen by everyone who can open the item. Public tags are one vocabulary for the whole app: a public tag is created when it is first used, and lists and suggestions show only those still on some item.
* Public tags on values, files and events need `manage_tags` in the item's group; on a group, `manage_tags` in that group or in its parent. Admins hold it, and they can give it through a role. A profile's public tags are put on it by the profile itself, from its edit page or its row in a members list.
* An item carries at most 10 public tags and 10 private tags per profile.
* `/tags` lists the profile's private tags (to rename or delete) and the public tags in use. `?t=3,7` shows what carries every one of the tags and the profile can open, by kind (`kind=groups|values|files|events|profiles`), optionally inside one group and its sub-groups (`group=12`; for profiles, its members). Clicking a tag anywhere opens it there, and a group's menu links to its tags and to the tags page limited to it.
* Changes to public tags reach the open pages of the item's group live.

Calendar:

* The calendar tab (`/groups/:id/calendar`) shows a month (`?month=2026-11`) or that month as a list (`mode=list`), and an open occurrence (`event=12&on=2026-11-07`). Only members see it. Other groups can include the events of the sub-groups the profile is a member of; the root group's calendar ("My calendar") shows the events of every group the profile is a member of.
* Members with `create_events` add events, except in the root group. Authors change and cancel their own events while they are members; `manage_events` changes anyone's. A cancelled event leaves the calendar and its chat card says it was cancelled. A single occurrence of a repeating event can be cancelled as well.
* Events happen once, all day or repeatedly: every N days, weeks (on chosen weekdays), months (on the start's day of the month, or its nth or last weekday) or years, optionally until a date. The rules follow RFC 5545, so an exported RRULE yields the same dates.
* Times are kept in the event's IANA zone (the creator's browser zone, through the `tz` database), so repeats keep their wall-clock time across daylight saving changes. Pages show times in the viewer's zone, which the browser sends when the LiveView socket connects.
* An occurrence is named by its local start date. Members answer going, maybe or not going per occurrence. Answers to come are dropped when the event's time changes, or when their date is no longer an occurrence.
* A new event can be announced in the group's chat: a chat value that shows the event's card, counts as unread and sends members a push. Members are also told when an event's time, place or repeat rule changes, and when the event or one of its occurrences is cancelled.
* The organizer picks the event's reminders (from "when it starts" to a week before; for all-day events counted from 09:00 on the day), and every member can pick their own or turn them off. Members who declined an occurrence get no reminder for it.
* `PotokIde.Events.ReminderScheduler` runs on every node and sends due reminders every 30 seconds. It takes events with `FOR UPDATE SKIP LOCKED`, so no reminder is sent twice, and drops reminders found more than 10 minutes late (say, after a deploy).
* Push notifications about events are written in the language each device saved its push subscription with; the browser saves it again when the language changes.
* `GET /events/:id/event.ics` downloads an event for Google, Apple or Outlook calendars.

Relationship summary:

```text
Account 1----* AccountProfile *----1 Profile
Account 1----0..1 current_profile -> Profile
Account 1----0..1 default_profile -> Profile
Account 1----* PushSubscription

Profile 1----* GroupMembership *----1 Group
Profile 1----* GroupMemberRole *----1 Group
Profile 1----* GroupValueRead *----1 Group
Profile 1----* created_groups
Profile 1----* values

Group 1----* child_groups
Group 1----* values
Group 1----0..1 GroupManifest 1----* GroupRole
Group 1----* GroupAltDescription
Group 1----* Event
Group 0..1----1 parent_group
Group 0..1----1 parent_value (thread groups)

Value 0..1----1 parent_value (reply)
Value 1----* child_values
Value 1----* ValueReaction
Value 1----* ValueAttachment
Value 1----0..1 Event (announcement)

Event 1----* Events.Response *----1 Profile
Event 1----* Events.MemberSetting *----1 Profile

Tag 0..1----1 owner (Profile, private tags)
Tag 1----* Tagging *----1 Group | Profile | Event | Value | ValueAttachment

GroupInvitation belongs_to group, inviter(profile), invitee(profile)
GroupAccountInvitation belongs_to group, inviter(profile), account
GroupJoinRequest belongs_to group, requester(profile)
GroupJoinRequestApproval belongs_to group, requester(profile), approver(profile)
ProfileInvitation belongs_to profile, inviter(profile), invitee(profile)
```

Default profile behavior:

* The first profile created for an account becomes both its `current_profile` and `default_profile`.
* Later profile creation does not overwrite either selection.
* If `current_profile` is cleared, the web layer falls back to `default_profile` for profile-scoped behavior.

Avatar behavior:

* Profile avatars are resolved from `profile_picture_url` only when it is a non-empty string.
* When a profile has no avatar URL (or an empty URL), the app uses `GET /avatar/profile/:id` to render initials.
* Group avatars are served from `GET /avatar/group/:id` the same way, from `group_picture_url` or the group's initials.
* The nav bar updates this avatar source during profile switches through the `phx:current_profile_updated` event so changing from a profile with a URL to one without a URL immediately falls back to `/avatar/profile/:id`.
* Push-notification avatar fields follow the same fallback route strategy and are converted to absolute URLs before sending FCM payloads.

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

### Capacitor wrapper

Potok now includes Capacitor wrappers in `assets/` for both Android and iOS.

Important architecture note:

* Potok is a Phoenix LiveView application, so the Capacitor shell does **not** run a standalone static build of the app.
* The native WebView loads a running Phoenix server through Capacitor's `server.url` setting.
* By default the Capacitor config uses `http://10.0.2.2:4000` when syncing Android and `http://localhost:4000` when syncing iOS.
* Use `CAPACITOR_SERVER_URL` for a shared override, or `CAPACITOR_ANDROID_SERVER_URL` and `CAPACITOR_IOS_SERVER_URL` for platform-specific overrides.
* Magic-link emails now include a standard HTTPS deep link at `https://potok.rs/accounts/log-in/<token>?app=1`, which is used for both Android App Links and iOS Universal Links.

Files and commands:

* Capacitor config: `assets/capacitor.config.ts`
* Android project: `assets/android`
* iOS project: `assets/ios`
* Sync native project after config changes: `cd assets && npm run cap:sync:android`
* Sync iOS project after config changes: `cd assets && npm run cap:sync:ios`
* Open Android Studio: `cd assets && npm run cap:open:android`
* Open the iOS project in Xcode: `cd assets && npm run cap:open:ios`
* Run on a connected emulator or device: `cd assets && npm run cap:run:android`
* Run on an iOS simulator or device from macOS: `cd assets && npm run cap:run:ios`

Development workflow:

1. Start Phoenix locally with `mix phx.server`.
1. In another shell, set `CAPACITOR_SERVER_URL` if you are not using the platform default.
1. From `assets/`, run `npm run cap:sync:android`.
1. Open or run the Android app with one of the Capacitor scripts above.

Examples:

```powershell
# Android emulator against local Phoenix server
Set-Location assets
$env:CAPACITOR_SERVER_URL = "http://10.0.2.2:4000"
npm run cap:sync:android
npm run cap:open:android
```

```powershell
# Physical device on the same LAN
$env:PHX_DEV_BIND_ALL = "true"
mix phx.server

Set-Location assets
$env:CAPACITOR_SERVER_URL = "http://192.168.1.50:4000"
npm run cap:sync:android
npm run cap:run:android
```

For production, point `CAPACITOR_SERVER_URL` at your deployed HTTPS endpoint before syncing.

Example iOS simulator flow on macOS:

```sh
cd assets
CAPACITOR_SERVER_URL=http://localhost:4000 npm run cap:sync:ios
CAPACITOR_SERVER_URL=http://localhost:4000 npm run cap:open:ios
```

Magic-link login in the native apps:

1. Start the Capacitor app against the same backend you want to use for login.
1. Request a magic link from the login screen in the app.
1. In the email, tap the `https://potok.rs/accounts/log-in/...?...` app link to reopen the Potok app.
1. The app will navigate its WebView to the existing `/accounts/log-in/:token` screen on your configured backend.
1. Confirm the login on that screen so the Phoenix session cookie is created inside the app WebView.

Older `potok://login/...` links are still handled by the app for backward compatibility, but new emails use standard HTTPS deep links so they are clickable in mail clients and can be claimed by both Android and iOS.

iOS Universal Links notes:

* the app serves `/.well-known/apple-app-site-association` and `/apple-app-site-association`
* the generated iOS app enables the `applinks:potok.rs` associated domain in `assets/ios/App/App/App.entitlements`
* set `IOS_APP_LINK_TEAM_ID` in production so the association file can publish the real Apple app identifier
* if you need to override the generated identifier directly, set `IOS_APP_LINK_APP_ID`; otherwise the server composes it from `IOS_APP_LINK_TEAM_ID` and `IOS_APP_LINK_BUNDLE_ID`

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

### Capacitor push notifications

The same account settings screen at `/accounts/settings` now also manages native push notifications for the installed Android and iOS apps.

Android setup requirements:

* install the Capacitor push plugin in `assets/` with `npm install @capacitor/push-notifications`
* place your Firebase `google-services.json` file in `assets/android/app/google-services.json`
* run `cd assets && npm run cap:sync:android` after changing Capacitor or Android notification config

iOS setup requirements:

* in Apple Developer, enable `Push Notifications` for the bundle identifier used by the signed app
* in Firebase Console, add the iOS app for that bundle identifier and upload an APNs auth key under Cloud Messaging
* replace `assets/ios/App/App/GoogleService-Info.plist` with the real Firebase-generated file before building a signed app
* the iOS app now forwards APNs registration to Capacitor and publishes the Firebase Messaging token from `assets/ios/App/App/AppDelegate.swift`
* the iOS target now includes `aps-environment` in `assets/ios/App/App/App.entitlements`; Debug uses `development` and Release uses `production`
* run `cd assets && npm run cap:sync:ios` after changing Capacitor or iOS notification config

Server-side Firebase configuration:

* either set `FIREBASE_SERVICE_ACCOUNT_JSON` to the full service-account JSON document
* or set all of `FIREBASE_PROJECT_ID`, `FIREBASE_CLIENT_EMAIL`, and `FIREBASE_PRIVATE_KEY`
* optionally set `FIREBASE_TOKEN_URL` if you need a non-default Google OAuth token endpoint
* optionally set `FIREBASE_CHANNEL_ID` to override the default notification channel id (`potok-default`)

Once the relevant browser or Firebase credentials are configured, `/accounts/settings` exposes the shared enable, disable, and test notification controls for the PWA and the installed native apps.

### Share to Potok

Potok appears in the system share sheet of the native apps and of the installed web app on Android. Shared text, links and files stay on the device until a group is picked on `/share`; the group's composer then takes them into its usual upload, so the file count, size and `attach_files` checks are the composer's own. `assets/js/share_inbox.js` reads the share from one of three places:

* Android: `SEND` / `SEND_MULTIPLE` intent filters on `MainActivity` and `ShareInboxPlugin.java`, which copies shared files into the app cache
* iOS: the `ShareExtension` target (`assets/ios/App/ShareExtension/`), which copies them into the App Group container `group.rs.potok.ide` and opens `potok://share/<id>`; `App/ShareInboxPlugin.swift` reads them from there
* installed web app: `share_target` in `priv/static/manifest.webmanifest`; the service worker keeps the post in IndexedDB (`POST /share-target` is the text-only fallback)

Native changes need a new app build. iOS setup in Apple Developer:

* enable `App Groups` on the app's identifier and add the group `group.rs.potok.ide`
* register the identifier `rs.potok.ide.share` with the same App Group
* regenerate the app's App Store provisioning profile and create one for `rs.potok.ide.share`; the workflow takes the second one from `IOS_SHARE_PROVISION_PROFILE_BASE64` and `IOS_SHARE_PROVISION_PROFILE_NAME`

### Signed release APKs via Gradle

The Android project is now set up so `assembleRelease` produces a signed APK and `bundleRelease` produces a signed Android App Bundle when the signing values are provided in `assets/android/release-signing.properties`, as Gradle properties, or as environment variables.

Required signing keys:

* `POTOK_UPLOAD_STORE_FILE`
* `POTOK_UPLOAD_STORE_PASSWORD`
* `POTOK_UPLOAD_KEY_ALIAS`
* `POTOK_UPLOAD_KEY_PASSWORD`

Recommended setup:

1. Copy `assets/android/release-signing.properties.example` to `assets/android/release-signing.properties`.
1. Fill in your keystore path, alias, and passwords there.

The real `release-signing.properties` file is gitignored, so you do not need to put signing secrets in shell history.

Example PowerShell flow:

```powershell
Set-Location assets
$env:CAPACITOR_SERVER_URL = "https://potok.rs"
npm run cap:sync:android

Set-Location android
.\gradlew.bat assembleRelease
```

The signed APK will be written to `assets/android/app/build/outputs/apk/release/`.

If you need an Android App Bundle (`.aab`) for Play Console upload, run:

```powershell
Set-Location assets
$env:CAPACITOR_SERVER_URL = "https://potok.rs"
npm run cap:sync:android

Set-Location android
.\gradlew.bat bundleRelease
```

The signed AAB will be written to `assets/android/app/build/outputs/bundle/release/app-release.aab`.

If any of the signing values are missing, Gradle now fails release builds with a clear error instead of silently producing an unsigned release artifact.

### Optional debug signing properties

The Android project can also load debug signing values from `assets/android/debug-signing.properties`.

Required debug signing keys:

* `POTOK_DEBUG_STORE_FILE`
* `POTOK_DEBUG_STORE_PASSWORD`
* `POTOK_DEBUG_KEY_ALIAS`
* `POTOK_DEBUG_KEY_PASSWORD`

Recommended setup:

1. Copy `assets/android/debug-signing.properties.example` to `assets/android/debug-signing.properties`.
1. Fill in the debug keystore path, alias, and passwords there.

If `debug-signing.properties` is absent, Android Gradle Plugin falls back to its normal default debug keystore behavior. If the file is present but incomplete, debug builds fail with a clear error.

### Development behavior

The default development configuration includes:

* local email delivery through `Swoosh.Adapters.Local`
* mailbox preview at `http://localhost:4000/dev/mailbox`
* LiveDashboard at `http://localhost:4000/dev/dashboard`
* live asset rebuilding through Phoenix endpoint watchers
* file attachments stored on disk in `./uploads` (git-ignored)

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
* `dns_cluster`
* `tz` for IANA time zones of calendar events

Authentication, email, and HTTP:

* `pbkdf2_elixir`
* `Swoosh` and `mail`
* `Req`

Content:

* `Earmark` for Markdown
* `html_sanitize_ex` for sanitizing Markdown and HTML descriptions and values
* `LazyHTML` for parsing pages when building link previews

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

Public routes:

* `GET /` redirects based on account and profile state
* `GET /locale/:locale` updates the active locale
* `GET /privacy-policy` renders `priv/static/PRIVACY_POLICY.md`
* `GET /avatar/profile/:id` and `GET /avatar/group/:id` serve avatar images (no session)
* `GET /.well-known/assetlinks.json` for Android App Links
* `GET /.well-known/apple-app-site-association` and `GET /apple-app-site-association` for iOS Universal Links
* `POST /share-target` passes text shared to the installed web app on to `/share` when no service worker took the post (no session or CSRF; see "Share to Potok")
* `DELETE /accounts/log-out`

Routes for logged-out visitors only (logged-in accounts are redirected):

* `GET /accounts/log-in` and `GET /accounts/log-in/password` for password login
* `GET /accounts/log-in/magic-link` to request a login link
* `GET /accounts/log-in/:token` to confirm a login link
* `POST /accounts/log-in`

Authenticated routes:

* `GET /profiles` for profile selection and setup
* `GET /profiles/new`
* `GET /profiles/:id/edit`
* `GET /accounts/settings/confirm-email/:token`
* `POST /accounts/update-password`
* `POST /accounts/push-subscriptions`
* `DELETE /accounts/push-subscriptions`
* `POST /accounts/push-subscriptions/test`
* `GET /files/:id` serves an attached file to members of its group (logged-out visitors go to the login page and come back)
* `GET /events/:id/event.ics` serves an event as an iCalendar file to members of its group (logged-out visitors go to the login page and come back)

Authenticated routes that require a current profile:

* `GET /profiles/:id/direct`
* `GET /groups`
* `GET /share` picks the group for content shared from another app (see "Share to Potok")
* `GET /groups/:id`
* `GET /groups/:id/:tab`
* `GET /invitations`
* `GET /requests`
* `GET /accounts/register`
* `GET /accounts/settings`

Development-only routes when `dev_routes` is enabled:

* `GET /dev/dashboard`
* `GET /dev/mailbox`

The router uses separate LiveView sessions for:

* logged-out login pages (`:current_account`)
* email-change confirmation (`:require_authenticated_account`)
* authenticated profile selection (`:authenticated`)
* profile-required collaboration screens and account settings (`:profile_required`)

## App API

In groups with `uses_api`, the group description is an app: HTML that runs in a sandboxed iframe (`Components.app_frame/1`) instead of being rendered as formatted content. An alternative description with `uses_api` is an app too, so a group can have one app per description. Each app has its own data values, `localStorage` and API calls; the default description's app is the one that existed before (its values have no `description_id`). The iframe has no `allow-same-origin`, so it gets an opaque origin and cannot reach the page, its cookies or the LiveSocket.

The frame loads `assets/js/potok_app_sdk.js` first. The SDK talks to the `GroupAppFrame` hook in `assets/js/app.js` over `postMessage`. The hook forwards whitelisted methods to the LiveView (`app_api` event) together with the frame's app id (`data-app-id`), and `PotokIdeWeb.GroupLive.Show.AppApi` checks every call again on the server. Calls act on the description on screen; a call from an app the viewer has just switched away from is refused with `stale_app`.

The frame document looks like this:

```html
<head>
  <link rel="stylesheet" href="/assets/css/app.css">  <!-- the page's daisyUI styles -->
  <meta name="potok-app" content="">  <!-- "" for the default description, else the alternative description's id -->
  <script src="/assets/js/potok_app_sdk.js"></script>
</head>
<body><div id="group-panel-description"><!-- group description --></div></body>
```

### `window.potok`

Every call resolves to the server reply, `{ok: true, ...}` or `{ok: false, error, message?}`, and rejects if the page does not answer within 10 seconds.

* `insertValue(data, options)` creates a data value of this app and resolves to `{ok: true, value}`.
  * `data` is an object or a JSON object string; anything else is refused with `invalid_value`.
  * `options.contentFormat`: `"markdown"` (default) or `"html"`.
  * Members only; rate limited.
* `listValues(options)` resolves to `{ok: true, values, has_more}`. Members only. Options:
  * `scope`: without it, only this app's values; `"group"` adds the values of the group's other apps that the viewer can open (each carries its `description_id`)
  * `limit` (at most 200, default 50), `offset`
  * `afterId` / `beforeId`: only values with a greater / smaller id
  * `searchField` + `searchValue`: case-insensitive substring match on `data[searchField]`
  * `orderBy`: a key in `data` (`"number"` sorts numerically first); without it values come in insertion order
  * `orderDir`: `"asc"` (default) or `"desc"`
  * snake_case names (`after_id`, `order_by`, ...) work too.
* `updateDescription(description, options)` resolves to `{ok: true, group}`. It changes the app's own description (the default or an alternative one). `options.descriptionFormat` sets the format. It needs the `edit_group` permission and is rate limited. A new description is new app HTML, so the app restarts.
* `getDescription()` resolves to `{ok: true, group}` for the app's own description.
* `getCurrentProfile()` resolves to the profile, or `null`.
* `onNewValue(listener, options)` calls `listener(value)` for every new data value of this app, including the viewer's own, and returns a function that removes the listener. With `{scope: "group"}` it also gets the values of the group's other apps that the viewer can open. Each value of this app is also dispatched on `window` as a `phx:new_data_value` `CustomEvent` (`detail` is the value). Values are pushed only while a description is on screen.

Reply shapes:

```js
// value (insertValue, onNewValue); listed values also have inserted_at and updated_at
{id, content: "data:", data: {...}, content_format, is_data: true, group_id, parent_id, creator_id, creator_username, description_id}

// group (updateDescription, getDescription); description_id is null for the default description
{id, description_id, name, description, description_format}

// profile; roles are the names of the roles the profile holds in the group
{id, username, profile_picture_url, description, description_format, sharing, inserted_at, updated_at, admin, roles}
```

Error codes (`error`):

* From the server, with a localized `message`: `not_a_member`, `forbidden`, `invalid_value`, `invalid_description`, `rate_limited` (writes come in bursts of up to 30, refilled over 10 seconds).
* From the server, without a message: `stale_app` (the call came from an app that is no longer on screen), `unknown_method`.
* From the hook: `preview` (the edit form's preview frame refuses API calls), `unknown_method`, `disconnected`.

The frame environment:

* `localStorage` in the frame is an in-memory `Storage`. The page keeps a copy per app (`potok-app:<group id>` for the default description, `potok-app:<group id>:alt-<id>` for an alternative one, at most 256 KB) and restores it, so it survives reloads. `sessionStorage` is in memory only. The copy belongs to the place, not the app: after "Make default" swaps two apps, each finds the other's saved copy.
* The frame follows the page's daisyUI theme (`data-theme`).
* After a LiveSocket reconnect the frame reloads, because values pushed while offline never arrive.
* The app also restarts when the description or the viewer's access (profile, membership, roles) changes.

### Legacy API

Apps written before the sandbox ran inside the page and found the API on `document.getElementById("group-panel-description").potok`. The SDK keeps that working. Once the page is ready, it sets `potok` on `#group-panel-description` to a shim (also `window.__potokLegacy`):

* `el` (`#group-panel-description`) and `abortController` (for `{signal}` listener options)
* `insertGroupValue(content, options)`: `insertValue`, where `content` must be a string (a JSON object)
* `updateGroupDescription(description, options)`: `updateDescription`
* `getGroupDescription()`: resolves to `{description, descriptionFormat}` (format defaults to `"html"`)
* `getGroupDataValues(options)`: without `options.limit`, resolves to every value as `{ok: true, values}` (fetched in pages of 200, at most 5,000); with it, to one `listValues` page
* `getCurrentProfile()`
* `setNewValueCallback(fn)`: a single callback (a new one replaces it) that receives a `phx:new_data_value` `CustomEvent` with the value as `detail`

## Internationalization

The application currently ships with:

* `en` for English
* `sr` for Serbian in the Latin script (the default locale)
* `sr_Cyrl` for Serbian in the Cyrillic script

Translations live under `priv/gettext/`. Locale switching is exposed through the UI and backed by `PotokIdeWeb.Locale` in both Plug and LiveView flows.

`sr_Cyrl` is generated from `sr`, so don't edit its files by hand: change `sr` and run `mix potok.sr_cyrl`. A test fails when the two are out of step.

## Project Structure

High-level layout:

```text
.
|- .github/workflows/      # iOS build/TestFlight and Fly deploy workflows
|- assets/
|  |- css/                 # Tailwind CSS entrypoint
|  |- js/                  # Phoenix / LiveView JavaScript entrypoint and app SDK
|  |- vendor/              # Bundled frontend vendor files
|  |- android/, ios/       # Capacitor native projects
|- config/                 # Environment-specific configuration
|- docs/                   # iOS secrets and checklist
|- lib/
|  |- potok_ide/           # Domain contexts, schemas, repo, mailer, release helpers
|  |  |- accounts/         # Account schema and auth-related domain code
|  |  |- social/           # Profile, group, value, role, attachment schemas, access and inheritance
|  |  |- events/           # Calendar events, repeat rules, reminders and iCalendar export
|  |  |- storage/          # Local and S3 storage adapters for attachments
|  |  |- link_previews/    # HTTP fetcher for Open Graph previews
|  |  |- push_notifications/ # Web Push and FCM senders
|  |  |- accounts.ex       # Account context
|  |  |- social.ex         # Social context
|  |  |- events.ex         # Calendar context
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
|- load_test/              # Docker stress test of the production release
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
* Runtime avatar generation relies on ImageMagick SVG rendering support (for example `imagemagick` + `librsvg2-bin` on Debian-based images).

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
* `BOOTSTRAP_ACCOUNT_EMAIL` and `BOOTSTRAP_ACCOUNT_PASSWORD` (both together) make sure an account with that login exists at startup
* `ANDROID_APP_LINK_PACKAGE` (default `rs.potok.ide`) and `ANDROID_APP_LINK_SHA256_CERT_FINGERPRINTS` for Android App Links
* `IOS_APP_LINK_TEAM_ID`, `IOS_APP_LINK_BUNDLE_ID` (default `rs.potok.ide`), `IOS_APP_LINK_APP_ID` and `IOS_APP_LINK_PATHS` (default `/accounts/log-in/*`) for iOS Universal Links

File attachments (without `BUCKET_NAME` attachments are off in production):

* `BUCKET_NAME` turns on the S3 storage adapter
* `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY` are required with it
* `AWS_ENDPOINT_URL_S3` defaults to `https://fly.storage.tigris.dev`
* `AWS_REGION` defaults to `auto`
* `S3_VIRTUAL_HOST=true` uses virtual-host style bucket URLs
* `ATTACHMENT_MAX_FILES` (default `10`) and `ATTACHMENT_MAX_FILE_SIZE_MB` (default `100`) set the limits per value

Operational notes:

* `PHX_HOST` is used to build endpoint URLs in production.
* `PORT` is read in all environments, not just production.
* `MAILGUN_BASE_URL` is useful for EU-region Mailgun accounts.
* `DNS_CLUSTER_QUERY` is only needed when you want DNS-based node discovery across multiple running nodes.

## Fly.io Deployment

The repository already contains `fly.toml` with these defaults:

* app name: `potok-ide`
* primary region: `fra`
* runtime host: `potok.rs`
* internal service port: `8080`
* release command: `/app/bin/migrate`
* preconfigured runtime env: `PHX_HOST=potok.rs`, `PORT=8080`, `MAILER_FROM_NAME=Potok`

Example Fly.io secrets setup:

```sh
fly secrets set SECRET_KEY_BASE=your-secret
fly secrets set DATABASE_URL=ecto://USER:PASS@HOST/DATABASE
fly secrets set MAILGUN_API_KEY=your-key MAILGUN_DOMAIN=mg.example.com MAILER_FROM_EMAIL=no-reply@mg.example.com
fly secrets set MAILER_FROM_NAME="Potok"
fly secrets set ANDROID_APP_LINK_SHA256_CERT_FINGERPRINTS="your-signing-cert-sha256"
fly secrets set IOS_APP_LINK_TEAM_ID="ABCDE12345" IOS_APP_LINK_BUNDLE_ID="rs.potok.ide"
```

For file attachments, `fly storage create` creates a Tigris bucket and sets `BUCKET_NAME`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_ENDPOINT_URL_S3` and `AWS_REGION` as app secrets.

For Android App Links, `ANDROID_APP_LINK_SHA256_CERT_FINGERPRINTS` should contain one or more comma-separated SHA-256 certificate fingerprints for the APK signing keys that should be allowed to open `https://potok.rs/accounts/log-in/...` inside the app. Use your debug key for `npm run cap:run:android` testing and add your release key fingerprint before shipping a signed release.

For iOS Universal Links, `IOS_APP_LINK_TEAM_ID` should be your Apple Developer Team ID and `IOS_APP_LINK_BUNDLE_ID` should match the bundle identifier used by the signed iOS app. If you prefer to set the full value yourself, use `IOS_APP_LINK_APP_ID` with the `TEAMID.bundle.id` format.

Deploy with:

```sh
fly deploy
```

`fly.toml` already enables HTTPS, exposes the app on port `8080`, and runs migrations during deployment.

`.github/workflows/fly-deploy.yml` deploys on pushes to `main`, which this repository does not use (the main branch is `dev`), so deploys are run by hand with `fly deploy`.

### iOS build and TestFlight workflow

The repository now includes `.github/workflows/ios-build-publish.yml`, which runs on GitHub-hosted macOS runners and performs these steps:

* installs npm dependencies in `assets/`
* syncs the Capacitor iOS project with `npm run cap:sync:ios`
* imports an Apple distribution certificate and the provisioning profiles of the app and its Share Extension
* archives the Xcode project and exports an IPA
* uploads the IPA as a GitHub artifact
* optionally uploads the IPA to App Store Connect / TestFlight

Current iOS versioning in the project:

* `MARKETING_VERSION` is currently `1.0` in `assets/ios/App/App.xcodeproj/project.pbxproj`
* `CFBundleVersion` is wired to `CURRENT_PROJECT_VERSION` in `assets/ios/App/App/Info.plist`
* the workflow overrides `CURRENT_PROJECT_VERSION` with the GitHub Actions run number, so each workflow run gets a unique build number automatically

Required GitHub Actions secrets:

* `CAPACITOR_SERVER_URL`
* `IOS_BUILD_CERTIFICATE_BASE64`
* `IOS_BUILD_CERTIFICATE_PASSWORD`
* `IOS_BUILD_KEYCHAIN_PASSWORD`
* `IOS_BUILD_PROVISION_PROFILE_BASE64`
* `IOS_BUILD_PROVISION_PROFILE_NAME`
* `IOS_SHARE_PROVISION_PROFILE_BASE64` and `IOS_SHARE_PROVISION_PROFILE_NAME` (the Share Extension `<bundle id>.share`, see "Share to Potok")
* `IOS_DEVELOPMENT_TEAM`
* `IOS_BUNDLE_IDENTIFIER`
* `IOS_FIREBASE_GOOGLE_SERVICE_INFO_BASE64`
* `APP_STORE_CONNECT_KEY_ID`
* `APP_STORE_CONNECT_ISSUER_ID`
* `APP_STORE_CONNECT_PRIVATE_KEY_BASE64`

Publish a new iOS build:

1. Commit and push the code you want to ship.
1. If this should appear as a new app version in App Store Connect, bump `MARKETING_VERSION` in `assets/ios/App/App.xcodeproj/project.pbxproj` before pushing. You usually only do this for a new public version such as `1.0` to `1.1`. The build number does not need a manual bump.
1. Make sure the required GitHub Actions secrets listed above are up to date.
1. Open GitHub Actions and run `iOS Build And Publish` with `upload_to_testflight=true`.
1. Wait for the workflow to finish. It will upload the `.ipa` artifact to GitHub either way, and when `upload_to_testflight=true` it also sends the build to App Store Connect.
1. In App Store Connect, wait for processing to finish, then add the build to TestFlight testing or to the App Store release you are preparing.

You can also trigger the workflow from the command line:

```powershell
gh workflow run "iOS Build And Publish" --repo aberged/potok-ide -f upload_to_testflight=true
```

Set `upload_to_testflight` to `false` if you only want a signed artifact without publishing it to TestFlight.

For iOS push-enabled builds, make sure the provisioning profile includes the Push Notifications capability and that `IOS_BUNDLE_IDENTIFIER` matches the identifier registered in both Apple Developer and Firebase.

For exact PowerShell and macOS secret commands plus a checked Apple Developer and Firebase review against the current Potok bundle id, see `docs/ios-secrets-and-checklist.md`.

## Maintenance Notes

Use `mix precommit` as the final verification step for code changes. If you change the domain model, routes, or deployment assumptions, update this README at the same time so it stays aligned with the application.
