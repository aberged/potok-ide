defmodule PotokIde.Processes.GroupField do
  @moduledoc """
  A field the processes drawn in a group keep for each other
  (`PotokIde.Processes.GroupFields`): a name, its type, what it holds as a
  text of that type, and the process that wrote it last.
  """

  use Ecto.Schema

  schema "group_fields" do
    belongs_to :group, PotokIde.Social.Group
    field :name, :string
    field :value, :string, default: ""
    # text, number, boolean, date, datetime or choice (`GroupFields.types/0`),
    # with the `options` of a choice.
    field :type, :string, default: "text"
    field :options, {:array, :string}, default: []
    belongs_to :app_process, PotokIde.Social.AppProcess

    timestamps(type: :utc_datetime)
  end
end
