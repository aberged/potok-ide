defmodule PotokIde.Processes.GroupField do
  @moduledoc """
  A field the processes drawn in a group keep for each other
  (`PotokIde.Processes.GroupFields`): a name, a text, and the process that
  wrote it last.
  """

  use Ecto.Schema

  schema "group_fields" do
    belongs_to :group, PotokIde.Social.Group
    field :name, :string
    field :value, :string, default: ""
    belongs_to :app_process, PotokIde.Social.AppProcess

    timestamps(type: :utc_datetime)
  end
end
