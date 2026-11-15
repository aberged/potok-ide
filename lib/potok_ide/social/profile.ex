defmodule PotokIde.Social.Profile do
  use Ecto.Schema

  import Ecto.Changeset

  alias PotokIde.Repo
  alias PotokIde.Social.AppProcess

  @max_profile_picture_url_length 1_000_000
  @max_username_length 16
  @username_format ~r/^[\p{L}\p{Nd}_.-]+$/u

  @description_formats [:markdown, :html]
  @sharing_modes [:unique, :shared]
  @kinds [:person, :process]

  schema "profiles" do
    field :username, :string
    # Pictures can be ~1 MB data URLs; never load them with regular queries.
    # Use `PotokIde.Social.load_picture/1` when the raw value is needed (edit forms, avatar route).
    field :profile_picture_url, :string, load_in_query: false
    field :description, :string
    field :description_format, Ecto.Enum, values: @description_formats, default: :markdown
    field :sharing, Ecto.Enum, values: @sharing_modes, default: :unique
    # A person's profile, or the one that signs what an app's process does
    # (`PotokIde.Social.AppProcesses`): no account holds it, nobody picks it,
    # and where people are listed, mentioned or invited it is left out.
    # Never cast: only `AppProcesses` makes a process.
    field :kind, Ecto.Enum, values: @kinds, default: :person
    # Whether the notices of the groups it follows push to its devices at all;
    # never cast, `PotokIde.Notices.set_notice_push/2` changes it.
    field :notice_push, :boolean, default: true
    # The tags the viewing profile sees (`PotokIde.Tags.put_tags/3`): the
    # public ones and its own private ones.
    field :tags, {:array, :any}, virtual: true, default: []

    many_to_many :accounts, PotokIde.Accounts.Account,
      join_through: PotokIde.Social.AccountProfile,
      on_replace: :delete

    many_to_many :member_groups, PotokIde.Social.Group,
      join_through: PotokIde.Social.GroupMembership,
      join_keys: [profile_id: :id, group_id: :id]

    has_many :created_groups, PotokIde.Social.Group, foreign_key: :creator_id
    has_many :values, PotokIde.Social.Value, foreign_key: :creator_id
    # Only for a process profile: the process it signs for.
    has_one :app_process, PotokIde.Social.AppProcess

    timestamps(type: :utc_datetime)
  end

  def changeset(profile, attrs) do
    profile
    |> cast(attrs, [:username, :profile_picture_url, :description, :description_format, :sharing])
    |> validate_required([:username, :description_format, :sharing])
    |> validate_length(:username, min: 2, max: @max_username_length)
    |> validate_format(:username, @username_format,
      message: "must contain only letters, numbers, _, ., and -"
    )
    |> unsafe_validate_unique(:username, Repo)
    |> unique_constraint(:username)
    |> validate_length(:profile_picture_url, max: @max_profile_picture_url_length)
  end

  @doc "Whether the profile signs for an app's process rather than for a person."
  def process?(%__MODULE__{kind: :process}), do: true
  def process?(_profile), do: false

  @doc """
  The name people see. A process goes by its rule's name once its
  `app_process` is loaded, and by its generated username otherwise.
  """
  def display_name(%__MODULE__{kind: :process, app_process: %AppProcess{name: name}}), do: name
  def display_name(%{username: username}), do: username
end
