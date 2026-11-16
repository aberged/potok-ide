defmodule PotokIdeWeb.GroupLive.Show.ProcessEditor do
  @moduledoc """
  The process editor over the Processes tab (`ProcessEditorState`): a bar
  with the name and the actions, the canvas (`ProcessCanvas`), and a panel
  with the step or flow picked on it, a sheet on a phone and a column beside
  the canvas on a wide screen.
  """

  use PotokIdeWeb, :html

  alias PotokIde.Processes.{Graph, GraphEdit}
  alias PotokIdeWeb.GroupLive.Show.ProcessEditorState

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
      |> assign(:role_options, role_options(assigns.access))
      |> assign(
        :canvas_state,
        Jason.encode!(ProcessEditorState.canvas_state(assigns.editor, assigns.access))
      )
      |> assign(:panel?, assigns.editor.selected != nil or assigns.editor.inserting != nil)

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
              disabled={@editor.error != nil or not @editor.dirty? or @editor.collection == nil}
              variant="primary"
              size="sm"
            >
              <.icon name="hero-check" class="size-4" />
              {gettext("Save")}
            </.button>
          </div>

          <div class="mt-1 flex flex-wrap items-center gap-1.5 pl-1 sm:pl-11">
            <%= if @editor.source == :new do %>
              <select
                :if={length(@editor.apps) > 1}
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
              <label class="inline-flex items-center gap-1.5 text-xs text-base-content/60">
                {gettext("When a value comes to")}
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
              <span class="inline-flex h-7 items-center gap-1 rounded-full bg-base-200 px-2.5 text-xs text-base-content/70">
                <.icon name="hero-inbox-arrow-down" class="size-3.5" />
                {@editor.collection}
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
                  />
                <% match?({:flow, _}, @editor.selected) and @form -> %>
                  <.flow_panel editor={@editor} form={@form} />
                <% true -> %>
                  <.hint editor={@editor} />
              <% end %>
            </div>
          </aside>
        </div>

        <ol id="process-outline" class="sr-only">
          <li :for={node <- @editor.graph["nodes"]} id={"process-outline-#{node["id"]}"}>
            {elem(ProcessEditorState.describe(node, @editor.graph, @roles), 2)}
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

  defp hint(assigns) do
    ~H"""
    <div id="process-panel-hint" class="space-y-3 text-sm text-base-content/70">
      <h2 class="text-base font-semibold text-base-content">
        {if(@editor.editable?, do: gettext("How to draw"), else: gettext("The drawing"))}
      </h2>
      <%= if @editor.editable? do %>
        <p>
          {gettext(
            "Every new value of the collection starts the process at the top and goes along the arrows."
          )}
        </p>
        <p class="lg:hidden">
          {gettext("Tap + on an arrow to add a step, and a step or an arrow to change it.")}
        </p>
        <p class="max-lg:hidden">
          {gettext(
            "Click + on an arrow to add a step. Drag the steps where you like them, and drag from the dot under a step to another step to draw an arrow. Click a step or an arrow to change it."
          )}
        </p>
        <p>{gettext("Save a drawing, then switch it on.")}</p>
      <% else %>
        <p>{gettext("Tap a step or an arrow to see what it does.")}</p>
      <% end %>
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

  defp insert_kinds do
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
      {"push", "hero-bell-alert", gettext("Push"),
       gettext("Lets the people of a role know on their phones."),
       "bg-rose-500/10 text-rose-600 dark:text-rose-300"},
      {"timer", "hero-clock", gettext("Wait"), gettext("Waits a while before going on."),
       "bg-teal-500/10 text-teal-600 dark:text-teal-300"},
      {"gateway", "hero-arrows-right-left", gettext("Condition"),
       gettext("Goes one way or another by what was sent."),
       "bg-amber-500/10 text-amber-700 dark:text-amber-300"}
    ]
  end

  attr :editor, :map, required: true
  attr :form, :any, required: true
  attr :roles, :map, required: true
  attr :role_options, :list, required: true

  defp node_panel(assigns) do
    {:node, id} = assigns.editor.selected
    node = Graph.node(assigns.editor.graph, id)

    {kind, icon, title, _detail} =
      ProcessEditorState.describe(node, assigns.editor.graph, assigns.roles)

    assigns =
      assigns
      |> assign(node: node, kind: kind, icon: icon, title: title)
      |> assign(
        :subgroups,
        for(%{"action" => "subgroup"} = n <- assigns.editor.graph["nodes"], do: n)
      )
      |> assign(:outcome_flows, outcome_flows(assigns.editor.graph, node))
      |> assign(:condition_flows, condition_flows(assigns.editor.graph, node))

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
            <% _start_or_end -> %>
              <p class="text-sm text-base-content/65">
                {if(@kind == "start",
                  do: gettext("Every new value of the collection starts here."),
                  else: gettext("Here the run is done.")
                )}
              </p>
          <% end %>
        </fieldset>
      </.form>
    </div>
    """
  end

  attr :editor, :map, required: true
  attr :target, :string, required: true

  defp fields(assigns) do
    ~H"""
    <div
      :if={@editor.editable? and @editor.fields != []}
      class="-mt-1 flex flex-wrap items-center gap-1"
    >
      <span class="text-[11px] text-base-content/50">{gettext("Put in:")}</span>
      <button
        :for={{path, i} <- Enum.with_index(@editor.fields)}
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

          <%= if Map.has_key?(@flow, "condition") do %>
            <.input
              field={@form[:field]}
              type="text"
              label={gettext("Field")}
              list="process-field-list"
              phx-debounce="400"
            />
            <datalist id="process-field-list">
              <option :for={path <- @editor.fields} value={path} />
            </datalist>
            <.input field={@form[:op]} type="select" label={gettext("Is")} options={op_options()} />
            <.input
              :if={@form[:op].value != "empty"}
              field={@form[:value]}
              type="text"
              label={gettext("Value")}
              phx-debounce="400"
            />
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
      Enum.reject(role_options, fn {_label, key} -> key == "everyone" end)
  end

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
