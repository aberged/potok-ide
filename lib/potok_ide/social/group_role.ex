defmodule PotokIde.Social.GroupRole do
  @moduledoc """
  A role of a group manifest. For each permission a role either allows it,
  denies it or says nothing; a denial wins over any allowance. The built-in
  "admin" role holds every permission and "everyone" is held by every member.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @admin_key "admin"
  @everyone_key "everyone"
  @builtin_keys [@admin_key, @everyone_key]

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
    :edit_group
  ]

  # What "everyone" holds by default: what every member could do before roles
  # existed, and attaching files. The rest was creator-only.
  @default_everyone_permissions [
    :post_values,
    :attach_files,
    :react,
    :open_threads,
    :create_subgroups,
    :invite_members,
    :mention_roles
  ]

  # Same characters as usernames, so `@name` mentions parse the same way.
  @name_format ~r/^[\p{L}\p{Nd}_.-]+$/u

  schema "group_roles" do
    field :key, :string
    field :name, :string
    field :allowed, {:array, Ecto.Enum}, values: @permissions, default: []
    field :denied, {:array, Ecto.Enum}, values: @permissions, default: []
    field :position, :integer, default: 0

    belongs_to :manifest, PotokIde.Social.GroupManifest

    timestamps(type: :utc_datetime)
  end

  def admin_key, do: @admin_key
  def everyone_key, do: @everyone_key
  def permissions, do: @permissions
  def default_everyone_permissions, do: @default_everyone_permissions

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
