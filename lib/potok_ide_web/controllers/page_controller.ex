defmodule PotokIdeWeb.PageController do
  use PotokIdeWeb, :controller

  import PotokIdeWeb.AccountAuth, only: [assign_nav_counts: 2]

  plug :assign_nav_counts when action in [:privacy]

  # `mix potok.sr_cyrl` writes the Cyrillic policy from the Latin one.
  for {locale, file} <- %{
        "en" => "PRIVACY_POLICY.md",
        "sr" => "PRIVACY_POLICY.sr.md",
        "sr_Cyrl" => "PRIVACY_POLICY.sr_Cyrl.md"
      } do
    path = Path.expand("../../../priv/static/#{file}", __DIR__)
    @external_resource path

    html =
      path
      |> File.read!()
      |> String.trim()
      |> Earmark.as_html!(breaks: true)
      |> HtmlSanitizeEx.html5()

    defp privacy_policy_html(unquote(locale)), do: unquote(html)
  end

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
        render(conn, :home)
    end
  end

  def privacy(conn, _params) do
    render(conn, :privacy, privacy_policy_html: privacy_policy_html(conn.assigns.current_locale))
  end
end
