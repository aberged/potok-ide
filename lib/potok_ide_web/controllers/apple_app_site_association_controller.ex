defmodule PotokIdeWeb.AppleAppSiteAssociationController do
  use PotokIdeWeb, :controller

  def show(conn, _params) do
    config = Application.get_env(:potok_ide, :ios_app_links, [])

    conn
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(payload(config)))
  end

  defp payload(config) do
    %{
      "applinks" => %{
        "apps" => [],
        "details" =>
          case app_id(config) do
            nil ->
              []

            app_id ->
              [
                %{
                  "appID" => app_id,
                  "paths" => paths(config)
                }
              ]
          end
      }
    }
  end

  defp app_id(config) do
    direct_app_id = normalize_string(Keyword.get(config, :app_id))
    team_id = normalize_string(Keyword.get(config, :team_id))
    bundle_id = normalize_string(Keyword.get(config, :bundle_id)) || "rs.potok.ide"

    cond do
      direct_app_id -> direct_app_id
      team_id -> "#{team_id}.#{bundle_id}"
      true -> nil
    end
  end

  defp paths(config) do
    config
    |> Keyword.get(:paths, ["/accounts/log-in/*"])
    |> Enum.map(&normalize_string/1)
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> ["/accounts/log-in/*"]
      paths -> paths
    end
  end

  defp normalize_string(value) when is_binary(value) do
    value = String.trim(value)

    if value == "" do
      nil
    else
      value
    end
  end

  defp normalize_string(_value), do: nil
end
