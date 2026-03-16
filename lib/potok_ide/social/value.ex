defmodule PotokIde.Social.Value do
  use Ecto.Schema

  import Ecto.Changeset

  @content_formats [:markdown, :html]

  schema "values" do
    field :content, :string
    field :content_format, Ecto.Enum, values: @content_formats, default: :markdown

    belongs_to :creator, PotokIde.Social.Profile
    belongs_to :group, PotokIde.Social.Group

    belongs_to :parent, __MODULE__
    has_many :children, __MODULE__, foreign_key: :parent_id

    timestamps(type: :utc_datetime)
  end

  def changeset(value, attrs) do
    value
    |> cast(attrs, [:content, :content_format, :creator_id, :group_id, :parent_id])
    |> validate_required([:content, :content_format, :creator_id, :group_id])
    |> check_constraint(:content_format, name: :values_content_format_check)
  end
end
