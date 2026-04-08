defmodule PotokIde.Social.Profile do
  use Ecto.Schema

  import Ecto.Changeset

  alias PotokIde.Repo

  @description_formats [:markdown, :html]
  @sharing_modes [:unique, :shared]

  schema "profiles" do
    field :username, :string
    field :profile_picture_url, :string
    field :description, :string
    field :description_format, Ecto.Enum, values: @description_formats, default: :markdown
    field :sharing, Ecto.Enum, values: @sharing_modes, default: :unique

    many_to_many :accounts, PotokIde.Accounts.Account,
      join_through: PotokIde.Social.AccountProfile,
      on_replace: :delete

    many_to_many :member_groups, PotokIde.Social.Group,
      join_through: PotokIde.Social.GroupMembership,
      join_keys: [profile_id: :id, group_id: :id]

    has_many :created_groups, PotokIde.Social.Group, foreign_key: :creator_id
    has_many :values, PotokIde.Social.Value, foreign_key: :creator_id

    timestamps(type: :utc_datetime)
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:username, :profile_picture_url, :description, :description_format, :sharing])
    |> validate_required([:username, :description_format, :sharing])
    |> validate_length(:username, min: 2, max: 50)
    |> unsafe_validate_unique(:username, Repo)
    |> unique_constraint(:username)
    |> validate_length(:profile_picture_url, max: 2048)
  end
end
