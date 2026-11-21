defmodule PotokIdeWeb.GroupLive.Show.TemplatesCard do
  @moduledoc """
  The Šabloni card of the edit tab: the templates of the group's own, which
  its editors make, order and delete here, and those it takes from the groups
  above, which are only listed. `TemplatesState` holds the form and handles
  its events.

  The form has the template's name and purpose, its field rows, its HTML with
  a summary of the tags, and a preview with sample values that says what the
  display sanitizer leaves out.
  """

  use PotokIdeWeb, :html

  alias PotokIde.Social.{GroupTemplate, GroupTemplates}

  attr :section, :string, required: true
  attr :own, :list, required: true, doc: "the group's own templates (`GroupTemplate`)"

  attr :inherited, :list,
    required: true,
    doc: "templates from the groups above (`GroupTemplates.catalog/2` entries)"

  attr :form, :any, default: nil
  attr :editing, :any, default: nil
  attr :rows, :list, default: []
  attr :preview, :any, default: nil

  def card(assigns) do
    assigns = assign(assigns, :max, GroupTemplates.max_per_group())

    ~H"""
    <section
      id="group-edit-templates"
      role="tabpanel"
      aria-labelledby="group-edit-tab-templates"
      class={[
        "rounded-3xl border border-base-300/70 bg-base-100/80 p-4 shadow-sm sm:p-5",
        @section != "templates" && "hidden"
      ]}
    >
      <div class="flex flex-wrap items-start justify-between gap-3">
        <.card_title
          icon="hero-rectangle-group"
          title={gettext("Templates")}
          subtitle={
            gettext(
              "Forms with fields and the HTML they fill, for the descriptions of this group and of every group below it, and for posts in FeedCreator."
            )
          }
        />
        <.button
          :if={is_nil(@form) and length(@own) < @max}
          id="group-template-new"
          type="button"
          phx-click="group_template_new"
          variant="soft"
          class="shrink-0"
        >
          <.icon name="hero-plus" class="size-4" /> <span>{gettext("New template")}</span>
        </.button>
      </div>

      <p
        :if={@own == [] and @inherited == [] and is_nil(@form)}
        id="group-template-empty"
        class="mt-4 rounded-2xl border border-dashed border-base-300 px-4 py-6 text-center text-sm text-base-content/65"
      >
        {gettext(
          "No templates yet. Make one, and it shows in the list of templates next to the built-in ones."
        )}
      </p>

      <ul :if={@own != []} id="group-template-list" class="mt-4 flex flex-col gap-2">
        <li
          :for={{template, index} <- Enum.with_index(@own)}
          id={"group-template-#{template.id}"}
          class={[
            "flex flex-wrap items-center gap-3 rounded-2xl border px-3 py-2 transition duration-150",
            if(editing?(@editing, template),
              do: "border-primary/50 bg-primary/5",
              else: "border-base-300/80 bg-base-100 hover:border-base-content/20"
            )
          ]}
        >
          <div class="flex min-w-0 flex-1 flex-col">
            <span class="truncate font-medium text-base-content">{template.name}</span>
            <span class="truncate text-sm text-base-content/65">
              {fields_summary(template)}
            </span>
          </div>

          <div class="flex items-center gap-1">
            <.icon_button
              id={"group-template-#{template.id}-up"}
              type="button"
              phx-click="group_template_move"
              phx-value-id={template.id}
              phx-value-direction="up"
              disabled={index == 0}
              icon="hero-arrow-up"
              label={gettext("Move up")}
            />
            <.icon_button
              id={"group-template-#{template.id}-down"}
              type="button"
              phx-click="group_template_move"
              phx-value-id={template.id}
              phx-value-direction="down"
              disabled={index == length(@own) - 1}
              icon="hero-arrow-down"
              label={gettext("Move down")}
            />
            <.icon_button
              id={"group-template-#{template.id}-edit"}
              type="button"
              phx-click="group_template_edit"
              phx-value-id={template.id}
              icon="hero-pencil-square"
              label={gettext("Edit")}
            />
            <.icon_button
              id={"group-template-#{template.id}-delete"}
              type="button"
              phx-click="group_template_delete"
              phx-value-id={template.id}
              icon="hero-trash"
              label={gettext("Delete")}
              variant="danger"
              data-confirm={
                gettext(
                  "Delete this template? Descriptions made with it keep their look, and open as text."
                )
              }
            />
          </div>

          <.template_form
            :if={@form && editing?(@editing, template)}
            form={@form}
            editing={@editing}
            rows={@rows}
            preview={@preview}
            class="basis-full"
          />
        </li>
      </ul>

      <.template_form
        :if={@form && @editing && is_nil(@editing.id)}
        form={@form}
        editing={@editing}
        rows={@rows}
        preview={@preview}
        class="mt-4"
      />

      <div :if={@inherited != []} id="group-template-inherited" class="mt-6">
        <h4 class="text-sm font-semibold text-base-content">{gettext("From the groups above")}</h4>
        <p class="text-xs text-base-content/65">
          {gettext("This group uses them too. They are edited in their own group.")}
        </p>
        <ul class="mt-2 flex flex-col gap-2">
          <li
            :for={entry <- @inherited}
            id={"group-template-inherited-#{entry.template.id}"}
            class="flex flex-wrap items-center gap-3 rounded-2xl border border-base-300/60 bg-base-200/30 px-3 py-2"
          >
            <div class="flex min-w-0 flex-1 flex-col">
              <span class="truncate font-medium text-base-content">{entry.template.name}</span>
              <span class="truncate text-sm text-base-content/65">
                {fields_summary(entry.template)}
              </span>
            </div>
            <span class="shrink-0 rounded-full bg-primary/10 px-2 py-0.5 text-xs text-primary">
              {entry.owner}
            </span>
          </li>
        </ul>
      </div>
    </section>
    """
  end

  attr :form, :any, required: true
  attr :editing, :any, required: true
  attr :rows, :list, required: true
  attr :preview, :any, default: nil
  attr :class, :any, default: nil

  defp template_form(assigns) do
    assigns =
      assigns
      |> assign(:field_errors, Enum.map(assigns.form[:fields].errors, &translate_error/1))
      # Shown even before the box is typed in: removing a field the HTML
      # names is an error of the HTML.
      |> assign(:html_errors, Enum.map(assigns.form[:html].errors, &translate_error/1))
      |> assign(:kinds, kind_options())

    ~H"""
    <.form
      for={@form}
      id="group-template-form"
      phx-change="group_template_validate"
      phx-submit="group_template_save"
      class={["rounded-2xl border border-primary/30 bg-base-100 p-4 shadow-sm", @class]}
    >
      <h5 class="mb-2 font-medium text-base-content">
        {if(is_nil(@editing.id), do: gettext("New template"), else: gettext("Edit template"))}
      </h5>

      <.input field={@form[:name]} label={gettext("Name")} required />
      <.input field={@form[:purpose]} label={gettext("What it is for")} />

      <fieldset id="group-template-fields" class="fieldset mt-2">
        <legend class="fieldset-legend">{gettext("Fields")}</legend>
        <p class="text-xs text-base-content/65">
          {gettext(
            "The first required short text names a post in FeedCreator, and the first longer text goes on the card of a shared link."
          )}
        </p>

        <div
          :for={{row, index} <- Enum.with_index(@rows)}
          id={"group-template-field-#{index}"}
          class="mt-2 rounded-2xl border border-base-300/80 bg-base-100 p-3"
        >
          <div class="grid gap-x-3 sm:grid-cols-[minmax(0,1fr)_12rem]">
            <.input
              id={"group-template-field-#{index}-label"}
              name={"group_template[fields][#{index}][label]"}
              value={row["label"]}
              label={gettext("Label")}
              phx-debounce="400"
            />
            <.input
              id={"group-template-field-#{index}-kind"}
              type="select"
              name={"group_template[fields][#{index}][kind]"}
              value={row["kind"]}
              label={gettext("Kind")}
              options={@kinds}
            />
          </div>
          <div class="grid gap-x-3 sm:grid-cols-[12rem_minmax(0,1fr)]">
            <.input
              id={"group-template-field-#{index}-key"}
              name={"group_template[fields][#{index}][key]"}
              value={row["key"]}
              label={gettext("Key")}
              placeholder={key_of(row)}
              phx-debounce="400"
            />
            <.input
              id={"group-template-field-#{index}-hint"}
              name={"group_template[fields][#{index}][hint]"}
              value={row["hint"]}
              label={gettext("Hint")}
              phx-debounce="400"
            />
          </div>
          <.input
            :if={row["kind"] == "choice"}
            id={"group-template-field-#{index}-options"}
            type="textarea"
            rows="3"
            name={"group_template[fields][#{index}][options]"}
            value={row["options"]}
            label={gettext("Options, one per line")}
            phx-debounce="400"
          />
          <div class="flex flex-wrap items-center justify-between gap-2">
            <.input
              id={"group-template-field-#{index}-required"}
              type="checkbox"
              name={"group_template[fields][#{index}][required]"}
              value={row["required"]}
              label={gettext("Required")}
            />
            <code
              :if={key_of(row) != ""}
              id={"group-template-field-#{index}-tag"}
              class="rounded bg-base-200 px-1.5 py-0.5 text-xs text-base-content/80"
            >
              {tag_of(row)}
            </code>
            <div class="flex items-center gap-1">
              <.icon_button
                id={"group-template-field-#{index}-up"}
                type="button"
                name="group_template_action"
                value={"up:#{index}"}
                phx-click={JS.dispatch("change")}
                disabled={index == 0}
                icon="hero-arrow-up"
                label={gettext("Move up")}
              />
              <.icon_button
                id={"group-template-field-#{index}-down"}
                type="button"
                name="group_template_action"
                value={"down:#{index}"}
                phx-click={JS.dispatch("change")}
                disabled={index == length(@rows) - 1}
                icon="hero-arrow-down"
                label={gettext("Move down")}
              />
              <.icon_button
                id={"group-template-field-#{index}-remove"}
                type="button"
                name="group_template_action"
                value={"remove:#{index}"}
                phx-click={JS.dispatch("change")}
                icon="hero-x-mark"
                label={gettext("Remove the field")}
              />
            </div>
          </div>
        </div>

        <p
          :for={message <- @field_errors}
          id="group-template-fields-error"
          class="mt-2 flex items-center gap-1.5 text-sm text-error"
        >
          <.icon name="hero-exclamation-circle" class="size-4" /> {message}
        </p>

        <.button
          :if={length(@rows) < GroupTemplate.max_fields()}
          id="group-template-add-field"
          type="button"
          size="sm"
          class="mt-2 justify-self-start"
          name="group_template_action"
          value="add_field"
          phx-click={JS.dispatch("change")}
        >
          <.icon name="hero-plus" class="size-4" /> {gettext("Add a field")}
        </.button>
      </fieldset>

      <div class="mt-4">
        <.input
          id="group-template-html"
          name={@form[:html].name}
          value={@form[:html].value}
          errors={@html_errors}
          type="textarea"
          rows="12"
          label="HTML"
          spellcheck="false"
          phx-debounce="500"
          class="w-full rounded-2xl border border-base-300 bg-base-100 px-3 py-2 font-mono text-sm leading-relaxed"
        />
        <div class="flex flex-wrap items-start justify-between gap-3">
          <details id="group-template-syntax" class="text-sm text-base-content/75">
            <summary class="cursor-pointer select-none font-medium">
              {gettext("Tags that take the fields")}
            </summary>
            <ul class="mt-2 space-y-1">
              <li :for={{tag, meaning} <- syntax()} class="flex flex-wrap gap-x-2">
                <code class="rounded bg-base-200 px-1.5 py-0.5 text-xs">{tag}</code>
                <span>{meaning}</span>
              </li>
            </ul>
          </details>
          <.button
            id="group-template-html-from-fields"
            type="button"
            size="sm"
            variant="soft"
            name="group_template_action"
            value="html_from_fields"
            phx-click={JS.dispatch("change")}
            data-confirm={
              (@form[:html].value || "") != "" &&
                gettext("Replace the HTML with a plain layout of the fields?")
            }
          >
            <.icon name="hero-sparkles" class="size-4" /> {gettext("Make HTML from the fields")}
          </.button>
        </div>
      </div>

      <div :if={@preview} id="group-template-preview-box" class="mt-4">
        <h6 class="text-sm font-semibold text-base-content">
          {gettext("Preview with sample values")}
        </h6>
        <div
          id="group-template-preview"
          class="rich-content mt-2 max-h-96 overflow-auto rounded-2xl border border-base-300 bg-base-100 p-4"
        >
          {Phoenix.HTML.raw(@preview.html)}
        </div>
        <div
          :if={@preview.dropped != []}
          id="group-template-dropped"
          class="mt-2 rounded-2xl border border-warning/40 bg-warning/10 px-3 py-2 text-sm"
        >
          <p>
            {gettext(
              "A description shows no scripts and leaves out some tags, attributes and styles. Of this template it leaves out:"
            )}
          </p>
          <div class="mt-1 flex flex-wrap gap-1">
            <code
              :for={part <- @preview.dropped}
              class="rounded bg-base-100 px-1.5 py-0.5 text-xs"
            >
              {dropped_label(part)}
            </code>
          </div>
        </div>
      </div>

      <div class="mt-4 flex flex-wrap items-center justify-end gap-2">
        <.button id="group-template-cancel" type="button" phx-click="group_template_cancel">
          {gettext("Cancel")}
        </.button>
        <.button id="group-template-save" variant="primary" phx-disable-with={gettext("Saving...")}>
          {gettext("Save template")}
        </.button>
      </div>
    </.form>
    """
  end

  defp editing?(%GroupTemplate{id: id}, %GroupTemplate{id: id}) when not is_nil(id), do: true
  defp editing?(_editing, _template), do: false

  defp fields_summary(%GroupTemplate{fields: fields}) do
    case fields do
      [] -> gettext("No fields")
      fields -> Enum.map_join(fields, ", ", & &1["label"])
    end
  end

  # The key the row is saved with: its own, or one from its label.
  defp key_of(%{"key" => key, "label" => label}) do
    case String.trim(key) do
      "" -> if String.trim(label) == "", do: "", else: GroupTemplate.slug(label)
      key -> key
    end
  end

  defp tag_of(%{"kind" => kind} = row) do
    key = key_of(row)

    case kind do
      "textarea" -> "{{#{key}|paragraphs}}"
      "url" -> "{{#{key}|url}}"
      "date" -> "{{#{key}|date}}"
      "image" -> "{{#{key}|image}}"
      "video" -> "{{#{key}|video}}"
      "items" -> "{{##{key}}}{{.}}{{/#{key}}}"
      "pictures" -> "{{##{key}}}{{picture|image}} {{caption}}{{/#{key}}}"
      _text -> "{{#{key}}}"
    end
  end

  defp kind_options do
    [
      {gettext("Short text"), "text"},
      {gettext("Longer text"), "textarea"},
      {gettext("Link"), "url"},
      {gettext("Date"), "date"},
      {gettext("Time"), "time"},
      {gettext("Choice"), "choice"},
      {gettext("List"), "items"},
      {gettext("Picture"), "image"},
      {gettext("Pictures with captions"), "pictures"},
      {gettext("Video"), "video"}
    ]
  end

  defp syntax do
    [
      {"{{kljuc}}", gettext("the field's text")},
      {"{{kljuc|inline}}", gettext("with **bold**, *italics* and links")},
      {"{{kljuc|paragraphs}}", gettext("a longer text in paragraphs")},
      {"{{kljuc|date}}", gettext("a date, written out")},
      {"{{kljuc|url}} {{kljuc|image}} {{kljuc|video}}",
       gettext("an address, for href and src: the only way into one")},
      {"{{#kljuc}}…{{/kljuc}}", gettext("only when the field is filled; once per row of a list")},
      {"{{^kljuc}}…{{/kljuc}}", gettext("only when the field is empty")},
      {"{{.}}", gettext("the row of a list")},
      {"{{picture}} {{caption}}", gettext("the picture and caption of a row of pictures")}
    ]
  end

  defp dropped_label({:tag, tag}), do: tag
  defp dropped_label({:attribute, attribute}), do: attribute
  defp dropped_label({:style, style}), do: "style: " <> style
end
