defmodule PotokIde.Accounts.PushSubscription do
  use Ecto.Schema
  import Ecto.Changeset

  schema "push_subscriptions" do
    field :endpoint, :string
    field :p256dh, :string
    field :auth, :string
    field :expires_at, :utc_datetime
    field :user_agent, :string
    field :last_success_at, :utc_datetime
    field :last_failure_at, :utc_datetime
    field :failure_reason, :string

    belongs_to :account, PotokIde.Accounts.Account

    timestamps(type: :utc_datetime)
  end

  def changeset(push_subscription, attrs) do
    push_subscription
    |> cast(attrs, [
      :endpoint,
      :p256dh,
      :auth,
      :expires_at,
      :user_agent,
      :last_success_at,
      :last_failure_at,
      :failure_reason
    ])
    |> validate_required([:endpoint, :p256dh, :auth])
    |> validate_length(:endpoint, max: 2048)
    |> validate_length(:p256dh, max: 255)
    |> validate_length(:auth, max: 255)
    |> unique_constraint(:endpoint)
  end
end
