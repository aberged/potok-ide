defmodule PotokIde.Social.GroupValueRead do
  use Ecto.Schema

  import Ecto.Changeset

  @primary_key false
  schema "group_value_reads" do
    field :last_read_value_id, :integer

    belongs_to :profile, PotokIde.Social.Profile
    belongs_to :group, PotokIde.Social.Group

    timestamps(type: :utc_datetime)
  end

  def changeset(group_value_read, attrs) do
    group_value_read
    |> cast(attrs, [:profile_id, :group_id, :last_read_value_id])
    |> validate_required([:profile_id, :group_id])
    |> unique_constraint([:profile_id, :group_id],
      name: :group_value_reads_profile_id_group_id_index
    )
  end
end
