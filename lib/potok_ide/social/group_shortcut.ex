defmodule PotokIde.Social.GroupShortcut do
  @moduledoc """
  A shortcut stands in a group (`parent`) as one of its sub-groups and opens
  another group (`target`), wherever that one stands in the tree, as a
  shortcut does on a computer. It is not a group: it has no members, values or
  counts of its own, and the lists show the target's row in its place
  (`PotokIde.Social.Group`'s `shortcut_id`).

  Whoever may make sub-groups in the parent places one to a group they see
  (`PotokIde.Social.create_group_shortcut/3`); everyone who sees both the
  parent and the target sees it. Its author or an admin of the parent takes it
  away, which leaves the target as it is. Deleting either group takes it away.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "group_shortcuts" do
    belongs_to :parent, PotokIde.Social.Group
    belongs_to :target, PotokIde.Social.Group
    belongs_to :creator, PotokIde.Social.Profile

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc false
  def changeset(shortcut) do
    shortcut
    |> change()
    |> unique_constraint(:target_id, name: :group_shortcuts_parent_id_target_id_index)
    |> check_constraint(:target_id, name: :group_shortcuts_not_self_check)
    |> foreign_key_constraint(:parent_id)
    |> foreign_key_constraint(:target_id)
  end
end
