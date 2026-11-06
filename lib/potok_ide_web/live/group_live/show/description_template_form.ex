defmodule PotokIdeWeb.GroupLive.Show.DescriptionTemplateForm do
  @moduledoc """
  A description written through a template (`PotokIdeWeb.PostTemplates`): the
  list of templates and the form of the chosen one. Both sit inside the form
  of the description, and every button is a form change, so all of it goes
  through that form's validate event and `PostTemplates.Form`.
  """

  use PotokIdeWeb, :html

  alias PotokIdeWeb.PostTemplates
  alias PotokIdeWeb.PostTemplates.Markup

  attr :id_prefix, :string, required: true
  attr :decoded, :any, required: true, doc: "the description, as `Post.decode/1` reads it"
  attr :open, :boolean, default: false, doc: "whether the list of templates is open"

  attr :replaces_text, :boolean,
    default: false,
    doc: "whether picking a template replaces text someone wrote"

  # The list is only rendered while open. Its pictures are the size of a
  # description, and a closed one would be sent again with every keystroke.
  def chooser(assigns) do
    assigns = assign(assigns, :current, current_template(assigns.decoded))

    ~H"""
    <div class="mt-4 flex flex-wrap items-center justify-between gap-2">
      <p id={"#{@id_prefix}-template-current"} class="text-sm">
        <span class="text-base-content/65">{gettext("Template:")}</span>
        <span class="font-medium">{PostTemplates.template(@current).name}</span>
      </p>
      <.button
        id={"#{@id_prefix}-template-change"}
        type="button"
        size="sm"
        aria-expanded={to_string(@open)}
        phx-click="toggle_template_list"
        phx-value-workspace={@id_prefix}
      >
        <.icon name="hero-squares-2x2" class="size-4" />
        {if(@open, do: gettext("Close the list"), else: gettext("Change template"))}
      </.button>
    </div>

    <.changed_notice
      :if={match?({:changed, _post}, @decoded)}
      id_prefix={@id_prefix}
      decoded={@decoded}
    />

    <div :if={@open} id={"#{@id_prefix}-templates"} class="post-template-grid mt-3">
      <button
        :for={template <- PostTemplates.templates()}
        id={"#{@id_prefix}-template-#{template.id}"}
        type="button"
        name="description_template[pick]"
        value={template.id}
        aria-current={template.id == @current && "true"}
        data-confirm={
          (@replaces_text and template.id != PostTemplates.free_text()) &&
            gettext("The template replaces the text now in the description. Continue?")
        }
        phx-click={JS.dispatch("change")}
        class={["post-template", template.id == @current && "post-template-current"]}
      >
        <span class="post-template-thumb" aria-hidden="true">
          <span class="post-template-page rich-content">
            {Phoenix.HTML.raw(PostTemplates.thumbnail(template.id))}
          </span>
        </span>
        <span class="px-3 pt-2 font-medium">{template.name}</span>
        <span class="px-3 pb-3 text-sm opacity-70">{template.purpose}</span>
      </button>
    </div>
    """
  end

  defp current_template({:post, %{template: id}}), do: id
  defp current_template(_decoded), do: PostTemplates.free_text()

  attr :id_prefix, :string, required: true
  attr :decoded, :any, required: true

  defp changed_notice(assigns) do
    {:changed, %{template: id}} = assigns.decoded
    assigns = assign(assigns, :template, PostTemplates.template(id))

    ~H"""
    <div
      id={"#{@id_prefix}-template-changed"}
      role="status"
      class="mt-3 rounded-2xl border border-warning/40 bg-warning/10 px-4 py-3 text-sm"
    >
      <p>
        {gettext(
          "This description was changed by hand, so it opens as text. The form would undo that change."
        )}
      </p>
      <.button
        id={"#{@id_prefix}-template-restore"}
        type="button"
        size="sm"
        class="mt-2"
        name="description_template[restore]"
        value="1"
        data-confirm={gettext("Going back to the template drops the change made by hand. Continue?")}
        phx-click={JS.dispatch("change")}
      >
        {gettext("Back to the template %{name}", name: @template.name)}
      </.button>
    </div>
    """
  end

  attr :id_prefix, :string, required: true
  attr :post, :map, required: true, doc: "the template and fields of the description"
  attr :picture_upload, :any, default: nil

  def fields(assigns) do
    template = PostTemplates.template(assigns.post.template)

    assigns =
      assigns
      |> assign(:template, template)
      |> assign(:missing, PostTemplates.missing_fields(template.id, assigns.post.fields))

    ~H"""
    <div id={"#{@id_prefix}-template-fields"}>
      <input type="hidden" name="description_template[id]" value={@template.id} />
      <.template_field
        :for={field <- @template.fields}
        id={"#{@id_prefix}-template-field-#{field.key}"}
        field={field}
        value={@post.fields[field.key]}
        picture_upload={@picture_upload}
      />
      <p
        :if={@missing != []}
        id={"#{@id_prefix}-template-missing"}
        class="mt-2 text-sm text-base-content/70"
      >
        {gettext("Still needed: %{fields}", fields: Enum.join(@missing, ", "))}
      </p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :field, :map, required: true
  attr :value, :any, default: nil
  attr :picture_upload, :any, default: nil

  defp template_field(%{field: %{kind: :items}} = assigns) do
    items = if is_list(assigns.value) and assigns.value != [], do: assigns.value, else: [""]
    assigns = assign(assigns, :items, Enum.filter(items, &is_binary/1))

    ~H"""
    <fieldset id={@id} class="fieldset mb-2">
      <legend class="label mb-1">{@field.label}</legend>
      <div :for={{item, index} <- Enum.with_index(@items)} class="flex items-center gap-2">
        <span class="w-5 shrink-0 text-right text-sm font-semibold text-base-content/65">
          {index + 1}
        </span>
        <div class="min-w-0 flex-1">
          <.input
            id={"#{@id}-#{index}"}
            type="text"
            name={field_name(@field) <> "[]"}
            value={item}
            phx-debounce="500"
          />
        </div>
        <.button
          :if={length(@items) > 1}
          id={"#{@id}-#{index}-remove"}
          type="button"
          variant="ghost"
          size="sm"
          name="description_template[remove_item]"
          value={index}
          aria-label={gettext("Remove item %{number}", number: index + 1)}
          phx-click={JS.dispatch("change")}
        >
          <.icon name="hero-x-mark" class="size-4" />
        </.button>
      </div>
      <.button
        :if={length(@items) < PostTemplates.max_items()}
        id={"#{@id}-add"}
        type="button"
        size="sm"
        class="justify-self-start"
        name="description_template[add_item]"
        value="1"
        phx-click={JS.dispatch("change")}
      >
        <.icon name="hero-plus" class="size-4" /> {gettext("Add an item")}
      </.button>
    </fieldset>
    """
  end

  defp template_field(%{field: %{kind: :image}} = assigns) do
    address = assigns |> text_value() |> Markup.safe_image()
    sending? = assigns.picture_upload != nil and assigns.picture_upload.entries != []

    assigns =
      assigns
      |> assign(:address, address)
      |> assign(:failed, picture_failed?(assigns.picture_upload))
      |> assign(:sending, sending? and not picture_failed?(assigns.picture_upload))

    ~H"""
    <div id={"#{@id}-box"} class="mb-2">
      <%!-- Without `phx-debounce`: the address of a sent picture is written here
           from the outside, and a page update coming during the wait would
           clear it again. --%>
      <.input
        id={@id}
        type="text"
        inputmode="url"
        name={field_name(@field)}
        label={@field.label}
        value={text_value(assigns)}
        placeholder="https://"
      />
      <div class="flex flex-wrap items-center gap-2">
        <.button
          :if={@picture_upload}
          id={"#{@id}-device"}
          type="button"
          size="sm"
          phx-click={
            JS.dispatch("potok:pick-picture", to: "#description-picture", detail: %{target: @id})
          }
        >
          <.icon name="hero-photo" class="size-4" /> {gettext("From the device")}
        </.button>
        <.button
          :if={@address != ""}
          id={"#{@id}-clear"}
          type="button"
          variant="ghost"
          size="sm"
          name="description_template[clear_image]"
          value="1"
          phx-click={JS.dispatch("change")}
        >
          <.icon name="hero-x-mark" class="size-4" /> {gettext("Remove the picture")}
        </.button>
        <span :if={@sending} id={"#{@id}-sending"} class="text-sm text-base-content/70">
          {gettext("Sending the picture...")}
        </span>
        <span :if={@failed} id={"#{@id}-failed"} class="text-sm text-error">
          {gettext("The picture could not be sent.")}
        </span>
      </div>
      <p :if={@picture_upload} class="mt-1 text-xs text-base-content/65">
        {gettext(
          "It goes to the chat as a message with the file. Deleting that message removes the picture from the description."
        )}
      </p>
      <img :if={@address != ""} src={@address} alt="" class="mt-2 max-h-32 rounded-xl" />
    </div>
    """
  end

  defp template_field(assigns) do
    assigns = assign(assigns, :text, text_value(assigns))

    ~H"""
    <.input
      :if={@field.kind == :level}
      id={@id}
      type="select"
      name={field_name(@field)}
      label={@field.label}
      value={@text}
      options={PostTemplates.level_options()}
    />
    <.input
      :if={@field.kind == :textarea}
      id={@id}
      type="textarea"
      rows={if(@field.key == "body", do: "6", else: "3")}
      name={field_name(@field)}
      label={@field.label}
      value={@text}
      placeholder={@field.placeholder}
      phx-debounce="500"
    />
    <.input
      :if={@field.kind in [:text, :url, :date, :time]}
      id={@id}
      type={input_type(@field.kind)}
      inputmode={@field.kind == :url && "url"}
      name={field_name(@field)}
      label={@field.label}
      value={@text}
      placeholder={@field.placeholder}
      phx-debounce="500"
    />
    <p :if={@field.hint} class="-mt-1 mb-2 text-xs text-base-content/65">{@field.hint}</p>
    """
  end

  # An address stays plain text: `example.com` is fine here, and the browser
  # would stop the form over it.
  defp input_type(:date), do: "date"
  defp input_type(:time), do: "time"
  defp input_type(_kind), do: "text"

  defp field_name(%{key: key}), do: "description_template[fields][#{key}]"

  defp text_value(%{value: value}) when is_binary(value), do: value
  defp text_value(_assigns), do: ""

  defp picture_failed?(nil), do: false

  defp picture_failed?(upload),
    do: upload_errors(upload) != [] or Enum.any?(upload.entries, &(not &1.valid?))
end
