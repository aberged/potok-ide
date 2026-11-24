defmodule PotokIde.Repo.Migrations.AddHistoryTriggers do
  use Ecto.Migration

  # What fills `group_changes`. Postgres writes what changed, so that no path
  # of the app, no bulk statement and no cascade leaves a hole in the history;
  # the app only says who did it and why, in `potok.history`, a setting local
  # to the transaction (`PotokIde.History.signed/2`). Outside of such a
  # transaction the setting reads as NULL, or as '' on a connection that had
  # it before.
  #
  # What the triggers leave out is the point of them too: votes, members,
  # profiles and accounts have none, and neither do the columns Potok keeps
  # for itself (`PotokIde.History.Tracked` names every column of these
  # tables, and a test holds the two together).
  #
  # Each trigger is its own short transaction, as it takes a lock that stops
  # writes to its table, and gives up after 5 seconds rather than hold
  # everyone behind a long query. Running it again is safe.
  @disable_ddl_transaction true
  @disable_migration_lock true

  @group ~w(name description description_format description_name home_page
            home_alt_description_id has_public_chat description_for_guests is_public
            is_root_public uses_api preset inherits_members inherit_role_keys elects_admins
            join_mode join_poll published_at latitude longitude pin_icon area route
            external_key)
  @description ~w(name description description_format uses_api visible_role_keys for_guests)
  @template ~w(name purpose fields html)
  @process ~w(name active graph layout trigger trigger_config collection entry_entity_id
              return_entity_id is_public hears_related)
  @entity ~w(name attributes)
  @field ~w(name value type options)
  @poll ~w(question description kind max_choices allow_change secret is_public
           allow_member_options closes_at closed_at reminder_minutes voter_role_keys
           results_role_keys details_role_keys results_when details_when quorum_percent
           majority effect effect_role_key effect_replace unique_votes shared_votes)
  @event ~w(title description location all_day starts_at ends_at time_zone recurrence
            recurrence_interval recurrence_weekdays recurrence_monthly recurrence_until
            excluded_dates reminder_minutes cancelled_at is_public place_group_id latitude
            longitude area route)
  @record ~w(data managed content)

  def up do
    functions()

    updated("groups", @group ++ ["group_picture_url"], "history_group_changed", args: @group)
    row("groups", "created", "AFTER INSERT", "history_sub_group", when: sub_group("NEW"))
    row("groups", "deleted", "AFTER DELETE", "history_sub_group", when: sub_group("OLD"))

    row("group_alt_descriptions", "created", "AFTER INSERT", "history_description",
      when: "NEW.position >= 0"
    )

    updated("group_alt_descriptions", @description, "history_description", args: @description)

    row("group_alt_descriptions", "deleted", "AFTER DELETE", "history_description",
      when: "OLD.position >= 0",
      args: @description
    )

    thing("group_templates", "template", true, @template)
    thing("group_entities", "entity", true, @entity)
    thing("group_fields", "field", true, @field)
    thing("group_events", "event", false, @event)

    row("polls", "created", "AFTER INSERT", "history_thing", args: ["poll", "false"])
    updated("polls", @poll, "history_thing", args: ["poll", "false" | @poll])
    # Before the delete, as the options go with the poll.
    row("polls", "deleted", "BEFORE DELETE", "history_poll_deleted", args: @poll)

    row("group_notices", "deleted", "AFTER DELETE", "history_notice")

    row("app_processes", "created", "AFTER INSERT", "history_process", when: "NEW.drawn")

    updated("app_processes", @process, "history_process", when: "NEW.drawn", args: @process)

    row("app_processes", "deleted", "AFTER DELETE", "history_process",
      when: "OLD.drawn",
      args: @process
    )

    row("group_shortcuts", "created", "AFTER INSERT", "history_shortcut")
    row("group_shortcuts", "deleted", "AFTER DELETE", "history_shortcut")

    row("values", "record_created", "AFTER INSERT", "history_record",
      when: "NEW.is_data AND #{kept_collection("NEW")}"
    )

    updated("values", @record, "history_record",
      name: "record_changed",
      when: "NEW.is_data AND #{kept_collection("NEW")}",
      args: @record
    )

    updated("values", ["content"], "history_message",
      name: "message_changed",
      when: "NOT NEW.is_data"
    )

    # A statement at a time: an app's collection goes with all its records.
    execute_ddl("""
    CREATE OR REPLACE TRIGGER history_deleted AFTER DELETE ON "values"
    REFERENCING OLD TABLE AS old_values
    FOR EACH STATEMENT EXECUTE FUNCTION history_values_deleted()
    """)

    row("value_reactions", "created", "AFTER INSERT", "history_reaction")
    row("value_reactions", "deleted", "AFTER DELETE", "history_reaction")
    row("group_reactions", "created", "AFTER INSERT", "history_group_reaction")
    row("group_reactions", "deleted", "AFTER DELETE", "history_group_reaction")
  end

  def down do
    for function <- ~w(history_group_changed history_sub_group history_description
                       history_thing history_poll_deleted history_notice history_process
                       history_shortcut history_record history_message
                       history_values_deleted history_reaction history_group_reaction) do
      execute "DROP FUNCTION IF EXISTS #{function}() CASCADE"
    end

    for function <- ~w(history_write history_delta history_pick history_kept) do
      execute "DROP FUNCTION IF EXISTS #{function}"
    end
  end

  # A group others may come to hear of: not a conversation, a thread, or one
  # of an import.
  defp sub_group(row) do
    "#{row}.parent_id IS NOT NULL AND #{row}.is_public AND NOT #{row}.is_direct " <>
      "AND #{row}.parent_value_id IS NULL AND #{row}.external_key IS NULL"
  end

  defp kept_collection(row) do
    "#{row}.collection IS DISTINCT FROM 'notify' AND #{row}.collection IS DISTINCT FROM 'files'"
  end

  # A table whose rows belong to a group and need nothing more.
  defp thing(table, type, merge?, columns) do
    row(table, "created", "AFTER INSERT", "history_thing", args: [type, "#{merge?}"])
    updated(table, columns, "history_thing", args: [type, "#{merge?}" | columns])
    row(table, "deleted", "AFTER DELETE", "history_thing", args: [type, "#{merge?}" | columns])
  end

  defp row(table, name, event, function, opts \\ []) do
    condition = if opts[:when], do: "WHEN (#{opts[:when]})", else: ""

    execute_ddl("""
    CREATE OR REPLACE TRIGGER history_#{name} #{event} ON "#{table}"
    FOR EACH ROW #{condition} EXECUTE FUNCTION #{function}(#{args(opts)})
    """)
  end

  # Runs only for an UPDATE that names one of the columns and changes it, so
  # the writes Potok makes for itself cost nothing.
  defp updated(table, columns, function, opts) do
    changes = Enum.map_join(columns, " OR ", &"OLD.#{&1} IS DISTINCT FROM NEW.#{&1}")
    changes = if opts[:when], do: "#{opts[:when]} AND (#{changes})", else: changes

    execute_ddl("""
    CREATE OR REPLACE TRIGGER history_#{opts[:name] || "changed"}
    AFTER UPDATE OF #{Enum.join(columns, ", ")} ON "#{table}"
    FOR EACH ROW WHEN (#{changes}) EXECUTE FUNCTION #{function}(#{args(opts)})
    """)
  end

  defp args(opts), do: Enum.map_join(opts[:args] || [], ", ", &"'#{&1}'")

  defp execute_ddl(sql) do
    execute("""
    DO $ddl$
    BEGIN
      PERFORM set_config('lock_timeout', '5s', true);
      EXECUTE $sql$ #{sql} $sql$;
    END
    $ddl$
    """)
  end

  defp functions do
    # Whether a group keeps its history: one that is not being deleted, and
    # not a direct conversation, which nobody reads the history of.
    execute """
    CREATE OR REPLACE FUNCTION history_kept(p_group bigint) RETURNS boolean
    LANGUAGE sql STABLE AS $$
      SELECT EXISTS (SELECT 1 FROM groups WHERE id = p_group AND NOT is_direct)
    $$
    """

    # The named keys of a row.
    execute """
    CREATE OR REPLACE FUNCTION history_pick(p_row jsonb, p_keys text[]) RETURNS jsonb
    LANGUAGE sql IMMUTABLE AS $$
      SELECT COALESCE(jsonb_object_agg(k, p_row -> k), '{}'::jsonb) FROM unnest(p_keys) k
    $$
    """

    # The old values of the named keys that changed.
    execute """
    CREATE OR REPLACE FUNCTION history_delta(p_old jsonb, p_new jsonb, p_keys text[])
    RETURNS jsonb LANGUAGE sql IMMUTABLE AS $$
      SELECT COALESCE(jsonb_object_agg(k, p_old -> k), '{}'::jsonb)
      FROM unnest(p_keys) k
      WHERE p_old -> k IS DISTINCT FROM p_new -> k
    $$
    """

    # One row of the history. `p_default` is who did it when the app did not
    # say. A burst of changes to one thing by one person (`p_merge`) stays one
    # row for five minutes: it keeps the values from before the first of them.
    execute """
    CREATE OR REPLACE FUNCTION history_write(
      p_group bigint, p_type text, p_subject bigint, p_op text, p_fields text[],
      p_before jsonb, p_default bigint, p_creator bigint, p_alt bigint,
      p_collection text, p_anonymous boolean, p_keys_before text[], p_keys_after text[],
      p_merge boolean
    ) RETURNS void LANGUAGE plpgsql AS $$
    DECLARE
      context jsonb := NULLIF(current_setting('potok.history', true), '')::jsonb;
      who bigint := p_default;
      why jsonb;
      now_at timestamp := timezone('utc', clock_timestamp());
      last record;
    BEGIN
      IF context ? 'off' THEN
        RETURN;
      END IF;

      IF context ? 'actor' THEN
        who := (context ->> 'actor')::bigint;
      END IF;

      why := NULLIF(context - 'actor' - 'op', '{}'::jsonb);

      IF who IS NULL AND why IS NULL
         AND current_setting('potok.history_strict', true) = 'on' THEN
        RAISE EXCEPTION 'history: nobody signed % of % %', p_op, p_type, p_subject;
      END IF;

      -- The author of an anonymous record stays one.
      IF p_anonymous AND who = p_creator THEN
        who := NULL;
      END IF;

      IF p_merge AND p_op = 'changed' THEN
        SELECT c.id, c.op, c.actor_id, c.cause, c.at, c.purged_at INTO last
        FROM group_changes c
        WHERE c.subject_type = p_type AND c.subject_id = p_subject
        ORDER BY c.id DESC
        LIMIT 1;

        IF FOUND AND last.op = 'changed' AND last.purged_at IS NULL
           AND last.actor_id IS NOT DISTINCT FROM who
           AND last.cause IS NOT DISTINCT FROM why
           AND last.at > now_at - interval '5 minutes' THEN
          UPDATE group_changes c
          SET before = NULLIF(
                COALESCE(p_before, '{}'::jsonb) || COALESCE(c.before, '{}'::jsonb),
                '{}'::jsonb
              ),
              fields = ARRAY(
                SELECT DISTINCT f FROM unnest(c.fields || p_fields) f ORDER BY f
              ),
              keys_after = p_keys_after,
              last_at = now_at
          WHERE c.id = last.id;

          RETURN;
        END IF;
      END IF;

      INSERT INTO group_changes (
        group_id, subject_type, subject_id, op, fields, before, actor_id, creator_id,
        alt_description_id, collection, anonymous, keys_before, keys_after, cause, op_id,
        listed, at
      ) VALUES (
        p_group, p_type, p_subject, p_op, COALESCE(p_fields, '{}'), p_before, who, p_creator,
        p_alt, p_collection, p_anonymous, p_keys_before, p_keys_after, why,
        (context ->> 'op')::bigint,
        -- What Potok does by itself is kept for what things were, and not told;
        -- of what is put back in bulk the app tells once.
        COALESCE(why ->> 'via', '') NOT IN ('system', 'regrade', 'bulk'), now_at
      );
    END
    $$
    """

    execute """
    CREATE OR REPLACE FUNCTION history_group_changed() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      delta jsonb;
      changed text[];
    BEGIN
      IF NEW.is_direct THEN
        RETURN NULL;
      END IF;

      delta := history_delta(to_jsonb(OLD), to_jsonb(NEW), TG_ARGV::text[]);
      changed := ARRAY(SELECT jsonb_object_keys(delta));

      -- The picture itself, up to a megabyte, is not kept.
      IF OLD.group_picture_url IS DISTINCT FROM NEW.group_picture_url THEN
        changed := changed || 'group_picture_url'::text;
      END IF;

      PERFORM history_write(
        NEW.id, 'group', NEW.id, 'changed', changed, NULLIF(delta, '{}'::jsonb), NULL,
        NEW.creator_id, NULL, NULL, false, NULL, NULL, true
      );

      RETURN NULL;
    END
    $$
    """

    # A sub-group is told of in the group above it, unless that is the root.
    execute """
    CREATE OR REPLACE FUNCTION history_sub_group() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      child groups%ROWTYPE;
    BEGIN
      IF TG_OP = 'INSERT' THEN child := NEW; ELSE child := OLD; END IF;

      IF EXISTS (SELECT 1 FROM groups WHERE id = child.parent_id AND NOT is_root) THEN
        PERFORM history_write(
          child.parent_id, 'sub_group', child.id,
          CASE TG_OP WHEN 'INSERT' THEN 'created' ELSE 'deleted' END, '{}',
          CASE TG_OP WHEN 'DELETE' THEN jsonb_build_object('name', child.name) END,
          CASE TG_OP WHEN 'INSERT' THEN child.creator_id END, child.creator_id, NULL, NULL,
          false, NULL, NULL, false
        );
      END IF;

      RETURN NULL;
    END
    $$
    """

    # An alternative description, with the roles that saw it on each side.
    execute """
    CREATE OR REPLACE FUNCTION history_description() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      delta jsonb;
    BEGIN
      IF TG_OP = 'INSERT' THEN
        IF history_kept(NEW.group_id) THEN
          PERFORM history_write(
            NEW.group_id, 'description', NEW.id, 'created', '{}', NULL, NEW.creator_id,
            NEW.creator_id, NEW.id, NULL, false, NULL, NEW.visible_role_keys::text[], false
          );
        END IF;
      ELSIF TG_OP = 'UPDATE' THEN
        IF history_kept(NEW.group_id) THEN
          delta := history_delta(to_jsonb(OLD), to_jsonb(NEW), TG_ARGV::text[]);

          PERFORM history_write(
            NEW.group_id, 'description', NEW.id, 'changed',
            ARRAY(SELECT jsonb_object_keys(delta)), delta, NULL, NEW.creator_id, NEW.id, NULL,
            false, OLD.visible_role_keys::text[], NEW.visible_role_keys::text[], true
          );
        END IF;
      ELSIF history_kept(OLD.group_id) THEN
        PERFORM history_write(
          OLD.group_id, 'description', OLD.id, 'deleted', '{}',
          history_pick(to_jsonb(OLD), TG_ARGV::text[]), NULL, OLD.creator_id, OLD.id, NULL,
          false, OLD.visible_role_keys::text[], NULL, false
        );
      END IF;

      RETURN NULL;
    END
    $$
    """

    # TG_ARGV: the type, whether bursts merge, and the columns kept.
    execute """
    CREATE OR REPLACE FUNCTION history_thing() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      keys text[] := TG_ARGV[2:];
      delta jsonb;
      creator bigint;
      place bigint;
    BEGIN
      IF TG_OP = 'INSERT' THEN
        IF history_kept(NEW.group_id) THEN
          creator := (to_jsonb(NEW) ->> 'creator_id')::bigint;

          PERFORM history_write(
            NEW.group_id, TG_ARGV[0], NEW.id, 'created', '{}', NULL, creator, creator, NULL,
            NULL, false, NULL, NULL, false
          );
        END IF;
      ELSIF TG_OP = 'UPDATE' THEN
        IF history_kept(NEW.group_id) THEN
          delta := history_delta(to_jsonb(OLD), to_jsonb(NEW), keys);
          place := (delta ->> 'place_group_id')::bigint;

          -- The group an event is held in was deleted. Whoever deleted it did
          -- not change the event, and may not be of this group at all.
          IF place IS NOT NULL AND NOT EXISTS (SELECT 1 FROM groups WHERE id = place) THEN
            IF NOT COALESCE(
                 NULLIF(current_setting('potok.history', true), '')::jsonb ? 'off', false
               ) THEN
              INSERT INTO group_changes (
                group_id, subject_type, subject_id, op, fields, before, creator_id, cause, at
              ) VALUES (
                NEW.group_id, TG_ARGV[0], NEW.id, 'changed',
                ARRAY(SELECT jsonb_object_keys(delta)), delta,
                (to_jsonb(NEW) ->> 'creator_id')::bigint, '{"via": "gone"}',
                timezone('utc', clock_timestamp())
              );
            END IF;

            RETURN NULL;
          END IF;

          PERFORM history_write(
            NEW.group_id, TG_ARGV[0], NEW.id, 'changed',
            ARRAY(SELECT jsonb_object_keys(delta)), delta, NULL,
            (to_jsonb(NEW) ->> 'creator_id')::bigint, NULL, NULL, false, NULL, NULL,
            TG_ARGV[1]::boolean
          );
        END IF;
      ELSIF history_kept(OLD.group_id) THEN
        PERFORM history_write(
          OLD.group_id, TG_ARGV[0], OLD.id, 'deleted', '{}',
          history_pick(to_jsonb(OLD), keys), NULL,
          (to_jsonb(OLD) ->> 'creator_id')::bigint, NULL, NULL, false, NULL, NULL, false
        );
      END IF;

      RETURN NULL;
    END
    $$
    """

    # With its answers, but never how many chose each. A candidate is kept by
    # the profile's id, as the answer's text is their name.
    execute """
    CREATE OR REPLACE FUNCTION history_poll_deleted() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF history_kept(OLD.group_id) THEN
        PERFORM history_write(
          OLD.group_id, 'poll', OLD.id, 'deleted', '{}',
          history_pick(to_jsonb(OLD), TG_ARGV::text[]) || jsonb_build_object(
            'options', (
              SELECT COALESCE(
                jsonb_agg(
                  CASE WHEN o.profile_id IS NULL
                    THEN jsonb_build_object('text', o.text)
                    ELSE jsonb_build_object('profile_id', o.profile_id)
                  END ORDER BY o.position, o.id
                ),
                '[]'::jsonb
              )
              FROM poll_options o WHERE o.poll_id = OLD.id
            )
          ),
          NULL, OLD.creator_id, NULL, NULL, false, NULL, NULL, false
        );
      END IF;

      RETURN OLD;
    END
    $$
    """

    execute """
    CREATE OR REPLACE FUNCTION history_notice() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF history_kept(OLD.group_id) THEN
        PERFORM history_write(
          OLD.group_id, 'notice', OLD.id, 'deleted', '{}', NULL, NULL, OLD.creator_id, NULL,
          NULL, false, NULL, NULL, false
        );
      END IF;

      RETURN NULL;
    END
    $$
    """

    # A drawing that is off is the editors' alone.
    execute """
    CREATE OR REPLACE FUNCTION history_process() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      delta jsonb;
    BEGIN
      IF TG_OP = 'INSERT' THEN
        IF history_kept(NEW.group_id) THEN
          PERFORM history_write(
            NEW.group_id, 'process', NEW.id, 'created', '{}', NULL, NEW.owner_profile_id,
            NEW.owner_profile_id, NEW.alt_description_id, NEW.collection, false, NULL,
            CASE WHEN NOT NEW.active THEN ARRAY['admin'] END, false
          );
        END IF;
      ELSIF TG_OP = 'UPDATE' THEN
        IF history_kept(NEW.group_id) THEN
          delta := history_delta(to_jsonb(OLD), to_jsonb(NEW), TG_ARGV::text[]);

          PERFORM history_write(
            NEW.group_id, 'process', NEW.id, 'changed',
            ARRAY(SELECT jsonb_object_keys(delta)), delta, NULL, NEW.owner_profile_id,
            NEW.alt_description_id, NEW.collection, false,
            CASE WHEN NOT OLD.active THEN ARRAY['admin'] END,
            CASE WHEN NOT NEW.active THEN ARRAY['admin'] END, true
          );
        END IF;
      ELSIF history_kept(OLD.group_id) THEN
        PERFORM history_write(
          OLD.group_id, 'process', OLD.id, 'deleted', '{}',
          history_pick(to_jsonb(OLD), TG_ARGV::text[]), NULL, OLD.owner_profile_id,
          OLD.alt_description_id, OLD.collection, false,
          CASE WHEN NOT OLD.active THEN ARRAY['admin'] END, NULL, false
        );
      END IF;

      RETURN NULL;
    END
    $$
    """

    # The subject is the group it leads to: whoever sees that group may read it.
    execute """
    CREATE OR REPLACE FUNCTION history_shortcut() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      shortcut group_shortcuts%ROWTYPE;
    BEGIN
      IF TG_OP = 'INSERT' THEN shortcut := NEW; ELSE shortcut := OLD; END IF;

      IF history_kept(shortcut.parent_id) THEN
        PERFORM history_write(
          shortcut.parent_id, 'shortcut', shortcut.target_id,
          CASE TG_OP WHEN 'INSERT' THEN 'created' ELSE 'deleted' END, '{}', NULL,
          CASE TG_OP WHEN 'INSERT' THEN shortcut.creator_id END, shortcut.creator_id, NULL,
          NULL, false, NULL, NULL, false
        );
      END IF;

      RETURN NULL;
    END
    $$
    """

    # An app's record. The secret part of its config is never kept.
    execute """
    CREATE OR REPLACE FUNCTION history_record() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      old_row jsonb;
      new_row jsonb;
      delta jsonb;
      changed text[];
      config boolean := NEW.collection IS NOT DISTINCT FROM 'config';
    BEGIN
      IF NOT history_kept(NEW.group_id) THEN
        RETURN NULL;
      END IF;

      IF TG_OP = 'INSERT' THEN
        PERFORM history_write(
          NEW.group_id, 'record', NEW.id, 'created', '{}', NULL, NEW.creator_id, NEW.creator_id,
          NEW.alt_description_id, NEW.collection, NEW.anonymous, NULL, NULL, false
        );

        RETURN NULL;
      END IF;

      old_row := jsonb_build_object(
        'content', OLD.content, 'managed', OLD.managed,
        'data', CASE WHEN config THEN OLD.data - 'secret' ELSE OLD.data END
      );

      new_row := jsonb_build_object(
        'content', NEW.content, 'managed', NEW.managed,
        'data', CASE WHEN config THEN NEW.data - 'secret' ELSE NEW.data END
      );

      delta := history_delta(old_row, new_row, TG_ARGV::text[]);
      changed := ARRAY(SELECT jsonb_object_keys(delta));

      IF config AND OLD.data -> 'secret' IS DISTINCT FROM NEW.data -> 'secret' THEN
        changed := changed || 'secret'::text;
      END IF;

      PERFORM history_write(
        NEW.group_id, 'record', NEW.id, 'changed', changed, NULLIF(delta, '{}'::jsonb), NULL,
        NEW.creator_id, NEW.alt_description_id, NEW.collection, NEW.anonymous, NULL, NULL,
        config
      );

      RETURN NULL;
    END
    $$
    """

    # A message: only that its text changed.
    execute """
    CREATE OR REPLACE FUNCTION history_message() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF history_kept(NEW.group_id) THEN
        PERFORM history_write(
          NEW.group_id, 'message', NEW.id, 'changed', '{}', NULL, NULL, NEW.creator_id, NULL,
          NULL, false, NULL, NULL, false
        );
      END IF;

      RETURN NULL;
    END
    $$
    """

    # Messages and records deleted by one statement, whatever their number. Of
    # a message only when it was written stays, of a record all of it.
    execute """
    CREATE OR REPLACE FUNCTION history_values_deleted() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      context jsonb := NULLIF(current_setting('potok.history', true), '')::jsonb;
      who bigint := (context ->> 'actor')::bigint;
      why jsonb := NULLIF(context - 'actor' - 'op', '{}'::jsonb);
      now_at timestamp := timezone('utc', clock_timestamp());
      act bigint := (random() * 9e15)::bigint;
      written integer;
    BEGIN
      IF context ? 'off' THEN
        RETURN NULL;
      END IF;

      INSERT INTO group_changes (
        group_id, subject_type, subject_id, op, before, actor_id, creator_id,
        alt_description_id, collection, anonymous, cause, op_id, listed, at
      )
      SELECT
        o.group_id,
        CASE WHEN o.is_data THEN 'record' ELSE 'message' END,
        o.id,
        'deleted',
        CASE WHEN o.is_data
          THEN jsonb_build_object(
            'data',
            CASE WHEN o.collection = 'config' THEN o.data - 'secret' ELSE o.data END,
            'managed', o.managed, 'content', o.content, 'content_format', o.content_format,
            'lock_version', o.lock_version, 'inserted_at', o.inserted_at,
            'updated_at', o.updated_at
          )
          ELSE jsonb_build_object('inserted_at', o.inserted_at)
        END,
        CASE WHEN o.anonymous AND who = o.creator_id THEN NULL ELSE who END,
        o.creator_id,
        o.alt_description_id,
        o.collection,
        o.anonymous,
        -- The one that stands for the rest says how many they were.
        CASE WHEN t.n > 1
          THEN COALESCE(why, '{}'::jsonb) || jsonb_build_object('count', t.n)
          ELSE why
        END,
        COALESCE((context ->> 'op')::bigint, act),
        t.id IS NOT NULL,
        now_at
      FROM old_values o
      JOIN groups g ON g.id = o.group_id AND NOT g.is_direct
      LEFT JOIN (
        SELECT max(v.id) AS id, count(*) AS n
        FROM old_values v
        GROUP BY v.group_id, v.is_data, v.alt_description_id, v.collection
      ) t ON t.id = o.id
      WHERE o.collection IS DISTINCT FROM 'notify' AND o.collection IS DISTINCT FROM 'files';

      GET DIAGNOSTICS written = ROW_COUNT;

      IF written > 0 AND who IS NULL AND why IS NULL
         AND current_setting('potok.history_strict', true) = 'on' THEN
        RAISE EXCEPTION 'history: nobody signed the delete of % values', written;
      END IF;

      RETURN NULL;
    END
    $$
    """

    # Whose reaction, to which message, and no more. One gone with its message
    # or its profile says nothing.
    execute """
    CREATE OR REPLACE FUNCTION history_reaction() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      reaction value_reactions%ROWTYPE;
      of_group bigint;
    BEGIN
      IF TG_OP = 'INSERT' THEN reaction := NEW; ELSE reaction := OLD; END IF;

      SELECT v.group_id INTO of_group
      FROM "values" v
      JOIN groups g ON g.id = v.group_id AND NOT g.is_direct
      JOIN profiles p ON p.id = reaction.profile_id
      WHERE v.id = reaction.value_id;

      IF FOUND THEN
        PERFORM history_write(
          of_group, 'reaction', reaction.value_id,
          CASE TG_OP WHEN 'INSERT' THEN 'created' ELSE 'deleted' END, '{}', NULL,
          reaction.profile_id, reaction.profile_id, NULL, NULL, false, NULL, NULL, false
        );
      END IF;

      RETURN NULL;
    END
    $$
    """

    execute """
    CREATE OR REPLACE FUNCTION history_group_reaction() RETURNS trigger
    LANGUAGE plpgsql AS $$
    DECLARE
      reaction group_reactions%ROWTYPE;
    BEGIN
      IF TG_OP = 'INSERT' THEN reaction := NEW; ELSE reaction := OLD; END IF;

      IF history_kept(reaction.group_id)
         AND EXISTS (SELECT 1 FROM profiles WHERE id = reaction.profile_id) THEN
        PERFORM history_write(
          reaction.group_id, 'group_reaction', reaction.group_id,
          CASE TG_OP WHEN 'INSERT' THEN 'created' ELSE 'deleted' END, '{}', NULL,
          reaction.profile_id, reaction.profile_id, NULL, NULL, false, NULL, NULL, false
        );
      END IF;

      RETURN NULL;
    END
    $$
    """
  end
end
