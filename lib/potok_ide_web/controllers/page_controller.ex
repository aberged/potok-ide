defmodule PotokIdeWeb.PageController do
  use PotokIdeWeb, :controller

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
end
