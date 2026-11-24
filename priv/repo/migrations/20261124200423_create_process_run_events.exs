defmodule PotokIde.Repo.Migrations.CreateProcessRunEvents do
  use Ecto.Migration

  # The trace of the runs of a group's processes (`PotokIde.Processes.RunEvents`):
  # when a run started, which steps it passed and what it changed on the way,
  # where it waited, who answered what, and how it ended. Postgres writes it as
  # the run's row moves, so a run woken or cancelled in bulk is in it too.
  #
  # It is the group's: a run goes with its value, its trace stays, with the
  # step's name as it was, as a run's copy of the drawing goes 30 days after it
  # ends. The values of variables go then too, by the age of the event.
  def up do
    create table(:process_run_events) do
      add :group_id, references(:groups, on_delete: :delete_all), null: false
      add :app_process_id, :bigint, null: false
      add :run_id, :bigint, null: false
      add :kind, :string, null: false
      add :element, :text
      add :label, :text
      add :type, :string
      add :outcome, :text
      add :actor_id, references(:profiles, on_delete: :nilify_all)
      add :vars, :map
      # A loop's steps past the first 200 of a run add up in one row each.
      add :count, :integer, null: false, default: 1
      add :at, :utc_datetime_usec, null: false
      add :last_at, :utc_datetime_usec
    end

    create index(:process_run_events, [:run_id, :id])
    create index(:process_run_events, [:app_process_id, :id], where: "kind = 'started'")
    create index(:process_run_events, [:group_id])
    create index(:process_run_events, [:actor_id], where: "actor_id IS NOT NULL")
    create index(:process_run_events, [:at], where: "vars IS NOT NULL")

    create constraint(:process_run_events, :process_run_events_kind_check,
             check:
               "kind IN ('started', 'passed', 'waits', 'answered', 'woke', 'failed', " <>
                 "'retried', 'cancelled', 'done')"
           )

    execute """
    CREATE OR REPLACE FUNCTION history_run() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      context jsonb := NULLIF(current_setting('potok.history', true), '')::jsonb;
      of_group bigint;
      what text;
      at_element text := NEW.element;
      how text;
      who bigint := (context ->> 'actor')::bigint;
      node jsonb;
      changed jsonb;
      entry jsonb;
      now_at timestamp := timezone('utc', clock_timestamp());
    BEGIN
      IF context ? 'off' THEN
        RETURN NULL;
      END IF;

      SELECT p.group_id INTO of_group FROM app_processes p WHERE p.id = NEW.app_process_id;

      IF NOT FOUND THEN
        RETURN NULL;
      END IF;

      IF TG_OP = 'INSERT' THEN
        what := 'started';
        who := NEW.started_by_id;
      ELSIF NEW.status IS DISTINCT FROM OLD.status
            AND NEW.status IN ('failed', 'cancelled', 'done') THEN
        what := NEW.status;
        at_element := COALESCE(
          CASE WHEN NEW.status = 'failed' THEN NEW.error ->> 'element' END, OLD.element
        );
        how := CASE WHEN NEW.status = 'failed' THEN NEW.error ->> 'reason' END;
      ELSIF OLD.status = 'failed' AND NEW.status = 'running' THEN
        what := 'retried';
      ELSIF NEW.status = 'waiting' AND OLD.status <> 'waiting' THEN
        what := 'waits';
        who := NULL;
      ELSIF NEW.element IS DISTINCT FROM OLD.element THEN
        at_element := OLD.element;
        who := NULL;

        IF OLD.status <> 'waiting' THEN
          what := 'passed';
        ELSIF NEW.log IS DISTINCT FROM OLD.log THEN
          entry := NEW.log[array_upper(NEW.log, 1)];
          what := 'answered';
          who := (entry ->> 'by')::bigint;
          how := entry ->> 'outcome';
        ELSE
          what := 'woke';
        END IF;
      ELSE
        RETURN NULL;
      END IF;

      -- A run that goes round and round keeps a row for each of its steps.
      IF what = 'passed' AND NEW.steps > 200 THEN
        UPDATE process_run_events e
        SET count = e.count + 1, last_at = now_at
        WHERE e.id = (
          SELECT l.id FROM process_run_events l
          WHERE l.run_id = NEW.id AND l.kind = 'passed' AND l.element = at_element
          ORDER BY l.id DESC LIMIT 1
        );

        IF FOUND THEN
          RETURN NULL;
        END IF;
      END IF;

      SELECT n INTO node
      FROM jsonb_array_elements(
        CASE WHEN jsonb_typeof(NEW.graph -> 'nodes') = 'array' THEN NEW.graph -> 'nodes'
          ELSE '[]'::jsonb END
      ) n
      WHERE n ->> 'id' = at_element
      LIMIT 1;

      -- What the step made of the run's variables: `[before, after]` of each,
      -- or only which they were when that is much.
      IF TG_OP = 'UPDATE' THEN
        SELECT jsonb_object_agg(k, jsonb_build_array(OLD.vars -> k, NEW.vars -> k)) INTO changed
        FROM (
          SELECT jsonb_object_keys(COALESCE(OLD.vars, '{}'::jsonb) || COALESCE(NEW.vars, '{}'::jsonb)) k
        ) keys
        WHERE OLD.vars -> k IS DISTINCT FROM NEW.vars -> k;

        IF changed IS NOT NULL AND pg_column_size(changed) > 4096 THEN
          SELECT jsonb_object_agg(k, NULL) INTO changed FROM jsonb_object_keys(changed) k;
        END IF;
      END IF;

      INSERT INTO process_run_events (
        group_id, app_process_id, run_id, kind, element, label, type, outcome, actor_id, vars, at
      ) VALUES (
        of_group, NEW.app_process_id, NEW.id, what, at_element,
        COALESCE(NULLIF(node ->> 'label', ''), at_element), node ->> 'type', how, who, changed,
        now_at
      );

      RETURN NULL;
    END
    $$
    """

    execute """
    CREATE OR REPLACE TRIGGER history_run_started AFTER INSERT ON value_processes
    FOR EACH ROW EXECUTE FUNCTION history_run()
    """

    execute """
    CREATE OR REPLACE TRIGGER history_run_moved AFTER UPDATE OF element, status ON value_processes
    FOR EACH ROW WHEN (
      OLD.element IS DISTINCT FROM NEW.element OR OLD.status IS DISTINCT FROM NEW.status
    ) EXECUTE FUNCTION history_run()
    """
  end

  def down do
    execute "DROP FUNCTION IF EXISTS history_run() CASCADE"
    drop table(:process_run_events)
  end
end
