defmodule PotokIdeWeb.GroupLive.Show.ProcessesTab do
  @moduledoc """
  The group's Processes tab (`ProcessesState`): what waits on the viewer, then
  the processes of each app, those it writes into its rules and those drawn
  in Potok, with how their instances are doing.
  """

  use PotokIdeWeb, :html

  alias PotokIde.Social.ValueRules
  alias PotokIde.Social.DrawnProcesses
  alias PotokIdeWeb.GroupLive.Show.{Components, ProcessEditor, ProcessEditorState, RolesTab}

  attr :group, :map, required: true
  attr :access, :any, required: true
  attr :current_profile, :map, required: true
  attr :apps, :list, required: true, doc: "`%{id, name, entries}`, see `ProcessesState`"
  attr :tasks, :list, required: true, doc: "from `Processes.tasks_for/3`"

  attr :can_draw?, :boolean,
    default: false,
    doc: "whether the viewer may draw, on an app the group has"

  attr :editor, :map, default: nil, doc: "the drawing open over the tab (`ProcessEditorState`)"
  attr :editor_form, :any, default: nil
  attr :editor_meta, :any, default: nil
  attr :start, :map, default: nil, doc: "`%{process, form, error}` while someone starts a process"

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
      </Components.tab_body>

      <.start_dialog start={@start} />

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
        <p :if={@task.text} class="line-clamp-4 whitespace-pre-line break-words text-base-content/80">
          {@task.text}
        </p>
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
        <span class="font-semibold">{entry.by.username || gettext("someone")}</span> → {entry.outcome}
        <span :if={entry.comment} class="italic">„{entry.comment}“</span>
      </li>
    </ol>

    <.form
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

    Enum.join([start, owner], " · ")
  end

  attr :start, :map, default: nil, doc: "`%{process, form, error}` while someone starts a process"

  # Starting a process by hand: a title and a text its steps can put in.
  defp start_dialog(assigns) do
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
  defp failure_reason(_reason), do: gettext("an error")

  @doc "The permissions a process lacks, in words."
  def missing_permissions(missing) do
    Enum.map_join(missing, ", ", &RolesTab.permission_label(String.to_existing_atom(&1)))
  end
end
