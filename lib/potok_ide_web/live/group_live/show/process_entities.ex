defmodule PotokIdeWeb.GroupLive.Show.ProcessEntities do
  @moduledoc """
  The entities of a group on its Processes tab
  (`PotokIde.Processes.GroupEntities`), for the app's editors: the list of
  them, and the form of one over the tab, with a row for each attribute.
  `ProcessesState` holds the form and takes its `"processes_entity_*"` events.
  """

  use PotokIdeWeb, :html

  alias PotokIde.Processes.GroupEntity
  alias PotokIde.Processes.GroupEntity.Attribute

  attr :entities, :list, required: true, doc: "the group's entities (`GroupEntities.list/1`)"

  def section(assigns) do
    ~H"""
    <section id="group-entities" class="mb-6">
      <div class="mb-1 flex items-center justify-between gap-2 px-1">
        <h2 class="flex items-center gap-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/55">
          <.icon name="hero-cube" class="size-3.5" />
          {gettext("Entities")}
        </h2>
        <.button
          id="group-entity-new"
          type="button"
          phx-click="processes_entity_new"
          variant="ghost"
          size="sm"
        >
          <.icon name="hero-plus" class="size-4" />
          {gettext("New entity")}
        </.button>
      </div>
      <p class="mb-2 px-1 text-xs text-base-content/60">
        {gettext(
          "What the data of the processes looks like: a name, and attributes with the type of what each holds."
        )}
      </p>
      <ul
        :if={@entities != []}
        id="group-entities-list"
        class="divide-y divide-base-300/60 overflow-hidden rounded-3xl border border-base-300/70 bg-base-100/80 shadow-sm"
      >
        <li
          :for={entity <- @entities}
          id={"group-entity-#{entity.id}"}
          class="flex items-start gap-3 px-4 py-2.5 transition-colors duration-150 hover:bg-base-200/40"
        >
          <div class="min-w-0 flex-1">
            <p class="truncate text-sm font-semibold">{entity.name}</p>
            <p class="mt-1 flex flex-wrap gap-1">
              <span
                :for={attribute <- entity.attributes}
                class="inline-flex items-baseline gap-1 rounded-full bg-violet-500/10 px-2 py-0.5 text-[11px]"
              >
                <code class="font-mono text-violet-700 dark:text-violet-300">{attribute.name}</code>
                <span class="text-base-content/55">{type_label(attribute, @entities)}</span>
              </span>
            </p>
          </div>
          <.icon_button
            id={"group-entity-#{entity.id}-edit"}
            type="button"
            phx-click="processes_entity_edit"
            phx-value-id={entity.id}
            icon="hero-pencil-square"
            label={gettext("Change the entity")}
          />
        </li>
      </ul>
    </section>
    """
  end

  attr :entity, :map, default: nil, doc: "`%{entity, form}` while an editor defines one"
  attr :entities, :list, required: true

  # Defining an entity: its name, and a row for each attribute.
  def dialog(assigns) do
    ~H"""
    <dialog
      :if={@entity}
      id="entity-dialog"
      phx-hook=".EntityDialog"
      phx-mounted={JS.ignore_attributes(["open"])}
      aria-labelledby="entity-dialog-title"
      class="fixed inset-0 m-0 size-full max-h-none max-w-none overflow-hidden bg-transparent p-0 backdrop:bg-transparent"
    >
      <div class="flex size-full items-end justify-center sm:items-center sm:p-4">
        <div
          class="absolute inset-0 bg-black/30 backdrop-blur-[2px] dark:bg-black/60"
          phx-click="processes_entity_close"
          aria-hidden="true"
        >
        </div>
        <section
          tabindex="-1"
          autofocus
          class="relative flex max-h-[90dvh] w-full flex-col overflow-hidden rounded-t-3xl border border-b-0 border-base-300/70 bg-base-100 text-base-content shadow-2xl outline-none sm:max-w-xl sm:rounded-3xl sm:border-b"
        >
          <header class="flex items-start gap-3 border-b border-base-300/60 px-5 pt-5 pb-4">
            <span class="inline-flex size-10 shrink-0 items-center justify-center rounded-2xl bg-violet-500/10 text-violet-600 dark:text-violet-300">
              <.icon name="hero-cube" class="size-5" />
            </span>
            <div class="min-w-0 flex-1">
              <h2 id="entity-dialog-title" class="text-base font-semibold">
                {if(@entity.entity.id, do: @entity.entity.name, else: gettext("New entity"))}
              </h2>
              <p class="text-xs text-base-content/60">
                {gettext("The processes of the group read and fill in its attributes.")}
              </p>
            </div>
            <.icon_button
              id="entity-dialog-close"
              type="button"
              phx-click="processes_entity_close"
              icon="hero-x-mark"
              label={gettext("Close")}
            />
          </header>
          <.form
            for={@entity.form}
            id="entity-form"
            phx-change="processes_entity_validate"
            phx-submit="processes_entity_save"
            class="flex min-h-0 flex-1 flex-col"
          >
            <div class="min-h-0 flex-1 space-y-3 overflow-y-auto px-5 py-4">
              <p
                :for={message <- form_errors(@entity.form)}
                class="entity-form-error rounded-xl bg-error/10 px-3 py-2 text-sm text-error"
              >
                {message}
              </p>
              <.input
                field={@entity.form[:name]}
                type="text"
                label={gettext("Name")}
                placeholder={gettext("Fault report")}
                maxlength="40"
                phx-debounce="300"
                required
              />
              <div id="entity-attributes" class="space-y-2">
                <p class="label">{gettext("Attributes")}</p>
                <.inputs_for :let={attribute} field={@entity.form[:attributes]}>
                  <.attribute_row
                    attribute={attribute}
                    form_name={@entity.form.name}
                    others={others(@entities, @entity.entity)}
                  />
                </.inputs_for>
                <input type="hidden" name={"#{@entity.form.name}[attributes_drop][]"} />
                <.button
                  id="entity-attribute-add"
                  type="button"
                  name={"#{@entity.form.name}[attributes_sort][]"}
                  value="new"
                  phx-click={JS.dispatch("change")}
                  variant="ghost"
                  size="sm"
                >
                  <.icon name="hero-plus" class="size-4" />
                  {gettext("Add an attribute")}
                </.button>
              </div>
            </div>
            <footer class="flex items-center gap-2 border-t border-base-300/60 bg-base-200/40 px-5 pt-3 pb-[calc(0.75rem+var(--app-safe-area-bottom))] sm:pb-3">
              <.button
                :if={@entity.entity.id}
                id="entity-delete"
                type="button"
                phx-click="processes_entity_delete"
                phx-value-id={@entity.entity.id}
                data-confirm={gettext("Delete this entity?")}
                variant="ghost"
                size="sm"
              >
                <.icon name="hero-trash" class="size-4" />
                {gettext("Delete")}
              </.button>
              <span class="flex-1"></span>
              <.button type="button" phx-click="processes_entity_close" variant="ghost" size="sm">
                {gettext("Cancel")}
              </.button>
              <.button id="entity-submit" type="submit" variant="primary" size="sm">
                {gettext("Save")}
              </.button>
            </footer>
          </.form>
        </section>
      </div>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".EntityDialog">
      export default {
        mounted() {
          // Escape and Android's back button close it through the server.
          this.el.addEventListener("cancel", event => {
            event.preventDefault()
            this.pushEvent("processes_entity_close", {})
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

  attr :attribute, :any, required: true, doc: "the form of one attribute"
  attr :form_name, :string, required: true
  attr :others, :list, required: true, doc: "the entities the attribute may hold"

  defp attribute_row(assigns) do
    assigns = assign(assigns, :type, to_string(assigns.attribute[:type].value))

    ~H"""
    <div
      id={"entity-attribute-#{@attribute.index}"}
      class="space-y-2 rounded-2xl border border-base-300/70 bg-base-100 p-3 transition-shadow duration-200 focus-within:shadow-sm"
    >
      <input type="hidden" name={"#{@form_name}[attributes_sort][]"} value={@attribute.index} />
      <div class="flex items-start gap-2">
        <div class="grid min-w-0 flex-1 grid-cols-1 gap-x-2 sm:grid-cols-2">
          <.input
            field={@attribute[:name]}
            type="text"
            aria-label={gettext("Name of the attribute")}
            placeholder={gettext("floor")}
            maxlength="40"
            phx-debounce="300"
          />
          <.input
            field={@attribute[:type]}
            type="select"
            aria-label={gettext("Type")}
            options={type_options(@others)}
          />
        </div>
        <button
          id={"entity-attribute-#{@attribute.index}-remove"}
          type="button"
          name={"#{@form_name}[attributes_drop][]"}
          value={@attribute.index}
          phx-click={JS.dispatch("change")}
          aria-label={gettext("Remove the attribute")}
          title={gettext("Remove the attribute")}
          class="mt-1 inline-flex size-8 shrink-0 cursor-pointer items-center justify-center rounded-full text-base-content/50 transition hover:bg-error/10 hover:text-error"
        >
          <.icon name="hero-minus-circle" class="size-5" />
        </button>
      </div>
      <.input
        :if={@type == "choice"}
        field={@attribute[:options]}
        type="text"
        value={options_value(@attribute[:options].value)}
        label={gettext("What it may be")}
        placeholder={gettext("low, medium, high")}
        phx-debounce="300"
      />
      <.input
        :if={@type == "entity"}
        field={@attribute[:entity_id]}
        type="select"
        label={gettext("Which entity")}
        prompt={gettext("Pick an entity")}
        options={for entity <- @others, do: {entity.name, entity.id}}
      />
      <div class="-mb-2 flex flex-wrap gap-x-5">
        <.input field={@attribute[:list]} type="checkbox" label={gettext("A list of them")} />
        <.input field={@attribute[:required]} type="checkbox" label={gettext("Must be filled in")} />
      </div>
    </div>
    """
  end

  @doc "What an attribute holds, in words: its type, or the entity it holds."
  def type_label(%Attribute{} = attribute, entities) do
    label =
      case attribute.type do
        "entity" ->
          case Enum.find(entities, &(&1.id == attribute.entity_id)) do
            %GroupEntity{name: name} -> name
            nil -> gettext("entity")
          end

        type ->
          type_name(type)
      end

    if attribute.list, do: gettext("list of %{type}", type: label), else: label
  end

  @doc "The name of a plain type, in small letters."
  def type_name("text"), do: gettext("text")
  def type_name("number"), do: gettext("number")
  def type_name("boolean"), do: gettext("yes or no")
  def type_name("date"), do: gettext("date")
  def type_name("datetime"), do: gettext("date and time")
  def type_name("choice"), do: gettext("choice")
  def type_name(_type), do: gettext("entity")

  # Another entity can be held only where the group has one.
  defp type_options(others) do
    [
      {gettext("Text"), "text"},
      {gettext("Number"), "number"},
      {gettext("Yes or no"), "boolean"},
      {gettext("Date"), "date"},
      {gettext("Date and time"), "datetime"},
      {gettext("Choice from a list"), "choice"}
    ] ++ if(others == [], do: [], else: [{gettext("Another entity"), "entity"}])
  end

  defp others(entities, %GroupEntity{id: id}), do: Enum.reject(entities, &(&1.id == id))

  # Options as they were typed, or as the entity keeps them.
  defp options_value(options) when is_list(options), do: Enum.join(options, ", ")
  defp options_value(options), do: options

  # What is wrong with the entity as a whole; a form not used yet has no errors.
  defp form_errors(%Phoenix.HTML.Form{errors: errors}) do
    for {field, error} <- errors, field in [:attributes, :lock_version] do
      case {field, error} do
        {:lock_version, _stale} ->
          gettext("Someone changed this entity in the meantime. Close it and open it again.")

        {_field, error} ->
          translate_error(error)
      end
    end
  end
end
