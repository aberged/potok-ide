defmodule PotokIdeWeb.SidebarTest do
  @moduledoc """
  The app's menu (`Layouts.app/1`): at the side of a wide screen, where it can
  be hidden and brought back from the top bar, and over the page on a phone.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  describe "signed in" do
    setup :register_and_log_in_account

    test "hides at the side and comes back from the top bar", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/profiles")

      assert has_element?(view, "#app-sidebar #app-sidebar-hide[phx-click*='phx:toggle-sidebar']")
      assert has_element?(view, "#app-sidebar-show[phx-click*='phx:toggle-sidebar']")
      refute has_element?(view, "#app-sidebar #app-sidebar-show")
    end

    test "shows the mark, the account and the parts of the app", %{conn: conn, account: account} do
      {:ok, view, _html} = live(conn, ~p"/profiles")

      assert has_element?(
               view,
               "#app-sidebar-home-link img#app-sidebar-mark[src^='/images/mark']"
             )

      assert has_element?(view, "#app-sidebar-account", account.email)
      assert has_element?(view, "#app-sidebar [data-nav-link][href='/groups']")
      assert has_element?(view, "#app-sidebar [data-nav-link][href='/accounts/settings']")

      assert has_element?(
               view,
               "#app-sidebar a.sidebar-link[href='/accounts/log-out'][data-method='delete'][data-tone='danger']"
             )
    end

    test "the top bar holds the drop that falls while a page loads", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/profiles")

      assert has_element?(view, "nav #nav-page-loader.page-loader .page-loader-drop")
      assert has_element?(view, "#nav-page-loader .page-loader-ripple")
    end
  end

  test "a guest opens it over the page, with nothing to hide" do
    assigns = %{}

    document =
      ~H"""
      <PotokIdeWeb.Layouts.app flash={%{}}>page</PotokIdeWeb.Layouts.app>
      """
      |> rendered_to_string()
      |> LazyHTML.from_fragment()

    refute Enum.empty?(LazyHTML.query(document, "label[for='app-drawer-toggle']"))
    assert Enum.empty?(LazyHTML.query(document, "#app-sidebar-show, #app-sidebar-hide"))
    assert Enum.empty?(LazyHTML.query(document, "#app-sidebar-account"))
  end
end
