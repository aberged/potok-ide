defmodule PotokIdeWeb.TagEditor do
  @moduledoc """
  The tag editor of a LiveView: one dialog per page (`TagComponents.tag_editor/1`)
  for the tags of one item at a time. The host LiveView calls `init/1` in
  mount and delegates every `"tag_editor_*"` event to `handle_event/3`.

  After a change the host gets `{:tags_changed, kind, item_id}`, the same
  message `PotokIde.Tags` broadcasts to the item's group for public tags, so
  one handler refreshes the item for both.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  import Phoenix.Component, only: [assign: 3, to_form: 2]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias PotokIde.Events.Event
  alias PotokIde.Social.{Group, Profile, Value, ValueAttachment}
  alias PotokIde.Tags
  alias PotokIde.Tags.Tag

  @kinds Map.new(Tags.kinds(), &{Atom.to_string(&1), &1})

  def init(socket), do: assign(socket, :tag_editor, nil)

  @doc """
  Opens the editor for an item. `actor` puts and takes off the tags: the
  current profile, or on its own edit page the profile itself. With
  `public_only?` only public tags are added.
  """
  def open(socket, %Profile{} = actor, kind, item_id, opts \\ []) do
    case Tags.get_taggable(actor, kind, item_id) do
      {:ok, %{item: item, can_public?: can_public?}} ->
        public_only? = Keyword.get(opts, :public_only?, false) and can_public?

        editor = %{
          actor: actor,
          kind: kind,
          item_id: item_id,
          title: title(item),
          can_public?: can_public?,
          public_only?: public_only?,
          tags: editor_tags(actor, kind, item_id, public_only?),
          form: form("", if(public_only?, do: "public", else: "private")),
          suggestions: [],
          error: nil
        }

        socket
        |> assign(:tag_editor, editor)
        |> put_suggestions("")

      {:error, _reason} ->
        put_flash(socket, :error, gettext("That item is no longer available."))
    end
  end

  def handle_event("tag_editor_open", %{"kind" => kind, "id" => id}, socket) do
    with {:ok, kind} <- Map.fetch(@kinds, kind),
         {item_id, ""} <- Integer.parse(to_string(id)) do
      {:noreply, open(socket, socket.assigns.current_profile, kind, item_id)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("tag_editor_close", _params, socket),
    do: {:noreply, assign(socket, :tag_editor, nil)}

  def handle_event(_event, _params, %{assigns: %{tag_editor: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("tag_editor_search", %{"tag" => params}, socket) do
    editor = socket.assigns.tag_editor
    name = Map.get(params, "name", "")
    visibility = visibility_param(params["visibility"], editor)

    {:noreply,
     socket
     |> assign(:tag_editor, %{editor | form: form(name, visibility), error: nil})
     |> put_suggestions(name)}
  end

  # From the form (`%{"tag" => ...}`) or a suggestion (`name`, `visibility`).
  def handle_event("tag_editor_add", params, socket) do
    editor = socket.assigns.tag_editor
    params = Map.get(params, "tag", params)
    name = Map.get(params, "name", "")
    visibility = visibility_param(params["visibility"], editor)

    case Tags.add_tag(
           editor.actor,
           editor.kind,
           editor.item_id,
           name,
           String.to_existing_atom(visibility)
         ) do
      {:ok, _tag} ->
        send(self(), {:tags_changed, editor.kind, editor.item_id})

        {:noreply,
         socket
         |> assign(:tag_editor, %{refresh_tags(editor) | form: form("", visibility), error: nil})
         |> put_suggestions("")}

      {:error, reason} ->
        {:noreply, put_error(socket, reason)}
    end
  end

  def handle_event("tag_editor_remove", %{"tag-id" => tag_id}, socket) do
    editor = socket.assigns.tag_editor

    with {tag_id, ""} <- Integer.parse(to_string(tag_id)),
         {:ok, _tag} <- Tags.remove_tag(editor.actor, editor.kind, editor.item_id, tag_id) do
      send(self(), {:tags_changed, editor.kind, editor.item_id})

      {:noreply,
       socket
       |> assign(:tag_editor, %{refresh_tags(editor) | error: nil})
       |> put_suggestions(editor.form[:name].value || "")}
    else
      {:error, reason} -> {:noreply, put_error(socket, reason)}
      _ -> {:noreply, socket}
    end
  end

  # In the dialog, which covers the page's flash messages.
  defp put_error(socket, reason),
    do: assign(socket, :tag_editor, %{socket.assigns.tag_editor | error: error_message(reason)})

  @doc """
  Reads the item's tags again when the editor shows that item, as after a
  `{:tags_changed, kind, item_id}` from another member.
  """
  def refresh(
        %{assigns: %{tag_editor: %{kind: kind, item_id: item_id} = editor}} = socket,
        kind,
        item_id
      ),
      do: assign(socket, :tag_editor, refresh_tags(editor))

  def refresh(socket, _kind, _item_id), do: socket

  defp refresh_tags(editor),
    do: %{
      editor
      | tags: editor_tags(editor.actor, editor.kind, editor.item_id, editor.public_only?)
    }

  defp editor_tags(actor, kind, item_id, public_only?) do
    tags = Map.get(Tags.tags_for(actor, kind, [item_id]), item_id, [])
    if public_only?, do: Enum.filter(tags, &Tag.public?/1), else: tags
  end

  # Tags not on the item yet; only public ones when only those are added.
  defp put_suggestions(socket, query) do
    editor = socket.assigns.tag_editor
    on_item = MapSet.new(editor.tags, & &1.id)

    suggestions =
      editor.actor
      |> Tags.suggest_tags(query, 12)
      |> Enum.reject(&MapSet.member?(on_item, &1.id))
      |> Enum.filter(&(not editor.public_only? or Tag.public?(&1)))
      |> Enum.take(8)

    assign(socket, :tag_editor, %{editor | suggestions: suggestions})
  end

  defp form(name, visibility),
    do: to_form(%{"name" => name, "visibility" => visibility}, as: :tag)

  defp visibility_param(_param, %{public_only?: true}), do: "public"
  defp visibility_param("public", %{can_public?: true}), do: "public"
  defp visibility_param(_param, _editor), do: "private"

  defp title(%Group{name: name}), do: name
  defp title(%Profile{username: username}), do: "@" <> username
  defp title(%Event{title: title}), do: title
  defp title(%ValueAttachment{filename: filename}), do: filename

  defp title(%Value{} = value) do
    case Value.excerpt(value, 80) do
      nil -> "@" <> value.creator.username
      excerpt -> "@#{value.creator.username}: #{excerpt}"
    end
  end

  defp error_message(:not_permitted),
    do: gettext("You are not allowed to change the public tags here.")

  defp error_message(:too_many_tags),
    do:
      gettext("An item carries at most %{count} public tags and %{count} of your private ones.",
        count: Tags.max_tags_per_item()
      )

  defp error_message(:not_found), do: gettext("That item is no longer available.")

  defp error_message(%Ecto.Changeset{}),
    do:
      gettext("A tag is up to %{count} letters, numbers, spaces, _, . and -.",
        count: Tag.max_length()
      )
end
