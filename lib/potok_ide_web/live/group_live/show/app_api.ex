defmodule PotokIdeWeb.GroupLive.Show.AppApi do
  @moduledoc """
  Server side of the API that apps in `uses_api` groups reach from their
  sandboxed iframe (`potok_app_sdk.js` -> `GroupAppFrame` hook -> `app_api`).

  The hook only forwards whitelisted methods, but every permission is checked
  here again: the iframe content is written by the group creator and runs for
  every viewer.
  """
  use Gettext, backend: PotokIdeWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias PotokIde.Social
  alias PotokIdeWeb.Avatars
  alias PotokIdeWeb.GroupLive.Show

  # Token bucket for writes: bursts of up to @write_burst, refilled over @write_window_ms.
  @write_burst 30
  @write_window_ms 10_000

  @max_list_limit 200

  def new_bucket do
    %{tokens: @write_burst, refilled_at: System.monotonic_time(:millisecond)}
  end

  @doc "Runs an API method and returns `{reply, socket}`."
  def call("insert_value", params, socket) do
    with :ok <- require_member(socket, gettext("You must be a group member to post values.")),
         {:ok, socket} <- take_write_token(socket) do
      attrs = %{
        "content" => "data:",
        "data" => Map.get(params, "data"),
        "content_format" => Map.get(params, "content_format") || "markdown"
      }

      case Social.create_data_value(
             socket.assigns.current_profile,
             socket.assigns.group,
             attrs
           ) do
        {:ok, value} ->
          {%{ok: true, value: Show.value_payload(value)}, socket}

        {:error, _reason} ->
          {error("invalid_value", gettext("Could not create value.")), socket}
      end
    else
      {:error, reply} -> {reply, socket}
    end
  end

  def call("list_values", params, socket) do
    case require_member(
           socket,
           gettext("You must be a group member to access group data values.")
         ) do
      :ok ->
        {rows, has_more?} =
          Social.list_group_data_value_rows(socket.assigns.group,
            limit: non_negative_integer(params["limit"]) |> clamp_limit(),
            offset: non_negative_integer(params["offset"]),
            after_id: non_negative_integer(params["after_id"]),
            before_id: non_negative_integer(params["before_id"]),
            search_field: optional_string(params["search_field"]),
            search_value: optional_string(params["search_value"]),
            order_by: optional_string(params["order_by"]),
            order_dir: optional_string(params["order_dir"])
          )

        values = Enum.map(rows, &Map.update!(&1, :content_format, fn f -> to_string(f) end))
        {%{ok: true, values: values, has_more: has_more?}, socket}

      {:error, reply} ->
        {reply, socket}
    end
  end

  def call("update_description", params, socket) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group
    not_creator = gettext("Only the group creator can edit this group.")

    with true <- creator?(current_profile, group) || {:error, error("forbidden", not_creator)},
         {:ok, socket} <- take_write_token(socket) do
      attrs = %{
        "description" => string_param(params["description"], group.description || ""),
        "description_format" =>
          string_param(params["description_format"], to_string(group.description_format))
      }

      case Social.update_group_description(current_profile, group, attrs) do
        {:ok, updated_group} ->
          {%{ok: true, group: description_payload(updated_group)},
           assign(socket, :group, updated_group)}

        {:error, :not_group_creator} ->
          {error("forbidden", not_creator), socket}

        {:error, _reason} ->
          {error("invalid_description", gettext("Could not update group description.")), socket}
      end
    else
      {:error, reply} -> {reply, socket}
    end
  end

  def call("get_description", _params, socket) do
    {%{ok: true, group: description_payload(socket.assigns.group)}, socket}
  end

  def call("current_profile", _params, socket) do
    {%{ok: true, profile: profile_payload(socket.assigns.current_profile)}, socket}
  end

  def call(_method, _params, socket) do
    {error("unknown_method", nil), socket}
  end

  defp require_member(socket, message) do
    if socket.assigns.is_member, do: :ok, else: {:error, error("not_a_member", message)}
  end

  defp creator?(%{id: profile_id}, %{creator_id: profile_id}), do: true
  defp creator?(_profile, _group), do: false

  defp take_write_token(socket) do
    now = System.monotonic_time(:millisecond)
    %{tokens: tokens, refilled_at: refilled_at} = socket.assigns.app_api_bucket
    refill = (now - refilled_at) * @write_burst / @write_window_ms
    tokens = min(@write_burst, tokens + refill)

    if tokens >= 1 do
      {:ok, assign(socket, :app_api_bucket, %{tokens: tokens - 1, refilled_at: now})}
    else
      {:error,
       error("rate_limited", gettext("Too many changes in a short time. Try again shortly."))}
    end
  end

  defp error(code, nil), do: %{ok: false, error: code}
  defp error(code, message), do: %{ok: false, error: code, message: message}

  defp description_payload(group) do
    %{
      id: group.id,
      description: group.description || "",
      description_format: to_string(group.description_format)
    }
  end

  defp profile_payload(nil), do: nil

  defp profile_payload(profile) do
    %{
      id: profile.id,
      username: profile.username,
      profile_picture_url: Avatars.profile_avatar_url(profile),
      description: profile.description,
      description_format: profile.description_format,
      sharing: profile.sharing,
      inserted_at: profile.inserted_at,
      updated_at: profile.updated_at
    }
  end

  defp clamp_limit(nil), do: nil
  defp clamp_limit(limit), do: min(limit, @max_list_limit)

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _ -> nil
    end
  end

  defp non_negative_integer(_value), do: nil

  defp optional_string(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp optional_string(_value), do: nil

  defp string_param(value, _default) when is_binary(value), do: value
  defp string_param(_value, default), do: default
end
