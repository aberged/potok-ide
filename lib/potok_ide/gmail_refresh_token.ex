defmodule PotokIde.GmailRefreshToken do
  @moduledoc false

  use Ecto.Schema

  import Ecto.Query, warn: false

  alias PotokIde.Repo

  @provider "gmail"

  schema "gmail_refresh_tokens" do
    field :provider, :string
    field :refresh_token, :string

    timestamps(type: :utc_datetime)
  end

  def get do
    from(token in __MODULE__, where: token.provider == ^@provider)
    |> Repo.one()
  end

  def upsert(refresh_token) when is_binary(refresh_token) and refresh_token != "" do
    now = DateTime.utc_now(:second)

    %__MODULE__{}
    |> Ecto.Changeset.change(%{
      provider: @provider,
      refresh_token: refresh_token
    })
    |> Repo.insert(
      on_conflict: [set: [refresh_token: refresh_token, updated_at: now]],
      conflict_target: :provider,
      returning: true
    )
  end

  def delete_all do
    from(token in __MODULE__, where: token.provider == ^@provider)
    |> Repo.delete_all()
  end
end
