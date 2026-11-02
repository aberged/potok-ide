defmodule PotokIde.Repo.Migrations.AddEventPermissions do
  use Ecto.Migration

  # Every member may add events to the calendar, so the "everyone" role of
  # every manifest gets `create_events`. `manage_events` (changing anyone's
  # events) is given by admins; they hold every permission without it being
  # stored.
  def up do
    execute """
    UPDATE group_roles
    SET allowed = array_append(allowed, 'create_events')
    WHERE key = 'everyone' AND NOT ('create_events' = ANY(allowed))
    """
  end

  def down do
    execute """
    UPDATE group_roles
    SET allowed = array_remove(array_remove(allowed, 'create_events'), 'manage_events'),
        denied = array_remove(array_remove(denied, 'create_events'), 'manage_events')
    """
  end
end
