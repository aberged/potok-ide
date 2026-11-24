defmodule PotokIde.History.Tracked do
  @moduledoc """
  What the history keeps of each table it follows, and what it leaves out and
  why. The triggers hold the same lists (migration `AddHistoryTriggers`); a
  test compares both with the columns the database has, so a new column is
  either kept or named here as one that is not.

  `kept` columns have their old values in `PotokIde.History.GroupChange`.
  `marked` ones only say that they changed. Every other column is listed as
  left out: what Potok keeps for itself, whose the row is and what it hangs
  on, and what would give away more than the group's members see.
  """

  @tables %{
    "groups" => %{
      type: "group",
      kept:
        ~w(name description description_format description_name home_page home_alt_description_id
           has_public_chat description_for_guests is_public is_root_public uses_api preset
           inherits_members inherit_role_keys elects_admins join_mode join_poll published_at
           latitude longitude pin_icon area route external_key),
      marked: ~w(group_picture_url),
      left_out:
        ~w(id is_root creator_id parent_id inserted_at updated_at parent_value_id is_direct
           last_value_at name_folded area_size area_west area_south area_east area_north
           area_span route_length route_west route_south route_east route_north route_span
           member_count)
    },
    "group_alt_descriptions" => %{
      type: "description",
      kept: ~w(name description description_format uses_api visible_role_keys for_guests),
      marked: [],
      left_out: ~w(id group_id position creator_id inserted_at updated_at)
    },
    "group_templates" => %{
      type: "template",
      kept: ~w(name purpose fields html),
      marked: [],
      left_out: ~w(id group_id creator_id rev position inserted_at updated_at)
    },
    "values" => %{
      type: "record",
      kept: ~w(data managed content),
      marked: [],
      left_out: ~w(id content_format creator_id group_id parent_id inserted_at updated_at is_data
           mentions mentioned_profile_ids alt_description_id link_preview
           link_preview_dismissed collection anonymous lock_version content_folded)
    },
    "app_processes" => %{
      type: "process",
      kept: ~w(name active graph layout trigger trigger_config collection entry_entity_id
           return_entity_id is_public hears_related),
      marked: [],
      left_out:
        ~w(id profile_id group_id alt_description_id owner_profile_id inserted_at updated_at
           drawn lock_version next_run_at)
    },
    "group_entities" => %{
      type: "entity",
      kept: ~w(name attributes),
      marked: [],
      left_out: ~w(id group_id lock_version inserted_at updated_at)
    },
    "group_fields" => %{
      type: "field",
      kept: ~w(name value type options),
      marked: [],
      left_out: ~w(id group_id app_process_id inserted_at updated_at)
    },
    # Never who voted, nor how many: counts and outcomes are read by the
    # poll's own rules, and in a secret poll a count next to a time would tell.
    "polls" => %{
      type: "poll",
      kept: ~w(question description kind max_choices allow_change secret is_public
           allow_member_options closes_at closed_at reminder_minutes voter_role_keys
           results_role_keys details_role_keys results_when details_when quorum_percent
           majority effect effect_role_key effect_replace unique_votes shared_votes),
      marked: [],
      left_out: ~w(id group_id creator_id value_id remind_at last_nudged_at eligible_count outcome
           voters_count inserted_at updated_at winner_option_id effect_profile_id
           effect_status process_instance_id from_request)
    },
    "group_events" => %{
      type: "event",
      kept: ~w(title description location all_day starts_at ends_at time_zone recurrence
           recurrence_interval recurrence_weekdays recurrence_monthly recurrence_until
           excluded_dates reminder_minutes cancelled_at is_public place_group_id latitude
           longitude area route),
      marked: [],
      left_out: ~w(id group_id creator_id value_id reminded_through next_reminder_at sequence
           inserted_at updated_at live_until)
    }
  }

  @doc "The tables the history follows with old values, each with its `type`, `kept`, `marked` and `left_out`."
  def tables, do: @tables

  @doc "The columns kept of the things of `type`, by the names `before` has them under."
  def kept(type) do
    Enum.find_value(@tables, [], fn {_table, spec} -> if spec.type == type, do: spec.kept end)
  end
end
