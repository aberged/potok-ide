defmodule PotokIde.Social.GroupManifest do
  @moduledoc """
  The roles of a group. A group without its own manifest uses the manifest of
  its nearest ancestor that has one (see `PotokIde.Social.Access`).
  """

  use Ecto.Schema

  schema "group_manifests" do
    belongs_to :group, PotokIde.Social.Group
    has_many :roles, PotokIde.Social.GroupRole, foreign_key: :manifest_id

    timestamps(type: :utc_datetime)
  end
end
