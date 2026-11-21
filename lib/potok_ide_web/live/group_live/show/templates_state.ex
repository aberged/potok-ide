defmodule PotokIdeWeb.GroupLive.Show.TemplatesState do
  @moduledoc """
  What `GroupLive.Show` holds about the templates of a group's own
  (`PotokIde.Social.GroupTemplates`): the catalog the description forms offer,
  and the Šabloni card of the edit tab where the group's editors make them.
  `GroupLive.Show` delegates every `"group_template_*"` event here.

  The card's form keeps its field rows as the browser sent them
  (`template_rows`), so a row still being written stays on screen while the
  changeset reports what is wrong; a row with neither a label nor a key is
  left out of what is saved. Its buttons (add, remove and move a row, make the
  HTML from the fields) send the form as a change, with `group_template_action`.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3, to_form: 1]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias PotokIde.Social.{GroupTemplate, GroupTemplates, Profile}
  alias PotokIdeWeb.PostTemplates.Custom

  def init(socket) do
    assign(socket,
      template_catalog: [],
      own_templates: [],
      inherited_templates: [],
      template_form: nil,
      template_editing: nil,
      template_rows: [],
      template_preview: nil
    )
  end

  @doc """
  The templates of the group's own and of the groups above it: as the
  description's form takes them (`template_catalog`), and as the Šabloni card
  lists them. Only the edit tab writes descriptions.
  """
  def load(%{assigns: %{current_profile: %Profile{} = profile}} = socket, group, "edit_group") do
    {own, inherited} =
      group
      |> GroupTemplates.catalog(profile)
      |> Enum.split_with(& &1.own?)

    socket
    |> assign(:template_catalog, Enum.map(own ++ inherited, &form_template/1))
    |> assign(:own_templates, Enum.map(own, & &1.template))
    |> assign(:inherited_templates, Enum.map(inherited, &%{&1 | owner: owner(&1)}))
  end

  def load(socket, _group, _active_tab) do
    socket
    |> assign(template_catalog: [], own_templates: [], inherited_templates: [])
    |> close()
  end

  defp reload(socket), do: load(socket, socket.assigns.group, socket.assigns.active_tab)

  defp form_template(entry), do: Custom.form_template(entry.template, owner(entry))

  # A template of the group's own needs no label; one from above names its
  # group, unless the viewer cannot see that group.
  defp owner(%{own?: true}), do: nil
  defp owner(%{owner: name}) when is_binary(name), do: name
  defp owner(_entry), do: gettext("From a group above")

  ## Events

  def handle_event("group_template_new", _params, socket) do
    rows = [
      %{"label" => gettext("Title"), "kind" => "text", "required" => true},
      %{"label" => gettext("Text"), "kind" => "textarea"}
    ]

    html =
      case GroupTemplate.normalize_fields(rows) do
        {:ok, fields} -> Custom.starter_html(fields)
        {:error, _message} -> ""
      end

    {:noreply,
     open(socket, %GroupTemplate{}, Enum.map(rows, &row/1), %{
       "name" => "",
       "purpose" => "",
       "html" => html
     })}
  end

  def handle_event("group_template_edit", %{"id" => id}, socket) do
    case find_own(socket, id) do
      nil ->
        {:noreply, socket}

      template ->
        {:noreply,
         open(socket, template, Enum.map(template.fields, &row/1), %{
           "name" => template.name,
           "purpose" => template.purpose,
           "html" => template.html
         })}
    end
  end

  def handle_event("group_template_cancel", _params, socket), do: {:noreply, close(socket)}

  def handle_event("group_template_validate", %{"group_template" => params} = all, socket) do
    if socket.assigns.template_editing do
      {rows, params} = act(rows(params), params, all["group_template_action"])
      {:noreply, put_form(socket, rows, params, :validate)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("group_template_save", %{"group_template" => params}, socket) do
    %{current_profile: profile, group: group, template_editing: editing} = socket.assigns
    rows = rows(params)
    attrs = attrs(rows, params)

    result =
      case editing do
        %GroupTemplate{id: nil} -> GroupTemplates.create(profile, group, attrs)
        %GroupTemplate{} -> GroupTemplates.update(profile, group, editing, attrs)
        nil -> {:error, :not_found}
      end

    case result do
      {:ok, _template} ->
        {:noreply, socket |> close() |> reload() |> put_flash(:info, gettext("Template saved."))}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_form(socket, rows, params, :insert)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("group_template_delete", %{"id" => id}, socket) do
    %{current_profile: profile, group: group} = socket.assigns

    with %GroupTemplate{} = template <- find_own(socket, id),
         {:ok, _deleted} <- GroupTemplates.delete(profile, group, template) do
      editing = socket.assigns.template_editing
      socket = if editing && editing.id == template.id, do: close(socket), else: socket

      {:noreply, socket |> reload() |> put_flash(:info, gettext("Template deleted."))}
    else
      nil -> {:noreply, socket}
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event("group_template_move", %{"id" => id, "direction" => direction}, socket)
      when direction in ["up", "down"] do
    %{current_profile: profile, group: group} = socket.assigns

    with %GroupTemplate{} = template <- find_own(socket, id),
         {:ok, _moved} <-
           GroupTemplates.move(profile, group, template, String.to_existing_atom(direction)) do
      {:noreply, reload(socket)}
    else
      nil -> {:noreply, socket}
      {:error, reason} -> {:noreply, put_flash(socket, :error, error_message(reason))}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  ## The form

  defp open(socket, template, rows, params) do
    socket
    |> assign(:template_editing, template)
    |> put_form(rows, params, nil)
  end

  defp close(socket) do
    assign(socket,
      template_form: nil,
      template_editing: nil,
      template_rows: [],
      template_preview: nil
    )
  end

  defp put_form(socket, rows, params, action) do
    changeset =
      socket.assigns.template_editing
      |> GroupTemplates.change(attrs(rows, params))
      |> then(&if(action, do: Map.put(&1, :action, action), else: &1))

    socket
    |> assign(:template_rows, rows)
    |> assign(:template_form, to_form(changeset))
    |> assign(:template_preview, preview(changeset))
  end

  defp attrs(rows, params) do
    %{
      "name" => params["name"] || "",
      "purpose" => params["purpose"] || "",
      "html" => params["html"] || "",
      "fields" => Enum.reject(rows, &blank_row?/1)
    }
  end

  defp blank_row?(row), do: String.trim(row["label"]) == "" and String.trim(row["key"]) == ""

  # The template with sample values, as a description shows it, and what the
  # sanitizer leaves out; nothing while the fields or the HTML are wrong.
  defp preview(changeset) do
    if Keyword.has_key?(changeset.errors, :fields) or Keyword.has_key?(changeset.errors, :html) do
      nil
    else
      template = Ecto.Changeset.apply_changes(changeset)
      %{html: Custom.thumbnail(template), dropped: Custom.dropped(template)}
    end
  end

  # A row as the form shows it: options as lines, `required` as a boolean.
  defp row(field) do
    %{
      "label" => text(field["label"]),
      "kind" => if(field["kind"] in GroupTemplate.kinds(), do: field["kind"], else: "text"),
      "required" => field["required"] in [true, "true", "on"],
      "key" => text(field["key"]),
      "options" => field["options"] |> List.wrap() |> Enum.map_join("\n", &text/1),
      "hint" => text(field["hint"])
    }
  end

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: ""

  defp rows(params) do
    case params["fields"] do
      %{} = fields ->
        fields
        |> Enum.sort_by(fn {index, _row} -> index_of(index) end)
        |> Enum.map(fn {_index, row} -> row(row) end)

      _none ->
        []
    end
  end

  defp index_of(index) do
    case Integer.parse(to_string(index)) do
      {number, ""} -> number
      _other -> 0
    end
  end

  @empty_row %{
    "label" => "",
    "kind" => "text",
    "required" => false,
    "key" => "",
    "options" => "",
    "hint" => ""
  }

  defp act(rows, params, "add_field") do
    if length(rows) < GroupTemplate.max_fields(),
      do: {rows ++ [@empty_row], params},
      else: {rows, params}
  end

  defp act(rows, params, "html_from_fields") do
    case GroupTemplate.normalize_fields(Enum.reject(rows, &blank_row?/1)) do
      {:ok, fields} -> {rows, Map.put(params, "html", Custom.starter_html(fields))}
      {:error, _message} -> {rows, params}
    end
  end

  defp act(rows, params, action) when is_binary(action) do
    with [verb, index] <- String.split(action, ":", parts: 2),
         {index, ""} <- Integer.parse(index),
         true <- index >= 0 and index < length(rows) do
      {row_action(rows, verb, index), params}
    else
      _invalid -> {rows, params}
    end
  end

  defp act(rows, params, _action), do: {rows, params}

  defp row_action(rows, "remove", index), do: List.delete_at(rows, index)
  defp row_action(rows, "up", index) when index > 0, do: swap(rows, index, index - 1)

  defp row_action(rows, "down", index) when index < length(rows) - 1,
    do: swap(rows, index, index + 1)

  defp row_action(rows, _verb, _index), do: rows

  defp swap(rows, a, b) do
    rows
    |> List.replace_at(a, Enum.at(rows, b))
    |> List.replace_at(b, Enum.at(rows, a))
  end

  defp find_own(socket, id) do
    with {id, ""} <- Integer.parse(to_string(id)) do
      Enum.find(socket.assigns.own_templates, &(&1.id == id))
    else
      _invalid -> nil
    end
  end

  defp error_message(:too_many_templates),
    do:
      gettext("A group holds at most %{count} templates.",
        count: GroupTemplates.max_per_group()
      )

  defp error_message(:not_permitted), do: gettext("You may not change this group's templates.")
  defp error_message(_reason), do: gettext("The template is gone.")
end
