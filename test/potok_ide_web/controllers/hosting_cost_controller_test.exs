defmodule PotokIdeWeb.HostingCostControllerTest do
  use PotokIdeWeb.ConnCase, async: true

  import PotokIde.AccountsFixtures

  alias PotokIde.HostingCosts.{CostHour, Invoice}
  alias PotokIde.Repo

  defp page(conn, path \\ ~p"/troskovi") do
    conn |> get(path) |> html_response(200) |> LazyHTML.from_document()
  end

  defp has?(document, selector), do: LazyHTML.query(document, selector) |> Enum.any?()

  defp text(document, selector), do: document |> LazyHTML.query(selector) |> LazyHTML.text()

  defp operator, do: account_fixture(%{email: "operator@example.com"})

  defp this_month, do: Date.utc_today() |> Date.beginning_of_month()

  defp key(month), do: Calendar.strftime(month, "%Y-%m")

  # An hour of the current month, as the sampler writes it.
  defp cost_hour(category, item, amount) do
    hour = %{DateTime.utc_now(:second) | minute: 0, second: 0}

    Repo.insert!(%CostHour{
      hour: hour,
      category: category,
      item: item,
      quantity: 1.0,
      amount_usd: Decimal.new(amount),
      detail: %{}
    })
  end

  test "guests see what this month costs so far and every month", %{conn: conn} do
    cost_hour(:machines, "m1", "0.014")
    cost_hour(:postgres, "basic", "0.053")
    last = this_month() |> Date.add(-1) |> Date.beginning_of_month()
    Repo.insert!(%Invoice{month: last, amount_usd: Decimal.new("47.50"), note: "with VAT"})

    document = page(conn)

    assert has?(document, "#costs-current #costs-so-far")
    assert has?(document, "#costs-projected")
    assert has?(document, "#costs-current-machines")
    assert text(document, "#costs-current-machines-projected") =~ "by the end of the month"
    assert has?(document, "#costs-current-postgres")
    assert has?(document, "#costs-month-#{key(this_month())}")
    assert text(document, "#costs-month-#{key(last)} .hc-month-invoice") =~ "$47.50"
    assert text(document, "#costs-month-#{key(last)}") =~ "with VAT"
    assert has?(document, "#costs-notes")
    refute has?(document, "#invoice-form")
    refute has?(document, "[id^=costs-month-edit]")
  end

  test "says when there is nothing to show yet", %{conn: conn} do
    document = page(conn)

    assert has?(document, "#costs-current-empty")
    refute has?(document, "#costs-so-far")
  end

  test "writes sums the way the page's language does", %{conn: conn} do
    cost_hour(:machines, "m1", "1234.5")

    # Tests read English unless they ask for another language.
    assert text(page(conn), "#costs-so-far") =~ "$1,234.50"
    assert text(page(build_conn(), ~p"/troskovi?locale=sr"), "#costs-so-far") =~ "1.234,50 $"
  end

  test "accounts that are not operators see the page as guests do", %{conn: conn} do
    document = conn |> log_in_account(account_fixture()) |> page()

    assert has?(document, "#costs")
    refute has?(document, "#invoice-form")
  end

  test "an operator gets the form, for the month asked for", %{conn: conn} do
    document = conn |> log_in_account(operator()) |> page(~p"/troskovi?mesec=2026-09")

    assert has?(document, "#invoice-form")
    assert has?(document, "#costs-month-edit-#{key(this_month())}")

    assert document
           |> LazyHTML.query("#invoice-form input[type=month]")
           |> LazyHTML.attribute("value") == ["2026-09"]
  end

  test "an operator saves an invoice", %{conn: conn} do
    conn =
      conn
      |> log_in_account(operator())
      |> post(~p"/troskovi/racuni", %{
        "invoice" => %{"month" => "2026-10", "amount_usd" => "48.10", "note" => ""}
      })

    assert redirected_to(conn) == ~p"/troskovi" <> "#costs-months"
    assert %Invoice{amount_usd: amount} = Repo.get_by(Invoice, month: ~D[2026-10-01])
    assert Decimal.equal?(amount, Decimal.new("48.10"))
  end

  test "a wrong sum comes back with its error", %{conn: conn} do
    response =
      conn
      |> log_in_account(operator())
      |> post(~p"/troskovi/racuni", %{"invoice" => %{"month" => "2026-10", "amount_usd" => "-3"}})
      |> html_response(422)

    document = LazyHTML.from_document(response)
    assert has?(document, "#invoice-form .text-error")
    assert Repo.aggregate(Invoice, :count) == 0
  end

  test "nobody else may save one", %{conn: conn} do
    params = %{"invoice" => %{"month" => "2026-10", "amount_usd" => "1"}}

    assert conn
           |> log_in_account(account_fixture())
           |> post(~p"/troskovi/racuni", params)
           |> response(404)

    assert conn |> post(~p"/troskovi/racuni", params) |> redirected_to() == ~p"/accounts/log-in"
    assert Repo.aggregate(Invoice, :count) == 0
  end

  test "the English address leads to the page", %{conn: conn} do
    assert conn |> get(~p"/costs") |> redirected_to() == ~p"/troskovi"
  end

  test "/stack and the guest pages link to it", %{conn: conn} do
    assert has?(page(conn, ~p"/stack"), "#stack-costs-link[href='/troskovi']")
    assert has?(page(build_conn(), ~p"/troskovi"), "#guest-costs-link")
  end
end
