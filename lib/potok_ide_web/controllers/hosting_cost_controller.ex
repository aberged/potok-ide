defmodule PotokIdeWeb.HostingCostController do
  @moduledoc """
  `/troskovi`: what Potok costs on Fly, open to everyone
  (`PotokIde.HostingCosts`). Operators also get the form that copies a Fly
  invoice, which posts to `/troskovi/racuni`.
  """

  use PotokIdeWeb, :controller

  alias PotokIde.{HostingCosts, Operators}

  def index(conn, params) do
    month =
      case HostingCosts.parse_month(params["mesec"]) do
        {:ok, month} -> month
        {:error, :invalid_month} -> last_month()
      end

    render_page(conn, HostingCosts.change_invoice(month), month)
  end

  # For those who type the address in English.
  def index_redirect(conn, _params), do: redirect(conn, to: ~p"/troskovi")

  def save_invoice(conn, %{"invoice" => %{} = attrs}) do
    scope = conn.assigns.current_scope

    if !Operators.operator?(scope) do
      raise Phoenix.Router.NoRouteError, conn: conn, router: PotokIdeWeb.Router
    end

    case HostingCosts.save_invoice(scope, attrs["month"], attrs) do
      {:ok, _invoice} ->
        conn
        |> put_flash(:info, dgettext("costs", "The invoice is saved."))
        |> redirect(to: ~p"/troskovi" <> "#costs-months")

      {:error, %Ecto.Changeset{} = changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> render_page(changeset, changeset.data.month)

      {:error, :invalid_month} ->
        conn
        |> put_flash(:error, dgettext("costs", "Pick the month of the invoice."))
        |> redirect(to: ~p"/troskovi" <> "#costs-invoice")
    end
  end

  def save_invoice(conn, _params) do
    raise Phoenix.Router.NoRouteError, conn: conn, router: PotokIdeWeb.Router
  end

  defp render_page(conn, changeset, month) do
    operator? = Operators.operator?(conn.assigns.current_scope)

    conn
    |> assign(:page_title, dgettext("costs", "What Potok costs"))
    |> assign(:page_description, PotokIdeWeb.HostingCostHTML.lead())
    |> render(:index,
      overview: HostingCosts.overview(),
      operator?: operator?,
      form: if(operator?, do: Phoenix.Component.to_form(changeset, as: :invoice)),
      form_month: Calendar.strftime(month, "%Y-%m")
    )
  end

  # The month whose invoice comes next.
  defp last_month do
    Date.utc_today() |> Date.beginning_of_month() |> Date.add(-1) |> Date.beginning_of_month()
  end
end
