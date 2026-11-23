defmodule PotokIdeWeb.GroupLive.Show.AccessTab do
  @moduledoc """
  The access overview of a group: who may do what in it, and why. Every
  member sees it whole, as the rules of power belong to those they rule;
  someone outside a public group sees only what they may do there and how one
  comes in, with no names.

  Verdicts come from `AccessCatalog`, which asks the page's own rules; what it
  counts and lists comes from `PotokIde.Social.AccessOverview`, rules and
  never content.
  """

  use PotokIdeWeb, :html

  alias PotokIde.Processes.Graph
  alias PotokIde.Social.{Access, AccessHistory, Group, GroupAccessChange, GroupRole}
  alias PotokIdeWeb.GroupLive.Show.{AccessCatalog, Components, RequestRules, RolesTab}

  attr :group, :map, required: true
  attr :access, Access, required: true, doc: "the viewer's own access"
  attr :current_profile, :map, required: true

  attr :overview, :map,
    default: nil,
    doc: "`%{facts, data}`: `PageRules.facts/1` with `notices?`, and `AccessOverview.load/3`"

  attr :view, :any, default: :self, doc: "`:self`, or the spec the viewer looks as"

  def panel(assigns) do
    manifest = assigns.access.manifest
    real = AccessCatalog.real_viewer(assigns.access, assigns.current_profile)
    member? = assigns.access.member?
    view = if member?, do: assigns.view, else: :self
    spec = if view == :self, do: AccessCatalog.spec_of(real), else: view
    viewer = if view == :self, do: real, else: AccessCatalog.viewer(manifest, spec)
    facts = assigns.overview && assigns.overview.facts
    data = assigns.overview && assigns.overview.data

    assigns =
      assigns
      |> assign(:manifest, manifest)
      |> assign(:member?, member?)
      |> assign(:spec, spec)
      |> assign(:self?, view == :self)
      |> assign(:viewer, viewer)
      |> assign(:facts, facts)
      |> assign(:data, data)
      |> assign(:presets, presets(assigns.group))
      |> assign(:picked_keys, picked_keys(spec))
      |> assign(
        :pickable_roles,
        Enum.reject(manifest.roles, &(&1.key == GroupRole.everyone_key()))
      )
      |> assign(:rows, facts && AccessCatalog.rows(viewer, assigns.group, facts))
      |> assign(:sees, facts && data && AccessCatalog.sees(viewer, assigns.group, facts, data))
      |> assign(:columns, AccessCatalog.columns(manifest, assigns.group))
      |> assign(:statute, AccessCatalog.statute(manifest, assigns.group))
      |> assign(:own_manifest?, Access.own_manifest?(assigns.group, manifest))

    ~H"""
    <div id="group-panel-access" class="card flex min-h-0 flex-1 flex-col px-2">
      <Components.tab_body>
        <.page_header id="group-access-header" icon="hero-eye">
          {gettext("Access overview")}
          <:subtitle>
            {if @member?,
              do:
                gettext(
                  "Who may do what in this group, and why. The rules are the same for everyone, so every member sees them."
                ),
              else: gettext("What you may do in this group, and how one becomes a member.")}
          </:subtitle>
        </.page_header>

        <div
          :if={is_nil(@facts)}
          id="access-loading"
          class="py-10 text-center text-sm text-base-content/60"
        >
          {gettext("Loading…")}
        </div>

        <%= if @facts do %>
          <section
            :if={@member?}
            id="access-view"
            class="mb-5 rounded-3xl border border-base-300/70 bg-base-100/70 p-4 shadow-sm"
          >
            <h3 class="text-sm font-semibold">{gettext("See it as")}</h3>
            <p class="mt-0.5 text-xs text-base-content/65">
              {gettext(
                "Pick roles, one or more, or someone outside the group. A role that denies takes the permission away even from one who holds another role that allows it."
              )}
            </p>
            <div
              id="access-view-presets"
              role="group"
              aria-label={gettext("Who to see it as")}
              class="mt-3 flex flex-wrap gap-1.5"
            >
              <button
                :for={preset <- @presets}
                type="button"
                id={"access-view-preset-#{preset.key}"}
                phx-click="access_view_preset"
                phx-value-preset={preset.key}
                aria-pressed={to_string(preset_on?(preset, @self?, @spec))}
                class={[
                  "inline-flex h-8 items-center gap-1.5 rounded-full border px-3 text-xs font-semibold transition duration-150 ease-out hover:-translate-y-px active:scale-95",
                  if(preset_on?(preset, @self?, @spec),
                    do: "border-primary/60 bg-primary/10 text-primary",
                    else: "border-base-300 bg-base-100 text-base-content/70 hover:text-base-content"
                  )
                ]}
              >
                <.icon name={preset.icon} class="size-3.5" />
                {preset.label}
              </button>
            </div>
            <form
              id="access-view-roles-form"
              phx-change="access_view_roles"
              class="mt-3 flex flex-wrap gap-1.5"
            >
              <input type="hidden" name="roles[]" value="" />
              <label
                :for={role <- @pickable_roles}
                id={"access-view-role-#{role.key}"}
                class={[
                  "inline-flex h-8 cursor-pointer items-center gap-1.5 rounded-full border px-3 text-xs font-semibold transition duration-150 ease-out has-focus-visible:ring-2 has-focus-visible:ring-primary/40",
                  if(role.key in @picked_keys,
                    do: "border-primary/60 bg-primary text-primary-content",
                    else: "border-base-300 bg-base-100 text-base-content/70 hover:text-base-content"
                  )
                ]}
              >
                <input
                  type="checkbox"
                  name="roles[]"
                  value={role.key}
                  checked={role.key in @picked_keys}
                  class="sr-only"
                />
                <.icon name={RolesTab.role_icon(role)} class="size-3.5" />
                {RolesTab.role_label(role)}
              </label>
            </form>
          </section>

          <section id="access-rows" class="mb-5">
            <div class="mb-2 flex flex-wrap items-baseline justify-between gap-2 px-1">
              <h3 id="access-view-label" class="text-sm font-semibold">
                {if @self?,
                  do: gettext("You"),
                  else: AccessCatalog.spec_label(@spec, @manifest)}
              </h3>
              <p id="access-view-count" class="text-xs text-base-content/60">
                {gettext("%{yes} of %{all} things",
                  yes: count_yes(@rows),
                  all: length(AccessCatalog.capabilities())
                )}
              </p>
            </div>
            <div class="grid gap-3 lg:grid-cols-2">
              <div
                :for={{area, items} <- @rows}
                id={"access-area-#{area}"}
                class="rounded-3xl border border-base-300/70 bg-base-100/70 p-3 shadow-sm"
              >
                <h4 class="mb-1 px-1 text-xs font-semibold uppercase tracking-wide text-base-content/55">
                  {AccessCatalog.area_label(area)}
                </h4>
                <ul class="divide-y divide-base-300/50">
                  <li
                    :for={item <- items}
                    id={"access-row-#{item.key}"}
                    data-ok={to_string(item.ok)}
                    class="flex items-start gap-2.5 px-1 py-2"
                  >
                    <.verdict_icon ok={item.ok} />
                    <div class="min-w-0">
                      <p class={[
                        "text-sm",
                        if(item.ok, do: "font-medium", else: "text-base-content/60")
                      ]}>
                        {AccessCatalog.label(item.key)}
                      </p>
                      <p class="text-xs text-base-content/55">
                        {AccessCatalog.reason_text(item.reason, @manifest)}
                      </p>
                    </div>
                  </li>
                </ul>
              </div>
            </div>
          </section>

          <section
            :if={@sees}
            id="access-sees"
            class="mb-5 rounded-3xl border border-base-300/70 bg-base-100/70 p-4 shadow-sm"
          >
            <h3 class="text-sm font-semibold">{gettext("What they would see")}</h3>
            <dl class="mt-2 grid gap-x-4 gap-y-2 text-sm sm:grid-cols-[minmax(0,12rem)_1fr]">
              <dt class="text-base-content/60">{gettext("Sections")}</dt>
              <dd id="access-sees-sections">
                <%= if @sees.sections == [] do %>
                  <span class="text-base-content/60">
                    {gettext("Only the group's card and description")}
                  </span>
                <% else %>
                  {Enum.map_join(@sees.sections, ", ", & &1.label)}
                <% end %>
              </dd>
              <%= if @data.alts != [] do %>
                <dt class="text-base-content/60">{gettext("Other descriptions")}</dt>
                <dd id="access-sees-alts">
                  {if @sees.alts == [],
                    do: gettext("none"),
                    else: Enum.map_join(@sees.alts, ", ", & &1.name)}
                </dd>
              <% end %>
              <%= if @data.children.entries != [] do %>
                <dt class="text-base-content/60">{gettext("A member of the sub-groups")}</dt>
                <dd id="access-sees-children">
                  {if @sees.children == [],
                    do: gettext("none of those listed below"),
                    else: Enum.map_join(@sees.children, ", ", & &1.name)}
                </dd>
              <% end %>
              <%= if @sees.polls != [] do %>
                <dt class="text-base-content/60">{gettext("Open polls")}</dt>
                <dd id="access-sees-polls">
                  {gettext("votes in %{vote} of %{all}, sees the results of %{results}",
                    vote: Enum.count(@sees.polls, & &1.vote),
                    all: length(@sees.polls),
                    results: Enum.count(@sees.polls, & &1.results)
                  )}
                </dd>
              <% end %>
              <%= if @sees.collections != [] do %>
                <dt class="text-base-content/60">{gettext("App data")}</dt>
                <dd id="access-sees-collections">
                  {gettext("writes to %{write} of %{all} collections, reads all of %{read}",
                    write: Enum.count(@sees.collections, & &1.write),
                    all: length(@sees.collections),
                    read: Enum.count(@sees.collections, & &1.read_all)
                  )}
                </dd>
              <% end %>
              <%= if @sees.waiting > 0 do %>
                <dt class="text-base-content/60">{gettext("Waiting for them")}</dt>
                <dd id="access-sees-waiting">
                  {ngettext(
                    "%{count} run of a process",
                    "%{count} runs of processes",
                    @sees.waiting
                  )}
                </dd>
              <% end %>
            </dl>
          </section>

          <section
            :if={@member?}
            id="access-table-section"
            class="mb-5 rounded-3xl border border-base-300/70 bg-base-100/70 p-4 shadow-sm"
          >
            <h3 class="text-sm font-semibold">{gettext("All roles side by side")}</h3>
            <p class="mt-0.5 text-xs text-base-content/65">
              {gettext(
                "Each role as if a member held only it, besides Everyone, which every member holds."
              )}
            </p>
            <div class="mt-3 overflow-x-auto">
              <table
                id="access-table"
                class="w-full min-w-max border-separate border-spacing-0 text-sm"
              >
                <thead>
                  <tr>
                    <th
                      scope="col"
                      class="sticky left-0 z-10 bg-base-100 py-2 pr-3 text-left text-xs font-semibold text-base-content/60"
                    >
                      {gettext("What")}
                    </th>
                    <th
                      :for={column <- @columns}
                      scope="col"
                      id={"access-col-#{column.key}"}
                      class="px-2 py-2 text-center text-xs font-semibold"
                    >
                      {column.label}
                    </th>
                  </tr>
                </thead>
                <%= for {area, items} <- AccessCatalog.table(@columns, @manifest, @group, @facts) do %>
                  <tbody>
                    <tr>
                      <th
                        colspan={length(@columns) + 1}
                        scope="colgroup"
                        class="sticky left-0 bg-base-100 pt-3 pb-1 text-left text-[11px] font-semibold uppercase tracking-wide text-base-content/50"
                      >
                        {AccessCatalog.area_label(area)}
                      </th>
                    </tr>
                    <tr :for={item <- items} class="hover:bg-base-200/40">
                      <th
                        scope="row"
                        class="sticky left-0 z-10 max-w-56 bg-base-100 py-1.5 pr-3 text-left font-normal"
                      >
                        {AccessCatalog.label(item.key)}
                      </th>
                      <td
                        :for={{column, {ok, reason}} <- Enum.zip(@columns, item.cells)}
                        id={"access-cell-#{item.key}-#{column.key}"}
                        data-ok={to_string(ok)}
                        title={AccessCatalog.reason_text(reason, @manifest)}
                        class="px-2 py-1.5 text-center"
                      >
                        <.verdict_icon ok={ok} label={AccessCatalog.reason_text(reason, @manifest)} />
                      </td>
                    </tr>
                  </tbody>
                <% end %>
              </table>
            </div>
          </section>

          <section
            :if={@data}
            id="access-power"
            class="mb-5 rounded-3xl border border-base-300/70 bg-base-100/70 p-4 shadow-sm"
          >
            <h3 class="text-sm font-semibold">{gettext("Who holds power")}</h3>
            <p class="mt-0.5 text-xs text-base-content/65">
              {gettext(
                "How many people hold the permissions that act on others, and through which roles."
              )}
            </p>
            <ul class="mt-3 grid gap-2 sm:grid-cols-2">
              <li
                :for={item <- AccessCatalog.power(@manifest, @data.role_sets)}
                id={"access-power-#{item.key}"}
                class="rounded-2xl border border-base-300/60 bg-base-100 px-3 py-2"
              >
                <div class="flex items-baseline justify-between gap-2">
                  <span class="text-sm font-medium">{power_label(item.key)}</span>
                  <span class="text-xs text-base-content/60">
                    {ngettext("%{count} person", "%{count} people", item.count)}
                  </span>
                </div>
                <div class="mt-1 flex flex-wrap gap-1">
                  <.link
                    :for={role <- item.roles}
                    id={"access-power-#{item.key}-role-#{role.key}"}
                    patch={~p"/groups/#{@group.id}/members?#{[role: role.key]}"}
                    class="inline-flex h-6 items-center gap-1 rounded-full bg-base-200 px-2 text-[11px] font-semibold text-base-content/75 transition-colors hover:bg-primary/10 hover:text-primary"
                  >
                    <.icon name={RolesTab.role_icon(role)} class="size-3" />
                    {RolesTab.role_label(role)}
                  </.link>
                </div>
              </li>
            </ul>
          </section>

          <section
            id="access-statute"
            class="mb-5 rounded-3xl border border-base-300/70 bg-base-100/70 p-4 shadow-sm"
          >
            <h3 class="text-sm font-semibold">
              {if @member?,
                do: gettext("Roles and how each is had"),
                else: gettext("How one comes in")}
            </h3>
            <p id="access-join-rule" class="mt-1 text-sm text-base-content/75">
              <%= if @group.is_public do %>
                {RequestRules.rule_text(:join, @group.join_mode, @group.join_poll)}
              <% else %>
                {gettext("The group is private: one comes in by an invitation.")}
              <% end %>
            </p>
            <ul class="mt-3 space-y-2">
              <li
                :for={entry <- @statute}
                :if={@member? or entry.mode != :closed}
                id={"access-role-#{entry.role.key}"}
                class="rounded-2xl border border-base-300/60 bg-base-100 px-3 py-2"
              >
                <div class="flex flex-wrap items-center justify-between gap-2">
                  <span class="inline-flex items-center gap-1.5 text-sm font-medium">
                    <.icon name={RolesTab.role_icon(entry.role)} class="size-4 text-base-content/60" />
                    {RolesTab.role_label(entry.role)}
                  </span>
                  <.link
                    :if={@data}
                    id={"access-role-#{entry.role.key}-members"}
                    patch={~p"/groups/#{@group.id}/members?#{[role: entry.role.key]}"}
                    class="text-xs font-semibold text-primary underline-offset-2 hover:underline"
                  >
                    {holders_text(@data.role_origins, entry.role.key)}
                  </.link>
                </div>
                <p class="mt-0.5 text-xs text-base-content/65">
                  <span class="font-semibold">{entry.label}.</span> {entry.text}
                </p>
              </li>
            </ul>
          </section>

          <section
            :if={@data && things?(@data)}
            id="access-things"
            class="mb-5 rounded-3xl border border-base-300/70 bg-base-100/70 p-4 shadow-sm"
          >
            <h3 class="text-sm font-semibold">{gettext("Rules of single things")}</h3>
            <p class="mt-0.5 text-xs text-base-content/65">
              {gettext(
                "Some things narrow or widen who sees them by their own rules. Only those you see are here."
              )}
            </p>
            <ul class="mt-3 space-y-2 text-sm">
              <li :for={alt <- @data.alts} id={"access-thing-alt-#{alt.id}"} class="flex gap-2">
                <.icon name="hero-document-text" class="mt-0.5 size-4 shrink-0 text-base-content/50" />
                <span>
                  <span class="font-medium">{alt.name}</span> — {alt_rule_text(alt, @manifest)}
                </span>
              </li>
              <li :for={poll <- @data.polls} id={"access-thing-poll-#{poll.id}"} class="flex gap-2">
                <.icon name="hero-chart-bar" class="mt-0.5 size-4 shrink-0 text-base-content/50" />
                <span>
                  <.link
                    patch={~p"/groups/#{@group.id}/polls?#{[poll: poll.id]}"}
                    class="font-medium underline-offset-2 hover:underline"
                  >
                    {poll.question}
                  </.link>
                  — {poll_rule_text(poll, @manifest)}
                </span>
              </li>
              <%= for app <- @data.apps, {collection, rule} <- Enum.sort(app.rules) do %>
                <li
                  id={"access-thing-collection-#{app.alt_id || "main"}-#{collection}"}
                  class="flex gap-2"
                >
                  <.icon name="hero-circle-stack" class="mt-0.5 size-4 shrink-0 text-base-content/50" />
                  <span>
                    <span class="font-medium">{collection}</span>
                    — {collection_rule_text(rule, @manifest)}
                  </span>
                </li>
              <% end %>
              <li
                :for={process <- @data.processes}
                id={"access-thing-process-#{process.id}"}
                class="flex gap-2"
              >
                <.icon name="hero-cog-6-tooth" class="mt-0.5 size-4 shrink-0 text-base-content/50" />
                <span>
                  <span class="font-medium">{process.name}</span>
                  — {process_rule_text(process, @manifest)}
                </span>
              </li>
              <li :if={@data.public_events > 0} id="access-thing-public-events" class="flex gap-2">
                <.icon name="hero-calendar-days" class="mt-0.5 size-4 shrink-0 text-base-content/50" />
                <span>
                  {ngettext(
                    "%{count} public event: every signed-in user sees it in their calendar, though the group is private.",
                    "%{count} public events: every signed-in user sees them in their calendar, though the group is private.",
                    @data.public_events
                  )}
                </span>
              </li>
            </ul>
          </section>

          <section
            :if={@data && @data.children.entries != []}
            id="access-children"
            class="mb-5 rounded-3xl border border-base-300/70 bg-base-100/70 p-4 shadow-sm"
          >
            <h3 class="text-sm font-semibold">{gettext("Sub-groups")}</h3>
            <p class="mt-0.5 text-xs text-base-content/65">
              {gettext(
                "Each sub-group has members of its own. An admin of this group does not come into a closed sub-group by that alone."
              )}
            </p>
            <ul class="mt-3 space-y-2">
              <li
                :for={child <- @data.children.entries}
                id={"access-child-#{child.id}"}
                class="flex flex-wrap items-center justify-between gap-2 rounded-2xl border border-base-300/60 bg-base-100 px-3 py-2"
              >
                <.link
                  navigate={~p"/groups/#{child.id}/access"}
                  class="min-w-0 truncate text-sm font-medium underline-offset-2 hover:underline"
                >
                  {child.name}
                </.link>
                <span class="text-xs text-base-content/65">{child_rule_text(child, @manifest)}</span>
              </li>
            </ul>
            <p
              :if={@data.children.total > length(@data.children.entries)}
              id="access-children-more"
              class="mt-2 text-xs text-base-content/60"
            >
              {gettext("And %{count} more, on the Sub-groups tab.",
                count: @data.children.total - length(@data.children.entries)
              )}
            </p>
          </section>

          <section
            :if={@data}
            id="access-history"
            class="mb-5 rounded-3xl border border-base-300/70 bg-base-100/70 p-4 shadow-sm"
          >
            <h3 class="text-sm font-semibold">{gettext("Recent changes")}</h3>
            <p class="mt-0.5 text-xs text-base-content/65">
              {gettext(
                "Who gave or took which role, changed the roles or a setting that lets people in, and when. Kept since the history began."
              )}
            </p>
            <p
              :if={@data.history == []}
              id="access-history-empty"
              class="mt-3 text-sm text-base-content/60"
            >
              {gettext("No change of access yet.")}
            </p>
            <ol :if={@data.history != []} id="access-history-list" class="mt-3 space-y-2">
              <li
                :for={change <- @data.history}
                id={"access-change-#{change.id}"}
                data-kind={change.kind}
                class="flex items-start gap-2.5 text-sm"
              >
                <.icon
                  name={change_icon(change.kind)}
                  class="mt-0.5 size-4 shrink-0 text-base-content/50"
                />
                <div class="min-w-0">
                  <p>{change_text(change, @manifest)}</p>
                  <Components.local_time
                    id={"access-change-#{change.id}-at"}
                    datetime={change.inserted_at}
                    class="text-xs text-base-content/55"
                  />
                </div>
              </li>
            </ol>
            <div
              :if={
                length(@data.history) >= AccessHistory.page_size() and
                  !Map.get(@data, :history_end?, false)
              }
              class="mt-3"
            >
              <.button
                id="access-history-more"
                type="button"
                phx-click="access_history_more"
                size="sm"
              >
                {gettext("Older changes")}
              </.button>
            </div>
            <p
              :if={!@own_manifest?}
              id="access-history-manifest"
              class="mt-3 text-xs text-base-content/60"
            >
              {gettext(
                "The manifest this group uses belongs to a group above it, whose history holds its changes."
              )}
            </p>
          </section>

          <section
            :if={@member?}
            id="access-changes"
            class="mb-5 rounded-3xl border border-base-300/70 bg-base-100/70 p-4 shadow-sm"
          >
            <h3 class="text-sm font-semibold">{gettext("How access changes")}</h3>
            <ul class="mt-2 list-disc space-y-1 pl-5 text-sm text-base-content/80">
              <li id="access-changes-roles">
                {if @group.elects_admins,
                  do:
                    gettext(
                      "An admin gives and takes roles, but Admin itself only a decision of a poll, as the group elects its admins."
                    ),
                  else: gettext("An admin gives and takes roles.")}
              </li>
              <li id="access-changes-manifest">
                {if @own_manifest?,
                  do:
                    gettext(
                      "The group has a manifest of its own, which its admins change, and the groups below that use it follow."
                    ),
                  else:
                    gettext(
                      "The group uses the manifest of a group above it, whose admins change it. An admin here can make it a manifest of its own."
                    )}
              </li>
              <li :if={@group.inherits_members} id="access-changes-inherit">
                {if @group.inherit_role_keys in [nil, []],
                  do: gettext("The parent's members are members here too, with their roles."),
                  else:
                    gettext(
                      "The parent's members who hold %{roles} are members here too, with their roles.",
                      roles: role_names(@group.inherit_role_keys, @manifest)
                    )}
              </li>
              <li id="access-changes-decisions">
                {gettext(
                  "A decision of a poll can give and take a role, when it is put to the whole group."
                )}
              </li>
            </ul>
            <div class="mt-3 flex flex-wrap gap-2">
              <.button
                id="access-go-roles"
                type="button"
                phx-click="switch_tab"
                phx-value-tab="roles"
                variant="soft"
                size="sm"
              >
                <.icon name="hero-shield-check" class="size-4" />
                {gettext("Roles")}
              </.button>
              <.button
                id="access-go-members"
                type="button"
                phx-click="switch_tab"
                phx-value-tab="members"
                variant="soft"
                size="sm"
              >
                <.icon name="hero-user-group" class="size-4" />
                {gettext("Members")}
              </.button>
              <.button
                :if={Access.can?(@access, :edit_group)}
                id="access-go-edit"
                type="button"
                phx-click="switch_tab"
                phx-value-tab="edit_group"
                variant="soft"
                size="sm"
              >
                <.icon name="hero-cog-6-tooth" class="size-4" />
                {gettext("Edit group")}
              </.button>
            </div>
          </section>
        <% end %>
      </Components.tab_body>
    </div>
    """
  end

  attr :ok, :boolean, required: true
  attr :label, :string, default: nil

  defp verdict_icon(assigns) do
    ~H"""
    <span
      class={[
        "inline-flex size-5 shrink-0 items-center justify-center rounded-full",
        if(@ok, do: "bg-success/15 text-success", else: "bg-base-200 text-base-content/40")
      ]}
      role="img"
      aria-label={@label || if(@ok, do: gettext("Yes"), else: gettext("No"))}
    >
      <.icon name={if(@ok, do: "hero-check-micro", else: "hero-minus-micro")} class="size-3.5" />
    </span>
    """
  end

  # The ready picks above the roles: yourself, a new member, an admin, and
  # someone outside where the group lets them see it.
  defp presets(%Group{} = group) do
    [
      %{key: "self", icon: "hero-user", label: gettext("You"), spec: :self},
      %{key: "new", icon: "hero-user-plus", label: gettext("A new member"), spec: {:member, []}},
      %{
        key: "admin",
        icon: "hero-shield-check",
        label: gettext("Admin"),
        spec: {:member, [GroupRole.admin_key()]}
      }
    ] ++
      if(group.is_public,
        do: [
          %{
            key: "outsider",
            icon: "hero-user-circle",
            label: gettext("Someone outside the group"),
            spec: :outsider
          },
          %{
            key: "blocked",
            icon: "hero-no-symbol",
            label: gettext("A blocked profile"),
            spec: :blocked
          }
        ],
        else: []
      ) ++
      if(Group.guest_preview?(group),
        do: [%{key: "guest", icon: "hero-globe-alt", label: gettext("Guest"), spec: :guest}],
        else: []
      )
  end

  @doc "The spec of a ready pick, if `key` names one the group offers."
  def preset_spec(%Group{} = group, key) do
    case Enum.find(presets(group), &(&1.key == key)) do
      nil -> nil
      preset -> preset.spec
    end
  end

  defp preset_on?(%{spec: :self}, self?, _spec), do: self?
  defp preset_on?(%{spec: spec}, false, spec), do: true
  defp preset_on?(_preset, _self?, _spec), do: false

  defp picked_keys({:member, keys}), do: keys
  defp picked_keys(_spec), do: []

  defp count_yes(rows), do: rows |> Enum.flat_map(&elem(&1, 1)) |> Enum.count(& &1.ok)

  defp power_label(:admin), do: gettext("Admin")
  defp power_label(permission), do: RolesTab.permission_label(permission)

  defp holders_text(origins, key) do
    case Map.get(origins, key) do
      nil ->
        gettext("nobody holds it")

      %{count: count, inherited: inherited, decided: decided} ->
        [
          ngettext("%{count} holder", "%{count} holders", count),
          inherited > 0 && gettext("%{count} through the parent", count: inherited),
          decided > 0 && gettext("%{count} by a decision", count: decided)
        ]
        |> Enum.filter(& &1)
        |> Enum.join(" · ")
    end
  end

  defp things?(data),
    do:
      data.alts != [] or data.polls != [] or data.apps != [] or data.processes != [] or
        data.public_events > 0

  defp role_names(keys, manifest) do
    names =
      manifest.roles
      |> Enum.filter(&(&1.key in keys))
      |> Enum.map_join(", ", &RolesTab.role_label/1)

    if names == "", do: gettext("no role there is"), else: names
  end

  defp alt_rule_text(alt, manifest) do
    cond do
      alt.visible_role_keys != [] ->
        gettext("seen by %{roles} and those who edit the group",
          roles: role_names(alt.visible_role_keys, manifest)
        )

      alt.for_guests ->
        gettext("seen by everyone who sees the group, guests too")

      true ->
        gettext("seen by everyone who sees the group")
    end
  end

  defp poll_rule_text(poll, manifest) do
    [
      cond do
        poll.effect -> gettext("a decision put to the whole group")
        poll.is_public -> gettext("non-members vote too")
        true -> gettext("%{roles} vote", roles: role_names(poll.voter_role_keys, manifest))
      end,
      poll.secret && gettext("secret, results when it closes"),
      not poll.secret &&
        gettext("%{roles} see the results", roles: role_names(poll.results_role_keys, manifest)),
      poll.details_role_keys != [] &&
        gettext("%{roles} see who voted how", roles: role_names(poll.details_role_keys, manifest))
    ]
    |> Enum.filter(& &1)
    |> Enum.join("; ")
  end

  defp collection_rule_text(%{ruled?: false}, _manifest),
    do: gettext("no rule: members write, only the author and the editors read")

  defp collection_rule_text(rule, manifest) do
    [
      if(rule.public,
        do: gettext("non-members write too"),
        else: gettext("%{roles} write", roles: role_names(rule.write, manifest))
      ),
      if(rule.read == [],
        do: gettext("only the author and the editors read"),
        else: gettext("%{roles} read everything", roles: role_names(rule.read, manifest))
      ),
      rule.summary != [] &&
        gettext("%{roles} see the counts", roles: role_names(rule.summary, manifest))
    ]
    |> Enum.filter(& &1)
    |> Enum.join("; ")
  end

  defp process_rule_text(process, manifest) do
    asked = step_roles(process.graph)

    [
      if(process.trigger == "manual",
        do:
          gettext("%{roles} start it",
            roles: role_names(process.trigger_config["roles"] || ["everyone"], manifest)
          ),
        else: gettext("it starts by itself")
      ),
      asked != [] && gettext("it asks %{roles}", roles: role_names(asked, manifest)),
      not process.active && gettext("switched off")
    ]
    |> Enum.filter(& &1)
    |> Enum.join("; ")
  end

  defp step_roles(%{"nodes" => _} = graph),
    do: graph |> Graph.role_refs() |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

  defp step_roles(_graph), do: []

  ## The history

  defp change_icon(kind) when kind in [:role_given, :role_taken], do: "hero-tag"

  defp change_icon(kind)
       when kind in [:member_admitted, :member_removed, :member_blocked, :member_unblocked],
       do: "hero-user"

  defp change_icon(kind) when kind in [:elections_on, :elections_off], do: "hero-scale"
  defp change_icon(:settings_changed), do: "hero-cog-6-tooth"
  defp change_icon(:alt_visibility_set), do: "hero-document-text"
  defp change_icon(_kind), do: "hero-shield-check"

  # Who did it: a profile, a decision of a poll, or someone since deleted.
  defp actor_name(%GroupAccessChange{actor: %{username: name}}), do: name

  defp actor_name(%GroupAccessChange{poll_id: id}) when not is_nil(id),
    do: gettext("A decision of a poll")

  defp actor_name(_change), do: gettext("Someone")

  defp subject_name(%GroupAccessChange{subject: %{username: name}}), do: name
  defp subject_name(_change), do: gettext("someone")

  # A role by its name now, or as it was called when it went.
  defp change_role(%GroupAccessChange{role_key: key, data: data}, manifest) do
    case Enum.find(manifest.roles, &(&1.key == key)) do
      nil -> data["role"] || key
      role -> RolesTab.role_label(role)
    end
  end

  defp change_text(%GroupAccessChange{kind: :role_given} = change, manifest) do
    words = [
      actor: actor_name(change),
      subject: subject_name(change),
      role: change_role(change, manifest)
    ]

    if change.data["via"] == "request",
      do: gettext("%{actor} gives %{subject} the role %{role}, as they asked.", words),
      else: gettext("%{actor} gives %{subject} the role %{role}.", words)
  end

  defp change_text(%GroupAccessChange{kind: :role_taken} = change, manifest) do
    gettext("%{actor} takes the role %{role} from %{subject}.",
      actor: actor_name(change),
      subject: subject_name(change),
      role: change_role(change, manifest)
    )
  end

  defp change_text(%GroupAccessChange{kind: :permission_set} = change, manifest) do
    gettext("%{actor}: the role %{role} now %{state}: %{permission}.",
      actor: actor_name(change),
      role: change_role(change, manifest),
      state: permission_state(change.data["to"]),
      permission: permission_name(change.data["permission"])
    )
  end

  defp change_text(%GroupAccessChange{kind: :role_added} = change, manifest),
    do:
      gettext("%{actor} adds the role %{role}.",
        actor: actor_name(change),
        role: change_role(change, manifest)
      )

  defp change_text(%GroupAccessChange{kind: :role_renamed} = change, _manifest) do
    gettext("%{actor} renames the role %{from} to %{to}.",
      actor: actor_name(change),
      from: change.data["from"],
      to: change.data["to"]
    )
  end

  defp change_text(%GroupAccessChange{kind: :role_removed} = change, _manifest) do
    gettext("%{actor} deletes the role %{role}, which %{count} held.",
      actor: actor_name(change),
      role: change.data["role"],
      count: change.data["assignments"] || 0
    )
  end

  defp change_text(%GroupAccessChange{kind: :request_rule_set} = change, manifest) do
    gettext("%{actor} changes how the role %{role} is had: %{mode}.",
      actor: actor_name(change),
      role: change_role(change, manifest),
      mode: mode_name(:role, change.data["to"])
    )
  end

  defp change_text(%GroupAccessChange{kind: :manifest_copied} = change, _manifest),
    do: gettext("%{actor} gives the group a manifest of its own.", actor: actor_name(change))

  defp change_text(%GroupAccessChange{kind: :manifest_dropped} = change, _manifest),
    do:
      gettext("%{actor} makes the group use the manifest of the group above it again.",
        actor: actor_name(change)
      )

  defp change_text(%GroupAccessChange{kind: :settings_changed} = change, manifest) do
    gettext("%{actor}: %{changes}.",
      actor: actor_name(change),
      changes: settings_words(change.data, manifest)
    )
  end

  defp change_text(%GroupAccessChange{kind: :alt_visibility_set} = change, manifest) do
    gettext("%{actor} sets who sees the description %{alt}: %{who}.",
      actor: actor_name(change),
      alt: change.data["alt"],
      who:
        alt_rule_text(
          %{visible_role_keys: change.data["roles"] || [], for_guests: change.data["guests"]},
          manifest
        )
    )
  end

  defp change_text(%GroupAccessChange{kind: :join_rule_set} = change, _manifest) do
    gettext("%{actor} changes how a request to join is decided: %{mode}.",
      actor: actor_name(change),
      mode: mode_name(:join, change.data["to"])
    )
  end

  defp change_text(%GroupAccessChange{kind: :elections_on} = change, _manifest),
    do: gettext("%{actor} lets the group elect its admins.", actor: actor_name(change))

  defp change_text(%GroupAccessChange{kind: :elections_off} = change, _manifest),
    do: gettext("%{actor} gives the group back to its founders' rule.", actor: actor_name(change))

  defp change_text(%GroupAccessChange{kind: :member_admitted} = change, _manifest),
    do:
      gettext("%{actor} admits %{subject}.",
        actor: actor_name(change),
        subject: subject_name(change)
      )

  defp change_text(%GroupAccessChange{kind: :member_removed} = change, _manifest),
    do:
      gettext("%{actor} removes %{subject}.",
        actor: actor_name(change),
        subject: subject_name(change)
      )

  defp change_text(%GroupAccessChange{kind: :member_blocked} = change, _manifest),
    do:
      gettext("%{actor} blocks %{subject}.",
        actor: actor_name(change),
        subject: subject_name(change)
      )

  defp change_text(%GroupAccessChange{kind: :member_unblocked} = change, _manifest),
    do:
      gettext("%{actor} lifts the block on %{subject}.",
        actor: actor_name(change),
        subject: subject_name(change)
      )

  defp permission_state("allow"), do: gettext("allows")
  defp permission_state("deny"), do: gettext("denies")
  defp permission_state(_neutral), do: gettext("no longer sets")

  defp permission_name(name) when is_binary(name) do
    permission = Enum.find(GroupRole.permissions(), &(Atom.to_string(&1) == name))
    if permission, do: RolesTab.permission_label(permission), else: name
  end

  defp permission_name(_name), do: ""

  defp mode_name(kind, mode) when is_binary(mode) do
    case Enum.find(RequestRules.modes(kind), &(Atom.to_string(&1) == mode)) do
      nil -> mode
      known -> String.downcase(RequestRules.mode_label(kind, known))
    end
  end

  defp mode_name(_kind, _mode), do: ""

  defp settings_words(data, manifest) do
    [
      setting(
        data["is_public"],
        gettext("makes the group public"),
        gettext("makes the group private")
      ),
      setting(
        data["has_public_chat"],
        gettext("opens the chat to non-members"),
        gettext("closes the chat to non-members")
      ),
      setting(
        data["description_for_guests"],
        gettext("opens the description to guests"),
        gettext("closes the description to guests")
      ),
      setting(
        data["inherits_members"],
        gettext("lets it take the parent's members"),
        gettext("stops it taking the parent's members")
      ),
      data["inherit_role_keys"] &&
        gettext("sets which of the parent's members it takes: %{roles}",
          roles: inherit_words(List.last(data["inherit_role_keys"]), manifest)
        ),
      data["withdrawn"] && gettext("withdraws the group")
    ]
    |> Enum.filter(& &1)
    |> Enum.join(", ")
  end

  defp setting([_old, true], yes, _no), do: yes
  defp setting([_old, false], _yes, no), do: no
  defp setting(_change, _yes, _no), do: nil

  defp inherit_words(keys, _manifest) when keys in [nil, []], do: gettext("all of them")
  defp inherit_words(keys, manifest), do: role_names(keys, manifest)

  defp child_rule_text(child, manifest) do
    [
      if(child.is_public, do: gettext("public sub-group"), else: gettext("private sub-group")),
      cond do
        not child.inherits_members ->
          gettext("members of its own")

        child.inherit_role_keys in [nil, []] ->
          gettext("takes this group's members")

        true ->
          gettext("takes the members who hold %{roles}",
            roles: role_names(child.inherit_role_keys, manifest)
          )
      end,
      child.own_manifest? && gettext("roles of its own"),
      child.open_chat? && gettext("open chat"),
      ngettext("%{count} member", "%{count} members", child.member_count || 0)
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end
end
