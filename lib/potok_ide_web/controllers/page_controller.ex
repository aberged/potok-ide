defmodule PotokIdeWeb.PageController do
  use PotokIdeWeb, :controller

  @privacy_policy_path Path.expand("../../../priv/static/PRIVACY_POLICY.md", __DIR__)
  @external_resource @privacy_policy_path
  @privacy_policy_html @privacy_policy_path |> File.read!() |> String.trim() |> Earmark.as_html!(breaks: true) |> HtmlSanitizeEx.html5()

  def home(conn, _params) do
    current_account =
      case conn.assigns[:current_scope] do
        %{account: account} -> account
        _ -> nil
      end

    cond do
      conn.assigns.current_profile ->
        redirect(conn, to: ~p"/groups")

      current_account ->
        redirect(conn, to: ~p"/profiles")

      true ->
        redirect(conn, to: ~p"/accounts/log-in")
    end
  end

  def privacy(conn, _params) do
    render(conn, :privacy, privacy_policy_html: @privacy_policy_html)
  end
end
