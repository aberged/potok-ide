defmodule PotokIdeWeb.AssetLinksControllerTest do
  use PotokIdeWeb.ConnCase, async: true

  setup do
    original_config = Application.get_env(:potok_ide, :android_app_links, [])

    Application.put_env(
      :potok_ide,
      :android_app_links,
      package_name: "rs.potok.ide",
      sha256_cert_fingerprints: [
        "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99"
      ]
    )

    on_exit(fn ->
      Application.put_env(:potok_ide, :android_app_links, original_config)
    end)

    :ok
  end

  test "GET /.well-known/assetlinks.json returns Android app links metadata", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> get("/.well-known/assetlinks.json")

    assert [payload] = json_response(conn, 200)

    assert payload["relation"] == ["delegate_permission/common.handle_all_urls"]

    assert payload["target"] == %{
             "namespace" => "android_app",
             "package_name" => "rs.potok.ide",
             "sha256_cert_fingerprints" => [
               "AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99:AA:BB:CC:DD:EE:FF:00:11:22:33:44:55:66:77:88:99"
             ]
           }
  end
end
