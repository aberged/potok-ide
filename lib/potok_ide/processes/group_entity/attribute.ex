defmodule PotokIde.Processes.GroupEntity.Attribute do
  @moduledoc """
  One attribute of an entity (`PotokIde.Processes.GroupEntity`): its name and
  the type of what it holds (`PotokIde.Processes.Types`), whether it is a
  list, and whether a value of the entity must have it.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias PotokIde.Processes.Types

  @max_options 30
  @max_option 60

  # Its own id tells a form's rows apart, so a row keeps what it held when
  # the rows above it change.
  embedded_schema do
    field :name, :string
    field :type, :string, default: "text"
    field :list, :boolean, default: false
    field :required, :boolean, default: false
    # What a `choice` may be, in the order written.
    field :options, {:array, :string}, default: []
    # The entity an `entity` holds, one of the same group.
    field :entity_id, :integer
  end

  @doc """
  `entity_ids` are the entities the attribute may hold: the other ones of
  its group. Options may come as one text, split at commas and new lines.
  """
  def changeset(attribute, attrs, entity_ids) do
    attribute
    |> cast(split_options(attrs), [:name, :type, :list, :required, :options, :entity_id])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name, :type])
    |> validate_change(:name, fn :name, name ->
      if Types.name?(name), do: [], else: [name: name_error(name)]
    end)
    |> validate_inclusion(:type, Types.kinds())
    |> options()
    |> entity(entity_ids)
  end

  defp name_error(name) do
    if name in Types.reserved(),
      do: "is a word processes keep for themselves",
      else: "must start with a letter and hold only letters, digits and _"
  end

  defp split_options(%{"options" => text} = attrs) when is_binary(text),
    do: %{attrs | "options" => split(text)}

  defp split_options(%{options: text} = attrs) when is_binary(text),
    do: %{attrs | options: split(text)}

  defp split_options(attrs), do: attrs

  defp split(text) do
    text
    |> String.split(~r/[,\n]/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  # Only a choice has options, and it needs some.
  defp options(changeset) do
    if get_field(changeset, :type) == "choice" do
      options = get_field(changeset, :options) || []

      cond do
        options == [] ->
          add_error(changeset, :options, "can't be blank", validation: :required)

        length(options) > @max_options ->
          add_error(changeset, :options, "has too many options")

        Enum.any?(options, &(String.length(&1) > @max_option)) ->
          add_error(changeset, :options, "has an option that is too long")

        true ->
          changeset
      end
    else
      put_change(changeset, :options, [])
    end
  end

  # Only an entity names another, and it must be one the group has.
  defp entity(changeset, entity_ids) do
    if get_field(changeset, :type) == "entity" do
      case get_field(changeset, :entity_id) do
        nil ->
          add_error(changeset, :entity_id, "can't be blank", validation: :required)

        id ->
          if id in entity_ids, do: changeset, else: add_error(changeset, :entity_id, "is invalid")
      end
    else
      put_change(changeset, :entity_id, nil)
    end
  end
end
