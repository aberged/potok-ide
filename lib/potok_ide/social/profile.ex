defmodule PotokIde.Social.Profile do
  use Ecto.Schema
  use Gettext, backend: PotokIdeWeb.Gettext

  import Ecto.Changeset

  alias PotokIde.Repo
  alias PotokIde.Social.{AppProcess, ProfileField}

  @max_profile_picture_url_length 1_000_000
  @max_username_length 16
  @username_format ~r/^[\p{L}\p{Nd}_.-]+$/u

  @description_formats [:markdown, :html]
  @sharing_modes [:unique, :shared]
  @kinds [:person, :process, :deleted]
  # As `PotokIde.Social.ProfileField.audiences/0`.
  @audiences [:only_me, :groups, :shared_groups, :signed_in]
  # Who may find it (`PotokIde.Social.Discovery`).
  @discoveries [:everyone, :by_username, :shared_groups]
  # The name a deleted person's profile takes (`PotokIde.Accounts.Deletion`),
  # which nobody may pick.
  @deleted_username ~r/^obrisan-\d+$/

  schema "profiles" do
    field :username, :string
    # Pictures can be ~1 MB data URLs; never load them with regular queries.
    # Use `PotokIde.Social.load_picture/1` when the raw value is needed (edit forms, avatar route).
    field :profile_picture_url, :string, load_in_query: false
    field :description, :string
    field :description_format, Ecto.Enum, values: @description_formats, default: :markdown
    # Who reads the description, as for a detail (`PotokIde.Social.ProfileField`).
    field :description_audience, Ecto.Enum, values: @audiences, default: :only_me
    field :description_group_ids, {:array, :id}, default: []
    field :sharing, Ecto.Enum, values: @sharing_modes, default: :unique
    field :discovery, Ecto.Enum, values: @discoveries, default: :by_username
    # A person's profile, or the one that signs what an app's process does
    # (`PotokIde.Social.AppProcesses`): no account holds it, nobody picks it,
    # and where people are listed, mentioned or invited it is left out.
    # Never cast: only `AppProcesses` makes a process. `:deleted` is what a
    # person's profile becomes when its only account is deleted
    # (`PotokIde.Accounts.Deletion`): left out the same way, it keeps what the
    # person wrote in the groups.
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

    # Never preloaded with the profile: `PotokIde.Social.ProfileDetails`
    # reads them and decides who sees which.
    has_many :fields, ProfileField

    has_many :created_groups, PotokIde.Social.Group, foreign_key: :creator_id
    has_many :values, PotokIde.Social.Value, foreign_key: :creator_id
    # Only for a process profile: the process it signs for.
    has_one :app_process, PotokIde.Social.AppProcess

    timestamps(type: :utc_datetime)
  end

  @doc """
  The profile as its form sends it. `allowed_group_ids:` are the groups the
  description may be shown to (`PotokIde.Social.ProfileDetails.allowed_group_ids/1`);
  besides them, it keeps only those it picked before.
  """
  def changeset(profile, attrs, opts \\ []) do
    profile
    |> cast(normalize_group_ids(attrs), [
      :username,
      :profile_picture_url,
      :description,
      :description_format,
      :description_audience,
      :description_group_ids,
      :sharing,
      :discovery
    ])
    |> validate_required([:username, :description_format, :sharing, :discovery])
    |> validate_length(:username, min: 2, max: @max_username_length)
    |> validate_format(:username, @username_format,
      message: "must contain only letters, numbers, _, ., and -"
    )
    |> validate_change(:username, fn :username, username ->
      if Regex.match?(@deleted_username, username),
        do: [username: "is kept for deleted accounts"],
        else: []
    end)
    |> unsafe_validate_unique(:username, Repo)
    |> unique_constraint(:username)
    |> validate_length(:profile_picture_url, max: @max_profile_picture_url_length)
    |> keep_description_group_ids(allowed_group_ids(profile, opts))
  end

  # The groups it picked stay allowed, so a form opens unchanged after the
  # profile left one (it only stops counting); the form drops it once the
  # profile picks again, as it lists only the groups the profile is in.
  defp allowed_group_ids(profile, opts) do
    stored =
      case profile do
        %__MODULE__{description_group_ids: ids} when is_list(ids) -> ids
        _ -> []
      end

    Keyword.get(opts, :allowed_group_ids, []) ++ stored
  end

  # A checkbox group sends a hidden "" so that none picked still sends the key.
  defp normalize_group_ids(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {key, ids} when key in [:description_group_ids, "description_group_ids"] and is_list(ids) ->
        {key, Enum.reject(ids, &(&1 in ["", nil]))}

      pair ->
        pair
    end)
  end

  defp normalize_group_ids(attrs), do: attrs

  # Picked groups only for `:groups`, and only among the profile's own.
  defp keep_description_group_ids(changeset, allowed_group_ids) do
    if get_field(changeset, :description_audience) == :groups do
      allowed = MapSet.new(allowed_group_ids)

      ids =
        changeset
        |> get_field(:description_group_ids)
        |> Enum.filter(&MapSet.member?(allowed, &1))
        |> Enum.uniq()

      changeset = put_change(changeset, :description_group_ids, ids)

      if ids == [],
        do: add_error(changeset, :description_group_ids, "pick at least one group"),
        else: changeset
    else
      put_change(changeset, :description_group_ids, [])
    end
  end

  def discoveries, do: @discoveries

  @doc "Whether the profile signs for an app's process rather than for a person."
  def process?(%__MODULE__{kind: :process}), do: true
  def process?(_profile), do: false

  @doc "Whether the profile's person deleted their account."
  def deleted?(%__MODULE__{kind: :deleted}), do: true
  def deleted?(_profile), do: false

  @doc "The username a deleted person's profile takes: `obrisan-<id>`."
  def deleted_username(id) when is_integer(id), do: "obrisan-#{id}"

  @doc """
  The name people see. A process goes by its rule's name once its
  `app_process` is loaded, and by its generated username otherwise.
  """
  def display_name(%__MODULE__{kind: :process, app_process: %AppProcess{name: name}}), do: name
  def display_name(%__MODULE__{kind: :deleted}), do: gettext("Deleted user")
  def display_name(%{username: username}), do: username

  @doc """
  An author as a line names it: `@username` for a person, who can be
  mentioned so, and `display_name/1` for a process or a deleted person, who
  cannot.
  """
  def author_label(%__MODULE__{kind: kind} = profile) when kind in [:process, :deleted],
    do: display_name(profile)

  def author_label(%{username: username}), do: "@" <> username
end
