defmodule PotokIde.Social.Group do
  use Ecto.Schema

  import Ecto.Changeset

  @description_formats [:markdown, :html]

  schema "groups" do
    field :name, :string
    field :description, :string
    field :description_format, Ecto.Enum, values: @description_formats, default: :markdown
    field :is_public, :boolean, default: false
    field :is_root, :boolean, default: false

    belongs_to :creator, PotokIde.Social.Profile
    belongs_to :parent, __MODULE__
    belongs_to :parent_value, PotokIde.Social.Value

    has_many :children, __MODULE__, foreign_key: :parent_id

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
      :description,
      :description_format,
      :is_public,
      :is_root,
      :creator_id,
      :parent_id,
      :parent_value_id
    ])
    |> validate_required([:name, :description_format, :is_public, :is_root])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_root_constraints()
  end

  defp validate_root_constraints(changeset) do
    is_root = get_field(changeset, :is_root)

    changeset =
      changeset
      |> check_constraint(:description_format, name: :groups_description_format_check)
      |> check_constraint(:is_public, name: :groups_root_private_check)
      |> check_constraint(:parent_id, name: :groups_root_parent_check)
      |> check_constraint(:creator_id, name: :groups_root_creator_check)

    if is_root do
      changeset
    else
      validate_required(changeset, [:creator_id, :parent_id])
    end
  end
end
