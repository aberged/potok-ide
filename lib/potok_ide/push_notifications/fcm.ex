defmodule PotokIde.PushNotifications.FCM do
  alias PotokIde.Accounts.PushSubscription
  alias PotokIde.PushNotifications
  alias PotokIdeWeb.Endpoint

  @default_scope "https://www.googleapis.com/auth/firebase.messaging"
  @default_token_url "https://oauth2.googleapis.com/token"
  @default_channel_id "potok-default"

  def configured? do
    match?({:ok, _credentials}, credentials())
  end

  def send_notification(%PushSubscription{} = subscription, payload) when is_map(payload) do
    with {:ok, credentials} <- credentials(),
         {:ok, access_token} <- fetch_access_token(credentials),
         {:ok, body} <- build_message_body(subscription, payload, credentials),
         {:ok, send_url} <-
           validate_url(message_url(credentials.project_id), "Firebase message URL is invalid."),
         {:ok, response} <-
           PushNotifications.request_fun().(
             url: send_url,
             auth: {:bearer, access_token},
             json: body
           ),
         :ok <- normalize_send_response(response) do
      {:ok, response}
    else
      {:error, %Req.TransportError{} = error} ->
        {:error, {:transport, Exception.message(error)}}

      {:error, %Jason.EncodeError{} = error} ->
        {:error, {:invalid_payload, Exception.message(error)}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    error in ArgumentError ->
      {:error, {:invalid_firebase_credentials, error.message}}

    error ->
      {:error, {:exception, Exception.message(error)}}
  end

  defp credentials do
    config = PushNotifications.config()

    with {:ok, raw_credentials} <- raw_credentials(config),
         {:ok, project_id} <- fetch_present_value(raw_credentials, "project_id"),
         {:ok, client_email} <- fetch_present_value(raw_credentials, "client_email"),
         {:ok, private_key} <- fetch_present_value(raw_credentials, "private_key"),
         {:ok, token_url} <-
           validate_url(
             config |> Keyword.get(:firebase_token_url, @default_token_url) |> normalize(),
             "Firebase token URL is invalid."
           ) do
      {:ok,
       %{
         project_id: project_id,
         client_email: client_email,
         private_key: normalize_private_key(private_key),
         token_url: token_url,
         scope: config |> Keyword.get(:firebase_scope, @default_scope) |> normalize(),
         channel_id:
           config |> Keyword.get(:firebase_channel_id, @default_channel_id) |> normalize()
       }}
    else
      {:error, :missing_credentials} -> {:error, :not_configured}
      {:error, reason} -> {:error, reason}
    end
  end

  defp raw_credentials(config) do
    service_account_json = normalize(Keyword.get(config, :firebase_service_account_json))

    cond do
      is_binary(service_account_json) ->
        Jason.decode(service_account_json)

      true ->
        project_id = normalize(Keyword.get(config, :firebase_project_id))
        client_email = normalize(Keyword.get(config, :firebase_client_email))
        private_key = normalize(Keyword.get(config, :firebase_private_key))

        if Enum.all?([project_id, client_email, private_key], &is_binary/1) do
          {:ok,
           %{
             "project_id" => project_id,
             "client_email" => client_email,
             "private_key" => private_key
           }}
        else
          {:error, :missing_credentials}
        end
    end
  end

  defp fetch_present_value(map, key) do
    case normalize(Map.get(map, key)) do
      nil -> {:error, {:invalid_firebase_credentials, "Missing #{key}."}}
      value -> {:ok, value}
    end
  end

  # Google access tokens are valid for ~1h; fetching one per message doubles the
  # HTTP round trips, so tokens are cached until shortly before they expire.
  @access_token_expiry_margin_seconds 60

  defp fetch_access_token(credentials) do
    cache_key = {:fcm_access_token, credentials.client_email, credentials.token_url}

    # Senders that find it expired together ask Google once.
    PotokIde.Cache.fetch_with_ttl(cache_key, fn ->
      with {:ok, access_token, expires_in} <- request_access_token(credentials) do
        case access_token_ttl_ms(expires_in) do
          nil -> {:uncached, access_token}
          ttl_ms -> {:ok, access_token, ttl_ms}
        end
      end
    end)
    |> case do
      {:uncached, access_token} -> {:ok, access_token}
      result -> result
    end
  end

  defp request_access_token(credentials) do
    issued_at = System.system_time(:second)
    assertion = jwt_assertion(credentials, issued_at)

    case PushNotifications.request_fun().(
           url: credentials.token_url,
           form: [
             grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
             assertion: assertion
           ]
         ) do
      {:ok, response} ->
        normalize_access_token_response(response)

      {:error, %Req.TransportError{} = error} ->
        {:error, {:transport, Exception.message(error)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Only responses that state a lifetime are cached.
  defp access_token_ttl_ms(expires_in)
       when is_integer(expires_in) and expires_in > @access_token_expiry_margin_seconds,
       do: (expires_in - @access_token_expiry_margin_seconds) * 1000

  defp access_token_ttl_ms(_expires_in), do: nil

  defp jwt_assertion(credentials, issued_at) do
    header = %{"alg" => "RS256", "typ" => "JWT"}

    claims = %{
      "iss" => credentials.client_email,
      "scope" => credentials.scope,
      "aud" => credentials.token_url,
      "iat" => issued_at,
      "exp" => issued_at + 3600
    }

    signing_input = [header, claims] |> Enum.map_join(".", &encode_segment/1)
    signature = :public_key.sign(signing_input, :sha256, pem_private_key(credentials.private_key))

    signing_input <> "." <> Base.url_encode64(signature, padding: false)
  end

  # Android gets the payload as data alone, so the app draws every
  # notification itself (`PotokMessagingService`: the picture, the tag that
  # replaces, the messages of a group in one), also in the background. With
  # a `notification` block Firebase drew it there instead, and in the
  # foreground the Capacitor plugin drew a second one. iOS shows the alert of
  # `apns`; a notification service extension adds the picture.
  defp build_message_body(%PushSubscription{} = subscription, payload, credentials) do
    android? = subscription.device_platform == :android
    notification = if android?, do: nil, else: notification_payload(payload)
    sound = payload_value(payload, [:android_sound, :sound])
    ttl = PushNotifications.ttl_for(payload)
    tag = payload_value(payload, [:tag])

    android_image =
      payload
      |> payload_value([:android_image, :image])
      |> absolute_url()

    icon = payload |> payload_value([:icon, :badge]) |> absolute_url()

    data_payload =
      payload
      |> Map.drop([:expires_at, "expires_at"])
      |> maybe_put_map_value(:android_image, android_image)
      |> maybe_put_map_value(:android_sound, sound)
      |> maybe_put_map_value(:icon, icon)
      |> maybe_put_map_value(
        :sender_icon,
        payload |> payload_value([:sender_icon]) |> absolute_url()
      )
      # Releases up to 1.0.4 draw their large icon from `badge`.
      |> maybe_put_map_value(:badge, icon)

    data_payload =
      if android?,
        do: Map.put(data_payload, :android_channel_id, channel_id(payload, credentials)),
        else: data_payload

    android_payload =
      if android? do
        %{priority: "high", ttl: duration_value(ttl)}
        |> maybe_put(:collapse_key, tag)
      end

    apns_payload = ios_apns_payload(subscription, notification, sound, payload, ttl)

    {:ok,
     %{
       message:
         %{
           token: subscription.device_token,
           data: stringify_payload(data_payload)
         }
         |> maybe_put(:notification, notification, is_map(notification))
         |> maybe_put(:android, android_payload, is_map(android_payload))
         |> maybe_put(:apns, apns_payload, is_map(apns_payload))
     }}
  end

  @doc """
  The Android notification channel of a payload's `kind`. The app creates
  the channels with names in the page's language (`assets/js/app.js`), and
  each can be silenced or given its own sound in the phone's settings.
  """
  def channel_for(kind) do
    case kind do
      "message" -> "potok-messages"
      kind when kind in ["mention", "reply", "reaction"] -> "potok-mentions"
      kind when kind in ["event", "event_reminder"] -> "potok-calendar"
      "poll" -> "potok-polls"
      "notice" -> "potok-notices"
      kind when kind in ["invitation", "request", "role"] -> "potok-invitations"
      kind when kind in ["app", "process"] -> "potok-apps"
      _other -> nil
    end
  end

  defp channel_id(payload, credentials),
    do: channel_for(payload_value(payload, [:kind])) || credentials.channel_id

  defp notification_payload(payload) when is_map(payload) do
    %{}
    |> maybe_put(:title, payload_value(payload, [:title]))
    |> maybe_put(:body, payload_value(payload, [:body]))
    |> case do
      notification when map_size(notification) > 0 -> notification
      _notification -> nil
    end
  end

  # `thread-id` groups a conversation's notifications, the collapse id lets a
  # newer one replace the one of the same tag, `mutable-content` hands it to
  # the notification service extension for the picture.
  defp ios_apns_payload(
         %PushSubscription{device_platform: :ios},
         notification,
         sound,
         payload,
         ttl
       )
       when is_map(notification) do
    alert = maybe_put(notification, :subtitle, payload_value(payload, [:label]))

    aps =
      %{alert: alert, sound: sound || "default", "mutable-content": 1}
      |> maybe_put(:"thread-id", thread_id(payload_value(payload, [:group_id])))

    headers =
      %{
        "apns-priority" => "10",
        "apns-push-type" => "alert",
        "apns-expiration" => Integer.to_string(System.system_time(:second) + ttl)
      }
      |> then(fn headers ->
        case payload_value(payload, [:tag]) do
          tag when is_binary(tag) ->
            Map.put(headers, "apns-collapse-id", PushNotifications.collapse_id(tag))

          _tag ->
            headers
        end
      end)

    %{headers: headers, payload: %{aps: aps}}
  end

  defp ios_apns_payload(_subscription, _notification, _sound, _payload, _ttl), do: nil

  defp thread_id(group_id) when is_integer(group_id), do: "group-#{group_id}"
  defp thread_id(_group_id), do: nil

  defp normalize_access_token_response(%Req.Response{status: status, body: body})
       when status in 200..299 do
    body = normalize_body(body)

    case Map.get(body, "access_token") do
      access_token when is_binary(access_token) and access_token != "" ->
        {:ok, access_token, normalize_expires_in(Map.get(body, "expires_in"))}

      _value ->
        {:error,
         {:invalid_firebase_credentials, "Firebase token response was missing access_token."}}
    end
  end

  defp normalize_access_token_response(%Req.Response{status: status, body: body}) do
    {:error, {:firebase_auth_error, "#{status}: #{response_error_message(body)}"}}
  end

  defp normalize_expires_in(value) when is_integer(value), do: value

  defp normalize_expires_in(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> int
      _ -> nil
    end
  end

  defp normalize_expires_in(_value), do: nil

  defp normalize_send_response(%Req.Response{status: status}) when status in 200..299, do: :ok

  defp normalize_send_response(%Req.Response{status: status, body: body}) do
    case response_error_code(body) do
      "UNREGISTERED" ->
        {:error, :expired}

      error_code ->
        {:error, {:http_error, "#{status}: #{error_code || response_error_message(body)}"}}
    end
  end

  defp stringify_payload(payload) do
    payload
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      if is_nil(value) do
        acc
      else
        Map.put(acc, to_string(key), stringify_value(value))
      end
    end)
  end

  defp stringify_value(value) when is_binary(value), do: value
  defp stringify_value(value) when is_boolean(value) or is_number(value), do: to_string(value)
  defp stringify_value(value), do: Jason.encode!(value)

  defp message_url(project_id),
    do: "https://fcm.googleapis.com/v1/projects/#{project_id}/messages:send"

  defp response_error_code(body) do
    body
    |> normalize_body()
    |> get_in(["error", "details"])
    |> case do
      details when is_list(details) ->
        Enum.find_value(details, fn
          %{"errorCode" => error_code} when is_binary(error_code) -> error_code
          _detail -> nil
        end)

      _value ->
        nil
    end
  end

  defp response_error_message(body) do
    normalized_body = normalize_body(body)

    get_in(normalized_body, ["error", "message"]) ||
      get_in(normalized_body, ["error", "status"]) ||
      inspect(body)
  end

  defp normalize_body(body) when is_map(body), do: body

  defp normalize_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _error -> %{"raw" => body}
    end
  end

  defp normalize_body(_body), do: %{}

  defp pem_private_key(private_key) do
    [pem_entry] = :public_key.pem_decode(private_key)
    :public_key.pem_entry_decode(pem_entry)
  end

  defp normalize_private_key(private_key) do
    private_key
    |> String.replace("\\n", "\n")
    |> then(fn value -> if String.ends_with?(value, "\n"), do: value, else: value <> "\n" end)
  end

  defp encode_segment(term) do
    term
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp payload_value(payload, keys) when is_list(keys) do
    Enum.find_value(keys, &payload_value(payload, &1))
  end

  defp payload_value(payload, key) do
    Map.get(payload, key) || Map.get(payload, Atom.to_string(key))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_map_value(map, _key, nil), do: map
  defp maybe_put_map_value(map, key, value), do: Map.put(map, key, value)

  defp maybe_put(map, _key, _value, false), do: map
  defp maybe_put(map, key, value, true), do: Map.put(map, key, value)

  defp duration_value(value) when is_integer(value) and value >= 0,
    do: Integer.to_string(value) <> "s"

  defp duration_value(value) when is_float(value) and value >= 0,
    do: :erlang.float_to_binary(value, [:compact]) <> "s"

  defp duration_value(value) when is_binary(value) do
    case String.trim(value) do
      "" ->
        nil

      trimmed ->
        cond do
          Regex.match?(~r/^\d+(\.\d+)?s$/, trimmed) -> trimmed
          Regex.match?(~r/^\d+(\.\d+)?$/, trimmed) -> trimmed <> "s"
          true -> trimmed
        end
    end
  end

  defp duration_value(_value), do: nil

  defp validate_url(url, message) when is_binary(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host}
      when is_binary(scheme) and scheme != "" and is_binary(host) and host != "" ->
        {:ok, url}

      _uri ->
        {:error, {:invalid_firebase_credentials, message}}
    end
  end

  defp validate_url(_url, message), do: {:error, {:invalid_firebase_credentials, message}}

  defp absolute_url(nil), do: nil

  defp absolute_url(url) when is_binary(url) do
    trimmed = String.trim(url)

    cond do
      trimmed == "" ->
        nil

      String.starts_with?(trimmed, ["https://", "http://"]) ->
        trimmed

      true ->
        Endpoint.url()
        |> URI.merge(trimmed)
        |> URI.to_string()
    end
  rescue
    _error -> nil
  end

  defp absolute_url(_value), do: nil

  defp normalize(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize(_value), do: nil
end
