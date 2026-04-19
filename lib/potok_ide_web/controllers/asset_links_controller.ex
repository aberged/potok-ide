defmodule PotokIdeWeb.AssetLinksController do
  use PotokIdeWeb, :controller

  def show(conn, _params) do
    config = Application.get_env(:potok_ide, :android_app_links, [])

    package_name = Keyword.get(config, :package_name, "com.potok.ide")
    fingerprints = Keyword.get(config, :sha256_cert_fingerprints, [])

    payload =
      if fingerprints == [] do
        []
      else
        [
          %{
            "relation" => ["delegate_permission/common.handle_all_urls"],
            "target" => %{
              "namespace" => "android_app",
              "package_name" => package_name,
              "sha256_cert_fingerprints" => fingerprints
            }
          }
        ]
      end

    conn
    |> put_resp_header("cache-control", "public, max-age=3600")
    |> json(payload)
  end
end
