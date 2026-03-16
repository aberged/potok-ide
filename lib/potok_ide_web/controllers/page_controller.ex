defmodule PotokIdeWeb.PageController do
  use PotokIdeWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
