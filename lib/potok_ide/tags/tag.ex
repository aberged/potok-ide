defmodule PotokIde.Tags.Tag do
  @moduledoc """
  A tag that can be put on groups, profiles, events, values and files. A tag
  without an owner is public and seen by everyone who sees the item; a
  private tag is seen only by the profile that owns it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @max_length 32

  # Letters, digits, spaces and `_ . -`, starting with a letter or digit.
  @name_format ~r/^[\p{L}\p{Nd}][\p{L}\p{Nd} _.\-]*$/u

  schema "tags" do
    field :name, :string

    belongs_to :owner, PotokIde.Social.Profile

    timestamps(type: :utc_datetime)
  end

  def max_length, do: @max_length

  def public?(%__MODULE__{owner_id: owner_id}), do: is_nil(owner_id)

  @doc """
  `owner_id` is set on the struct by the caller, never cast.
  """
  def changeset(tag, attrs) do
    tag
    |> cast(attrs, [:name])
    |> update_change(:name, &normalize_name/1)
    |> validate_required([:name])
    |> validate_length(:name, max: @max_length)
    |> validate_format(:name, @name_format,
      message: "must contain only letters, numbers, spaces, _, . and -"
    )
    |> unique_constraint(:name, name: :tags_public_lower_name_index)
    |> unique_constraint(:name, name: :tags_owner_id_lower_name_index)
  end

  @doc """
  The name as it is stored: trimmed, without a leading `#` and with runs of
  whitespace as one space.
  """
  def normalize_name(name) when is_binary(name) do
    name
    |> String.trim()
    |> String.trim_leading("#")
    |> String.split(~r/\s+/u, trim: true)
    |> Enum.join(" ")
  end

  def normalize_name(name), do: name
end
