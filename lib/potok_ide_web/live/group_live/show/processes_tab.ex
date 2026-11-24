defmodule PotokIdeWeb.GroupLive.Show.ProcessesTab do
  @moduledoc """
  The group's Processes tab (`ProcessesState`): what waits on the viewer, then
  the processes of each app, those it writes into its rules and those drawn
  in Potok, with how their instances are doing.
  """

  use PotokIdeWeb, :html

  alias PotokIde.Social.Profile
  alias PotokIde.Social.ValueRules
  alias PotokIde.Social.DrawnProcesses

  alias PotokIdeWeb.GroupLive.Show.{
    Components,
    EntityFields,
    ProcessEditor,
    ProcessEditorState,
    ProcessEntities,
    RolesTab
  }

  attr :group, :map, required: true
  attr :access, :any, required: true
  attr :current_profile, :map, required: true
  attr :apps, :list, required: true, doc: "`%{id, name, entries}`, see `ProcessesState`"
  attr :tasks, :list, required: true, doc: "from `Processes.tasks_for/3`"

  attr :fields, :list,
    default: [],
    doc: "the group's fields its processes keep, for the app's editors (`GroupFields`)"

  attr :entities, :list,
    default: [],
    doc: "the group's entities, for the app's editors (`GroupEntities`)"

  attr :entity, :map, default: nil, doc: "`%{entity, form}` while an editor defines an entity"

  attr :can_draw?, :boolean,
    default: false,
    doc: "whether the viewer may draw, on an app the group has"

  attr :editor, :map, default: nil, doc: "the drawing open over the tab (`ProcessEditorState`)"
  attr :editor_form, :any, default: nil
  attr :editor_meta, :any, default: nil

  def panel(assigns) do
    assigns = assign(assigns, :manage?, ValueRules.manage?(assigns.access))

    ~H"""
    <div id="group-panel-processes" class="card flex min-h-0 flex-1 flex-col px-2">
      <Components.tab_body>
        <.page_header id="group-processes-header" icon="hero-arrow-path-rounded-square" compact>
          {gettext("Processes")}
          <:subtitle>
            {gettext(
              "What happens on its own when a value comes to an app: messages, sub-groups, tasks."
            )}
          </:subtitle>
          <:actions :if={@can_draw?}>
            <.button
              id="processes-new"
              patch={~p"/groups/#{@group.id}/processes?#{[process: "new"]}"}
              variant="primary"
              size="sm"
            >
              <.icon name="hero-pencil-square" class="size-4" />
              {gettext("Draw a process")}
            </.button>
          </:actions>
        </.page_header>

        <section :if={@tasks != []} id="process-tasks" class="mb-8">
          <h2 class="mb-3 flex items-center gap-2 px-1 text-sm font-semibold">
            <span class="relative flex size-2.5">
              <span class="absolute inline-flex size-full animate-ping rounded-full bg-amber-400 opacity-60" />
              <span class="relative inline-flex size-2.5 rounded-full bg-amber-500" />
            </span>
            {gettext("Waiting for you")}
            <span class="text-base-content/50">{length(@tasks)}</span>
          </h2>

          <ul id="process-tasks-list" class="space-y-3">
            <li
              :for={task <- @tasks}
              id={"process-task-#{task.id}"}
              class="rounded-3xl border border-amber-500/30 bg-gradient-to-br from-amber-500/10 to-base-100 p-4 shadow-sm transition-shadow duration-200 hover:shadow-md"
            >
              <.task task={task} current_profile={@current_profile} />
            </li>
          </ul>
        </section>

        <div
          :if={@apps == []}
          id="group-processes-empty"
          class="rounded-3xl border border-dashed border-base-300 px-5 py-10 text-center text-sm text-base-content/65"
        >
          <.icon
            name="hero-arrow-path-rounded-square"
            class="mx-auto mb-2 size-8 text-base-content/30"
          />
          {gettext("No process runs in this group yet.")}
          <p :if={@can_draw?} class="mt-1">
            {gettext("Draw one: what happens when a new value comes in, step by step.")}
          </p>
        </div>

        <section
          :for={app <- @apps}
          id={"process-app-#{app.id}"}
          class="mb-6"
        >
          <h2
            :if={length(@apps) > 1}
            class="mb-2 flex items-center gap-1.5 px-1 text-xs font-semibold uppercase tracking-wide text-base-content/55"
          >
            <.icon name="hero-squares-2x2" class="size-3.5" />
            {app.name || gettext("Group description")}
          </h2>

          <ul class="space-y-2">
            <li
              :for={entry <- app.entries}
              id={"process-row-#{entry.id}"}
              class={[
                "rounded-3xl border bg-base-100/80 p-3 shadow-sm transition duration-200 hover:shadow-md",
                if(entry.process.active,
                  do: "border-base-300/70",
                  else: "border-dashed border-base-300 opacity-80"
                )
              ]}
            >
              <.process_row entry={entry} manage?={@manage?} group={@group} access={@access} />
            </li>
          </ul>
        </section>

        <section :if={@fields != [] or @manage?} id="group-fields" class="mb-6">
          <h2 class="mb-1 flex items-center gap-1.5 px-1 text-xs font-semibold uppercase tracking-wide text-base-content/55">
            <.icon name="hero-pencil-square" class="size-3.5" />
            {gettext("Fields of the group")}
          </h2>
          <p class="mb-2 px-1 text-xs text-base-content/60">
            {gettext(
              "What the processes keep for each other, each of its type. They read them as %{example}.",
              example: "group.kvarova"
            )}
          </p>
          <ul class="divide-y divide-base-300/60 overflow-hidden rounded-3xl border border-base-300/70 bg-base-100/80 shadow-sm">
            <li
              :for={field <- @fields}
              id={"group-field-#{field.id}"}
              class="flex items-center gap-3 px-4 py-2.5 transition-colors duration-150 hover:bg-base-200/40"
            >
              <div class="min-w-0 flex-1">
                <p class="flex min-w-0 items-baseline gap-2 text-sm">
                  <code class="shrink-0 rounded-full bg-lime-500/10 px-2 py-0.5 font-mono text-[11px] text-lime-700 dark:text-lime-300">
                    {field.name}
                  </code>
                  <span
                    :if={!@manage?}
                    id={"group-field-#{field.id}-type"}
                    class="shrink-0 text-xs text-base-content/60"
                  >
                    {field_type_label(field.type)}
                  </span>
                  <span class="truncate font-semibold">{field.value}</span>
                </p>
                <p class="mt-0.5 flex flex-wrap items-center gap-x-1.5 text-xs text-base-content/55">
                  <span :if={field.app_process}>{field.app_process.name}</span>
                  <span :if={field.app_process}>·</span>
                  <Components.local_time
                    id={"group-field-#{field.id}-at"}
                    datetime={field.updated_at}
                  />
                </p>
              </div>
              <form
                :if={@manage?}
                id={"group-field-#{field.id}-retype"}
                phx-change="processes_retype_field"
                class="shrink-0"
              >
                <input type="hidden" name="field_id" value={field.id} />
                <select
                  name="type"
                  aria-label={gettext("Type of the field")}
                  class="select select-xs w-28"
                >
                  <option
                    :for={type <- PotokIde.Processes.GroupFields.types()}
                    value={type}
                    selected={type == field.type}
                  >
                    {field_type_label(type)}
                  </option>
                </select>
              </form>
              <.icon_button
                :if={@manage? and field.value != ""}
                id={"group-field-#{field.id}-clear"}
                type="button"
                phx-click="processes_clear_field"
                phx-value-id={field.id}
                icon="hero-backspace"
                label={gettext("Empty the field")}
              />
              <.icon_button
                id={"group-field-#{field.id}-delete"}
                type="button"
                phx-click="processes_delete_field"
                phx-value-id={field.id}
                data-confirm={gettext("Delete this field? The processes read it as empty.")}
                icon="hero-trash"
                label={gettext("Delete the field")}
              />
            </li>
          </ul>
          <.form
            :if={@manage?}
            for={%{}}
            as={:field}
            id="group-field-form"
            phx-submit="processes_declare_field"
            class="mt-2 flex flex-wrap items-end gap-2 px-1"
          >
            <div class="min-w-32 flex-1">
              <.input
                type="text"
                id="group-field-name"
                name="field[name]"
                value=""
                label={gettext("New field")}
                placeholder={gettext("kvarova")}
                maxlength="40"
              />
            </div>
            <div>
              <.input
                type="select"
                id="group-field-type"
                name="field[type]"
                value="text"
                label={gettext("Type")}
                options={
                  Enum.map(PotokIde.Processes.GroupFields.types(), &{field_type_label(&1), &1})
                }
              />
            </div>
            <div class="min-w-32 flex-1">
              <.input
                type="text"
                id="group-field-options"
                name="field[options]"
                value=""
                label={gettext("Choices, for a choice")}
                placeholder={gettext("open, closed")}
              />
            </div>
            <.button id="group-field-declare" type="submit" class="mb-2">
              <.icon name="hero-plus" class="size-4" />
              {gettext("Add")}
            </.button>
          </.form>
        </section>

        <ProcessEntities.section :if={@can_draw?} entities={@entities} />
      </Components.tab_body>

      <ProcessEntities.dialog entity={@entity} entities={@entities} />

      <ProcessEditor.editor
        :if={@editor}
        editor={@editor}
        form={@editor_form}
        meta={@editor_meta}
        group={@group}
        access={@access}
      />
    </div>
    """
  end

  attr :task, :map, required: true
  attr :current_profile, :map, required: true

  defp task(assigns) do
    ~H"""
    <div class="flex flex-wrap items-start justify-between gap-2">
      <div class="min-w-0">
        <p class="text-xs font-medium text-base-content/60">{@task.process.name}</p>
        <h3 class="text-base font-semibold leading-snug">{@task.label}</h3>
      </div>
      <span
        :if={@task.deadline_at}
        id={"process-task-#{@task.id}-deadline"}
        class="inline-flex items-center gap-1 rounded-full bg-base-100/80 px-2.5 py-1 text-xs font-medium text-base-content/70 shadow-xs"
      >
        <.icon name="hero-clock" class="size-3.5" />
        <Components.local_time
          id={"process-task-#{@task.id}-deadline-at"}
          datetime={@task.deadline_at}
        />
      </span>
    </div>

    <div class="mt-3 rounded-2xl bg-base-100/80 p-3 text-sm shadow-xs">
      <div class="mb-2 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-base-content/60">
        <.icon name={subject_icon(@task.kind)} class="size-3.5" />
        <span :if={@task.kind == :call}>{gettext("Called by")}</span>
        <span :if={@task.kind == :signal}>{gettext("On a signal from")}</span>
        <span :if={@task.author_name} class="font-semibold text-base-content/80">
          {@task.author_name}
        </span>
        <span :if={!@task.author_name and @task.kind == :value}>{gettext("Anonymous")}</span>
        <span :if={@task.author_name || @task.kind == :value}>·</span>
        <Components.local_time id={"process-task-#{@task.id}-sent"} datetime={@task.sent_at} />
      </div>

      <div :if={@task.title || @task.text} id={"process-task-#{@task.id}-subject"} class="space-y-1">
        <%= if @task.link do %>
          <.link
            navigate={@task.link}
            class="inline-flex items-center gap-1 font-semibold text-primary transition hover:underline"
          >
            {@task.title || gettext("Open the message")}
            <.icon name="hero-arrow-up-right-mini" class="size-4" />
          </.link>
        <% else %>
          <p :if={@task.title} class="font-semibold">{@task.title}</p>
        <% end %>
        <%!-- On one line: the text keeps its own line breaks, and gets none of the template's. --%>
        <p
          :if={@task.text}
          class="line-clamp-4 whitespace-pre-line break-words text-base-content/80"
          phx-no-format
        >{@task.text}</p>
      </div>

      <details :if={@task.data != []} id={"process-task-#{@task.id}-data"} class="group">
        <summary class="flex cursor-pointer list-none items-center gap-1 text-xs font-semibold text-base-content/70 transition hover:text-base-content">
          <.icon
            name="hero-chevron-right-mini"
            class="size-4 transition-transform group-open:rotate-90"
          />
          {gettext("What was sent")}
        </summary>
        <dl class="mt-2 grid gap-x-3 gap-y-1 sm:grid-cols-[minmax(6rem,auto)_1fr]">
          <%= for {path, text} <- @task.data do %>
            <dt class="truncate font-mono text-[11px] text-base-content/50">{path}</dt>
            <dd class="min-w-0 break-words">{text}</dd>
          <% end %>
        </dl>
      </details>

      <p
        :if={!@task.reads?}
        id={"process-task-#{@task.id}-hidden"}
        class="text-xs text-base-content/60"
      >
        <.icon name="hero-eye-slash" class="mr-1 size-3.5 align-[-2px]" />
        {gettext("You may decide, but not read what was sent.")}
      </p>

      <div :if={@task.groups != []} class="mt-2 flex flex-wrap gap-1.5">
        <.link
          :for={group <- @task.groups}
          id={"process-task-#{@task.id}-group-#{group.id}"}
          navigate={~p"/groups/#{group.id}"}
          class="inline-flex items-center gap-1 rounded-full bg-primary/10 px-2.5 py-1 text-xs font-semibold text-primary transition hover:bg-primary/20"
        >
          <.icon name="hero-folder" class="size-3.5" />
          {group.name}
        </.link>
      </div>
    </div>

    <ol :if={@task.log != []} class="mt-2 space-y-1 px-1 text-xs text-base-content/65">
      <li :for={{entry, i} <- Enum.with_index(@task.log)} id={"process-task-#{@task.id}-log-#{i}"}>
        <span class="font-semibold">{entry.by.username || gettext("someone")}</span>
        <span :if={entry.form?}>{"→ " <> gettext("form filled in")}</span>
        <span :if={!entry.form?}>{"→ " <> to_string(entry.outcome)}</span>
        <span :if={entry.comment} class="italic">„{entry.comment}“</span>
      </li>
    </ol>

    <div :if={@task.form?} class="mt-3 flex flex-wrap items-center justify-between gap-2">
      <p
        :if={@task[:intro]}
        id={"process-task-#{@task.id}-intro"}
        class="line-clamp-2 min-w-0 flex-1 whitespace-pre-line break-words text-sm text-base-content/80"
        phx-no-format
      >{@task.intro}</p>
      <p :if={!@task[:intro]} class="text-xs text-base-content/60">
        {gettext("A form for you to fill in.")}
      </p>
      <.button
        id={"process-task-#{@task.id}-fill"}
        type="button"
        phx-click="process_form_open"
        phx-value-id={@task.id}
        variant="primary"
        size="sm"
        class="transition-transform active:scale-95"
      >
        <.icon name="hero-clipboard-document-list" class="size-4" />
        {gettext("Fill in")}
      </.button>
    </div>

    <.form
      :if={!@task.form?}
      for={%{}}
      as={:decision}
      id={"process-task-#{@task.id}-form"}
      phx-submit="processes_complete"
      class="mt-3 space-y-2"
    >
      <input type="hidden" name="instance" value={@task.id} />
      <input type="hidden" name="element" value={@task.element} />
      <.input
        type="textarea"
        id={"process-task-#{@task.id}-comment"}
        name="comment"
        value=""
        rows="2"
        maxlength="1000"
        placeholder={gettext("A comment, if you like")}
        class="textarea w-full rounded-2xl bg-base-100/90 text-sm"
      />
      <div class="flex flex-wrap gap-2">
        <.button
          :for={{outcome, i} <- Enum.with_index(@task.outcomes)}
          id={"process-task-#{@task.id}-outcome-#{i}"}
          type="submit"
          name="outcome"
          value={outcome}
          variant={if(i == 0, do: "primary", else: "secondary")}
          size="sm"
          class="transition-transform active:scale-95"
        >
          {outcome}
        </.button>
      </div>
    </.form>
    """
  end

  attr :entry, :map, required: true
  attr :manage?, :boolean, required: true
  attr :group, :map, required: true
  attr :access, :any, required: true

  defp process_row(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-3">
      <div class="min-w-0 flex-1">
        <div class="flex flex-wrap items-center gap-1.5">
          <span class="truncate font-semibold">{@entry.process.name}</span>
          <span
            id={"process-row-#{@entry.id}-kind"}
            class={[
              "inline-flex h-5 items-center rounded-full px-2 text-[11px] font-semibold",
              if(@entry.process.drawn,
                do: "bg-primary/10 text-primary",
                else: "bg-base-200 text-base-content/65"
              )
            ]}
          >
            {if(@entry.process.drawn, do: gettext("drawn"), else: gettext("from the app"))}
          </span>
          <span
            :if={@entry.process.is_public}
            id={"process-row-#{@entry.id}-public"}
            class="inline-flex h-5 items-center gap-1 rounded-full bg-sky-500/10 px-2 text-[11px] font-semibold text-sky-700 dark:text-sky-300"
            title={gettext("The processes of the groups above and below may call it.")}
          >
            <.icon name="hero-globe-alt" class="size-3" />
            {gettext("public")}
          </span>
          <span
            :if={!@entry.process.active}
            id={"process-row-#{@entry.id}-off"}
            class="inline-flex h-5 items-center rounded-full bg-base-200 px-2 text-[11px] font-semibold text-base-content/60"
          >
            {gettext("off")}
          </span>
        </div>
        <p class="mt-0.5 text-xs text-base-content/60">{subtitle(@entry.process, @access)}</p>
      </div>
      <.button
        :if={
          @entry.process.trigger == "manual" and @entry.process.active and
            DrawnProcesses.may_start?(@entry.process, @access)
        }
        id={"process-row-#{@entry.id}-start"}
        type="button"
        phx-click="processes_start_open"
        phx-value-id={@entry.id}
        variant="primary"
        size="sm"
      >
        <.icon name="hero-play" class="size-4" />
        {gettext("Start")}
      </.button>
      <.button
        id={"process-row-#{@entry.id}-open"}
        patch={~p"/groups/#{@group.id}/processes?#{[process: @entry.id]}"}
        variant={if(@entry.process.drawn and @manage?, do: "soft", else: "ghost")}
        size="sm"
      >
        <.icon
          name={if(@entry.process.drawn and @manage?, do: "hero-pencil-square", else: "hero-eye")}
          class="size-4"
        />
        {if(@entry.process.drawn and @manage?, do: gettext("Edit"), else: gettext("View"))}
      </.button>
    </div>

    <div
      :if={@entry.warning || @entry.shared?}
      id={"process-row-#{@entry.id}-warning"}
      class="mt-2 space-y-0.5 rounded-xl bg-amber-500/10 px-3 py-2 text-xs text-amber-900 dark:text-amber-100"
    >
      <p
        :if={@entry.warning && @entry.warning["missing"] != []}
        id={"process-row-#{@entry.id}-missing"}
      >
        <.icon name="hero-exclamation-triangle" class="mr-1 size-3.5 align-[-2px]" />
        {gettext("It may not: %{permissions}. Give its profile a role under Members.",
          permissions: missing_permissions(@entry.warning["missing"])
        )}
      </p>
      <p
        :if={@entry.warning && @entry.warning["owner_left"]}
        id={"process-row-#{@entry.id}-owner-left"}
      >
        <.icon name="hero-user-minus" class="mr-1 size-3.5 align-[-2px]" />
        {if(@entry.process.drawn,
          do:
            gettext(
              "Its owner no longer edits the app. Whoever saves the drawing next takes it over."
            ),
          else:
            gettext("Its owner no longer edits the app. Whoever saves its rules next takes it over.")
        )}
      </p>
      <p
        :if={@entry.warning && @entry.warning["stale"]}
        id={"process-row-#{@entry.id}-stale"}
      >
        <.icon name="hero-arrow-path" class="mr-1 size-3.5 align-[-2px]" />
        {gettext(
          "What it was saved with has changed: an entity, a process it calls or a signal. It runs on as it was saved. Open it, look it over and save it."
        )}
      </p>
      <p :if={@entry.shared?} id={"process-row-#{@entry.id}-shared"}>
        <.icon name="hero-square-2-stack" class="mr-1 size-3.5 align-[-2px]" />
        {gettext("Another process runs on the same collection too.")}
      </p>
    </div>

    <div
      :if={@entry.counts != %{}}
      id={"process-row-#{@entry.id}-counts"}
      class="mt-2 flex flex-wrap gap-1.5"
    >
      <span
        :for={{status, label} <- count_labels(@entry.counts)}
        id={"process-row-#{@entry.id}-count-#{status}"}
        class={[
          "inline-flex h-6 items-center rounded-full px-2 text-[11px] font-semibold",
          count_class(status)
        ]}
      >
        {label}
      </span>
    </div>

    <div class="mt-1.5">
      <button
        type="button"
        id={"process-row-#{@entry.id}-runs"}
        phx-click="processes_runs_open"
        phx-value-id={@entry.id}
        class="inline-flex h-6 items-center gap-1 rounded-full px-2 text-[11px] font-semibold text-primary hover:bg-primary/10"
      >
        <.icon name="hero-clock" class="size-3.5" />
        {gettext("What the runs did")}
      </button>
    </div>

    <ul :if={@entry.failed != []} id={"process-row-#{@entry.id}-failed"} class="mt-2 space-y-1">
      <li
        :for={%{instance: instance, label: label} <- @entry.failed}
        id={"process-instance-#{instance.id}"}
        class="flex flex-wrap items-center justify-between gap-2 rounded-xl bg-error/10 px-3 py-1.5 text-xs text-base-content"
      >
        <span class="min-w-0">
          <span class="font-semibold">{gettext("Stopped at %{element}", element: label)}</span>
          <span class="text-base-content/70">
            · {failure_reason((instance.error || %{})["reason"])}
          </span>
        </span>
        <span class="flex gap-1.5">
          <.button
            id={"process-instance-#{instance.id}-cancel"}
            type="button"
            phx-click="processes_cancel"
            phx-value-id={instance.id}
            variant="ghost"
            size="sm"
          >
            {gettext("Cancel")}
          </.button>
          <.button
            id={"process-instance-#{instance.id}-retry"}
            type="button"
            phx-click="processes_retry"
            phx-value-id={instance.id}
            size="sm"
          >
            {gettext("Take up again")}
          </.button>
        </span>
      </li>
    </ul>
    """
  end

  defp subject_icon(:message), do: "hero-chat-bubble-left-ellipsis"
  defp subject_icon(:group), do: "hero-folder-plus"
  defp subject_icon(:data), do: "hero-play-circle"
  defp subject_icon(:call), do: "hero-arrow-top-right-on-square"
  defp subject_icon(:signal), do: "hero-signal"
  defp subject_icon(_value), do: "hero-inbox-arrow-down"

  # What starts the process (its collection, for an app's), and who owns it.
  defp subtitle(process, access) do
    owner =
      case process.owner_profile do
        %{username: username} -> gettext("owner %{username}", username: username)
        nil -> gettext("no owner")
      end

    start =
      if process.trigger == "value",
        do: gettext("collection %{collection}", collection: process.collection),
        else:
          ProcessEditorState.trigger_summary(
            process.trigger,
            process.trigger_config,
            nil,
            ProcessEditorState.role_labels(access)
          )

    # The entity it takes when it starts, where it takes one.
    takes =
      case process.entry_entity do
        %{name: name} -> gettext("takes %{entity}", entity: name)
        _none -> nil
      end

    [start, takes, owner] |> Enum.reject(&is_nil/1) |> Enum.join(" · ")
  end

  attr :state, :map,
    default: nil,
    doc: "`%{process, runs, more?, open, events}` while the runs of a process are looked at"

  attr :manage?, :boolean, required: true

  @doc "What the runs of a process did (`PotokIde.Processes.RunEvents`): the list, and the run picked."
  def runs_dialog(assigns) do
    ~H"""
    <dialog
      :if={@state}
      id="process-runs-dialog"
      phx-hook=".ProcessRunsDialog"
      phx-mounted={JS.ignore_attributes(["open"])}
      aria-labelledby="process-runs-title"
      class="fixed inset-0 m-0 size-full max-h-none max-w-none overflow-hidden bg-transparent p-0 backdrop:bg-transparent"
    >
      <div class="flex size-full items-end justify-center sm:items-center sm:p-4">
        <div
          class="absolute inset-0 bg-black/30 backdrop-blur-[2px] dark:bg-black/60"
          phx-click="processes_runs_close"
          aria-hidden="true"
        >
        </div>
        <section
          tabindex="-1"
          autofocus
          class="relative flex max-h-[85dvh] w-full flex-col overflow-hidden rounded-t-3xl border border-b-0 border-base-300/70 bg-base-100 text-base-content shadow-2xl outline-none sm:max-w-xl sm:rounded-3xl sm:border-b"
        >
          <header class="flex items-start gap-3 border-b border-base-300/60 px-5 pt-5 pb-4">
            <span class="inline-flex size-10 shrink-0 items-center justify-center rounded-2xl bg-primary/10 text-primary">
              <.icon name="hero-clock" class="size-5" />
            </span>
            <div class="min-w-0 flex-1">
              <h2 id="process-runs-title" class="text-base font-semibold [overflow-wrap:anywhere]">
                {@state.process.name}
              </h2>
              <p class="text-xs text-base-content/60">
                {if @manage?,
                  do: gettext("What its runs did, step by step."),
                  else: gettext("The runs you started or answered.")}
              </p>
            </div>
            <.icon_button
              id="process-runs-close"
              type="button"
              phx-click="processes_runs_close"
              icon="hero-x-mark"
              label={gettext("Close")}
            />
          </header>
          <div class="min-h-0 flex-1 overflow-y-auto px-4 pt-3 pb-[calc(1rem+var(--app-safe-area-bottom))]">
            <p
              :if={@state.runs == []}
              id="process-runs-empty"
              class="py-8 text-center text-sm text-base-content/60"
            >
              {gettext("No run since the trace began.")}
            </p>
            <ul class="space-y-1">
              <li :for={run <- @state.runs} id={"process-run-#{run.id}"}>
                <button
                  type="button"
                  id={"process-run-#{run.id}-open"}
                  phx-click="processes_run_open"
                  phx-value-id={run.id}
                  aria-expanded={to_string(@state.open == run.id)}
                  class="flex w-full items-center gap-2.5 rounded-2xl px-2 py-2 text-left hover:bg-base-200"
                >
                  <.icon
                    name={run_icon(run.last.kind)}
                    class={["size-5 shrink-0", run_class(run.last.kind)]}
                  />
                  <span class="min-w-0 flex-1">
                    <span class="block truncate text-sm font-medium">{run_state(run.last)}</span>
                    <span class="block text-xs text-base-content/60">
                      <Components.local_time id={"process-run-#{run.id}-at"} datetime={run.at} />
                      {if run.actor, do: "· " <> Profile.display_name(run.actor)}
                    </span>
                  </span>
                  <.icon
                    name={if @state.open == run.id, do: "hero-chevron-up", else: "hero-chevron-down"}
                    class="size-4 shrink-0 opacity-50"
                  />
                </button>
                <ol
                  :if={@state.open == run.id}
                  id={"process-run-#{run.id}-events"}
                  class="mb-2 ml-4 space-y-1.5 border-l border-base-300 py-1 pl-4"
                >
                  <li :for={event <- @state.events} id={"run-event-#{event.id}"} class="text-sm">
                    <p class="[overflow-wrap:anywhere]">{event_text(event)}</p>
                    <p class="text-xs text-base-content/55">
                      <Components.local_time
                        id={"run-event-#{event.id}-at"}
                        datetime={event.at}
                      />
                    </p>
                    <ul :if={is_map(event.vars)} class="mt-0.5 space-y-0.5">
                      <li
                        :for={{name, sides} <- event.vars}
                        class="text-xs text-base-content/70 [overflow-wrap:anywhere]"
                      >
                        <code>{name}</code>{var_text(sides)}
                      </li>
                    </ul>
                  </li>
                </ol>
              </li>
            </ul>
            <div :if={@state.more?} class="mt-3 flex justify-center">
              <.button
                id="process-runs-more"
                type="button"
                phx-click="processes_runs_more"
                size="sm"
              >
                {gettext("Older runs")}
              </.button>
            </div>
          </div>
        </section>
      </div>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ProcessRunsDialog">
      export default {
        mounted() {
          // Escape and Android's back button close it through the server.
          this.el.addEventListener("cancel", event => {
            event.preventDefault()
            this.pushEvent("processes_runs_close", {})
          })

          this.el.showModal()
        },

        updated() {
          if (!this.el.open) this.el.showModal()
        },
      }
    </script>
    """
  end

  defp run_icon("done"), do: "hero-check-circle"
  defp run_icon("failed"), do: "hero-exclamation-circle"
  defp run_icon("cancelled"), do: "hero-x-circle"
  defp run_icon("waits"), do: "hero-pause-circle"
  defp run_icon(_kind), do: "hero-play-circle"

  defp run_class("done"), do: "text-emerald-600 dark:text-emerald-400"
  defp run_class("failed"), do: "text-rose-600 dark:text-rose-400"
  defp run_class(_kind), do: "text-base-content/50"

  # A step by its name, or by what it does, as its editor offers it.
  defp step(%{label: label}) when is_binary(label), do: label
  defp step(%{type: "startEvent"}), do: gettext("Start")
  defp step(%{type: "endEvent"}), do: gettext("End")

  defp step(%{type: type, element: element}) do
    kind =
      case type do
        "userTask" -> "task"
        "formTask" -> "form"
        "pollTask" -> "poll"
        "callActivity" -> "call"
        "receiveTask" -> "receive"
        "exclusiveGateway" -> "gateway"
        other -> other
      end

    case List.keyfind(ProcessEditor.insert_kinds(), kind, 0) do
      {_kind, _icon, name, _text, _class} -> name
      nil -> element || ""
    end
  end

  # Where a run stands, by the last thing it did.
  defp run_state(%{kind: "done"} = last), do: gettext("Ended at “%{step}”", step: step(last))
  defp run_state(%{kind: "failed"} = last), do: gettext("Stopped at “%{step}”", step: step(last))
  defp run_state(%{kind: "cancelled"}), do: gettext("Cancelled")
  defp run_state(%{kind: "waits"} = last), do: gettext("Waits at “%{step}”", step: step(last))
  defp run_state(last), do: gettext("Under way, after “%{step}”", step: step(last))

  # What an event of a run says, with who did it where someone did.
  defp event_text(%{kind: "started", actor: %Profile{} = actor}),
    do: gettext("%{name} sets it off.", name: Profile.display_name(actor))

  defp event_text(%{kind: "started"}), do: gettext("It starts.")

  defp event_text(%{kind: "passed", count: count} = event) when count > 1,
    do: gettext("“%{step}”, %{count} times in all.", step: step(event), count: count)

  defp event_text(%{kind: "passed"} = event), do: gettext("“%{step}”", step: step(event))

  defp event_text(%{kind: "waits"} = event),
    do: gettext("Waits at “%{step}”.", step: step(event))

  defp event_text(%{kind: "answered"} = event) do
    name = if event.actor, do: Profile.display_name(event.actor), else: gettext("Someone")

    if event.outcome,
      do:
        gettext("%{name} decides “%{step}”: %{outcome}.",
          name: name,
          step: step(event),
          outcome: event.outcome
        ),
      else: gettext("%{name} fills in “%{step}”.", name: name, step: step(event))
  end

  defp event_text(%{kind: "woke"} = event),
    do: gettext("Goes on from “%{step}”.", step: step(event))

  defp event_text(%{kind: "failed"} = event),
    do:
      gettext("Stops at “%{step}”: %{reason}.",
        step: step(event),
        reason: failure_reason(event.outcome)
      )

  defp event_text(%{kind: "retried"} = event) do
    case event.actor do
      %Profile{} = actor ->
        gettext("%{name} takes it up again.", name: Profile.display_name(actor))

      _nobody ->
        gettext("It is taken up again.")
    end
  end

  defp event_text(%{kind: "cancelled"} = event) do
    case event.actor do
      %Profile{} = actor -> gettext("%{name} cancels it.", name: Profile.display_name(actor))
      _nobody -> gettext("It is cancelled.")
    end
  end

  defp event_text(%{kind: "done"} = event), do: gettext("Ends at “%{step}”.", step: step(event))

  defp var_text([before, now]), do: ": #{var_value(before)} → #{var_value(now)}"
  defp var_text(_much), do: gettext(": changed")

  defp var_value(nil), do: "—"
  defp var_value(value) when is_binary(value), do: String.slice(value, 0, 120)
  defp var_value(value), do: value |> Jason.encode!() |> String.slice(0, 120)

  attr :start, :map,
    default: nil,
    doc:
      "`%{process, params, form, attributes, types, error, error_at}` while someone starts a process"

  @doc """
  Starting a process by hand: a title and a text its steps can put in, or
  the attributes of the entity it takes, each asked for as its type. On the
  page, beside the form a step asks for, so an app can open it too.
  """
  def start_dialog(assigns) do
    ~H"""
    <dialog
      :if={@start}
      id="process-start-dialog"
      phx-hook=".ProcessStartDialog"
      phx-mounted={JS.ignore_attributes(["open"])}
      aria-labelledby="process-start-title"
      class="fixed inset-0 m-0 size-full max-h-none max-w-none overflow-hidden bg-transparent p-0 backdrop:bg-transparent"
    >
      <div class="flex size-full items-end justify-center sm:items-center sm:p-4">
        <div
          class="absolute inset-0 bg-black/30 backdrop-blur-[2px] dark:bg-black/60"
          phx-click="processes_start_close"
          aria-hidden="true"
        >
        </div>
        <section
          tabindex="-1"
          autofocus
          class="relative flex max-h-[85dvh] w-full flex-col overflow-hidden rounded-t-3xl border border-b-0 border-base-300/70 bg-base-100 text-base-content shadow-2xl sm:max-w-lg sm:rounded-3xl sm:border-b"
        >
          <header class="flex items-start gap-3 border-b border-base-300/60 px-5 pt-5 pb-4">
            <span class="inline-flex size-10 shrink-0 items-center justify-center rounded-2xl bg-primary/10 text-primary">
              <.icon name="hero-play" class="size-5" />
            </span>
            <div class="min-w-0 flex-1">
              <h2 id="process-start-title" class="text-base font-semibold">
                {@start.process.name}
              </h2>
              <p class="text-xs text-base-content/60">{gettext("Start the process")}</p>
            </div>
            <.icon_button
              id="process-start-close"
              type="button"
              phx-click="processes_start_close"
              icon="hero-x-mark"
              label={gettext("Close")}
            />
          </header>
          <.form
            for={@start.form}
            id="process-start-form"
            phx-change="processes_start_validate"
            phx-submit="processes_start_save"
            class="space-y-3 overflow-y-auto px-5 py-4"
          >
            <p
              :if={@start.error}
              id="process-start-error"
              class="rounded-xl bg-error/10 px-3 py-2 text-sm text-error"
            >
              {@start.error}
            </p>
            <%= if @start.attributes do %>
              <EntityFields.fields
                prefix="start"
                id_prefix="process-start-field"
                attributes={@start.attributes}
                types={@start.types}
                params={@start.params}
                error={@start.error_at}
                add="processes_start_add"
                remove="processes_start_remove"
              />
            <% else %>
              <.input
                field={@start.form[:title]}
                type="text"
                label={gettext("Title")}
                maxlength="120"
                required
              />
              <.input
                field={@start.form[:text]}
                type="textarea"
                rows="4"
                maxlength="2000"
                label={gettext("Text")}
              />
            <% end %>
            <div class="flex justify-end gap-2 pt-1">
              <.button type="button" phx-click="processes_start_close" variant="ghost" size="sm">
                {gettext("Cancel")}
              </.button>
              <.button id="process-start-submit" type="submit" variant="primary" size="sm">
                <.icon name="hero-play" class="size-4" />
                {gettext("Start")}
              </.button>
            </div>
          </.form>
        </section>
      </div>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ProcessStartDialog">
      export default {
        mounted() {
          // Escape and Android's back button close it through the server.
          this.el.addEventListener("cancel", event => {
            event.preventDefault()
            this.pushEvent("processes_start_close", {})
          })

          this.el.showModal()
        },

        updated() {
          if (!this.el.open) this.el.showModal()
        },
      }
    </script>
    """
  end

  # How many instances are in each state, those under way first.
  defp count_labels(counts) do
    for status <- [:running, :waiting, :failed, :done, :cancelled],
        n = Map.get(counts, status, 0),
        n > 0,
        do: {status, count_label(status, n)}
  end

  defp count_label(:running, n), do: gettext("Running: %{count}", count: n)
  defp count_label(:waiting, n), do: gettext("Waiting: %{count}", count: n)
  defp count_label(:failed, n), do: gettext("Failed: %{count}", count: n)
  defp count_label(:done, n), do: gettext("Done: %{count}", count: n)
  defp count_label(:cancelled, n), do: gettext("Cancelled: %{count}", count: n)

  defp count_class(:running), do: "bg-primary/10 text-primary"
  defp count_class(:waiting), do: "bg-amber-500/15 text-amber-800 dark:text-amber-200"
  defp count_class(:failed), do: "bg-error/10 text-error"
  defp count_class(:done), do: "bg-success/10 text-success"
  defp count_class(:cancelled), do: "bg-base-200 text-base-content/65"

  # Why an instance stopped (`Processes.Engine`), in words.
  defp failure_reason("not_permitted"), do: gettext("the process lacks a permission")

  defp failure_reason("not_a_member_of_group"),
    do: gettext("the process is not a member of that group")

  defp failure_reason("not_process_group"),
    do: gettext("the process may not write in that group")

  defp failure_reason("no_admin"), do: gettext("nobody to run the sub-group")
  defp failure_reason("no_subgroup"), do: gettext("its sub-group is gone")
  defp failure_reason("empty_text"), do: gettext("the text came out empty")
  defp failure_reason("invalid_push"), do: gettext("the push text does not fit")
  defp failure_reason("process_inactive"), do: gettext("the process was stopped")
  defp failure_reason("loop"), do: gettext("it went round without waiting")
  defp failure_reason("too_many_steps"), do: gettext("it took too many steps")
  defp failure_reason("crash"), do: gettext("an unexpected error")
  defp failure_reason("too_deep"), do: gettext("processes called each other too deep")
  defp failure_reason("too_many_runs"), do: gettext("the process called has too many runs")
  defp failure_reason("call_cancelled"), do: gettext("the process it called was cancelled")
  defp failure_reason("call_inactive"), do: gettext("the process it calls is off")
  defp failure_reason("call_unknown"), do: gettext("the process it calls is gone")
  defp failure_reason("not_a_number"), do: gettext("it counted with what is no number")
  defp failure_reason("division_by_zero"), do: gettext("it divided by zero")
  defp failure_reason("number_too_large"), do: gettext("a number grew too large")
  defp failure_reason("not_a_list"), do: gettext("it took for a list what is none")
  defp failure_reason("not_a_date"), do: gettext("it took for a day what is none")
  defp failure_reason("bad_expression"), do: gettext("an expression could not be read")
  defp failure_reason("not_an_option"), do: gettext("a choice got what it does not list")
  defp failure_reason("not_a_boolean"), do: gettext("a yes or no got something else")
  defp failure_reason("not_a_datetime"), do: gettext("it took for a time what is none")
  defp failure_reason("not_a_text"), do: gettext("a text got what is none")
  defp failure_reason("not_an_entity"), do: gettext("an entity got what is none")
  defp failure_reason("too_many_items"), do: gettext("a list grew past 200 items")
  defp failure_reason("too_much_data"), do: gettext("its variables grew too large")
  defp failure_reason("too_many_fields"), do: gettext("the group has 50 fields already")
  defp failure_reason("invalid_field"), do: gettext("the field's name is not right")
  defp failure_reason("poll_gone"), do: gettext("its poll was deleted")
  defp failure_reason("invalid_poll"), do: gettext("its poll could not be put to the vote")

  defp failure_reason("effect_not_permitted"),
    do: gettext("it may not hand a decision on roles to the group")

  defp failure_reason("not_a_member"), do: gettext("the member it names is not in the group")
  defp failure_reason("no_starter"), do: gettext("nobody started the run")
  defp failure_reason(_reason), do: gettext("an error")

  @doc "The permissions a process lacks, in words."
  def missing_permissions(missing) do
    Enum.map_join(missing, ", ", &RolesTab.permission_label(String.to_existing_atom(&1)))
  end

  # A field's type as the entity editor names it.
  defp field_type_label(type) do
    PotokIdeWeb.GroupLive.Show.ProcessEntities.type_options([])
    |> Enum.find_value(type, fn {label, value} -> if value == type, do: label end)
  end
end
