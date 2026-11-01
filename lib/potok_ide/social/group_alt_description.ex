defmodule PotokIde.Social.GroupAltDescription do
  @moduledoc """
  An alternative description of a group, shown next to the default one kept
  on `PotokIde.Social.Group`. Like the default it is text or, with
  `uses_api`, an app, which keeps its data values apart from the other apps
  (`Value.alt_description_id`).

  `visible_role_keys` empty: visible to everyone who sees the group's
  description; otherwise only to members holding one of those roles
  ("everyone" = every member). See `PotokIde.Social.Access.sees_alt_description?/2`.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @description_formats [:markdown, :html]

  schema "group_alt_descriptions" do
    field :name, :string
    field :description, :string, default: ""
    field :description_format, Ecto.Enum, values: @description_formats, default: :markdown
    field :uses_api, :boolean, default: false
    field :visible_role_keys, {:array, :string}, default: []
    field :position, :integer, default: 0

    belongs_to :group, PotokIde.Social.Group
    belongs_to :creator, PotokIde.Social.Profile

    timestamps(type: :utc_datetime)
  end

  @doc """
  `group_id`, `creator_id` and `position` are set on the struct by the
  caller, never cast.
  """
  def changeset(alt_description, attrs) do
    alt_description
    |> cast(attrs, [:name, :description, :description_format, :uses_api, :visible_role_keys])
    |> update_change(:name, &trim/1)
    |> update_change(:visible_role_keys, &normalize_role_keys/1)
    |> put_blank_description()
    |> validate_required([:name, :description_format])
    |> validate_length(:name, min: 1, max: 60)
    |> maybe_force_html_from_uses_api()
    |> check_constraint(:description_format,
      name: :group_alt_descriptions_description_format_check
    )
    |> unique_constraint(:name,
      name: :group_alt_descriptions_group_id_lower_name_index,
      message: "is already used by another description"
    )
  end

  # Clearing the field casts to a nil change.
  defp trim(name) when is_binary(name), do: String.trim(name)
  defp trim(name), do: name

  # The column is NOT NULL, and casting "" yields nil.
  defp put_blank_description(changeset) do
    if get_field(changeset, :description) == nil,
      do: put_change(changeset, :description, ""),
      else: changeset
  end

  defp maybe_force_html_from_uses_api(changeset) do
    if get_field(changeset, :uses_api) do
      put_change(changeset, :description_format, :html)
    else
      changeset
    end
  end

  # Checkbox groups send a hidden "" so that clearing every box is a change.
  defp normalize_role_keys(keys) when is_list(keys) do
    keys |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()
  end

  defp normalize_role_keys(_keys), do: []
end
