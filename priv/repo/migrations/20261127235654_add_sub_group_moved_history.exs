defmodule PotokIde.Repo.Migrations.AddSubGroupMovedHistory do
  use Ecto.Migration

  # A sub-group moved to another parent (`Social.move_to_sibling/3`, a site's
  # article going to another section) is told of in both: the one it left
  # (`to`) and the one it came to (`from`), each with the other's id, as
  # `parent_id` itself is not kept in a group's own changes
  # (`History.Tracked`). The other's name is read when it is shown, and only
  # for a reader who sees it (`History.Feed`). Only for a group others may
  # hear of, as when it is made (`history_sub_group`).
  #
  # The trigger names no columns, so it watches none of those that
  # `History.Tracked` leaves out; its condition looks at `parent_id` alone.
  def up do
    execute """
    CREATE OR REPLACE FUNCTION history_sub_group_moved() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF EXISTS (SELECT 1 FROM groups WHERE id = OLD.parent_id AND NOT is_root) THEN
        PERFORM history_write(
          OLD.parent_id, 'sub_group', NEW.id, 'changed', ARRAY['parent_id'],
          jsonb_build_object('name', NEW.name, 'to', NEW.parent_id),
          NULL, NEW.creator_id, NULL, NULL, false, NULL, NULL, false
        );
      END IF;

      IF EXISTS (SELECT 1 FROM groups WHERE id = NEW.parent_id AND NOT is_root) THEN
        PERFORM history_write(
          NEW.parent_id, 'sub_group', NEW.id, 'changed', ARRAY['parent_id'],
          jsonb_build_object('name', NEW.name, 'from', OLD.parent_id),
          NULL, NEW.creator_id, NULL, NULL, false, NULL, NULL, false
        );
      END IF;

      RETURN NULL;
    END
    $$
    """

    execute """
    CREATE TRIGGER history_sub_group_moved AFTER UPDATE ON groups
    FOR EACH ROW
    WHEN (OLD.parent_id IS DISTINCT FROM NEW.parent_id AND NEW.parent_id IS NOT NULL
          AND NEW.is_public AND NOT NEW.is_direct AND NEW.parent_value_id IS NULL
          AND NEW.external_key IS NULL)
    EXECUTE FUNCTION history_sub_group_moved()
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS history_sub_group_moved ON groups"
    execute "DROP FUNCTION IF EXISTS history_sub_group_moved()"
  end
end
