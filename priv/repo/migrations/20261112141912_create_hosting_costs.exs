defmodule PotokIde.Repo.Migrations.CreateHostingCosts do
  use Ecto.Migration

  def change do
    # What one hour of one thing Potok runs on cost, as estimated from what Fly
    # reports and the price list (`PotokIde.HostingCosts`). Each hour is written
    # again until it is over, so a row is replaced, never added twice.
    create table(:hosting_cost_hours) do
      add :hour, :utc_datetime, null: false
      add :category, :string, null: false
      # A machine's id, the database plan, the bucket or a region.
      add :item, :string, null: false
      # Hours of a machine, or gigabytes stored or sent.
      add :quantity, :float, null: false, default: 0.0
      add :amount_usd, :decimal, precision: 12, scale: 6, null: false
      add :detail, :map, null: false, default: %{}

      timestamps(type: :utc_datetime)
    end

    # Leads with the hour, so it also serves the sums of a month.
    create unique_index(:hosting_cost_hours, [:hour, :category, :item])

    create constraint(:hosting_cost_hours, :hosting_cost_hours_category_check,
             check: "category IN ('machines', 'postgres', 'storage', 'bandwidth', 'ips')"
           )

    create constraint(:hosting_cost_hours, :hosting_cost_hours_amount_check,
             check: "amount_usd >= 0 AND quantity >= 0"
           )

    # What Fly actually billed for a month, written by an operator from the
    # invoice, next to the estimate.
    create table(:hosting_invoices) do
      add :month, :date, null: false
      add :amount_usd, :decimal, precision: 10, scale: 2, null: false
      add :note, :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:hosting_invoices, [:month])

    create constraint(:hosting_invoices, :hosting_invoices_month_check,
             check: "EXTRACT(DAY FROM month) = 1"
           )

    create constraint(:hosting_invoices, :hosting_invoices_amount_check,
             check: "amount_usd >= 0 AND char_length(coalesce(note, '')) <= 500"
           )
  end
end
