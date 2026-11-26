defmodule PotokIde.PushNotifications do
  alias PotokIde.Accounts.PushSubscription
  alias PotokIde.PushNotifications.FCM
  alias PotokIde.PushNotifications.WebPush

  @default_ttl 60
  @day 86_400
  @week 7 * @day

  # Kinds a person waits for, which the push services may deliver at once
  # even when the device saves power.
  @urgent_kinds ~w(message mention reply invitation event_reminder)

  def public_key do
    config()
    |> Keyword.get(:vapid_public_key)
    |> normalize_config_value()
  end

  def configured? do
    web_push_configured?() or fcm_configured?()
  end

  @doc """
  `fun` evaluated in every supported locale: the payload per language, as
  plain data that a job can carry (`PotokIde.PushNotifications.DeliverWorker`).
  Read a device's with `payload_for/2`.
  """
  def localized(fun) when is_function(fun, 0) do
    payloads =
      Map.new(PotokIdeWeb.Locale.supported_locales(), fn locale ->
        {locale, Gettext.with_locale(PotokIdeWeb.Gettext, locale, fun)}
      end)

    %{"default" => PotokIdeWeb.Locale.default_locale(), "payloads" => payloads}
  end

  @doc """
  The payload of `localized/1` for a device's locale
  (`PushSubscription.locale`); one without a locale, or with one Potok does
  not speak, gets the default language. Keys come back as atoms, also after
  a job's JSON.
  """
  def payload_for(%{"default" => default, "payloads" => payloads}, locale) do
    payloads
    |> Map.get(locale || default, Map.fetch!(payloads, default))
    |> Map.new(fn {key, value} -> {atomize(key), value} end)
  end

  # Keys of payloads written by Potok's own notification modules.
  defp atomize(key) when is_atom(key), do: key
  defp atomize(key) when is_binary(key), do: String.to_existing_atom(key)

  @doc """
  When a payload stops being worth delivering, as unix seconds: `:day` or
  `:week` from now, or a `DateTime` (a reminder until its event starts),
  never sooner than five minutes from now nor later than a week. A device
  that comes back online later does not get it, and a job that runs later
  sends nothing (`stale?/1`).
  """
  def expires_at(:day), do: System.system_time(:second) + @day
  def expires_at(:week), do: System.system_time(:second) + @week

  def expires_at(%DateTime{} = until) do
    now = System.system_time(:second)
    until |> DateTime.to_unix() |> max(now + 300) |> min(now + @week)
  end

  @doc "Milliseconds since the epoch, for a payload's `timestamp`."
  def now_ms, do: System.system_time(:millisecond)

  @doc """
  Seconds a push service keeps `payload` for a device that is offline: until
  its `expires_at`, or the configured TTL for a payload without one.
  """
  def ttl_for(%{expires_at: expires_at}) when is_integer(expires_at),
    do: max(expires_at - System.system_time(:second), 0)

  def ttl_for(_payload), do: ttl()

  @doc "Whether `payload` (a device's, or the per-language map of `localized/1`) has expired."
  def stale?(%{"payloads" => _payloads} = localized), do: stale?(payload_for(localized, nil))

  def stale?(%{expires_at: expires_at}) when is_integer(expires_at),
    do: expires_at <= System.system_time(:second)

  def stale?(_payload), do: false

  @doc "Web Push `Urgency` of a payload's `kind`."
  def urgency(%{kind: kind}) when kind in @urgent_kinds, do: "high"
  def urgency(_payload), do: "normal"

  @doc """
  The Web Push `Topic` of a `tag`: at most 32 characters of base64url. A push
  service keeps only the newest undelivered push of a topic, as a device
  keeps only the newest notification of a tag.
  """
  def topic(tag) when is_binary(tag), do: binary_part(hashed(tag), 0, 32)

  @doc "The APNs collapse id of a `tag`: the tag itself, or its hash past 64 bytes."
  def collapse_id(tag) when is_binary(tag) and byte_size(tag) <= 64, do: tag
  def collapse_id(tag) when is_binary(tag), do: hashed(tag)

  defp hashed(tag), do: :sha256 |> :crypto.hash(tag) |> Base.url_encode64(padding: false)

  def send_notification(%PushSubscription{} = subscription, payload) when is_map(payload) do
    case PushSubscription.delivery_type(subscription) do
      :fcm ->
        FCM.send_notification(subscription, payload)

      :web_push ->
        send_web_push_notification(subscription, payload)

      :unknown ->
        {:error,
         {:invalid_subscription,
          "Subscription is missing required endpoint or device token data."}}
    end
  end

  def web_push_configured? do
    match?({:ok, _details}, vapid_details())
  end

  def fcm_configured? do
    FCM.configured?()
  end

  def config do
    Application.get_env(:potok_ide, __MODULE__, [])
  end

  def request_fun do
    Keyword.get(config(), :request_fun, &Req.post/1)
  end

  def ttl do
    Keyword.get(config(), :ttl, @default_ttl)
  end

  defp send_web_push_notification(%PushSubscription{} = subscription, payload)
       when is_map(payload) do
    try do
      with {:ok, vapid} <- vapid_details(),
           {:ok, body} <- Jason.encode(Map.delete(payload, :expires_at)),
           encrypted <- WebPush.encrypt(body, subscription_payload(subscription)),
           headers <- request_headers(subscription.endpoint, encrypted, vapid, payload),
           {:ok, response} <-
             request_fun().(request_options(subscription.endpoint, encrypted, headers)),
           :ok <- normalize_response(response) do
        {:ok, response}
      else
        {:error, %Jason.EncodeError{} = error} ->
          {:error, {:invalid_payload, Exception.message(error)}}

        {:error, %Req.TransportError{} = error} ->
          {:error, {:transport, Exception.message(error)}}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      error in ArgumentError ->
        {:error, {:invalid_subscription, error.message}}

      error ->
        {:error, {:exception, Exception.message(error)}}
    end
  end

  defp normalize_response(%Req.Response{status: status}) when status in 200..299, do: :ok

  defp normalize_response(%Req.Response{status: status}) when status in [404, 410],
    do: {:error, :expired}

  defp normalize_response(%Req.Response{status: status}), do: {:error, {:http_error, status}}

  defp request_options(endpoint, encrypted, headers) do
    [
      url: endpoint,
      body: encrypted.ciphertext,
      headers: Enum.to_list(headers)
    ]
  end

  # The VAPID token keeps its own lifetime (12 hours): the TTL says how long
  # the push service holds the message, which may be a week.
  defp request_headers(endpoint, encrypted, vapid, payload) do
    vapid_headers =
      WebPush.vapid_headers(
        endpoint,
        Keyword.fetch!(vapid, :subject),
        Keyword.fetch!(vapid, :public_key),
        Keyword.fetch!(vapid, :private_key)
      )

    vapid_headers
    |> Map.merge(%{
      "TTL" => Integer.to_string(ttl_for(payload)),
      "Urgency" => urgency(payload),
      "Content-Encoding" => "aesgcm",
      "Content-Type" => "application/octet-stream",
      "Encryption" => "salt=#{ub64(encrypted.salt)}"
    })
    |> Map.put(
      "Crypto-Key",
      "dh=#{ub64(encrypted.server_public_key)};" <> Map.fetch!(vapid_headers, "Crypto-Key")
    )
    |> then(fn headers ->
      case payload do
        %{tag: tag} when is_binary(tag) -> Map.put(headers, "Topic", topic(tag))
        _payload -> headers
      end
    end)
  end

  defp subscription_payload(%PushSubscription{} = subscription) do
    %{
      endpoint: subscription.endpoint,
      keys: %{
        p256dh: subscription.p256dh,
        auth: subscription.auth
      }
    }
  end

  defp vapid_details do
    vapid_subject = normalize_config_value(Keyword.get(config(), :vapid_subject))
    vapid_public_key = normalize_config_value(Keyword.get(config(), :vapid_public_key))
    vapid_private_key = normalize_config_value(Keyword.get(config(), :vapid_private_key))

    if Enum.all?([vapid_subject, vapid_public_key, vapid_private_key], &is_binary/1) do
      {:ok,
       [
         subject: vapid_subject,
         public_key: vapid_public_key,
         private_key: vapid_private_key
       ]}
    else
      {:error, :not_configured}
    end
  end

  defp normalize_config_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_config_value(_value), do: nil

  defp ub64(value) do
    Base.url_encode64(value, padding: false)
  end
end
