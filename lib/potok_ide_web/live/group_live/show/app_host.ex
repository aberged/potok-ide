defmodule PotokIdeWeb.GroupLive.Show.AppHost do
  @moduledoc """
  What a LiveView that runs a group's app holds for its frame: the upload of
  the files the app sends, and the values and events pushed to the frame.

  `GroupLive.Show` runs the app of its own group (host `"page"`), and
  `GroupLive.Sheet` the app of a sub-group, over a map on the same page (host
  `"sheet"`). LiveView hands a pushed event to every hook of the page, so each
  push names its host and a frame takes only its own (`GroupAppFrame`). Each
  host has an upload of its own name too, as a page finds the file inputs of
  the views inside it as well.
  """

  import Phoenix.Component, only: [assign: 3, upload_errors: 2]

  import Phoenix.LiveView,
    only: [allow_upload: 3, cancel_upload: 3, consume_uploaded_entry: 3, push_event: 3]

  alias PotokIde.Social.{AppFiles, Group, Value, ValueAttachment}
  alias PotokIde.Storage
  alias PotokIdeWeb.GroupLive.Show
  alias PotokIdeWeb.PostTemplates

  @hosts ~w(page sheet)

  @doc "Sets up `socket` to run an app as `host`."
  def allow(socket, host) when host in @hosts do
    opts = [
      accept: :any,
      max_entries: 1,
      max_file_size: Storage.max_file_size(),
      auto_upload: true,
      progress: &app_file_progress/3
    ]

    opts =
      if Storage.direct_upload?(),
        do: Keyword.put(opts, :external, &presign_app_file/2),
        else: opts

    socket
    |> assign(:app_host, host)
    |> assign(:app_upload, nil)
    |> allow_upload(upload_name(host), opts)
  end

  @doc "The name of the upload of the host's frame."
  def upload_name("sheet"), do: :sheet_app_file
  def upload_name(_page), do: :app_file

  @doc "The id of the emoji picker of the host's description."
  def picker_id("sheet"), do: "sheet-reaction-picker"
  def picker_id(_page), do: "reaction-picker"

  @doc "The host the socket runs its app as."
  def host(socket), do: Map.get(socket.assigns, :app_host, "page")

  @doc "Pushes `event` to the frame of this host only."
  def push(socket, event, payload) when is_map(payload) do
    push_event(socket, event, Map.put(payload, :host, host(socket)))
  end

  @doc """
  A file the upload refuses outright (too big, too many) is told to the frame
  at once; the rest goes up on its own (`auto_upload`).
  """
  def validate_file(socket) do
    name = upload_name(host(socket))

    case Enum.reject(socket.assigns.uploads[name].entries, & &1.valid?) do
      [] ->
        socket

      rejected ->
        rejected
        |> Enum.reduce(socket, &cancel_upload(&2, name, &1.ref))
        |> app_upload_done(%{ok: false, error: "invalid_files"})
    end
  end

  @doc """
  Only the app frame listens for data values, so they are pushed only while
  the group description is on screen, and only those of apps the viewer can
  open. The SDK hands an app its own values unless it asked for all. Members
  only, like the list of values in `AppApi`: a public group lets anyone open
  the app, but its data stays with the members.
  """
  def announce_new_data_value(%{assigns: %{is_member: false}} = socket, _value), do: socket

  def announce_new_data_value(socket, %Value{} = value) do
    if Show.description_visible?(socket.assigns) and data_value_visible?(socket.assigns, value) do
      push(socket, "new_data_value", Show.value_payload(value))
    else
      socket
    end
  end

  defp data_value_visible?(_assigns, %Value{alt_description_id: nil}), do: true

  defp data_value_visible?(assigns, %Value{alt_description_id: id}),
    do: Enum.any?(assigns.visible_alt_descriptions, &(&1.id == id))

  # A file the app's frame sends for a value or a picture of the app, after the
  # app asked (`AppApi` `prepare_upload` keeps `:app_upload`). Only the file it
  # announced is taken, and into the group `AppFiles` chose for it.
  defp announced_app_file?(%{app_upload: %{} = upload}, entry),
    do:
      entry.client_name == upload.name and entry.client_size == upload.size and
        entry.client_size <= upload.max_bytes

  defp announced_app_file?(_assigns, _entry), do: false

  defp presign_app_file(entry, socket) do
    upload = socket.assigns.app_upload
    key = upload && Storage.new_key(upload.file_group_id)
    content_type = ValueAttachment.clean_content_type(entry.client_type)

    with true <- announced_app_file?(socket.assigns, entry),
         {:ok, url} <- Storage.presign_put(key, content_type, entry.client_size) do
      {:ok, %{uploader: "S3", key: key, url: url, content_type: content_type}, socket}
    else
      _ -> {:error, %{reason: "not_permitted"}, socket}
    end
  end

  # Also called when an upload to the bucket fails, with the entry not done.
  defp app_file_progress(name, %{done?: true} = entry, socket) do
    if announced_app_file?(socket.assigns, entry) do
      {:noreply, store_app_file(socket, name, entry)}
    else
      {:noreply,
       socket
       |> cancel_upload(name, entry.ref)
       |> app_upload_done(%{ok: false, error: "invalid_files"})}
    end
  end

  defp app_file_progress(name, entry, socket) do
    if upload_errors(socket.assigns.uploads[name], entry) == [] do
      {:noreply, app_upload_progress(socket, entry.progress)}
    else
      {:noreply,
       socket
       |> cancel_upload(name, entry.ref)
       |> app_upload_done(%{ok: false, error: "invalid_files"})}
    end
  end

  defp store_app_file(socket, _name, entry) do
    upload = socket.assigns.app_upload
    profile = socket.assigns.current_profile

    stored =
      consume_uploaded_entry(
        socket,
        entry,
        &{:ok, Show.store_attachment(%Group{id: upload.file_group_id}, &1, entry)}
      )

    with {:ok, attrs} <- stored,
         {:ok, attachment} <- AppFiles.store(profile, upload, attrs) do
      app_upload_done(socket, %{ok: true, file: app_file_payload(attachment, upload)})
    else
      _error -> app_upload_done(socket, %{ok: false, error: "invalid_files"})
    end
  end

  # A picture of the app has an address anyone who sees the app can open; a
  # file of a value is opened through `file_url`, by who may.
  defp app_file_payload(attachment, upload) do
    payload = %{
      file: attachment.id,
      name: attachment.filename,
      size: attachment.byte_size,
      type: attachment.content_type
    }

    if upload.collection,
      do: payload,
      else: Map.put(payload, :url, PostTemplates.Picture.address(attachment))
  end

  defp app_upload_done(%{assigns: %{app_upload: %{ref: ref}}} = socket, result) do
    socket
    |> assign(:app_upload, nil)
    |> push("app_upload_done", Map.put(result, :ref, ref))
  end

  defp app_upload_done(socket, _result), do: socket

  defp app_upload_progress(%{assigns: %{app_upload: %{ref: ref}}} = socket, progress),
    do: push(socket, "app_upload_progress", %{ref: ref, progress: progress})

  defp app_upload_progress(socket, _progress), do: socket
end
