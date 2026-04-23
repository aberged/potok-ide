defmodule PotokIdeWeb.AppleAppSiteAssociationControllerTest do
  use PotokIdeWeb.ConnCase, async: true

  setup do
    original_config = Application.get_env(:potok_ide, :ios_app_links, [])

    Application.put_env(
      :potok_ide,
      :ios_app_links,
      team_id: "ABCDE12345",
      bundle_id: "com.potok.ide",
      paths: ["/accounts/log-in/*", "/accounts/log-in"]
    )

    on_exit(fn ->
      Application.put_env(:potok_ide, :ios_app_links, original_config)
    end)

    :ok
  end

  test "GET /.well-known/apple-app-site-association returns iOS app links metadata", %{conn: conn} do
    conn = get(conn, "/.well-known/apple-app-site-association")

    assert %{
             "applinks" => %{
               "apps" => [],
               "details" => [
                 %{
                   "appID" => "ABCDE12345.com.potok.ide",
                   "paths" => ["/accounts/log-in/*", "/accounts/log-in"]
                 }
               ]
             }
           } = json_response(conn, 200)
  end

  test "GET /apple-app-site-association returns iOS app links metadata", %{conn: conn} do
    conn = get(conn, "/apple-app-site-association")

    assert %{
             "applinks" => %{
               "details" => [
                 %{
                   "appID" => "ABCDE12345.com.potok.ide"
                 }
               ]
             }
           } = json_response(conn, 200)
  end
end
