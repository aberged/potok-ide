defmodule PotokIde.GmailToken do
  @moduledoc false

  @token_url "https://oauth2.googleapis.com/token"

  def delivery_config(config) when is_list(config) do
    with {:ok, access_token} <- access_token(config) do
      {:ok, [access_token: access_token]}
    end
  end

  defp access_token(config) do
    case config[:access_token] do
      access_token when is_binary(access_token) and access_token != "" ->
        {:ok, access_token}

      _ ->
        refresh_access_token(config)
    end
  end

  defp refresh_access_token(config) do
    with {:ok, client_id} <- fetch_config(config, :client_id, "GMAIL_CLIENT_ID"),
         {:ok, client_secret} <- fetch_config(config, :client_secret, "GMAIL_CLIENT_SECRET"),
         {:ok, refresh_token} <- fetch_config(config, :refresh_token, "GMAIL_REFRESH_TOKEN"),
         {:ok, response} <- request_access_token(config, client_id, client_secret, refresh_token) do
      parse_access_token(response)
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

  defp parse_access_token(%{status: 200, body: %{"access_token" => access_token}})
       when is_binary(access_token) and access_token != "" do
    {:ok, access_token}
  end

  defp parse_access_token(%{status: status, body: body}) do
    {:error, {:gmail_token_request_failed, status, body}}
  end

  defp fetch_config(config, key, env_var) do
    case config[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:missing_config, env_var}}
    end
  end
end
