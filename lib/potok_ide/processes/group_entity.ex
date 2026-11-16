defmodule PotokIde.Processes.GroupEntity do
  @moduledoc """
  An entity the editors of a group define for the processes drawn in it
  (`PotokIde.Processes.GroupEntities`): a name, once in the group in any
  letter case, and its attributes, each with the type of what it holds
  (`PotokIde.Processes.Types`).
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias PotokIde.Processes.GroupEntity.Attribute
  alias PotokIde.Processes.Types

  @max_name 40
  @max_attributes 30

  schema "group_entities" do
    belongs_to :group, PotokIde.Social.Group
    field :name, :string
    embeds_many :attributes, Attribute, on_replace: :delete
    field :lock_version, :integer, default: 1

    timestamps(type: :utc_datetime)
  end

  @doc """
  `group_id` is set on the struct by the caller, never cast. `others` are the
  other entities of the group: an attribute may hold one of them, as long as
  no entity comes to hold itself and none nests deeper than
  `Types.max_depth/0`. Attributes come in the order of `attributes_sort`,
  without those of `attributes_drop`, as a form sends them.
  """
  def changeset(entity, attrs, others) do
    ids = Enum.map(others, & &1.id)

    entity
    |> cast(attrs, [:name])
    |> update_change(:name, &String.trim/1)
    |> validate_required([:name])
    |> validate_length(:name, max: @max_name)
    |> cast_embed(:attributes,
      with: &Attribute.changeset(&1, &2, ids),
      sort_param: :attributes_sort,
      drop_param: :attributes_drop
    )
    |> attributes()
    |> nesting(others)
    |> unique_constraint(:name, name: :group_entities_group_id_name_index)
    |> check_constraint(:name, name: :group_entities_name_check)
  end

  @doc "The entities the entity's attributes hold, by their ids."
  def held(%__MODULE__{attributes: attributes}),
    do: for(%Attribute{type: "entity", entity_id: id} <- attributes, is_integer(id), do: id)

  # Some attributes, not too many, each name once.
  defp attributes(changeset) do
    names = for %Attribute{name: name} <- apply_changes(changeset).attributes, do: name

    cond do
      names == [] ->
        add_error(changeset, :attributes, "An entity needs at least one attribute.")

      length(names) > @max_attributes ->
        add_error(changeset, :attributes, "An entity has at most 30 attributes.")

      names != Enum.uniq(names) ->
        add_error(changeset, :attributes, "Two attributes have the same name.")

      true ->
        changeset
    end
  end

  defp nesting(%Ecto.Changeset{valid?: false} = changeset, _others), do: changeset

  defp nesting(changeset, others) do
    entity = apply_changes(changeset)
    # A new entity has no id yet, and nothing holds it.
    holds = others |> Map.new(&{&1.id, held(&1)}) |> Map.put(entity.id || :new, held(entity))

    case Types.nesting(holds) do
      :ok ->
        changeset

      {:error, :cycle} ->
        add_error(changeset, :attributes, "An entity cannot come to hold itself.")

      {:error, :too_deep} ->
        add_error(changeset, :attributes, "Entities nest at most 4 deep.")
    end
  end
end
