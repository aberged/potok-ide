defmodule PotokIde.GmailToken do
  @moduledoc false

  require Logger

  alias PotokIde.GmailRefreshToken

  @token_url "https://oauth2.googleapis.com/token"

  def delivery_config(config) when is_list(config) do
    with {:ok, access_token} <- access_token(config) do
      {:ok, [access_token: access_token]}
    end
  end

  defp access_token(config) do
    cond do
      refresh_access_token_available?(config) ->
        refresh_access_token(config)

      present_binary?(config[:access_token]) ->
        {:ok, config[:access_token]}

      true ->
        refresh_access_token(config)
    end
  end

  defp refresh_access_token(config) do
    with {:ok, client_id} <- fetch_config(config, :client_id, "GMAIL_CLIENT_ID"),
         {:ok, client_secret} <- fetch_config(config, :client_secret, "GMAIL_CLIENT_SECRET"),
         {:ok, refresh_tokens} <- fetch_refresh_tokens(config) do
      refresh_access_token(config, client_id, client_secret, refresh_tokens)
    end
  end

  defp refresh_access_token(config, client_id, client_secret, [{source, refresh_token} | remaining]) do
    with {:ok, response} <- request_access_token(config, client_id, client_secret, refresh_token),
         {:ok, access_token} <- parse_access_token(response) do
      maybe_store_effective_refresh_token(response, refresh_token)
      {:ok, access_token}
    else
      error ->
        maybe_retry_refresh_access_token(
          config,
          client_id,
          client_secret,
          source,
          error,
          remaining
        )
    end
  end

  defp request_access_token(config, client_id, client_secret, refresh_token) do
    req_options =
      config
      |> Keyword.get(:req_options, [])
      |> Keyword.put_new(:url, config[:token_url] || @token_url)

    Req.post(
      req_options,
      form: [
        client_id: client_id,
        client_secret: client_secret,
        refresh_token: refresh_token,
        grant_type: "refresh_token"
      ]
    )
  end

  defp parse_access_token(%{status: 200, body: %{"access_token" => access_token} = body})
       when is_binary(access_token) and access_token != "" do
    maybe_store_refresh_token(body)
    {:ok, access_token}
  end

  defp parse_access_token(%{status: status, body: body}) do
    {:error, {:gmail_token_request_failed, status, body}}
  end

  defp refresh_access_token_available?(config) do
    Enum.all?([config[:client_id], config[:client_secret]], &present_binary?/1) and
      refresh_token_available?(config)
  end

  defp refresh_token_available?(config) do
    present_binary?(config[:refresh_token]) or persisted_refresh_token_available?()
  end

  defp fetch_config(config, key, env_var) do
    case config[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_config, env_var}}
    end
  end

  defp fetch_refresh_tokens(config) do
    config_refresh_token = configured_refresh_token(config)

    [persisted_refresh_token(), config_refresh_token]
    |> List.flatten()
    |> Enum.uniq_by(fn {_source, refresh_token} -> refresh_token end)
    |> case do
      [] -> {:error, {:missing_config, "GMAIL_REFRESH_TOKEN"}}
      refresh_tokens -> {:ok, refresh_tokens}
    end
  end

  defp configured_refresh_token(config) do
    case config[:refresh_token] do
      refresh_token when is_binary(refresh_token) and refresh_token != "" ->
        [{:configured, refresh_token}]

      _ ->
        []
    end
  end

  defp persisted_refresh_token do
    case GmailRefreshToken.get() do
      %GmailRefreshToken{refresh_token: refresh_token}
      when is_binary(refresh_token) and refresh_token != "" ->
        [{:persisted, refresh_token}]

      _ ->
        []
    end
  end

  defp maybe_retry_refresh_access_token(
         config,
         client_id,
         client_secret,
         :persisted,
         {:error, {:gmail_token_request_failed, _status, %{"error" => "invalid_grant"}}},
         [{:configured, _configured_refresh_token} | _] = remaining
       ) do
    Logger.warning("persisted Gmail refresh token was rejected; retrying configured refresh token")
    refresh_access_token(config, client_id, client_secret, remaining)
  end

  defp maybe_retry_refresh_access_token(
         _config,
         _client_id,
         _client_secret,
         _source,
         error,
         _remaining
       ),
       do: error

  defp maybe_store_effective_refresh_token(
         %{status: status, body: %{"refresh_token" => refresh_token}},
         _used_refresh_token
       )
       when status in 200..299 and is_binary(refresh_token) and refresh_token != "" do
    :ok
  end

  defp maybe_store_effective_refresh_token(%{status: status}, used_refresh_token)
       when status in 200..299 and is_binary(used_refresh_token) and used_refresh_token != "" do
    maybe_store_refresh_token(%{"refresh_token" => used_refresh_token})
  end

  defp maybe_store_effective_refresh_token(_response, _used_refresh_token), do: :ok

  defp persisted_refresh_token_available? do
    case GmailRefreshToken.get() do
      %GmailRefreshToken{refresh_token: refresh_token} -> present_binary?(refresh_token)
      _ -> false
    end
  end

  defp maybe_store_refresh_token(%{"refresh_token" => refresh_token})
       when is_binary(refresh_token) and refresh_token != "" do
    case GmailRefreshToken.upsert(refresh_token) do
      {:ok, _gmail_refresh_token} ->
        :ok

      {:error, reason} ->
        Logger.warning("failed to persist Gmail refresh token: #{inspect(reason)}")
    end
  end

  defp maybe_store_refresh_token(_body), do: :ok

  defp present_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_binary?(_value), do: false
end
