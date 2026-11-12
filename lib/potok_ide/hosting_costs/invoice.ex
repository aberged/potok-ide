defmodule PotokIde.HostingCosts.Invoice do
  @moduledoc """
  What Fly actually billed for a month, in US dollars, as an operator copied it
  from the invoice (`PotokIde.Operators`). `month` is the month's first day.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @max_note_length 500

  schema "hosting_invoices" do
    field :month, :date
    field :amount_usd, :decimal
    field :note, :string

    timestamps(type: :utc_datetime)
  end

  @doc "Only `amount_usd` and `note` are cast; `month` is set by the caller."
  def changeset(invoice, attrs) do
    invoice
    |> cast(attrs, [:amount_usd, :note])
    |> update_change(:note, &String.trim/1)
    |> validate_required([:month, :amount_usd])
    |> validate_number(:amount_usd, greater_than_or_equal_to: 0, less_than: 100_000_000)
    |> validate_length(:note, max: @max_note_length, count: :codepoints)
    |> check_constraint(:amount_usd, name: :hosting_invoices_amount_check)
    |> check_constraint(:month, name: :hosting_invoices_month_check)
    |> unique_constraint(:month)
  end
end
