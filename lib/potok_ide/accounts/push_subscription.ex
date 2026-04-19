defmodule PotokIde.Accounts.PushSubscription do
  use Ecto.Schema
  import Ecto.Changeset

  @subscription_types [:web_push, :fcm]
  @device_platforms [:android, :ios, :web]

  schema "push_subscriptions" do
    field :subscription_type, Ecto.Enum, values: @subscription_types, default: :web_push
    field :device_token, :string
    field :device_platform, Ecto.Enum, values: @device_platforms
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
      :subscription_type,
      :device_token,
      :device_platform,
      :endpoint,
      :p256dh,
      :auth,
      :expires_at,
      :user_agent,
      :last_success_at,
      :last_failure_at,
      :failure_reason
    ])
    |> put_default_subscription_type()
    |> validate_required([:subscription_type])
    |> validate_length(:endpoint, max: 2048)
    |> validate_length(:p256dh, max: 255)
    |> validate_length(:auth, max: 255)
    |> validate_length(:device_token, max: 4096)
    |> validate_required_fields_for_type()
    |> unique_constraint(:endpoint)
    |> unique_constraint(:device_token, name: :push_subscriptions_device_token_index)
  end

  def identifier(%__MODULE__{subscription_type: :fcm, device_token: device_token}),
    do: device_token

  def identifier(%__MODULE__{endpoint: endpoint}), do: endpoint

  def delivery_type(%__MODULE__{} = subscription) do
    cond do
      complete_web_push_subscription?(subscription) -> :web_push
      present_binary?(subscription.device_token) -> :fcm
      true -> :unknown
    end
  end

  def normalize_type(attrs) when is_map(attrs) do
    case Map.get(attrs, :subscription_type) || Map.get(attrs, "subscription_type") ||
           Map.get(attrs, :type) || Map.get(attrs, "type") do
      value when value in [:fcm, "fcm"] -> :fcm
      _ -> :web_push
    end
  end

  def web_push?(%__MODULE__{} = subscription), do: delivery_type(subscription) == :web_push

  def fcm?(%__MODULE__{} = subscription), do: delivery_type(subscription) == :fcm

  defp put_default_subscription_type(changeset) do
    case get_field(changeset, :subscription_type) do
      nil -> put_change(changeset, :subscription_type, :web_push)
      _value -> changeset
    end
  end

  defp validate_required_fields_for_type(changeset) do
    case get_field(changeset, :subscription_type) do
      :fcm ->
        validate_required(changeset, [:device_token, :device_platform])

      _web_push ->
        validate_required(changeset, [:endpoint, :p256dh, :auth])
    end
  end

  defp complete_web_push_subscription?(%__MODULE__{} = subscription) do
    present_binary?(subscription.endpoint) and
      present_binary?(subscription.p256dh) and
      present_binary?(subscription.auth)
  end

  defp present_binary?(value) when is_binary(value), do: String.trim(value) != ""
  defp present_binary?(_value), do: false
end
