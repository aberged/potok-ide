defmodule PotokIdeWeb.GroupLive.Show.ProcessEditor do
  @moduledoc """
  The process editor over the Processes tab (`ProcessEditorState`): a bar
  with the name and the actions, the canvas (`ProcessCanvas`), and a panel
  with the step or flow picked on it, a sheet on a phone and a column beside
  the canvas on a wide screen. With nothing picked the panel holds the data
  of the process: what set it going, its variables, what its steps bring
  back and the entities of the group.
  """

  use PotokIdeWeb, :html

  alias PotokIde.Processes.{Graph, GraphEdit, Triggers, Types}
  alias PotokIdeWeb.GroupLive.Show.{ProcessEditorState, ProcessEntities}

  attr :editor, :map, required: true
  attr :form, :any, required: true
  attr :meta, :any, required: true
  attr :group, :map, required: true
  attr :access, :any, required: true

  def editor(assigns) do
    roles = ProcessEditorState.role_labels(assigns.access)

    assigns =
      assigns
      |> assign(:roles, roles)
      |> assign(:start_title, ProcessEditorState.start_title(assigns.editor, roles))
      |> assign(:role_options, role_options(assigns.access))
      |> assign(
        :canvas_state,
        Jason.encode!(ProcessEditorState.canvas_state(assigns.editor, assigns.access))
      )
      |> assign(
        :panel?,
        assigns.editor.selected != nil or assigns.editor.inserting != nil or
          assigns.editor[:data?] == true
      )

    ~H"""
    <%!-- Out of the page's column, which holds fixed elements, and above the menu. --%>
    <.layer id="process-editor-portal">
      <div
        id="process-editor"
        class="fixed inset-0 z-[150] flex flex-col bg-base-100 pt-(--app-safe-area-top)"
        role="dialog"
        aria-modal="true"
        aria-labelledby="process-editor-name"
      >
        <header class="shrink-0 border-b border-base-300/70 bg-base-100/95 px-2 py-2 backdrop-blur sm:px-3">
          <div class="flex items-center gap-2">
            <.icon_button
              id="process-editor-close"
              type="button"
              phx-click="process_editor_close"
              data-confirm={
                if(@editor.dirty? and @editor.editable? and @editor.source != :new,
                  do: gettext("Leave without saving the drawing?")
                )
              }
              icon="hero-arrow-left"
              label={gettext("Back to the processes")}
            />

            <.form
              for={@meta}
              id="process-editor-meta"
              phx-change="process_editor_meta"
              phx-submit="process_editor_save"
              class="min-w-0 flex-1"
            >
              <input
                id="process-editor-name"
                name={@meta[:name].name}
                value={@meta[:name].value}
                maxlength="60"
                disabled={!@editor.editable?}
                phx-debounce="300"
                aria-label={gettext("Name of the process")}
                class="w-full min-w-0 rounded-xl border border-transparent bg-transparent px-2 py-1.5 text-base font-semibold transition hover:border-base-300 focus:border-primary focus:outline-none disabled:hover:border-transparent"
              />
            </.form>

            <.button
              :if={@editor.editable?}
              id="process-editor-save"
              type="button"
              phx-click="process_editor_save"
              disabled={
                @editor.error != nil or not (@editor.dirty? or @editor.stale?) or
                  (@editor.trigger == "value" and @editor.collection == nil)
              }
              variant="primary"
              size="sm"
            >
              <.icon name="hero-check" class="size-4" />
              {gettext("Save")}
            </.button>
          </div>

          <div class="mt-1 flex flex-wrap items-center gap-1.5 pl-1 sm:pl-11">
            <%= if @editor.source == :new do %>
              <label class="inline-flex items-center gap-1.5 text-xs text-base-content/60">
                {gettext("When")}
                <select
                  id="process-editor-trigger"
                  form="process-editor-meta"
                  name={@meta[:trigger].name}
                  aria-label={gettext("What starts the process")}
                  class="select select-sm w-auto max-w-60 rounded-xl"
                >
                  <option
                    :for={trigger <- trigger_options(@editor)}
                    value={trigger}
                    selected={trigger == @editor.trigger}
                  >
                    {ProcessEditorState.trigger_name(trigger)}
                  </option>
                </select>
              </label>
              <select
                :if={@editor.trigger == "value" and length(@editor.apps) > 1}
                id="process-editor-app"
                form="process-editor-meta"
                name={@meta[:app].name}
                aria-label={gettext("App")}
                class="select select-sm w-auto max-w-44 rounded-xl"
              >
                <option
                  :for={app <- @editor.apps}
                  value={if(app.alt_id, do: app.alt_id, else: "default")}
                  selected={app.alt_id == @editor.alt_id}
                >
                  {app.name || gettext("Group description")}
                </option>
              </select>
              <label
                :if={@editor.trigger == "value"}
                class="inline-flex items-center gap-1.5 text-xs text-base-content/60"
              >
                <select
                  id="process-editor-collection"
                  form="process-editor-meta"
                  name={@meta[:collection].name}
                  aria-label={gettext("Collection")}
                  class="select select-sm w-auto max-w-44 rounded-xl"
                >
                  <option :if={@editor.collections == []} value="">
                    {gettext("No collection yet")}
                  </option>
                  <option :for={c <- @editor.collections} value={c} selected={c == @editor.collection}>
                    {c}
                  </option>
                </select>
              </label>
            <% else %>
              <span
                id="process-editor-trigger-summary"
                class="inline-flex h-7 min-w-0 max-w-60 items-center gap-1 rounded-full bg-base-200 px-2.5 text-xs text-base-content/70"
                title={@start_title}
              >
                <.icon name={trigger_icon(@editor.trigger)} class="size-3.5 shrink-0" />
                <span class="truncate">{@editor.collection || @start_title}</span>
              </span>
              <span
                id="process-editor-state"
                class={[
                  "inline-flex h-7 items-center gap-1.5 rounded-full px-2.5 text-xs font-semibold",
                  if(@editor.active?,
                    do: "bg-emerald-500/15 text-emerald-700 dark:text-emerald-300",
                    else: "bg-base-200 text-base-content/60"
                  )
                ]}
              >
                <span class={[
                  "size-1.5 rounded-full",
                  if(@editor.active?, do: "animate-pulse bg-emerald-500", else: "bg-base-content/40")
                ]} />
                {if(@editor.active?, do: gettext("on"), else: gettext("off"))}
              </span>
            <% end %>

            <span class="flex-1" />

            <%!-- An icon alone: the row holds the state and the switch beside it on a phone. --%>
            <.icon_button
              :if={@editor.editable?}
              id="process-editor-data"
              type="button"
              phx-click="process_editor_data"
              icon="hero-cube"
              label={gettext("Data of the process")}
              class="lg:hidden"
            />

            <.button
              :if={@editor.editable?}
              id="process-editor-relayout"
              type="button"
              phx-click="process_editor_relayout"
              variant="ghost"
              size="sm"
              class="max-lg:hidden"
            >
              <.icon name="hero-sparkles" class="size-4" />
              {gettext("Lay out again")}
            </.button>

            <%= if @editor.editable? and @editor.source == :drawn do %>
              <.button
                :if={!@editor.active?}
                id="process-editor-activate"
                type="button"
                phx-click="process_editor_activate"
                disabled={@editor.dirty? or @editor.error != nil}
                variant="soft"
                size="sm"
              >
                <.icon name="hero-play" class="size-4" />
                {gettext("Switch on")}
              </.button>
              <.button
                :if={@editor.active?}
                id="process-editor-deactivate"
                type="button"
                phx-click="process_editor_deactivate"
                data-confirm={gettext("Switch it off? What runs or waits is cancelled.")}
                variant="ghost"
                size="sm"
              >
                <.icon name="hero-pause" class="size-4" />
                {gettext("Switch off")}
              </.button>
              <.icon_button
                id="process-editor-destroy"
                type="button"
                phx-click="process_editor_destroy"
                data-confirm={gettext("Delete this process with all its runs? What it wrote stays.")}
                icon="hero-trash"
                label={gettext("Delete the process")}
              />
            <% end %>
          </div>
        </header>

        <div
          :if={@editor.source == :app}
          id="process-editor-readonly"
          class="shrink-0 border-b border-base-300/60 bg-base-200/60 px-4 py-2 text-xs text-base-content/70"
        >
          <.icon name="hero-lock-closed" class="mr-1 size-3.5 align-[-2px]" />
          {gettext("The app draws this process and changes it in its own settings.")}
        </div>

        <div
          :if={@editor.source == :drawn and !@editor.editable?}
          id="process-editor-readonly"
          class="shrink-0 border-b border-base-300/60 bg-base-200/60 px-4 py-2 text-xs text-base-content/70"
        >
          <.icon name="hero-eye" class="mr-1 size-3.5 align-[-2px]" />
          {gettext("Only the app's editors change this drawing.")}
        </div>

        <div
          :if={@editor.conflict}
          id="process-editor-conflict"
          class="flex shrink-0 flex-wrap items-center gap-2 border-b border-amber-500/30 bg-amber-500/10 px-4 py-2 text-sm"
        >
          <.icon name="hero-users" class="size-4 text-amber-600" />
          <span class="flex-1">{gettext("Someone else saved this process meanwhile.")}</span>
          <.button
            id="process-editor-take-theirs"
            type="button"
            phx-click="process_editor_take_theirs"
            variant="ghost"
            size="sm"
          >
            {gettext("Load theirs")}
          </.button>
          <.button
            id="process-editor-keep-mine"
            type="button"
            phx-click="process_editor_keep_mine"
            variant="soft"
            size="sm"
          >
            {gettext("Keep mine")}
          </.button>
        </div>

        <div
          :if={@editor[:upgraded?] && @editor.editable?}
          id="process-editor-upgraded"
          class="flex shrink-0 items-center gap-2 border-b border-sky-500/25 bg-sky-500/10 px-4 py-2 text-sm"
        >
          <.icon name="hero-sparkles" class="size-4 shrink-0 text-sky-600 dark:text-sky-300" />
          <span class="min-w-0 flex-1">
            {gettext(
              "This drawing now reads what started it as %{example}, and its conditions are expressions. Look it over and save it.",
              example: "{{#{PotokIde.Processes.Graph.start(@editor.graph)}.…}}"
            )}
          </span>
        </div>

        <div
          :if={@editor.stale? && @editor.editable?}
          id="process-editor-stale"
          class="flex shrink-0 items-center gap-2 border-b border-amber-500/30 bg-amber-500/10 px-4 py-2 text-sm"
        >
          <.icon name="hero-arrow-path" class="size-4 shrink-0 text-amber-600 dark:text-amber-300" />
          <span class="min-w-0 flex-1">
            {gettext(
              "What this drawing was saved with has changed: an entity, a process it calls or a signal. Look it over and save it."
            )}
          </span>
        </div>

        <div
          :if={@editor.error && @editor.editable?}
          id="process-editor-error"
          class="flex shrink-0 items-center gap-2 border-b border-error/20 bg-error/10 px-4 py-2 text-sm text-base-content"
        >
          <.icon name="hero-exclamation-circle" class="size-4 shrink-0 text-error" />
          <span class="min-w-0 flex-1">{@editor.error.message}</span>
          <.button
            :if={@editor.error.target}
            id="process-editor-error-show"
            type="button"
            phx-click="process_editor_select"
            phx-value-node={target_node(@editor.error.target)}
            phx-value-flow={target_flow(@editor.error.target)}
            variant="ghost"
            size="sm"
          >
            {gettext("Show me")}
          </.button>
        </div>

        <div class="relative flex min-h-0 flex-1">
          <div
            id="process-canvas"
            phx-hook="ProcessCanvas"
            phx-update="ignore"
            data-state={@canvas_state}
            data-editable={to_string(@editor.editable?)}
            class="relative min-h-0 flex-1 bg-base-200/40 [background-image:radial-gradient(color-mix(in_oklab,var(--color-base-content)_12%,transparent)_1px,transparent_1px)] [background-size:20px_20px]"
          >
          </div>

          <aside
            id="process-panel"
            class={[
              "z-[151] flex flex-col bg-base-100",
              "max-lg:fixed max-lg:inset-x-0 max-lg:bottom-0 max-lg:max-h-[72dvh] max-lg:rounded-t-3xl max-lg:border-t max-lg:border-base-300 max-lg:pb-(--app-safe-area-bottom) max-lg:shadow-2xl",
              "max-lg:transition-transform max-lg:duration-200",
              "lg:w-96 lg:shrink-0 lg:border-l lg:border-base-300/70",
              if(@panel?,
                do: "max-lg:translate-y-0",
                else: "max-lg:pointer-events-none max-lg:translate-y-full"
              )
            ]}
          >
            <div class="mx-auto mt-2 h-1.5 w-10 shrink-0 rounded-full bg-base-300 lg:hidden" />
            <div class="min-h-0 flex-1 overflow-y-auto overscroll-contain p-4">
              <%= cond do %>
                <% @editor.inserting -> %>
                  <.insert_menu />
                <% match?({:node, _}, @editor.selected) and @form -> %>
                  <.node_panel
                    editor={@editor}
                    form={@form}
                    roles={@roles}
                    role_options={@role_options}
                    start_title={@start_title}
                  />
                <% match?({:flow, _}, @editor.selected) and @form -> %>
                  <.flow_panel editor={@editor} form={@form} />
                <% @editor.editable? -> %>
                  <.data_panel editor={@editor} />
                <% true -> %>
                  <.hint editor={@editor} />
              <% end %>
            </div>
          </aside>
        </div>

        <ol id="process-outline" class="sr-only">
          <li :for={node <- @editor.graph["nodes"]} id={"process-outline-#{node["id"]}"}>
            <% {_kind, _icon, title, detail} =
              ProcessEditorState.describe(node, @editor.graph, @roles,
                start: @start_title,
                processes: ProcessEditorState.process_names(@editor)
              ) %>
            {title}<span :if={detail}> · {detail}</span>
          </li>
        </ol>
      </div>
    </.layer>
    """
  end

  attr :id, :string, required: true
  slot :inner_block, required: true

  # In the body, above the page's menu and bars, as a browser shows it; in
  # place where portals are off (`config/test.exs`).
  defp layer(assigns) do
    if Application.get_env(:potok_ide, :portals, true) do
      ~H"""
      <.portal id={@id} target="body">{render_slot(@inner_block)}</.portal>
      """
    else
      ~H"""
      {render_slot(@inner_block)}
      """
    end
  end

  defp target_node({:node, id}), do: id
  defp target_node(_target), do: nil
  defp target_flow({:flow, key}), do: key
  defp target_flow(_target), do: nil

  attr :editor, :map, required: true

  # The data of the process: every name its texts and conditions may use,
  # with the type of what it stands for, and the entities of the group.
  defp data_panel(assigns) do
    assigns =
      assigns
      |> assign(:data, ProcessEditorState.data(assigns.editor))
      |> assign(:entities, assigns.editor[:entities] || [])
      # The public processes of other groups it may call, with the entity
      # each takes: theirs, so only to be read here.
      |> assign(
        :taken,
        for(p <- assigns.editor[:callable] || [], p.group && p.attributes != [], do: p)
      )

    ~H"""
    <div id="process-data-panel" class="space-y-5">
      <div class="flex items-start justify-between gap-2">
        <div class="min-w-0">
          <h2 class="flex items-center gap-2 text-base font-semibold">
            <.icon name="hero-cube" class="size-5 shrink-0 text-base-content/60" />
            {gettext("Data of the process")}
          </h2>
          <p class="mt-0.5 text-xs text-base-content/60">
            {gettext("What its texts and conditions may name, and what each holds.")}
          </p>
        </div>
        <.icon_button
          id="process-panel-close"
          type="button"
          phx-click="process_editor_deselect"
          icon="hero-x-mark"
          label={gettext("Close")}
          class="lg:hidden"
        />
      </div>

      <.data_section
        :if={@data.entry != []}
        id="process-data-entry"
        icon="hero-play-circle"
        title={gettext("What starts it")}
      >
        <.names rows={@data.entry} entities={@entities} />
      </.data_section>

      <.data_section id="process-data-variables" icon="hero-variable" title={gettext("Variables")}>
        <p class="mb-2 text-xs text-base-content/60">
          {gettext("What a run keeps for itself: a step sets them, and every step after reads them.")}
        </p>
        <.form
          :if={@data.variables != []}
          for={%{}}
          as={:variables}
          id="process-variables-form"
          phx-change="process_editor_variables"
          class="space-y-2"
        >
          <.variable_row
            :for={{variable, i} <- Enum.with_index(@data.variables)}
            variable={variable}
            index={i}
            entities={@entities}
          />
        </.form>
        <.button
          :if={length(@data.variables) < 30}
          id="process-variable-add"
          type="button"
          phx-click="process_editor_var_add"
          variant="ghost"
          size="sm"
          class="mt-1"
        >
          <.icon name="hero-plus" class="size-4" />
          {gettext("Add a variable")}
        </.button>
      </.data_section>

      <.data_section
        :if={@data.results != []}
        id="process-data-results"
        icon="hero-arrow-uturn-left"
        title={gettext("What its steps bring back")}
      >
        <.names rows={@data.results} entities={@entities} />
      </.data_section>

      <.data_section
        :if={@data.group != []}
        id="process-data-group"
        icon="hero-pencil-square"
        title={gettext("Fields of the group")}
      >
        <.names rows={@data.group} entities={@entities} />
      </.data_section>

      <.data_section
        :if={@taken != []}
        id="process-data-taken"
        icon="hero-globe-alt"
        title={gettext("What public processes take")}
      >
        <ul class="space-y-1.5">
          <li
            :for={process <- @taken}
            id={"process-data-taken-#{process.id}"}
            class="rounded-2xl border border-base-300/70 bg-base-100 px-3 py-2"
          >
            <p class="truncate text-sm font-semibold">
              {process.name}
              <span class="font-normal text-base-content/55">· {process.group}</span>
            </p>
            <p class="mt-1 flex flex-wrap gap-1">
              <span
                :for={attribute <- process.attributes}
                class="inline-flex items-baseline gap-1 rounded-full bg-violet-500/10 px-2 py-0.5 text-[11px]"
              >
                <code class="font-mono text-violet-700 dark:text-violet-300">
                  {attribute["name"]}
                </code>
                <span class="text-base-content/55">
                  {ProcessEntities.type_words(Types.of(attribute), @entities)}
                </span>
              </span>
            </p>
          </li>
        </ul>
      </.data_section>

      <.data_section
        id="process-data-entities"
        icon="hero-cube"
        title={gettext("Entities of the group")}
      >
        <p :if={@entities == []} class="text-xs text-base-content/60">
          {gettext(
            "None yet. An entity says what a variable holds: a name, and attributes with their types."
          )}
        </p>
        <ul :if={@entities != []} class="space-y-1.5">
          <li
            :for={entity <- @entities}
            id={"process-data-entity-#{entity.id}"}
            class="flex items-start gap-2 rounded-2xl border border-base-300/70 bg-base-100 px-3 py-2"
          >
            <div class="min-w-0 flex-1">
              <p class="truncate text-sm font-semibold">{entity.name}</p>
              <p class="mt-1 flex flex-wrap gap-1">
                <span
                  :for={attribute <- entity.attributes}
                  class="inline-flex items-baseline gap-1 rounded-full bg-violet-500/10 px-2 py-0.5 text-[11px]"
                >
                  <code class="font-mono text-violet-700 dark:text-violet-300">{attribute.name}</code>
                  <span class="text-base-content/55">
                    {ProcessEntities.type_label(attribute, @entities)}
                  </span>
                </span>
              </p>
            </div>
            <.icon_button
              id={"process-data-entity-#{entity.id}-edit"}
              type="button"
              phx-click="processes_entity_edit"
              phx-value-id={entity.id}
              icon="hero-pencil-square"
              label={gettext("Change the entity")}
            />
          </li>
        </ul>
        <.button
          id="process-data-entity-new"
          type="button"
          phx-click="processes_entity_new"
          variant="ghost"
          size="sm"
          class="mt-1"
        >
          <.icon name="hero-plus" class="size-4" />
          {gettext("New entity")}
        </.button>
      </.data_section>

      <details class="group rounded-2xl border border-base-300/70 px-3 py-2 text-sm text-base-content/70">
        <summary class="flex cursor-pointer list-none items-center gap-2 font-semibold text-base-content">
          <.icon
            name="hero-chevron-right"
            class="size-4 transition-transform duration-200 group-open:rotate-90"
          />
          {gettext("How to draw")}
        </summary>
        <div class="mt-2 space-y-2">
          <p class="lg:hidden">
            {gettext("Tap + on an arrow to add a step, and a step or an arrow to change it.")}
          </p>
          <p class="max-lg:hidden">
            {gettext(
              "Click + on an arrow to add a step. Drag the steps where you like them, and drag from the dot under a step to another step to draw an arrow. Click a step or an arrow to change it."
            )}
          </p>
          <p>{gettext("Save a drawing, then switch it on.")}</p>
        </div>
      </details>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  slot :inner_block, required: true

  defp data_section(assigns) do
    ~H"""
    <section id={@id}>
      <h3 class="mb-1.5 flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/55">
        <.icon name={@icon} class="size-3.5" />
        {@title}
      </h3>
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :rows, :list, required: true, doc: "`{path, type}`, the type as a term"
  attr :entities, :list, required: true

  # Names as an expression writes them, each with what it holds.
  defp names(assigns) do
    ~H"""
    <ul class="flex flex-wrap gap-1">
      <li
        :for={{path, type} <- @rows}
        class="inline-flex items-baseline gap-1 rounded-full bg-base-200 px-2 py-0.5 text-[11px]"
      >
        <code class="font-mono text-base-content/80">{path}</code>
        <span class="text-base-content/50">{ProcessEntities.type_words(type, @entities)}</span>
      </li>
    </ul>
    """
  end

  attr :variable, :map, required: true
  attr :index, :integer, required: true
  attr :entities, :list, required: true

  # One variable: its name, the type of what it holds, and what it starts with.
  defp variable_row(assigns) do
    assigns =
      assigns
      |> assign(:name, "variables[#{assigns.index}]")
      |> assign(:type, assigns.variable["type"] || "text")
      |> assign(:list?, assigns.variable["list"] == true)

    ~H"""
    <div
      id={"process-variable-#{@index}"}
      class="space-y-2 rounded-2xl border border-base-300/70 bg-base-100 p-2.5 transition-shadow duration-200 focus-within:shadow-sm"
    >
      <div class="flex items-start gap-1.5">
        <div class="grid min-w-0 flex-1 grid-cols-2 gap-1.5">
          <input
            type="text"
            id={"process-variable-#{@index}-name"}
            name={"#{@name}[name]"}
            value={@variable["name"]}
            maxlength="40"
            phx-debounce="400"
            aria-label={gettext("Name of the variable")}
            class="input input-sm w-full font-mono"
          />
          <select
            id={"process-variable-#{@index}-type"}
            name={"#{@name}[type]"}
            aria-label={gettext("Type")}
            class="select select-sm w-full"
          >
            {Phoenix.HTML.Form.options_for_select(
              ProcessEntities.type_options(@entities, gettext("Entity")),
              @type
            )}
          </select>
        </div>
        <.icon_button
          id={"process-variable-#{@index}-remove"}
          type="button"
          phx-click="process_editor_var_remove"
          phx-value-index={@index}
          icon="hero-minus-circle"
          label={gettext("Remove the variable")}
        />
      </div>
      <select
        :if={@type == "entity"}
        id={"process-variable-#{@index}-entity"}
        name={"#{@name}[entity]"}
        aria-label={gettext("Which entity")}
        class="select select-sm w-full"
      >
        <option value="">{gettext("Pick an entity")}</option>
        {Phoenix.HTML.Form.options_for_select(
          for(entity <- @entities, do: {entity.name, entity.id}),
          @variable["entity"]
        )}
      </select>
      <input
        :if={@type == "choice"}
        type="text"
        id={"process-variable-#{@index}-options"}
        name={"#{@name}[options]"}
        value={Enum.join(@variable["options"] || [], ", ")}
        placeholder={gettext("low, medium, high")}
        phx-debounce="400"
        aria-label={gettext("What it may be")}
        class="input input-sm w-full"
      />
      <div class="flex items-center gap-2">
        <input type="hidden" name={"#{@name}[list]"} value="false" />
        <label class="flex shrink-0 items-center gap-1.5 text-xs">
          <input
            type="checkbox"
            id={"process-variable-#{@index}-list"}
            name={"#{@name}[list]"}
            value="true"
            checked={@list?}
            class="checkbox checkbox-xs"
          />
          {gettext("A list")}
        </label>
        <input
          :if={@type != "entity" and not @list?}
          type="text"
          id={"process-variable-#{@index}-initial"}
          name={"#{@name}[initial]"}
          value={@variable["initial"]}
          maxlength="1000"
          placeholder={gettext("starts with")}
          phx-debounce="400"
          aria-label={gettext("What it starts with")}
          class="input input-sm min-w-0 flex-1 font-mono"
        />
      </div>
    </div>
    """
  end

  attr :editor, :map, required: true

  defp hint(assigns) do
    ~H"""
    <div id="process-panel-hint" class="space-y-3 text-sm text-base-content/70">
      <h2 class="text-base font-semibold text-base-content">{gettext("The drawing")}</h2>
      <p>{gettext("Tap a step or an arrow to see what it does.")}</p>
    </div>
    """
  end

  defp insert_menu(assigns) do
    assigns = assign(assigns, :kinds, insert_kinds())

    ~H"""
    <div id="process-insert-menu">
      <div class="mb-3 flex items-center justify-between">
        <h2 class="text-base font-semibold">{gettext("Add a step")}</h2>
        <.icon_button
          id="process-insert-cancel"
          type="button"
          phx-click="process_editor_insert_cancel"
          icon="hero-x-mark"
          label={gettext("Close")}
        />
      </div>
      <div class="grid gap-2 sm:grid-cols-2 lg:grid-cols-1">
        <button
          :for={{kind, icon, title, text, tone} <- @kinds}
          id={"process-insert-#{kind}"}
          type="button"
          phx-click="process_editor_insert"
          phx-value-kind={kind}
          class="group flex items-start gap-3 rounded-2xl border border-base-300/70 bg-base-100 p-3 text-left shadow-xs transition duration-150 hover:-translate-y-0.5 hover:border-primary/40 hover:shadow-md active:scale-[0.98]"
        >
          <span class={["grid size-10 shrink-0 place-items-center rounded-xl", tone]}>
            <.icon name={icon} class="size-5" />
          </span>
          <span class="min-w-0">
            <span class="block text-sm font-semibold">{title}</span>
            <span class="block text-xs text-base-content/60">{text}</span>
          </span>
        </button>
      </div>
    </div>
    """
  end

  @doc """
  The steps a process is drawn from, as the menu under **+** offers them:
  `{kind, icon, name, what it does, classes}`. The help's page on processes
  names them from here (`PotokIdeWeb.HelpGuides.step_names/0`).
  """
  def insert_kinds do
    [
      {"message", "hero-chat-bubble-left-ellipsis", gettext("Message"),
       gettext("Writes in the group's chat, or in a sub-group the process made."),
       "bg-sky-500/10 text-sky-600 dark:text-sky-300"},
      {"subgroup", "hero-folder-plus", gettext("Sub-group"),
       gettext("Opens a sub-group for the value, to talk it over."),
       "bg-violet-500/10 text-violet-600 dark:text-violet-300"},
      {"task", "hero-hand-raised", gettext("Decision"),
       gettext("Waits for someone of a role to pick an outcome."),
       "bg-amber-500/15 text-amber-700 dark:text-amber-300"},
      {"form", "hero-clipboard-document-list", gettext("Form"),
       gettext("Waits for someone to fill in an entity, an attribute at a time."),
       "bg-emerald-500/10 text-emerald-700 dark:text-emerald-300"},
      {"push", "hero-bell-alert", gettext("Push"),
       gettext("Lets the people of a role know on their phones."),
       "bg-rose-500/10 text-rose-600 dark:text-rose-300"},
      {"timer", "hero-clock", gettext("Wait"), gettext("Waits a while before going on."),
       "bg-teal-500/10 text-teal-600 dark:text-teal-300"},
      {"gateway", "hero-arrows-right-left", gettext("Condition"),
       gettext("Goes one way or another by what was sent."),
       "bg-amber-500/10 text-amber-700 dark:text-amber-300"},
      {"loop", "hero-arrow-path", gettext("For each"),
       gettext("Goes through a list an item at a time, with steps of its own for each."),
       "bg-orange-500/10 text-orange-700 dark:text-orange-300"},
      {"set", "hero-pencil-square", gettext("Group field"),
       gettext("Keeps a value, or adds to a count, that every process of the group reads."),
       "bg-lime-500/10 text-lime-700 dark:text-lime-300"},
      {"assign", "hero-variable", gettext("Set a value"),
       gettext(
         "Sets a variable of the process, or an attribute of one, to what an expression gives."
       ), "bg-violet-500/10 text-violet-700 dark:text-violet-300"},
      {"signal", "hero-megaphone", gettext("Send a signal"),
       gettext(
         "Wakes the processes of the group that wait for it, and starts those that start on it."
       ), "bg-fuchsia-500/10 text-fuchsia-600 dark:text-fuchsia-300"},
      {"receive", "hero-signal", gettext("Wait for a signal"),
       gettext("Waits until another process of the group sends it."),
       "bg-cyan-500/10 text-cyan-700 dark:text-cyan-300"},
      {"call", "hero-arrow-top-right-on-square", gettext("Call a process"),
       gettext("Starts another process of the group, and waits for how it ends."),
       "bg-indigo-500/10 text-indigo-600 dark:text-indigo-300"}
    ]
  end

  attr :editor, :map, required: true
  attr :form, :any, required: true
  attr :roles, :map, required: true
  attr :role_options, :list, required: true
  attr :start_title, :string, required: true

  defp node_panel(assigns) do
    {:node, id} = assigns.editor.selected
    node = Graph.node(assigns.editor.graph, id)

    {kind, icon, title, _detail} =
      ProcessEditorState.describe(node, assigns.editor.graph, assigns.roles,
        start: assigns.start_title,
        processes: ProcessEditorState.process_names(assigns.editor)
      )

    assigns =
      assigns
      |> assign(node: node, kind: kind, icon: icon, title: title)
      |> assign(
        :subgroups,
        for(%{"action" => "subgroup"} = n <- assigns.editor.graph["nodes"], do: n)
      )
      |> assign(:outcome_flows, outcome_flows(assigns.editor.graph, node))
      |> assign(:callee, Enum.find(assigns.editor.callable, &(&1.id == node["process"])))
      |> assign(:condition_flows, condition_flows(assigns.editor.graph, node))
      |> assign(:targets, ProcessEditorState.assign_targets(assigns.editor))
      |> assign(
        :signal_entity,
        Enum.find(assigns.editor[:entities] || [], &(&1.id == node["entity"]))
      )
      |> assign(
        :textual?,
        ProcessEditorState.textual_target?(assigns.editor, node["target"], node["op"])
      )
      |> assign(:list_target?, ProcessEditorState.list_target?(assigns.editor, node["target"]))
      |> assign(:form_entities, ProcessEditorState.form_entities(assigns.editor))
      |> assign(:asked, asked_entity(assigns.editor, node))
      |> assign(:returned, ProcessEditorState.return_entity(assigns.editor))

    ~H"""
    <div id="process-node-panel">
      <div class="mb-3 flex items-center justify-between gap-2">
        <h2 class="flex min-w-0 items-center gap-2 text-base font-semibold">
          <.icon name={@icon} class="size-5 shrink-0 text-base-content/60" />
          <span class="truncate">{@title}</span>
        </h2>
        <div class="flex items-center gap-1">
          <.icon_button
            :if={@editor.editable? and @kind != "start"}
            id="process-node-delete"
            type="button"
            phx-click="process_editor_delete"
            icon="hero-trash"
            label={gettext("Delete this step")}
          />
          <.icon_button
            id="process-panel-close"
            type="button"
            phx-click="process_editor_deselect"
            icon="hero-x-mark"
            label={gettext("Close")}
          />
        </div>
      </div>

      <.form
        for={@form}
        id="process-element-form"
        phx-change="process_editor_change"
        phx-submit="process_editor_save"
        class="space-y-3"
      >
        <fieldset disabled={!@editor.editable?} class="space-y-3">
          <.input
            field={@form[:label]}
            type="text"
            label={gettext("Name on the drawing")}
            placeholder={@title}
            maxlength="60"
            phx-debounce="300"
          />

          <%= case @kind do %>
            <% "message" -> %>
              <.input
                field={@form[:text]}
                type="textarea"
                rows="3"
                maxlength="1000"
                label={gettext("Message")}
                phx-debounce="300"
              />
              <.fields editor={@editor} target="text" />
              <.input
                field={@form[:in]}
                type="select"
                label={gettext("Where")}
                options={
                  [{gettext("In the app's group"), "app"}] ++
                    for(s <- @subgroups, do: {Graph.label(s), s["id"]})
                }
              />
            <% "subgroup" -> %>
              <.input
                field={@form[:name]}
                type="text"
                maxlength="120"
                label={gettext("Name of the sub-group")}
                phx-debounce="300"
              />
              <.fields editor={@editor} target="name" />
              <fieldset class="fieldset">
                <legend class="label mb-1">{gettext("Who runs it")}</legend>
                <input type="hidden" name="element[admins][]" value="" />
                <label
                  :for={{label, key} <- admin_options(@role_options)}
                  class="flex items-center gap-2 py-0.5 text-sm"
                >
                  <input
                    type="checkbox"
                    name="element[admins][]"
                    value={key}
                    checked={key in (@node["admins"] || [])}
                    class="checkbox checkbox-sm"
                  />
                  {label}
                </label>
              </fieldset>
              <div id="process-subgroup-inheritance">
                <input type="hidden" name="element[inherits]" value="false" />
                <label class="flex items-center gap-2 py-0.5 text-sm">
                  <input
                    type="checkbox"
                    id="process-subgroup-inherits"
                    name="element[inherits]"
                    value="true"
                    checked={@node["inherits"] == true}
                    class="checkbox checkbox-sm"
                  />
                  {gettext("Inherit members")}
                </label>
                <p class="text-xs text-base-content/60">
                  {gettext(
                    "Every member of this group is also a member of the sub-group, with the same roles."
                  )}
                </p>
              </div>
              <fieldset
                :if={@node["inherits"] == true}
                id="process-subgroup-inherit-roles"
                class="fieldset"
              >
                <legend class="label mb-1">{gettext("Only members with one of these roles")}</legend>
                <input type="hidden" name="element[inherit_roles][]" value="" />
                <label
                  :for={{label, key} <- inherit_role_options(@role_options)}
                  id={"process-subgroup-inherit-role-#{key}"}
                  class="flex items-center gap-2 py-0.5 text-sm"
                >
                  <input
                    type="checkbox"
                    name="element[inherit_roles][]"
                    value={key}
                    checked={key in (@node["inherit_roles"] || [])}
                    class="checkbox checkbox-sm"
                  />
                  {label}
                </label>
                <p class="text-xs text-base-content/60">
                  {gettext(
                    "With none picked, every member comes in. Whoever comes in brings all their roles, and leaves on losing the last of the picked ones."
                  )}
                </p>
              </fieldset>
            <% "push" -> %>
              <.input
                field={@form[:role]}
                type="select"
                label={gettext("To the people of")}
                options={@role_options}
              />
              <.input
                field={@form[:text]}
                type="textarea"
                rows="2"
                maxlength="240"
                label={gettext("Text")}
                phx-debounce="300"
              />
              <.fields editor={@editor} target="text" />
            <% "task" -> %>
              <.input
                field={@form[:role]}
                type="select"
                label={gettext("Who decides")}
                options={@role_options}
              />
              <div>
                <p class="label mb-1">{gettext("Outcomes")}</p>
                <ul class="space-y-1.5">
                  <li :for={flow <- @outcome_flows} class="flex items-center gap-1.5">
                    <button
                      id={"process-outcome-#{flow["key"]}"}
                      type="button"
                      phx-click="process_editor_select"
                      phx-value-flow={flow["key"]}
                      class="flex-1 truncate rounded-xl border border-base-300 bg-base-100 px-3 py-1.5 text-left text-sm font-medium transition hover:border-primary/50"
                    >
                      {flow["outcome"]}
                    </button>
                    <.icon_button
                      :if={@editor.editable? and length(@outcome_flows) > 1}
                      id={"process-outcome-#{flow["key"]}-remove"}
                      type="button"
                      phx-click="process_editor_remove_flow"
                      phx-value-flow={flow["key"]}
                      icon="hero-minus-circle"
                      label={gettext("Remove the outcome")}
                    />
                  </li>
                </ul>
                <.button
                  :if={@editor.editable? and length(@outcome_flows) < 10}
                  id="process-add-outcome"
                  type="button"
                  phx-click="process_editor_add_branch"
                  phx-value-node={@node["id"]}
                  variant="ghost"
                  size="sm"
                  class="mt-1.5"
                >
                  <.icon name="hero-plus" class="size-4" />
                  {gettext("Add an outcome")}
                </.button>
              </div>
              <div>
                <p class="label mb-1">{gettext("Deadline, with a reminder")}</p>
                <div class="flex gap-2">
                  <.input
                    field={@form[:deadline_amount]}
                    type="number"
                    min="1"
                    placeholder={gettext("none")}
                    phx-debounce="400"
                  />
                  <.input field={@form[:deadline_unit]} type="select" options={unit_options()} />
                </div>
              </div>
            <% "form" -> %>
              <.input
                :if={@editor.editable? and @form_entities != []}
                field={@form[:entity]}
                type="select"
                label={gettext("What it asks for")}
                prompt={gettext("Pick an entity")}
                options={for(entity <- @form_entities, do: {entity.name, entity.id})}
              />
              <p
                :if={@editor.editable? and @form_entities == []}
                id="process-form-no-entity"
                class="rounded-xl bg-amber-500/10 px-3 py-2 text-xs text-amber-900 dark:text-amber-100"
              >
                {gettext("A form asks for an entity. Define one under Data first.")}
              </p>
              <p :if={!@editor.editable? and @asked} id="process-form-asks" class="text-sm">
                {gettext("It asks for %{entity}.", entity: @asked["name"])}
              </p>
              <.input
                field={@form[:who]}
                type="select"
                label={gettext("Who fills it in")}
                options={
                  [{gettext("Whoever started the run"), "starter"}] ++
                    for({label, key} <- @role_options, do: {label, "role:" <> key})
                }
              />
              <.input
                field={@form[:intro]}
                type="textarea"
                rows="2"
                maxlength="1000"
                label={gettext("What it says first")}
                placeholder={gettext("Tell us what broke, and we will send someone.")}
                phx-debounce="300"
              />
              <.fields editor={@editor} target="intro" />
              <div :if={@asked} id="process-form-values" class="space-y-2">
                <p class="label">{gettext("Already filled in")}</p>
                <div
                  :for={%{"name" => name} <- @asked["attributes"] || []}
                  id={"process-form-value-#{name}"}
                  class="space-y-1 rounded-2xl border border-base-300/70 bg-base-100 p-2"
                >
                  <p class="label">
                    {signal_field_label(@signal_entity, name, @editor[:entities] || [])}
                  </p>
                  <.input
                    type="text"
                    id={"process-form-value-#{name}-input"}
                    name={"element[form_values][#{name}]"}
                    value={(@node["values"] || %{})[name] || ""}
                    aria-label={gettext("Already filled in")}
                    placeholder={gettext("empty")}
                    maxlength="1000"
                    phx-debounce="300"
                  />
                  <.fields editor={@editor} target={"form_values.#{name}"} />
                </div>
                <p class="text-xs text-base-content/60">
                  {gettext(
                    "Whoever fills it in sees this already written, and may change it. Leave an attribute empty to have it asked."
                  )}
                </p>
              </div>
              <div>
                <p class="label mb-1">{gettext("Deadline, then go on without it")}</p>
                <div class="flex gap-2">
                  <.input
                    field={@form[:deadline_amount]}
                    type="number"
                    min="1"
                    placeholder={gettext("none")}
                    phx-debounce="400"
                  />
                  <.input field={@form[:deadline_unit]} type="select" options={unit_options()} />
                </div>
              </div>
              <p id="process-form-reads" class="text-xs text-base-content/60">
                {gettext(
                  "The steps after it read what was filled in an attribute at a time, as %{field}, and who filled it in as %{author}.",
                  field: "{{#{asked_path(@node, @asked)}}}",
                  author: "{{#{@node["id"]}.author}}"
                )}
              </p>
              <p id="process-form-where" class="text-xs text-base-content/60">
                {if(@node["by"] == "role",
                  do:
                    gettext(
                      "It waits for the people of the role on the Processes tab, under Waiting for you."
                    ),
                  else:
                    gettext(
                      "It opens by itself for whoever started the run, when they have just done what led to it. Otherwise it waits on the Processes tab, under Waiting for you."
                    )
                )}
              </p>
            <% "timer" -> %>
              <p class="label mb-1">{gettext("Wait for")}</p>
              <div class="flex gap-2">
                <.input field={@form[:duration_amount]} type="number" min="1" phx-debounce="400" />
                <.input field={@form[:duration_unit]} type="select" options={unit_options()} />
              </div>
            <% "gateway" -> %>
              <div>
                <p class="label mb-1">{gettext("Conditions, in order")}</p>
                <ul class="space-y-1.5">
                  <li :for={flow <- @condition_flows}>
                    <button
                      id={"process-condition-#{flow["key"]}"}
                      type="button"
                      phx-click="process_editor_select"
                      phx-value-flow={flow["key"]}
                      class="w-full truncate rounded-xl border border-base-300 bg-base-100 px-3 py-1.5 text-left text-sm font-medium transition hover:border-primary/50"
                    >
                      {ProcessEditorState.flow_label(flow)}
                    </button>
                  </li>
                </ul>
                <.button
                  :if={@editor.editable?}
                  id="process-add-condition"
                  type="button"
                  phx-click="process_editor_add_branch"
                  phx-value-node={@node["id"]}
                  variant="ghost"
                  size="sm"
                  class="mt-1.5"
                >
                  <.icon name="hero-plus" class="size-4" />
                  {gettext("Add a condition")}
                </.button>
              </div>
            <% "signal" -> %>
              <.input
                field={@form[:name]}
                type="text"
                label={gettext("Signal")}
                list="process-signal-list"
                maxlength="40"
                phx-debounce="400"
              />
              <datalist id="process-signal-list">
                <option :for={name <- Map.keys(@editor.signals)} value={name} />
              </datalist>
              <.signal_entity editor={@editor} form={@form} />
              <div id="process-signal-fields" class="space-y-2">
                <p class="label">{gettext("What it carries")}</p>
                <div
                  :for={{field, i} <- Enum.with_index(@node["fields"] || [])}
                  id={"process-signal-field-#{i}"}
                  class="space-y-1 rounded-2xl border border-base-300/70 bg-base-100 p-2"
                >
                  <%!-- With an entity the signal carries its attributes, as they are named. --%>
                  <div :if={@signal_entity}>
                    <input
                      type="hidden"
                      name={"element[signal_fields][#{i}][name]"}
                      value={field["name"]}
                    />
                    <p class="label">
                      {signal_field_label(@signal_entity, field["name"], @editor[:entities] || [])}
                    </p>
                  </div>
                  <div :if={!@signal_entity} class="flex items-start gap-1.5">
                    <div class="min-w-0 flex-1">
                      <.input
                        type="text"
                        id={"process-signal-field-#{i}-name"}
                        name={"element[signal_fields][#{i}][name]"}
                        value={field["name"]}
                        aria-label={gettext("Name of the field")}
                        maxlength="40"
                        phx-debounce="400"
                      />
                    </div>
                    <.icon_button
                      :if={@editor.editable?}
                      id={"process-signal-field-#{i}-remove"}
                      type="button"
                      phx-click="process_editor_remove_signal_field"
                      phx-value-index={i}
                      icon="hero-minus-circle"
                      label={gettext("Remove the field")}
                    />
                  </div>
                  <.input
                    type="text"
                    id={"process-signal-field-#{i}-value"}
                    name={"element[signal_fields][#{i}][value]"}
                    value={field["value"]}
                    aria-label={gettext("What it holds")}
                    maxlength="1000"
                    phx-debounce="300"
                  />
                  <.fields editor={@editor} target={"signal_fields.#{i}"} />
                </div>
                <.button
                  :if={@editor.editable? and !@signal_entity and length(@node["fields"] || []) < 10}
                  id="process-add-signal-field"
                  type="button"
                  phx-click="process_editor_add_signal_field"
                  variant="ghost"
                  size="sm"
                >
                  <.icon name="hero-plus" class="size-4" />
                  {gettext("Add a field")}
                </.button>
              </div>
              <p class="text-xs text-base-content/60">
                {gettext(
                  "It wakes the runs of the group's processes that wait for this signal right now, and starts the processes that start on it. It is not kept: a run that comes to wait later does not get it."
                )}
              </p>
              <p
                :if={related_hearers(@editor, @node["name"]) > 0}
                id="process-signal-related-hearers"
                class="text-xs text-base-content/60"
              >
                {ngettext(
                  "It also reaches %{count} process in the groups above and below that hears them.",
                  "It also reaches %{count} processes in the groups above and below that hear them.",
                  related_hearers(@editor, @node["name"])
                )}
              </p>
            <% "receive" -> %>
              <.input
                field={@form[:signal]}
                type="text"
                label={gettext("Signal")}
                list="process-signal-list"
                maxlength="40"
                phx-debounce="400"
              />
              <datalist id="process-signal-list">
                <option :for={name <- Map.keys(@editor.signals)} value={name} />
              </datalist>
              <.signal_entity editor={@editor} form={@form} />
              <input type="hidden" name="element[same_subject]" value="false" />
              <label class="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  id="process-receive-same-subject"
                  name="element[same_subject]"
                  value="true"
                  checked={@node["same_subject"] == true}
                  disabled={@node["related"] == true}
                  class="checkbox checkbox-sm"
                />
                {gettext("Only from a process on the same value or sub-group")}
              </label>
              <input type="hidden" name="element[related]" value="false" />
              <label class="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  id="process-receive-related"
                  name="element[related]"
                  value="true"
                  checked={@node["related"] == true}
                  class="checkbox checkbox-sm"
                />
                {gettext("Also hears the groups above and below")}
              </label>
              <div>
                <p class="label mb-1">{gettext("Deadline, then go on without it")}</p>
                <div class="flex gap-2">
                  <.input
                    field={@form[:deadline_amount]}
                    type="number"
                    min="1"
                    placeholder={gettext("none")}
                    phx-debounce="400"
                  />
                  <.input field={@form[:deadline_unit]} type="select" options={unit_options()} />
                </div>
              </div>
              <p class="text-xs text-base-content/60">
                {gettext(
                  "The steps after it read who sent the signal as %{field}, and the fields it carries the same way.",
                  field: "{{#{@node["id"]}.from}}"
                )}
              </p>
            <% "set" -> %>
              <.input
                field={@form[:field]}
                type="text"
                label={gettext("Field of the group")}
                list="process-group-field-list"
                maxlength="40"
                phx-debounce="400"
              />
              <datalist id="process-group-field-list">
                <option :for={name <- @editor.group_fields} value={name} />
              </datalist>
              <.input
                field={@form[:op]}
                type="select"
                label={gettext("What it does")}
                options={[{gettext("Sets it to"), "set"}, {gettext("Adds to it"), "add"}]}
              />
              <.input
                field={@form[:value]}
                type="text"
                maxlength="1000"
                label={if(@node["op"] == "add", do: gettext("Number"), else: gettext("Value"))}
                phx-debounce="300"
              />
              <.fields editor={@editor} target="value" />
              <p
                :if={group_field_type(@editor, @node["field"])}
                id="process-group-field-type"
                class="text-xs text-base-content/70"
              >
                {gettext("Type of the field: %{type}",
                  type: group_field_type(@editor, @node["field"])
                )}
              </p>
              <p class="text-xs text-base-content/60">
                {gettext(
                  "Every process of the group reads it as %{field}, and the app's editors see it on the Processes tab. A field the group does not have yet comes with this drawing: a number when the step adds to it, a text otherwise.",
                  field: "{{#{PotokIde.Processes.Scope.path("group", @node["field"] || "")}}}"
                )}
              </p>
            <% "assign" -> %>
              <p
                :if={@targets == []}
                id="process-assign-none"
                class="rounded-xl bg-base-200/70 px-3 py-2 text-sm text-base-content/70"
              >
                {gettext(
                  "The process has no variable yet. Close this step and add one under Variables, then pick it here."
                )}
              </p>
              <.input
                :if={@targets != []}
                field={@form[:target]}
                type="select"
                label={gettext("What it sets")}
                prompt={if(@node["target"] not in @targets, do: gettext("Pick a variable"))}
                options={@targets}
              />
              <.input
                :if={@list_target?}
                field={@form[:op]}
                type="select"
                label={gettext("What it does")}
                options={[
                  {gettext("Sets the whole list"), "set"},
                  {gettext("Adds an item to its end"), "append"}
                ]}
              />
              <.input
                field={@form[:value]}
                type="textarea"
                rows="2"
                maxlength="1000"
                label={gettext("What it gets")}
                class="w-full textarea font-mono text-sm"
                phx-debounce="300"
              />
              <.fields editor={@editor} target={if(@textual?, do: "value", else: "value_expr")} />
              <p class="text-xs text-base-content/60">
                {if(@textual?,
                  do:
                    gettext(
                      "A text, which may hold names and expressions between %{open} and %{close}.",
                      open: "{{",
                      close: "}}"
                    ),
                  else:
                    gettext(
                      "An expression, such as %{example}. Write %{empty} to leave it without a value.",
                      example: "#{@node["target"] || "x"} + 1",
                      empty: "empty"
                    )
                )}
              </p>
            <% "loop" -> %>
              <.input
                field={@form[:list]}
                type="text"
                label={gettext("List it goes through")}
                placeholder={gettext("a list, such as a variable that keeps one")}
                maxlength="1000"
                class="w-full input font-mono text-sm"
                phx-debounce="300"
              />
              <.fields
                editor={@editor}
                target="list_expr"
                hints={ProcessEditorState.list_hints(@editor)}
              />
              <.input
                field={@form[:item]}
                type="text"
                label={gettext("Name of an item")}
                maxlength="40"
                class="w-full input font-mono text-sm"
                phx-debounce="400"
              />
              <p class="text-xs text-base-content/60">
                {gettext(
                  "Its own steps run once for each item of the list, and read the item on hand as %{item} and its place as %{index} of %{count}. After the last item it goes on. A list holds 200 items at most.",
                  item: "{{#{@node["item"]}}}",
                  index: "{{#{@node["id"]}.index}}",
                  count: "{{#{@node["id"]}.count}}"
                )}
              </p>
            <% "call" -> %>
              <p
                :if={@editor.callable == []}
                id="process-call-none"
                class="rounded-xl bg-base-200/70 px-3 py-2 text-sm text-base-content/70"
              >
                {gettext(
                  "No process of the group takes calls yet. Draw one that starts when another process calls it, then pick it here."
                )}
              </p>
              <.input
                :if={@editor.callable != []}
                field={@form[:process]}
                type="select"
                label={gettext("Process")}
                prompt={if(is_nil(@callee), do: gettext("Pick a process"))}
                options={for p <- @editor.callable, do: {callable_label(p), p.id}}
              />
              <p
                :if={@callee && @callee.group}
                id="process-call-foreign"
                class="rounded-xl bg-base-200/70 px-3 py-2 text-xs text-base-content/70"
              >
                <.icon name="hero-globe-alt" class="mr-1 size-3.5 align-[-2px]" />
                <%= if @callee.returned != [] do %>
                  {gettext(
                    "A public process of %{group}. It runs there with what this step hands it and nothing else, and this process learns which end it reached and what that end hands back.",
                    group: @callee.group
                  )}
                <% else %>
                  {gettext(
                    "A public process of %{group}. It runs there with what this step hands it and nothing else, and this process learns only which end it reached.",
                    group: @callee.group
                  )}
                <% end %>
              </p>
              <input type="hidden" name="element[wait]" value="false" />
              <label class="flex items-center gap-2 text-sm">
                <input
                  type="checkbox"
                  id="process-call-wait"
                  name="element[wait]"
                  value="true"
                  checked={@node["wait"] != false}
                  class="checkbox checkbox-sm"
                />
                {gettext("Wait for it to end")}
              </label>
              <div :if={@callee && @callee.fields != []} id="process-call-fields" class="space-y-2">
                <p class="label">{gettext("What it gets")}</p>
                <div :for={name <- @callee.fields} class="space-y-1">
                  <.input
                    type="text"
                    id={"process-call-field-#{name}"}
                    name={"element[fields][#{name}]"}
                    value={(@node["fields"] || %{})[name] || ""}
                    label={call_field_label(@callee, name, @editor[:entities] || [])}
                    maxlength="1000"
                    phx-debounce="300"
                  />
                  <.fields editor={@editor} target={"fields.#{name}"} />
                </div>
              </div>
              <div :if={@node["wait"] != false}>
                <p class="label mb-1">{gettext("Deadline, then give up on it")}</p>
                <div class="flex gap-2">
                  <.input
                    field={@form[:deadline_amount]}
                    type="number"
                    min="1"
                    placeholder={gettext("none")}
                    phx-debounce="400"
                  />
                  <.input field={@form[:deadline_unit]} type="select" options={unit_options()} />
                </div>
              </div>
              <p
                :if={(@node["wait"] != false and @callee) && @callee.returned != []}
                id="process-call-returns"
                class="rounded-xl bg-base-200/70 px-3 py-2 text-xs text-base-content/70"
              >
                <.icon name="hero-arrow-uturn-left" class="mr-1 size-3.5 align-[-2px]" />
                {gettext("It hands back %{entity}: %{attributes}.",
                  entity: returned_name(@callee),
                  attributes: Enum.map_join(@callee.returned, ", ", & &1["name"])
                )}
              </p>
              <p :if={@node["wait"] != false} class="text-xs text-base-content/60">
                <%= if @callee && @callee.returned != [] do %>
                  {gettext(
                    "The steps after it read how it ended as %{field}, and what it hands back as %{example}.",
                    field: "{{#{@node["id"]}.outcome}}",
                    example:
                      "{{#{PotokIde.Processes.Scope.path(@node["id"], hd(@callee.returned)["name"])}}}"
                  )}
                <% else %>
                  {gettext("The steps after it read how it ended as %{field}.",
                    field: "{{#{@node["id"]}.outcome}}"
                  )}
                <% end %>
              </p>
            <% "start" -> %>
              <p class="text-sm text-base-content/65">{trigger_hint(@editor.trigger)}</p>
            <% _end -> %>
              <p class="text-sm text-base-content/65">{gettext("Here the run is done.")}</p>
              <div :if={@returned} id="process-end-values" class="space-y-2">
                <p class="label">
                  {gettext("What it hands back to the process that called it")}
                </p>
                <div
                  :for={attribute <- @returned.attributes}
                  id={"process-end-value-#{attribute.name}"}
                  class="space-y-1 rounded-2xl border border-base-300/70 bg-base-100 p-2"
                >
                  <p class="label">
                    {signal_field_label(@returned, attribute.name, @editor[:entities] || [])}
                  </p>
                  <.input
                    type="text"
                    id={"process-end-value-#{attribute.name}-input"}
                    name={"element[end_values][#{attribute.name}]"}
                    value={(@node["values"] || %{})[attribute.name] || ""}
                    aria-label={attribute.name}
                    placeholder={gettext("empty")}
                    maxlength="1000"
                    phx-debounce="300"
                  />
                  <.fields editor={@editor} target={"end_values.#{attribute.name}"} />
                </div>
                <p class="text-xs text-base-content/60">
                  {gettext(
                    "A text is written as a text, with names in double braces; anything else is an expression of its type."
                  )}
                </p>
              </div>
          <% end %>
        </fieldset>
      </.form>

      <.trigger_form :if={@kind == "start"} editor={@editor} role_options={@role_options} />
    </div>
    """
  end

  attr :editor, :map, required: true
  attr :role_options, :list, required: true

  # What starts the process, set on its start step.
  defp trigger_form(assigns) do
    assigns = assign(assigns, :config, assigns.editor.trigger_config)

    ~H"""
    <.form
      for={%{}}
      as={:trigger}
      id="process-trigger-form"
      phx-change="process_editor_trigger"
      class="mt-4 space-y-3 border-t border-base-300/70 pt-4"
    >
      <fieldset disabled={!@editor.editable?} class="space-y-3">
        <h3 class="text-sm font-semibold">{gettext("What starts it")}</h3>

        <.entry_entity :if={Triggers.typed?(@editor.trigger)} editor={@editor} />
        <.return_entity_field :if={@editor.trigger == "process"} editor={@editor} />

        <%= case @editor.trigger do %>
          <% "message" -> %>
            <.input
              type="text"
              id="process-trigger-words"
              name="trigger[words]"
              value={words_value(@config["words"])}
              label={gettext("Words in the message")}
              placeholder={gettext("leak, broken, power")}
              phx-debounce="400"
            />
            <.input
              type="select"
              id="process-trigger-role"
              name="trigger[role]"
              value={@config["role"] || ""}
              label={gettext("Or a role the message mentions")}
              options={[{gettext("No role"), ""}] ++ @role_options}
            />
            <p class="text-xs text-base-content/60">
              {gettext(
                "A message a person writes in the group's chat starts it when it holds one of these words or mentions the role. Replies in threads do not count."
              )}
            </p>
          <% "subgroup" -> %>
            <input type="hidden" name="trigger[placed]" value="false" />
            <label class="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                id="process-trigger-placed"
                name="trigger[placed]"
                value="true"
                checked={@config["placed"] in [true, "true"]}
                class="checkbox checkbox-sm"
              />
              {gettext("Only sub-groups with a place on the map")}
            </label>
            <p class="text-xs text-base-content/60">
              {gettext(
                "A sub-group someone makes here starts it: by hand, from a preset, a place added on the map, or an app. Records, threads and what a process makes do not."
              )}
            </p>
          <% "schedule" -> %>
            <.input
              type="select"
              id="process-trigger-every"
              name="trigger[every]"
              value={@config["every"]}
              label={gettext("How often")}
              options={[
                {gettext("Every day"), "day"},
                {gettext("Every week"), "week"},
                {gettext("Every month"), "month"}
              ]}
            />
            <div :if={@config["every"] == "week"} id="process-trigger-weekdays">
              <p class="label mb-1">{gettext("On")}</p>
              <input type="hidden" name="trigger[weekdays][]" value="" />
              <div class="flex flex-wrap gap-1.5">
                <label
                  :for={day <- 1..7}
                  class="cursor-pointer rounded-full border border-base-300 px-2.5 py-1 text-xs font-semibold transition has-checked:border-primary has-checked:bg-primary has-checked:text-primary-content"
                >
                  <input
                    type="checkbox"
                    id={"process-trigger-weekday-#{day}"}
                    name="trigger[weekdays][]"
                    value={day}
                    checked={to_string(day) in Enum.map(List.wrap(@config["weekdays"]), &to_string/1)}
                    class="sr-only"
                  />
                  {PotokIde.Events.Format.weekday_short(day)}
                </label>
              </div>
            </div>
            <.input
              :if={@config["every"] == "month"}
              type="select"
              id="process-trigger-day"
              name="trigger[day]"
              value={to_string(@config["day"])}
              label={gettext("On day")}
              options={
                for(d <- 1..28, do: {to_string(d), to_string(d)}) ++ [{gettext("the last"), "last"}]
              }
            />
            <.input
              type="time"
              id="process-trigger-time"
              name="trigger[time]"
              value={@config["time"]}
              label={gettext("At")}
            />
            <p class="text-xs text-base-content/60">
              {gettext("Times are in %{zone}.", zone: @config["time_zone"])}
            </p>
          <% "manual" -> %>
            <div>
              <p class="label mb-1">{gettext("Who may start it")}</p>
              <input type="hidden" name="trigger[roles][]" value="" />
              <label
                :for={{label, key} <- @role_options}
                class="flex items-center gap-2 py-0.5 text-sm"
              >
                <input
                  type="checkbox"
                  id={"process-trigger-role-#{key}"}
                  name="trigger[roles][]"
                  value={key}
                  checked={key in List.wrap(@config["roles"])}
                  class="checkbox checkbox-sm"
                />
                {label}
              </label>
            </div>
            <p class="text-xs text-base-content/60">
              {if(@editor[:entry_entity],
                do:
                  gettext(
                    "They get a Start button on the Processes tab, with a form that asks for the attributes of the entity."
                  ),
                else:
                  gettext(
                    "They get a Start button on the Processes tab, with a title and a text the steps can put in."
                  )
              )}
            </p>
          <% "signal" -> %>
            <.input
              type="text"
              id="process-trigger-signal"
              name="trigger[name]"
              value={@config["name"]}
              label={gettext("Signal")}
              list="process-trigger-signal-list"
              placeholder={gettext("saturday")}
              phx-debounce="400"
            />
            <datalist id="process-trigger-signal-list">
              <option :for={name <- Map.keys(@editor.signals)} value={name} />
            </datalist>
            <input type="hidden" name="trigger[related]" value="false" />
            <label class="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                id="process-trigger-related"
                name="trigger[related]"
                value="true"
                checked={@config["related"] == true}
                disabled={!@editor.editable?}
                class="checkbox checkbox-sm"
              />
              {gettext("Also hears the groups above and below")}
            </label>
            <p class="text-xs text-base-content/60">
              {gettext(
                "Each time a process of the group sends this signal, it starts, with the fields the signal carries. Hearing the groups above and below, it starts on theirs too, on no subject and by nobody, with what the signal carries."
              )}
            </p>
          <% "process" -> %>
            <.input
              :if={is_nil(@editor[:entry_entity])}
              type="text"
              id="process-trigger-fields"
              name="trigger[fields]"
              value={words_value(@config["fields"])}
              label={gettext("Fields it takes")}
              placeholder={gettext("fault, floor")}
              phx-debounce="400"
            />
            <.button
              :if={
                @editor.editable? and is_nil(@editor[:entry_entity]) and
                  words_value(@config["fields"]) != ""
              }
              id="process-trigger-entity-from-fields"
              type="button"
              phx-click="process_editor_entity_from_fields"
              variant="ghost"
              size="sm"
            >
              <.icon name="hero-cube" class="size-4" />
              {gettext("Make an entity of these fields")}
            </.button>
            <input type="hidden" name="trigger[public]" value="false" />
            <label class="flex items-start gap-2 text-sm">
              <input
                type="checkbox"
                id="process-trigger-public"
                name="trigger[public]"
                value="true"
                checked={@editor.public?}
                class="checkbox checkbox-sm mt-0.5"
              />
              <span>
                <span class="font-medium">{gettext("Public process")}</span>
                <span class="block text-xs text-base-content/60">
                  {gettext(
                    "The processes of the groups above and below this one may call it too, and their editors see its name and what it takes. Left off, only the processes of this group call it."
                  )}
                </span>
              </span>
            </label>
            <p class="text-xs text-base-content/60">
              {if(@editor[:entry_entity],
                do:
                  gettext(
                    "Another process of the group starts it with the step Call a process, which fills in the attributes of the entity, each as its type. When it ends, the caller learns which end it reached."
                  ),
                else:
                  gettext(
                    "Another process of the group starts it with the step Call a process, which fills in these fields. When it ends, the caller learns which end it reached."
                  )
              )}
            </p>
          <% "value" -> %>
            <p :if={@editor[:entry_entity]} class="text-xs text-base-content/60">
              {gettext(
                "Each attribute reads the field of the same name in the value, as its type. What else the value holds is read as it comes."
              )}
            </p>
          <% _other -> %>
        <% end %>
      </fieldset>
    </.form>
    """
  end

  attr :editor, :map, required: true
  attr :form, :any, required: true

  # The entity a signal is sent or waited for with, of the group's own.
  defp signal_entity(assigns) do
    assigns = assign(assigns, :entities, assigns.editor[:entities] || [])

    ~H"""
    <.input
      :if={@entities != []}
      field={@form[:entity]}
      type="select"
      label={gettext("Entity it carries")}
      options={
        [{gettext("No entity, plain fields"), ""}] ++
          for(entity <- @entities, do: {entity.name, entity.id})
      }
    />
    """
  end

  attr :editor, :map, required: true

  # The entity the process takes when it starts, of the group's own.
  defp entry_entity(assigns) do
    assigns = assign(assigns, :entities, takeable(assigns.editor))

    ~H"""
    <div id="process-trigger-entity-field">
      <.input
        :if={@entities != []}
        type="select"
        id="process-trigger-entity"
        name="trigger[entity]"
        value={@editor[:entry_entity] || ""}
        label={entry_label(@editor.trigger)}
        options={
          [{entry_none(@editor.trigger), ""}] ++
            for(entity <- @entities, do: {entity.name, entity.id})
        }
      />
      <p :if={@entities == []} class="text-xs text-base-content/60">
        {gettext(
          "It takes plain texts. Define an entity under Data, and it can take that instead, each attribute as its type."
        )}
      </p>
    </div>
    """
  end

  attr :editor, :map, required: true

  # The entity a process others call hands back, which each of its ends
  # fills in.
  defp return_entity_field(assigns) do
    ~H"""
    <div :if={(@editor[:entities] || []) != []} id="process-trigger-returns-field">
      <.input
        type="select"
        id="process-trigger-returns"
        name="trigger[returns]"
        value={@editor[:return_entity] || ""}
        label={gettext("What it hands back")}
        options={
          [{gettext("Only the end it reached"), ""}] ++
            for(entity <- @editor[:entities] || [], do: {entity.name, entity.id})
        }
      />
      <p :if={@editor[:return_entity]} class="mt-1 text-xs text-base-content/60">
        {gettext(
          "Each end fills it in, and the process that called it reads it, in its own group or in another."
        )}
      </p>
    </div>
    """
  end

  # The name of the entity a process hands back, as it was saved.
  defp returned_name(%{returns: id, types: types}) when is_integer(id),
    do: get_in(types, [to_string(id), "name"]) || ""

  defp returned_name(_callee), do: ""

  defp takeable(editor), do: editor[:entities] || []

  # The entity a form asks for, as its name and attributes: as the group
  # has it now for its editors, and as the drawing was saved for the rest.
  defp asked_entity(editor, %{"type" => "formTask", "entity" => id}) when is_integer(id) do
    case Enum.find(editor[:entities] || [], &(&1.id == id)) do
      nil ->
        get_in(editor.graph, ["types", to_string(id)])

      entity ->
        %{
          "name" => entity.name,
          "attributes" => Enum.map(entity.attributes, &%{"name" => &1.name})
        }
    end
  end

  defp asked_entity(_editor, _node), do: nil

  # How a step after a form names one of its answers: its first attribute,
  # or a word for one while it asks for nothing yet.
  defp asked_path(%{"id" => id}, %{"attributes" => [%{"name" => name} | _rest]}),
    do: PotokIde.Processes.Scope.path(id, name)

  defp asked_path(%{"id" => id}, _none), do: "#{id}.#{gettext("attribute")}"

  defp entry_label("manual"), do: gettext("What its form asks for")
  defp entry_label("signal"), do: gettext("What the signal carries")
  defp entry_label("value"), do: gettext("How a value reads")
  defp entry_label(_process), do: gettext("What it takes")

  defp entry_none("manual"), do: gettext("A title and a text")
  defp entry_none("signal"), do: gettext("Whatever was put in it")
  defp entry_none("value"), do: gettext("As it comes")
  defp entry_none(_process), do: gettext("Plain fields")

  # A process a call may start, by its name: with its group for a public
  # one of another group.
  defp callable_label(process) do
    name =
      if process.active,
        do: process.name,
        else: gettext("%{name} (off)", name: process.name)

    if process.group, do: "#{name} · #{process.group}", else: name
  end

  # What a call hands over under `name`: the name, and for an attribute of
  # the entity the called process takes, its type and whether it is required.
  defp call_field_label(callee, name, entities) do
    case Enum.find(callee.attributes, &(&1["name"] == name)) do
      nil ->
        name

      attribute ->
        type = ProcessEntities.type_words(Types.of(attribute), entities)
        required = if attribute["required"] == true, do: " *", else: ""
        "#{name} · #{type}#{required}"
    end
  end

  # The same for an attribute of the entity a signal carries.
  # The type of a field the group declares, as the entity editor names it.
  defp group_field_type(editor, name) when is_binary(name) do
    case Map.get(editor[:group_field_types] || %{}, name) do
      %{"type" => type} ->
        PotokIdeWeb.GroupLive.Show.ProcessEntities.type_options([])
        |> Enum.find_value(type, fn {label, value} -> if value == type, do: label end)

      nil ->
        nil
    end
  end

  defp group_field_type(_editor, _name), do: nil

  # How many processes of the groups above and below hear the signal.
  defp related_hearers(editor, name) when is_binary(name),
    do: Map.get(editor[:related_hearers] || %{}, name, 0)

  defp related_hearers(_editor, _name), do: 0

  defp signal_field_label(entity, name, entities) do
    case entity && Enum.find(entity.attributes, &(&1.name == name)) do
      nil ->
        name

      attribute ->
        type = ProcessEntities.type_label(attribute, entities)
        required = if attribute.required, do: " *", else: ""
        "#{name} · #{type}#{required}"
    end
  end

  defp words_value(words) when is_list(words), do: Enum.join(words, ", ")
  defp words_value(words) when is_binary(words), do: words
  defp words_value(_words), do: ""

  defp trigger_options(%{apps: []}), do: PotokIde.Processes.Triggers.all() -- ["value"]
  defp trigger_options(_editor), do: PotokIde.Processes.Triggers.all()

  defp trigger_icon("message"), do: "hero-chat-bubble-left-ellipsis"
  defp trigger_icon("subgroup"), do: "hero-folder-plus"
  defp trigger_icon("schedule"), do: "hero-calendar-days"
  defp trigger_icon("manual"), do: "hero-hand-raised"
  defp trigger_icon("process"), do: "hero-arrow-down-on-square"
  defp trigger_icon("signal"), do: "hero-signal"
  defp trigger_icon(_value), do: "hero-inbox-arrow-down"

  defp trigger_hint("message"),
    do: gettext("A message with one of the words starts the process here.")

  defp trigger_hint("subgroup"), do: gettext("A new sub-group starts the process here.")
  defp trigger_hint("schedule"), do: gettext("The process starts here at the set time.")
  defp trigger_hint("manual"), do: gettext("Whoever starts it by hand starts here.")
  defp trigger_hint("process"), do: gettext("A call from another process starts here.")
  defp trigger_hint("signal"), do: gettext("The signal starts the process here.")
  defp trigger_hint(_value), do: gettext("Every new value of the collection starts here.")

  attr :editor, :map, required: true
  attr :target, :string, required: true
  attr :hints, :list, default: nil, doc: "the names to offer, where not all of them fit"

  defp fields(assigns) do
    assigns =
      assign(assigns, :hints, assigns.hints || ProcessEditorState.field_hints(assigns.editor))

    ~H"""
    <div
      :if={@editor.editable? and @hints != []}
      class="-mt-1 flex flex-wrap items-center gap-1"
    >
      <span class="text-[11px] text-base-content/50">{gettext("Put in:")}</span>
      <button
        :for={{path, i} <- Enum.with_index(@hints)}
        id={"process-field-#{@target}-#{i}"}
        type="button"
        phx-click="process_editor_insert_field"
        phx-value-target={@target}
        phx-value-path={path}
        class="rounded-full bg-base-200 px-2 py-0.5 font-mono text-[11px] text-base-content/70 transition hover:bg-primary/15 hover:text-primary"
      >
        {path}
      </button>
    </div>
    """
  end

  attr :editor, :map, required: true
  attr :form, :any, required: true

  defp flow_panel(assigns) do
    {:flow, key} = assigns.editor.selected
    flow = GraphEdit.flow(assigns.editor.graph, key)

    assigns =
      assigns
      |> assign(:flow, flow)
      |> assign(:targets, target_options(assigns.editor.graph, flow))
      |> assign(:removable?, removable?(assigns.editor.graph, flow))

    ~H"""
    <div id="process-flow-panel">
      <div class="mb-3 flex items-center justify-between gap-2">
        <h2 class="flex items-center gap-2 text-base font-semibold">
          <.icon name="hero-arrow-long-right" class="size-5 text-base-content/60" />
          {ProcessEditorState.flow_label(@flow) || gettext("Arrow")}
        </h2>
        <div class="flex items-center gap-1">
          <.icon_button
            :if={@editor.editable? and @removable?}
            id="process-flow-delete"
            type="button"
            phx-click="process_editor_remove_flow"
            phx-value-flow={@flow["key"]}
            icon="hero-trash"
            label={gettext("Remove this branch")}
          />
          <.icon_button
            id="process-panel-close"
            type="button"
            phx-click="process_editor_deselect"
            icon="hero-x-mark"
            label={gettext("Close")}
          />
        </div>
      </div>

      <.form for={@form} id="process-flow-form" phx-change="process_editor_change" class="space-y-3">
        <fieldset disabled={!@editor.editable?} class="space-y-3">
          <.input
            :if={Map.has_key?(@flow, "outcome")}
            field={@form[:outcome]}
            type="text"
            maxlength="40"
            label={gettext("Outcome")}
            phx-debounce="400"
          />

          <%= case @flow["condition"] do %>
            <% %{"expr" => _expression} -> %>
              <.input
                field={@form[:expr]}
                type="textarea"
                rows="2"
                maxlength="1000"
                label={gettext("Goes this way when")}
                placeholder={~s|start.title != "" and not empty(start.text)|}
                class="w-full textarea font-mono text-sm"
                phx-debounce="400"
              />
              <.fields editor={@editor} target="expr" />
              <p class="text-xs text-base-content/60">
                {gettext(
                  "An expression that is true or false: compare with %{compare}, join with %{join}, and write a text between quotes.",
                  compare: "= != < > <= >=",
                  join: "and, or, not"
                )}
              </p>
            <% %{"field" => _field} -> %>
              <%!-- A drawing in the first language, which is only looked at. --%>
              <.input field={@form[:field]} type="text" label={gettext("Field")} />
              <.input field={@form[:op]} type="select" label={gettext("Is")} options={op_options()} />
              <.input
                :if={@form[:op].value != "empty"}
                field={@form[:value]}
                type="text"
                label={gettext("Value")}
              />
            <% _none -> %>
          <% end %>

          <.input field={@form[:to]} type="select" label={gettext("Leads to")} options={@targets} />
        </fieldset>
      </.form>
    </div>
    """
  end

  defp outcome_flows(graph, %{"type" => "userTask", "id" => id}),
    do: graph |> Graph.out(id) |> Enum.filter(&Map.has_key?(&1, "outcome"))

  defp outcome_flows(_graph, _node), do: []

  defp condition_flows(graph, %{"type" => "exclusiveGateway", "id" => id}),
    do: graph |> Graph.out(id) |> Enum.filter(&Map.has_key?(&1, "condition"))

  defp condition_flows(_graph, _node), do: []

  defp removable?(graph, flow) do
    cond do
      Map.has_key?(flow, "outcome") ->
        length(outcome_flows(graph, Graph.node(graph, flow["from"]))) > 1

      Map.has_key?(flow, "condition") ->
        length(condition_flows(graph, Graph.node(graph, flow["from"]))) > 1

      Map.has_key?(flow, "deadline") ->
        true

      true ->
        false
    end
  end

  defp target_options(graph, flow) do
    roles = %{}

    steps =
      for node <- graph["nodes"],
          node["type"] != "startEvent",
          node["id"] != flow["from"],
          do: {elem(ProcessEditorState.describe(node, graph, roles), 2), node["id"]}

    steps ++ [{gettext("A new end"), "__new_end"}]
  end

  defp role_options(access) do
    roles = if access.manifest, do: access.manifest.roles, else: []
    for role <- roles, do: {PotokIdeWeb.GroupLive.Show.RolesTab.role_label(role), role.key}
  end

  defp admin_options(role_options) do
    [{gettext("The process's owner"), "owner"}, {gettext("Whoever set it going"), "triggered_by"}] ++
      inherit_role_options(role_options)
  end

  # Every member holds "everyone", so neither naming the admins nor
  # narrowing who is inherited offers it.
  defp inherit_role_options(role_options),
    do: Enum.reject(role_options, fn {_label, key} -> key == "everyone" end)

  defp unit_options do
    [
      {gettext("minutes"), "minutes"},
      {gettext("hours"), "hours"},
      {gettext("days"), "days"},
      {gettext("weeks"), "weeks"}
    ]
  end

  defp op_options do
    [
      {gettext("equal to"), "="},
      {gettext("not equal to"), "!="},
      {gettext("less than"), "<"},
      {gettext("more than"), ">"},
      {gettext("empty"), "empty"}
    ]
  end
end
