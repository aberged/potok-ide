defmodule PotokIdeWeb.HelpGuides do
  @moduledoc """
  The help's pages on how Potok works inside, each with its diagrams:

    * `/pomoc/procesi-i-aplikacije`: who talks to whom between an app, a group
      and the processes (`page_html/help_processes_apps.html.heex`);
    * `/pomoc/arhitektura-aplikacije`: how an app is built, the path of one
      write and the whole app API (`page_html/help_app_architecture.html.heex`);
    * `/pomoc/prava-pristupa`: what a profile may do in a group and how that is
      worked out, with a calculator (`page_html/help_access.html.heex`).

  They describe the code, so a change to it can make them wrong. What can be
  read from the code is read from it here: the limits (`facts/0`), the steps
  of a process (`step_names/0`) and what the calculator shows (`calc/0`,
  worked out by `PotokIde.Social.Access` itself). The app API is listed by
  hand (`api/0`) and a test holds it against `potok_app_sdk.js`. The arrows
  and sentences of the diagrams no test sees: `watch` of each page names the
  code they were drawn from, and `mix potok.sync_reminder` names the page
  when that code changes and the page does not. See "Landing page, domain map
  and help" in `AGENTS.md`.

  The words are in the `help_guides` Gettext domain, Serbian being the
  reference. Code in a text is marked as `` `name` ``, a link as
  `<a1>label</a1>` and a term as `<b>label</b>` (`parts/1`). A name from the
  code that stands in a label of a diagram comes in as a binding, so the
  Cyrillic text keeps it in Latin; a new technical word goes in `@kept` of
  `mix potok.sr_cyrl`.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  alias PotokIde.Processes.{Engine, Types}
  alias PotokIde.RateLimit

  alias PotokIde.Social.{
    Access,
    AppData,
    AppProfileStore,
    Group,
    GroupManifest,
    GroupRole,
    Profile
  }

  alias PotokIdeWeb.GroupLive.Show.{AppApi, ProcessEditor, RolesTab}

  @slugs ~w(procesi-i-aplikacije arhitektura-aplikacije prava-pristupa)

  @doc "The pages' addresses under `/pomoc`, the same in every language."
  def slugs, do: @slugs

  @doc "Every page, in the order they are read."
  def guides, do: Enum.map(@slugs, &guide!/1)

  @doc "A page by its address."
  def guide(slug) when slug in @slugs, do: {:ok, guide!(slug)}
  def guide(_slug), do: :error

  defp guide!("procesi-i-aplikacije") do
    %{
      slug: "procesi-i-aplikacije",
      id: "guide-processes",
      template: :help_processes_apps,
      title: dgettext("help_guides", "Potok, processes and apps"),
      lead:
        dgettext(
          "help_guides",
          "A group in Potok keeps data and rules. An app and a process work on the same group, but do not see each other. An app asks Potok through the API, a process writes into the group as its member, and both times Potok checks the permissions."
        ),
      sources: ~w(
        lib/potok_ide/processes/engine.ex
        lib/potok_ide/processes/triggers.ex
        lib/potok_ide/processes/reach.ex
        lib/potok_ide/social/app_processes.ex
        lib/potok_ide_web/live/group_live/show/app_api.ex
        assets/js/potok_app_sdk.js
      ),
      watch: ~w(
        lib/potok_ide/processes/
        lib/potok_ide/social/app_processes.ex
        lib/potok_ide_web/live/group_live/show/app_api.ex
        assets/js/potok_app_sdk.js
      )
    }
  end

  defp guide!("arhitektura-aplikacije") do
    %{
      slug: "arhitektura-aplikacije",
      id: "guide-architecture",
      template: :help_app_architecture,
      title: dgettext("help_guides", "The architecture of a Potok app"),
      lead:
        dgettext(
          "help_guides",
          "A Potok app is one HTML file in a group's description. It runs in a frame that does not see Potok's page, and asks for all it needs by messages that the server checks before it writes anything. The example is Mleko (`potok-mleko`), an app with which neighbors order milk and cheese together from one producer."
        ),
      sources: ~w(
        assets/js/potok_app_sdk.js
        assets/js/app.js
        lib/potok_ide_web/live/group_live/show/components.ex
        lib/potok_ide_web/live/group_live/show/app_api.ex
        lib/potok_ide_web/live/group_live/show/app_values.ex
        lib/potok_ide/social/app_data.ex
        lib/potok_ide/social/value_rules.ex
      ),
      watch: ~w(
        assets/js/potok_app_sdk.js
        assets/js/app.js
        lib/potok_ide_web/live/group_live/show/components.ex
        lib/potok_ide_web/live/group_live/show/app_api.ex
        lib/potok_ide_web/live/group_live/show/app_values.ex
        lib/potok_ide/social/app_data.ex
        lib/potok_ide/social/value_rules.ex
      )
    }
  end

  defp guide!("prava-pristupa") do
    %{
      slug: "prava-pristupa",
      id: "guide-access",
      template: :help_access,
      title: dgettext("help_guides", "Access rights in Potok"),
      lead:
        dgettext(
          "help_guides",
          "What a profile may do in a group depends on three things: the manifest the group uses, whether the profile is its member, and the roles the group assigned to it. The manifest says what each role allows or denies, and the group says who holds which role."
        ),
      # `social.ex` and `group.ex` change with every feature, so the reminder
      # leaves them out: the rules of who changes what are on the reader.
      sources: ~w(
        lib/potok_ide/social/access.ex
        lib/potok_ide/social/group_role.ex
        lib/potok_ide/social/group_manifest.ex
        lib/potok_ide/social/group_member_role.ex
        lib/potok_ide/social/member_inheritance.ex
        lib/potok_ide/social/access_overview.ex
        lib/potok_ide/social/access_history.ex
        lib/potok_ide/social/group_access_change.ex
        lib/potok_ide_web/live/group_live/show/access_catalog.ex
        lib/potok_ide_web/live/group_live/show/access_preview.ex
        lib/potok_ide/social/group.ex
        lib/potok_ide/social.ex
      ),
      watch: ~w(
        lib/potok_ide/social/access.ex
        lib/potok_ide/social/group_role.ex
        lib/potok_ide/social/group_manifest.ex
        lib/potok_ide/social/group_member_role.ex
        lib/potok_ide/social/member_inheritance.ex
        lib/potok_ide/social/access_overview.ex
        lib/potok_ide/social/access_history.ex
        lib/potok_ide/social/group_access_change.ex
        lib/potok_ide_web/live/group_live/show/access_catalog.ex
        lib/potok_ide_web/live/group_live/show/access_preview.ex
      )
    }
  end

  @doc "A text without its marks, for a card or a page's description."
  def plain(text) do
    text |> parts() |> Enum.map_join(&elem(&1, tuple_size(&1) - 1))
  end

  @markup ~r/`[^`]*`|<a\d+>.*?<\/a\d+>|<b>.*?<\/b>/u

  @doc """
  Splits a text into `{:text, text}`, `{:code, name}`, `{:link, name, label}`
  and `{:strong, label}`.
  """
  def parts(text) do
    @markup
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.map(&part/1)
  end

  defp part("`" <> rest), do: {:code, String.trim_trailing(rest, "`")}

  defp part("<b>" <> rest), do: {:strong, String.trim_trailing(rest, "</b>")}

  defp part("<a" <> _rest = text) do
    case Regex.run(~r/^<(a\d+)>(.*)<\/\1>$/u, text) do
      [_, name, label] -> {:link, name, label}
      nil -> {:text, text}
    end
  end

  defp part(text), do: {:text, text}

  # ---------------------------------------------------------------------
  # What the pages read from the code
  # ---------------------------------------------------------------------

  # What an app keeps of its `localStorage` in Potok's page, in KB: it is
  # `APP_FRAME_STORAGE_MAX_CHARS` in `app.js`, which a test holds this against.
  @storage_kb 256

  @doc "The numbers the pages give, each from where the code keeps it."
  def facts do
    {heavy_reads, _window} = RateLimit.limit(:app_heavy_read)
    {process_writes, _window} = RateLimit.limit(:process_step)

    %{
      max_run: Engine.max_run(),
      max_steps: number(Engine.max_steps()),
      max_depth: Engine.max_depth(),
      max_items: Types.max_items(),
      process_writes: process_writes,
      write_burst: AppApi.write_burst(),
      write_window_s: div(AppApi.write_window_ms(), 1000),
      value_kb: div(AppData.max_value_bytes(), 1024),
      config_kb: div(AppData.max_config_bytes(), 1024),
      outsider_values: AppData.outsider_values_per_minute(),
      children: AppApi.max_children_per_call(),
      heavy_reads: heavy_reads,
      storage_kb: @storage_kb,
      personal_keys: AppProfileStore.max_keys(),
      personal_kb: div(AppProfileStore.max_value_bytes(), 1024),
      manifest_minutes: div(Access.manifest_ttl(), :timer.minutes(1)),
      facts_seconds: div(Access.facts_ttl(), :timer.seconds(1)),
      permissions: length(GroupRole.permissions())
    }
  end

  # Thousands as the language writes them: 5.000 in Serbian, 5,000 in English.
  defp number(number) do
    separator = if Gettext.get_locale(PotokIdeWeb.Gettext) == "en", do: ",", else: "."

    number
    |> Integer.to_string()
    |> String.replace(~r/\B(?=(\d{3})+$)/, separator)
  end

  @doc "The names of the steps a process is drawn from, as its editor offers them."
  def step_names do
    for {_kind, _icon, name, _text, _class} <- ProcessEditor.insert_kinds(), do: name
  end

  # The app API by families: each method of `window.potok` with the method it
  # calls on the page (`nil` for one that only listens). A test holds the
  # list against `potok_app_sdk.js`, so a method added there has to be placed
  # here. `@example_uses` is what the example app, `potok-mleko`, calls: that
  # lives in its own repository, where no test of this one reaches.
  @api [
    values: [
      {"insertValue", "insert_value"},
      {"listValues", "list_values"},
      {"updateValue", "update_value"},
      {"deleteValue", "delete_value"},
      {"deleteValues", "delete_values"},
      {"aggregateValues", "aggregate_values"},
      {"summarizeValues", "summarize_values"},
      {"gradeValue", "grade_value"},
      {"onValues", nil},
      {"onNewValue", nil}
    ],
    settings: [
      {"getConfig", "get_config"},
      {"saveConfig", "save_config"},
      {"listRoles", "list_roles"},
      {"getCurrentProfile", "current_profile"},
      {"getGroup", "get_group"},
      {"setNotifications", "set_notifications"}
    ],
    groups: [
      {"listSubgroups", "list_subgroups"},
      {"listChildren", "list_children"},
      {"getChild", "get_child"},
      {"createChild", "create_child"},
      {"createChildren", "create_children"},
      {"updateChild", "update_child"},
      {"withdrawChild", "withdraw_child"},
      {"previewDescription", "preview_description"},
      {"listTemplates", "list_templates"},
      {"renderTemplate", "render_template"},
      {"openGroup", "open_group"},
      {"showGroup", "show_group"},
      {"onGroupSheetClose", nil},
      {"onSubgroupsChange", nil}
    ],
    map: [
      {"getMapConfig", "map_config"},
      {"listPlaces", "list_places"},
      {"listPlacesAt", "list_places_at"},
      {"placeShapes", "place_shapes"},
      {"createPlace", "create_place"},
      {"openMap", "open_map"}
    ],
    processes: [
      {"listProcesses", "list_processes"},
      {"completeTask", "complete_task"},
      {"retryProcess", "retry_process"},
      {"cancelProcess", "cancel_process"},
      {"listWaiting", "list_waiting"},
      {"openProcessForm", "open_process_form"},
      {"listStartable", "list_startable"},
      {"openProcessStart", "open_process_start"},
      {"onWaiting", nil}
    ],
    polls: [
      {"listPolls", "list_polls"},
      {"getPoll", "get_poll"},
      {"openPoll", "open_poll"},
      {"openPollForm", "open_poll_form"},
      {"onPollChange", nil}
    ],
    sharing: [
      {"toggleGroupReaction", "toggle_group_reaction"},
      {"pickEmoji", "pick_emoji"},
      {"shareGroup", "share_group"},
      {"linkGroup", "link_group"},
      {"getLinkedGroup", "linked_group"}
    ],
    personal: [
      {"listPersonal", "list_personal"},
      {"getPersonal", "get_personal"},
      {"setPersonal", "set_personal"},
      {"deletePersonal", "delete_personal"}
    ],
    files: [
      {"uploadFile", "upload_file"},
      {"uploadImage", "upload_image"},
      {"uploadMedia", "upload_media"},
      {"ensureFileGroups", "ensure_file_groups"},
      {"fileUrl", "file_url"},
      {"getDescription", "get_description"},
      {"updateDescription", "update_description"},
      {"openLogin", "open_login"}
    ]
  ]

  @example_uses ~w(
    insertValue listValues updateValue deleteValue onValues getConfig saveConfig
    listRoles getGroup setNotifications openMap
  )

  @doc """
  The app API by families: `%{id, title, methods}`, each method with its
  `name`, the `call` it makes, and whether the example `uses?` it and a
  `guest?` of a public group may make it (the personal memory a guest's frame
  keeps in the browser).
  """
  def api do
    guest = AppApi.guest_methods() ++ AppApi.local_guest_methods()

    for {id, methods} <- @api do
      %{
        id: id,
        title: family_title(id),
        methods:
          for {name, call} <- methods do
            %{name: name, call: call, uses?: name in @example_uses, guest?: call in guest}
          end
      }
    end
  end

  defp family_title(:values), do: dgettext("help_guides", "Data in collections")
  defp family_title(:settings), do: dgettext("help_guides", "Settings and people")
  defp family_title(:groups), do: dgettext("help_guides", "Groups below")
  defp family_title(:map), do: dgettext("help_guides", "Map")
  defp family_title(:processes), do: dgettext("help_guides", "Processes")
  defp family_title(:polls), do: dgettext("help_guides", "Polls")
  defp family_title(:sharing), do: dgettext("help_guides", "Reactions, sharing, link")
  defp family_title(:personal), do: dgettext("help_guides", "Personal memory")
  defp family_title(:files), do: dgettext("help_guides", "Files, description, sign-in")

  @doc "The limits the server keeps on an app: `%{id, mark, text}`, the mark being the number."
  def limits do
    facts = facts()

    [
      %{
        id: "writes",
        mark: "#{facts.write_burst} / #{facts.write_window_s} s",
        text:
          dgettext(
            "help_guides",
            "Writes in a row per open page, and then the tokens fill up again in %{seconds} s.",
            seconds: facts.write_window_s
          )
      },
      %{
        id: "sizes",
        mark: "#{facts.value_kb} KB · #{facts.config_kb} KB",
        text:
          dgettext(
            "help_guides",
            "The most one value in a collection holds, and an app's settings."
          )
      },
      %{
        id: "outsiders",
        mark: "#{facts.outsider_values} / min",
        text:
          dgettext(
            "help_guides",
            "Values of a profile that is not a member of a public group, where a rule lets it write, in one group across all its apps."
          )
      },
      %{
        id: "storage",
        mark: "#{facts.storage_kb} KB",
        text:
          dgettext(
            "help_guides",
            "An app's `localStorage`, a copy in Potok's page, apart for every app."
          )
      },
      %{
        id: "personal",
        mark: "#{facts.personal_keys} · #{facts.personal_kb} KB",
        text:
          dgettext(
            "help_guides",
            "Keys an app keeps in its personal memory for one person, and the most one holds. Only that person reads them; a guest's stay in the browser."
          )
      },
      %{
        id: "children",
        mark: "#{facts.children}",
        text:
          dgettext(
            "help_guides",
            "Groups by one `createChildren`, all or none, for one token."
          )
      },
      %{
        id: "heavy",
        mark: "#{facts.heavy_reads} / min",
        text:
          dgettext(
            "help_guides",
            "`summarizeValues` and `aggregateValues` read all of an app's values, so they are limited per viewer, together with `listWaiting`, `placeShapes` and `listPlaces`."
          )
      },
      %{
        id: "stale",
        mark: "stale_app",
        text:
          dgettext(
            "help_guides",
            "The answer to a call from an app the viewer has closed in the meantime."
          )
      }
    ]
  end

  # ---------------------------------------------------------------------
  # The calculator of access rights
  # ---------------------------------------------------------------------

  # The manifest of the example, M1: two roles of its own beside the built-in
  # ones. "everyone" holds what it holds by default.
  @council "savet"
  @tenant "podstanar"

  @council_allows ~w(
    invite_members manage_join_requests remove_members delete_values manage_events
    publish_events manage_polls send_notices manage_tags
  )a

  @tenant_denies ~w(create_subgroups invite_members create_polls)a

  @presets [
    %{key: "ana", account: true, member: true, held: ["admin"]},
    %{key: "marko", account: true, member: true, held: [@council]},
    %{key: "jelena", account: true, member: true, held: []},
    %{key: "petar", account: true, member: true, held: [@tenant]},
    %{key: "vesna", account: true, member: true, held: [@council, @tenant]},
    %{key: "neighbor", account: true, member: false, held: []},
    %{key: "guest", account: false, member: false, held: []}
  ]

  # What a field of the table says of a permission, in the order a click goes
  # through them. "everyone" has only the first two: it cannot deny.
  @cells ~w(none allow deny)

  @doc """
  All the calculator needs, for `data-calc`: the permissions and roles by
  their names in the app, the example's manifest and profiles, the texts, and
  `outcomes`, which `PotokIde.Social.Access` worked out for every case:

    * `outcomes.member[permission]` is a string of 0 and 1, one for every set
      of roles a member holds and every state of the three fields of that
      permission, at `member_index/4`;
    * `outcomes.outsider` has three marks (reacts to the group, reads the
      chat, writes in the chat) for every case of a profile that is not a
      member, at `outsider_index/5`.

  The script only looks the outcome up, so it cannot say other than the app does.
  """
  def calc do
    roles = [admin_role(), council_role(), tenant_role(), everyone_role()]

    %{
      permissions:
        for permission <- GroupRole.permissions() do
          %{key: permission, label: RolesTab.permission_label(permission)}
        end,
      roles:
        for role <- roles do
          %{
            key: role.key,
            name: RolesTab.role_label(role),
            allowed: role.allowed,
            denied: role.denied,
            locked: role.key == GroupRole.admin_key(),
            allow_only: role.key == GroupRole.everyone_key()
          }
        end,
      presets: Enum.map(@presets, &Map.put(&1, :label, preset_label(&1.key))),
      start: "marko",
      outcomes: %{member: member_outcomes(), outsider: outsider_outcomes()},
      texts: calc_texts()
    }
  end

  defp admin_role, do: %GroupRole{key: GroupRole.admin_key(), allowed: GroupRole.permissions()}

  defp council_role do
    %GroupRole{
      key: @council,
      name: dgettext("help_guides", "House council"),
      allowed: @council_allows
    }
  end

  defp tenant_role do
    %GroupRole{key: @tenant, name: dgettext("help_guides", "Tenant"), denied: @tenant_denies}
  end

  defp everyone_role do
    %GroupRole{key: GroupRole.everyone_key(), allowed: GroupRole.default_everyone_permissions()}
  end

  @doc "Where `outcomes.member` keeps a case: the roles held and the three fields' states."
  def member_index(held, council, tenant, everyone) do
    roles =
      Enum.sum(
        for {key, bit} <- [{GroupRole.admin_key(), 4}, {@council, 2}, {@tenant, 1}],
            key in held,
            do: bit
      )

    ((roles * 3 + cell(council)) * 3 + cell(tenant)) * 2 + cell(everyone)
  end

  defp cell(state), do: Enum.find_index(@cells, &(&1 == state))

  defp member_outcomes do
    Map.new(GroupRole.permissions(), fn permission ->
      marks =
        for admin? <- [false, true],
            council? <- [false, true],
            tenant? <- [false, true],
            council <- @cells,
            tenant <- @cells,
            everyone <- ~w(none allow) do
          held =
            if(admin?, do: [GroupRole.admin_key()], else: []) ++
              if(council?, do: [@council], else: []) ++ if(tenant?, do: [@tenant], else: [])

          manifest = %GroupManifest{
            roles: [
              %GroupRole{key: GroupRole.admin_key()},
              field(@council, permission, council),
              field(@tenant, permission, tenant),
              field(GroupRole.everyone_key(), permission, everyone)
            ]
          }

          manifest |> Access.from_facts({:member, held}) |> Access.can?(permission) |> mark()
        end

      {permission, Enum.join(marks)}
    end)
  end

  defp field(key, permission, "allow"), do: %GroupRole{key: key, allowed: [permission]}
  defp field(key, permission, "deny"), do: %GroupRole{key: key, denied: [permission]}
  defp field(key, _permission, "none"), do: %GroupRole{key: key}

  @doc "Where `outcomes.outsider` keeps a case, three marks from there on."
  def outsider_index(public?, open_chat?, blocked?, react?, post?) do
    3 *
      Enum.reduce([public?, open_chat?, blocked?, react?, post?], 0, fn on?, index ->
        index * 2 + if(on?, do: 1, else: 0)
      end)
  end

  defp outsider_outcomes do
    marks =
      for public? <- [false, true],
          open_chat? <- [false, true],
          blocked? <- [false, true],
          react? <- [false, true],
          post? <- [false, true] do
        group = %Group{
          is_public: public?,
          has_public_chat: open_chat?,
          is_root: false,
          is_direct: false
        }

        allowed = if(react?, do: [:react], else: []) ++ if(post?, do: [:post_values], else: [])

        manifest = %GroupManifest{
          roles: [%GroupRole{key: GroupRole.everyone_key(), allowed: allowed}]
        }

        # A block counts only where a profile that is not a member can do
        # anything: in a public group, as `Access` reads it.
        access = Access.from_facts(manifest, {:outsider, public? and blocked?})
        someone = %Profile{}

        [
          Access.can_react_to_group?(someone, access, group),
          Access.can_read_chat?(access, group),
          Access.can_post_in_chat?(someone, access, group)
        ]
        |> Enum.map_join(&mark/1)
      end

    Enum.join(marks)
  end

  defp mark(true), do: "1"
  defp mark(false), do: "0"

  defp preset_label("ana"), do: dgettext("help_guides", "Ana · Admin")
  defp preset_label("marko"), do: dgettext("help_guides", "Marko · House council")
  defp preset_label("jelena"), do: dgettext("help_guides", "Jelena · only Everyone")
  defp preset_label("petar"), do: dgettext("help_guides", "Petar · Tenant")
  defp preset_label("vesna"), do: dgettext("help_guides", "Vesna · council and tenant")
  defp preset_label("neighbor"), do: dgettext("help_guides", "A neighbor · not a member")
  defp preset_label("guest"), do: dgettext("help_guides", "A guest with no account")

  # What the script writes around the outcomes. It puts the names of roles
  # after "allowed by", "denied by" and "a denial beats the allowance".
  defp calc_texts do
    %{
      cell: %{
        allow: dgettext("help_guides", "allows"),
        deny: dgettext("help_guides", "denies"),
        none: dgettext("help_guides", "says nothing"),
        locked: dgettext("help_guides", "always has")
      },
      cell_locked: dgettext("help_guides", "(does not change)"),
      cell_allow_only: dgettext("help_guides", "(Everyone cannot deny)"),
      has: dgettext("help_guides", "has it"),
      has_not: dgettext("help_guides", "does not have it"),
      why: %{
        guest: dgettext("help_guides", "a guest has no profile, and so no permissions"),
        outsider: dgettext("help_guides", "not a member, so holds no role"),
        admin: dgettext("help_guides", "Admin holds every permission"),
        allowed: dgettext("help_guides", "allowed by"),
        denied: dgettext("help_guides", "denied by"),
        denied_over: dgettext("help_guides", "a denial beats the allowance"),
        none: dgettext("help_guides", "none of their roles allows it")
      },
      extra: %{
        react: dgettext("help_guides", "Reacts to the group"),
        read: dgettext("help_guides", "Reads the chat"),
        write: dgettext("help_guides", "Writes in the chat")
      },
      extra_why: %{
        guest_react: dgettext("help_guides", "only a signed-in profile reacts"),
        guest_read: dgettext("help_guides", "the chat is behind the sign-in"),
        guest_write: dgettext("help_guides", "only a signed-in profile writes"),
        not_public: dgettext("help_guides", "the group is not public"),
        blocked: dgettext("help_guides", "they are blocked"),
        react_yes: dgettext("help_guides", "a public group, and Everyone may react"),
        react_no: dgettext("help_guides", "Everyone may not react"),
        read_yes: dgettext("help_guides", "the chat is open; a block does not stop reading"),
        not_open: dgettext("help_guides", "the chat is not open"),
        write_yes: dgettext("help_guides", "an open chat, and Everyone may write"),
        write_no: dgettext("help_guides", "Everyone may not write"),
        member_react:
          dgettext("help_guides", "a member: by the permission %{permission}",
            permission: RolesTab.permission_label(:react)
          ),
        member_read: dgettext("help_guides", "a member reads the chat of their group"),
        member_write:
          dgettext("help_guides", "a member: by the permission %{permission}",
            permission: RolesTab.permission_label(:post_values)
          )
      },
      summary: %{
        custom: dgettext("help_guides", "A profile you set"),
        guest: dgettext("help_guides", "a guest, with no profile"),
        outsider: dgettext("help_guides", "not a member: holds no role"),
        roles: dgettext("help_guides", "roles:"),
        of:
          dgettext("help_guides", "of %{count} permissions",
            count: length(GroupRole.permissions())
          )
      }
    }
  end
end
