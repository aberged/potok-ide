defmodule PotokIde.Repo.Migrations.AddAttachFilesPermission do
  use Ecto.Migration

  # Every member could attach files from the start, like posting values, so
  # the "everyone" role of every manifest gets the new permission. Admins hold
  # every permission without it being stored.
  def up do
    execute """
    UPDATE group_roles
    SET allowed = array_append(allowed, 'attach_files')
    WHERE key = 'everyone' AND NOT ('attach_files' = ANY(allowed))
    """
  end

  def down do
    execute """
    UPDATE group_roles
    SET allowed = array_remove(allowed, 'attach_files'),
        denied = array_remove(denied, 'attach_files')
    """
  end
end
