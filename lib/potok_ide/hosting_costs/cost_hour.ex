defmodule PotokIde.HostingCosts.CostHour do
  @moduledoc """
  What one hour of one thing Potok runs on cost, in US dollars, as
  `PotokIde.HostingCosts.Sampler` estimated it from what Fly reports and the
  price list (`PotokIde.HostingCosts.Prices`).

  `item` says which one of its `category`: a machine's id, the database plan,
  the bucket or a region. `quantity` is hours of a machine or gigabytes, and
  `detail` keeps what the estimate was made from (a machine's size and state,
  whether the hour was filled in afterwards). The rows are written by the
  sampler alone and replaced while their hour lasts.
  """

  use Ecto.Schema

  @categories [:machines, :postgres, :storage, :bandwidth, :ips]

  schema "hosting_cost_hours" do
    field :hour, :utc_datetime
    field :category, Ecto.Enum, values: @categories
    field :item, :string
    field :quantity, :float, default: 0.0
    field :amount_usd, :decimal
    field :detail, :map, default: %{}

    timestamps(type: :utc_datetime)
  end

  def categories, do: @categories
end
