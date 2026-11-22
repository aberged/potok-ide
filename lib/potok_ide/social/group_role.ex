defmodule PotokIde.Social.GroupRole do
  @moduledoc """
  A role of a group manifest. For each permission a role either allows it,
  denies it or says nothing; a denial wins over any allowance. The built-in
  "admin" role holds every permission and "everyone" is held by every member.

  The role also says how it is had (`request_mode`), which a profile reads
  before it asks for the role: it cannot be asked for (`closed`), whoever
  manages requests gives or refuses it (`approve`), or may put it to a vote
  instead (`choose`), or every request raises a vote (`vote`). A vote goes as
  `request_poll` says (`PotokIde.Social.RequestPoll`). See
  `PotokIde.Social.GroupRequests`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias PotokIde.Social.RequestPoll

  @admin_key "admin"
  @everyone_key "everyone"
  @builtin_keys [@admin_key, @everyone_key]
  @request_modes [:closed, :approve, :choose, :vote]

  # Order is the order shown in the roles tab.
  @permissions [
    :post_values,
    :attach_files,
    :react,
    :open_threads,
    :create_subgroups,
    :invite_members,
    :mention_roles,
    :manage_join_requests,
    :remove_members,
    :delete_values,
    :create_events,
    :manage_events,
    :publish_events,
    :create_polls,
    :vote_polls,
    :manage_polls,
    :publish_polls,
    :send_notices,
    :manage_tags,
    :edit_group
  ]

  # What "everyone" holds by default: what every member could do before roles
  # existed, attaching files, adding events and voting. The rest was creator-only.
  @default_everyone_permissions [
    :post_values,
    :attach_files,
    :react,
    :open_threads,
    :create_subgroups,
    :invite_members,
    :mention_roles,
    :create_events,
    :create_polls,
    :vote_polls
  ]

  # Same characters as usernames, so `@name` mentions parse the same way.
  @name_format ~r/^[\p{L}\p{Nd}_.-]+$/u

  schema "group_roles" do
    field :key, :string
    field :name, :string
    field :allowed, {:array, Ecto.Enum}, values: @permissions, default: []
    field :denied, {:array, Ecto.Enum}, values: @permissions, default: []
    field :position, :integer, default: 0
    # How the role is had: see the moduledoc.
    field :request_mode, Ecto.Enum, values: @request_modes, default: :closed
    # How a vote on a request for it goes; set with `choose` and `vote`.
    embeds_one :request_poll, RequestPoll, on_replace: :update

    belongs_to :manifest, PotokIde.Social.GroupManifest

    timestamps(type: :utc_datetime)
  end

  def admin_key, do: @admin_key
  def everyone_key, do: @everyone_key
  def permissions, do: @permissions
  def default_everyone_permissions, do: @default_everyone_permissions
  def request_modes, do: @request_modes

  @doc "Whether a request for the role can end in a vote."
  def votes?(%__MODULE__{request_mode: mode}), do: mode in [:choose, :vote]

  def builtin?(%__MODULE__{key: key}), do: key in @builtin_keys
  def builtin?(key) when is_binary(key), do: key in @builtin_keys
  def builtin?(nil), do: false

  @doc """
  `manifest_id` and `key` are set on the struct by the caller, never cast.
  """
  def changeset(role, attrs) do
    role
    |> cast(attrs, [:name, :position])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, min: 2, max: 32)
    |> validate_format(:name, @name_format,
      message: "must contain only letters, numbers, _, ., and -"
    )
    |> validate_name_not_reserved()
    |> unique_constraint(:name,
      name: :group_roles_manifest_id_lower_name_index,
      message: "is already used by another role"
    )
    |> unique_constraint(:key, name: :group_roles_manifest_id_key_index)
  end

  def permissions_changeset(role, allowed, denied) do
    change(role, allowed: allowed, denied: denied)
  end

  @doc """
  How the role is had: `mode` and, for a mode that votes, the vote's rules.
  "everyone", which every member holds, is never asked for.
  """
  def request_changeset(%__MODULE__{} = role, attrs) do
    role
    |> cast(attrs, [:request_mode])
    |> validate_required([:request_mode])
    |> validate_change(:request_mode, fn :request_mode, mode ->
      if role.key == @everyone_key and mode != :closed,
        do: [request_mode: "is held by every member"],
        else: []
    end)
    |> request_poll()
    |> check_constraint(:request_poll, name: :group_roles_request_poll_check)
  end

  defp request_poll(changeset) do
    if get_field(changeset, :request_mode) in [:choose, :vote],
      do: cast_embed(changeset, :request_poll, with: &RequestPoll.changeset/2, required: true),
      else: put_embed(changeset, :request_poll, nil)
  end

  defp validate_name_not_reserved(changeset) do
    if builtin?(get_field(changeset, :key)) do
      changeset
    else
      validate_change(changeset, :name, fn :name, name ->
        if String.downcase(name) in @builtin_keys,
          do: [name: "is reserved"],
          else: []
      end)
    end
  end
end
