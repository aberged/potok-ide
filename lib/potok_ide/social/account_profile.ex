defmodule PotokIde.Social.AccountProfile do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  schema "accounts_profiles" do
    belongs_to :account, PotokIde.Accounts.Account
    belongs_to :profile, PotokIde.Social.Profile

    timestamps(type: :utc_datetime)
  end

  def changeset(account_profile, attrs) do
    account_profile
    |> cast(attrs, [:account_id, :profile_id])
    |> validate_required([:account_id, :profile_id])
    |> unique_constraint([:account_id, :profile_id],
      name: :accounts_profiles_account_id_profile_id_index
    )
  end
end
