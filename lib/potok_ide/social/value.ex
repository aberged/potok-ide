defmodule PotokIde.Social.Value do
  use Ecto.Schema

  import Ecto.Changeset

  @content_formats [:markdown, :html]

  schema "values" do
    field :content, :string
    field :content_format, Ecto.Enum, values: @content_formats, default: :markdown
    field :is_data, :boolean, default: false
    field :data, :map

    belongs_to :creator, PotokIde.Social.Profile
    belongs_to :group, PotokIde.Social.Group

    belongs_to :parent, __MODULE__
    has_many :children, __MODULE__, foreign_key: :parent_id

    timestamps(type: :utc_datetime)
  end

  def changeset(value, attrs) do
    attrs = normalize_data_attr(attrs)

    value
    |> cast(attrs, [
      :content,
      :content_format,
      :is_data,
      :data,
      :creator_id,
      :group_id,
      :parent_id
    ])
    |> validate_required([:content_format, :creator_id, :group_id])
    |> validate_content_required()
    |> check_constraint(:content_format, name: :values_content_format_check)
  end

  def changeset_for_update(value, attrs) do
    attrs = normalize_data_attr(attrs)

    value
    |> cast(attrs, [
      :content,
      :content_format,
      :is_data,
      :data,
      :creator_id,
      :group_id,
      :parent_id
    ])
    |> validate_required([:content_format, :creator_id, :group_id])
    |> check_constraint(:content_format, name: :values_content_format_check)
  end

  defp validate_content_required(changeset) do
    if get_field(changeset, :is_data) do
      changeset
    else
      validate_required(changeset, [:content])
    end
  end

  defp normalize_data_attr(attrs) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, "data") -> Map.update!(attrs, "data", &decode_data_value/1)
      Map.has_key?(attrs, :data) -> Map.update!(attrs, :data, &decode_data_value/1)
      true -> attrs
    end
  end

  defp normalize_data_attr(attrs), do: attrs

  defp decode_data_value(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        nil

      true ->
        case Jason.decode(trimmed) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _ -> value
        end
    end
  end

  defp decode_data_value(value), do: value
end
