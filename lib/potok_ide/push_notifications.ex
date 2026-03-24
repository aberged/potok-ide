defmodule PotokIde.PushNotifications do
  alias PotokIde.Accounts.PushSubscription
  alias PotokIde.PushNotifications.WebPush

  @default_ttl 60

  def public_key do
    config()
    |> Keyword.get(:vapid_public_key)
    |> normalize_config_value()
  end

  def configured? do
    match?({:ok, _details}, vapid_details())
  end

  def send_notification(%PushSubscription{} = subscription, payload) when is_map(payload) do
    try do
      with {:ok, vapid} <- vapid_details(),
           {:ok, body} <- Jason.encode(payload),
           encrypted <- WebPush.encrypt(body, subscription_payload(subscription)),
           headers <- request_headers(subscription.endpoint, encrypted, vapid),
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

  defp request_headers(endpoint, encrypted, vapid) do
    vapid_headers =
      WebPush.vapid_headers(
        endpoint,
        Keyword.fetch!(vapid, :subject),
        Keyword.fetch!(vapid, :public_key),
        Keyword.fetch!(vapid, :private_key),
        ttl()
      )

    vapid_headers
    |> Map.merge(%{
      "TTL" => Integer.to_string(ttl()),
      "Content-Encoding" => "aesgcm",
      "Content-Type" => "application/octet-stream",
      "Encryption" => "salt=#{ub64(encrypted.salt)}"
    })
    |> Map.put(
      "Crypto-Key",
      "dh=#{ub64(encrypted.server_public_key)};" <> Map.fetch!(vapid_headers, "Crypto-Key")
    )
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

  defp config do
    Application.get_env(:potok_ide, __MODULE__, [])
  end

  defp request_fun do
    Keyword.get(config(), :request_fun, &Req.post/1)
  end

  defp ttl do
    Keyword.get(config(), :ttl, @default_ttl)
  end

  defp ub64(value) do
    Base.url_encode64(value, padding: false)
  end
end
