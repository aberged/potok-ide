defmodule PotokIde.Social.Group do
  use Ecto.Schema

  import Ecto.Changeset

  @max_group_picture_url_length 1_000_000

  @description_formats [:markdown, :html]
  @home_pages [:chat, :description, :subgroups]

  schema "groups" do
    field :name, :string
    # See Profile.profile_picture_url: loaded only on demand via `Social.load_picture/1`.
    field :group_picture_url, :string, load_in_query: false
    field :description, :string
    field :description_format, Ecto.Enum, values: @description_formats, default: :markdown
    # Label of the default description next to the alternative ones.
    field :description_name, :string
    field :home_page, Ecto.Enum, values: @home_pages, default: :description
    field :has_public_chat, :boolean, default: false
    field :is_direct, :boolean, default: false
    field :is_public, :boolean, default: false
    field :is_root, :boolean, default: false
    field :is_root_public, :boolean, default: false
    field :uses_api, :boolean, default: false
    # Holds every member of the parent (see `Social.MemberInheritance`).
    # Threads always do; `Social` keeps it off for the root's children.
    field :inherits_members, :boolean, default: false
    # When the newest chat value was posted; kept by Social, never cast.
    field :last_value_at, :utc_datetime

    belongs_to :creator, PotokIde.Social.Profile
    belongs_to :parent, __MODULE__
    belongs_to :parent_value, PotokIde.Social.Value
    # Opened instead of the default description; nil opens the default.
    # `Social.update_group/3` checks that it is one of the group's own.
    belongs_to :home_alt_description, PotokIde.Social.GroupAltDescription

    has_many :children, __MODULE__, foreign_key: :parent_id
    has_many :alt_descriptions, PotokIde.Social.GroupAltDescription
    has_one :manifest, PotokIde.Social.GroupManifest

    many_to_many :members, PotokIde.Social.Profile,
      join_through: PotokIde.Social.GroupMembership,
      join_keys: [group_id: :id, profile_id: :id]

    has_many :values, PotokIde.Social.Value

    timestamps(type: :utc_datetime)
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [
      :name,
      :group_picture_url,
      :description,
      :description_format,
      :home_page,
      :has_public_chat,
      :is_direct,
      :is_public,
      :is_root,
      :is_root_public,
      :uses_api,
      :inherits_members,
      :creator_id,
      :parent_id,
      :parent_value_id
    ])
    |> validate_required([
      :name,
      :description_format,
      :home_page,
      :has_public_chat,
      :is_public,
      :is_root,
      :is_root_public
    ])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:group_picture_url, max: @max_group_picture_url_length)
    |> maybe_force_public_from_root_public()
    |> maybe_force_html_from_uses_api()
    |> maybe_force_inherits_members_for_thread()
    |> add_check_constraints()
    |> unique_constraint(:parent_value_id)
    |> validate_creation_constraints()
  end

  def update_changeset(group, attrs) do
    group
    |> cast(attrs, [
      :name,
      :group_picture_url,
      :description,
      :description_format,
      :description_name,
      :home_page,
      :home_alt_description_id,
      :has_public_chat,
      :is_public,
      :is_root_public,
      :uses_api,
      :inherits_members
    ])
    |> update_change(:description_name, &trim/1)
    |> validate_required([
      :name,
      :description_format,
      :home_page,
      :has_public_chat,
      :is_public,
      :is_root_public
    ])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:description_name, max: 60)
    |> validate_length(:group_picture_url, max: @max_group_picture_url_length)
    |> maybe_force_public_from_root_public()
    |> maybe_force_html_from_uses_api()
    |> maybe_force_inherits_members_for_thread()
    |> add_check_constraints()
    |> foreign_key_constraint(:home_alt_description_id)
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  defp maybe_force_public_from_root_public(changeset) do
    if get_field(changeset, :is_root_public) do
      put_change(changeset, :is_public, true)
    else
      changeset
    end
  end

  defp maybe_force_html_from_uses_api(changeset) do
    if get_field(changeset, :uses_api) do
      put_change(changeset, :description_format, :html)
    else
      changeset
    end
  end

  # A thread holds the members of the group its value was posted in.
  defp maybe_force_inherits_members_for_thread(changeset) do
    if get_field(changeset, :parent_value_id) do
      put_change(changeset, :inherits_members, true)
    else
      changeset
    end
  end

  defp add_check_constraints(changeset) do
    changeset
    |> check_constraint(:description_format, name: :groups_description_format_check)
    |> check_constraint(:home_page, name: :groups_home_page_check)
    |> check_constraint(:is_public, name: :groups_root_private_check)
    |> check_constraint(:parent_id, name: :groups_root_parent_check)
    |> check_constraint(:creator_id, name: :groups_root_creator_check)
    |> check_constraint(:inherits_members, name: :groups_inherits_members_check)
    |> check_constraint(:inherits_members, name: :groups_thread_inherits_members_check)
  end

  defp validate_creation_constraints(changeset) do
    is_root = get_field(changeset, :is_root)

    if is_root do
      changeset
    else
      validate_required(changeset, [:creator_id, :parent_id])
    end
  end
end
