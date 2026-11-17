defmodule PotokIdeWeb.DomainCopy do
  @moduledoc """
  The words of the domain map at `/domain`, in the `domain_map` Gettext domain,
  and the data the page hands to `assets/js/domain_map.js`.

  Texts mark code as `` `name` `` and a link to an entity as
  `<Value>a value</Value>`; `parts/1` splits them. `mix potok.sr_cyrl` leaves
  both in Latin.

  Columns are described in words and never named: `map/1` leaves their names
  out of what reaches the browser. Code in the texts is for what visitors see
  as it is, like the roles `admin` and `everyone`. A new column needs a line in
  `own_field/2` or `common_field/1`; a test fails until it has one.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  alias PotokIde.DomainMap
  alias PotokIde.Social.GroupRole

  @markup ~r/`[^`]+`|<([A-Z]\w+)>.+?<\/\1>/

  @doc "The page's data for the current locale, ready for `Jason.encode!/1`."
  def map(%{entities: entities, edges: edges}) do
    %{
      counts: counts(edges, entities),
      domains: Enum.map(DomainMap.domains(), &%{id: &1, name: domain_name(&1)}),
      entities: Map.new(entities, &{&1.id, entity(&1, edges)}),
      edges: Enum.map(edges, &public_edge/1),
      labels: labels()
    }
  end

  def counts(edges, entities) do
    keys = Enum.filter(edges, &(&1.kind == :key))

    %{
      entities: length(entities),
      domains: length(DomainMap.domains()),
      keys: length(keys),
      soft: length(edges) - length(keys),
      hub_keys: Enum.count(keys, &(&1.to in ["Profile", "Group"]))
    }
  end

  defp entity(entity, edges) do
    deletion = DomainMap.deletion(entity.id, edges)

    %{
      id: entity.id,
      domain: entity.domain,
      table: entity.table,
      file: entity.file,
      name: entity_name(entity.id),
      description: entity_description(entity.id, edges),
      fields: Enum.map(entity.fields, &public_field(entity.id, &1)),
      virtual: Enum.map(entity.virtual, &public_field(entity.id, &1)),
      unique: Enum.map(entity.unique, &public_index(entity.id, &1)),
      checks: for(%{name: name} <- entity.checks, text = check_text(name), do: %{text: text}),
      deletion: %{
        blocked_by: Enum.map(deletion.blocked_by, &public_edge/1),
        cascades: deletion.cascades,
        clears: Enum.map(deletion.clears, &public_edge/1)
      }
    }
  end

  defp public_field(entity, field) do
    %{field | name: label(entity, to_string(field.name))}
  end

  defp public_edge(%{kind: :soft} = edge) do
    %{edge | columns: labels_of(edge), target: label(edge.to, edge.target)}
  end

  defp public_edge(%{kind: :key} = edge), do: %{edge | columns: labels_of(edge)}

  defp labels_of(edge), do: Enum.map(edge.columns, &label(edge.from, &1))

  defp public_index(entity, %{columns: columns, where: where}) do
    %{
      columns: Enum.map_join(columns, " + ", &index_column(entity, &1)),
      condition: condition(entity, where)
    }
  end

  defp index_column(entity, "lower(" <> column) do
    field = label(entity, String.trim_trailing(column, ")"))
    dgettext("domain_map", "%{field}, in any letter case", field: field)
  end

  defp index_column(entity, column), do: label(entity, column)

  defp condition(_entity, nil), do: nil

  defp condition(entity, where) do
    case String.split(where) do
      [column, "IS", "NULL"] ->
        dgettext("domain_map", "while this is empty: %{field}", field: label(entity, column))

      [column, "IS", "NOT", "NULL"] ->
        dgettext("domain_map", "when this is set: %{field}", field: label(entity, column))

      [column] ->
        dgettext("domain_map", "when this holds: %{field}", field: label(entity, column))

      ["NOT", column] ->
        dgettext("domain_map", "unless this holds: %{field}", field: label(entity, column))

      [column, "=", value] ->
        dgettext("domain_map", "where %{field} is %{value}",
          field: label(entity, column),
          value: value
        )

      _other ->
        nil
    end
  end

  defp label(entity, column) do
    field_name(entity, column) || dgettext("domain_map", "other field")
  end

  @doc "What a column or virtual field of an entity is, in words; nil when nobody wrote it down."
  def field_name(entity, column), do: own_field(entity, column) || common_field(column)

  defp own_field("Account", "email"), do: dgettext("domain_map", "email address")
  defp own_field("Account", "hashed_password"), do: dgettext("domain_map", "password hash")
  defp own_field("Account", "password"), do: dgettext("domain_map", "password as typed")
  defp own_field("Account", "confirmed_at"), do: dgettext("domain_map", "email confirmed at")
  defp own_field("Account", "authenticated_at"), do: dgettext("domain_map", "last log-in")

  defp own_field("Account", "invited_by_id"),
    do: dgettext("domain_map", "profile that invited it")

  defp own_field("Account", "current_profile_id"), do: dgettext("domain_map", "current profile")
  defp own_field("Account", "default_profile_id"), do: dgettext("domain_map", "default profile")

  defp own_field("AccountToken", "token"), do: dgettext("domain_map", "token")
  defp own_field("AccountToken", "context"), do: dgettext("domain_map", "purpose")
  defp own_field("AccountToken", "sent_to"), do: dgettext("domain_map", "sent to")
  defp own_field("AccountToken", "authenticated_at"), do: dgettext("domain_map", "logged in at")

  defp own_field("PushSubscription", "subscription_type") do
    dgettext("domain_map", "delivery type")
  end

  defp own_field("PushSubscription", "device_token"), do: dgettext("domain_map", "device token")

  defp own_field("PushSubscription", "device_platform") do
    dgettext("domain_map", "device platform")
  end

  defp own_field("PushSubscription", "endpoint"), do: dgettext("domain_map", "delivery address")
  defp own_field("PushSubscription", "p256dh"), do: dgettext("domain_map", "encryption key")
  defp own_field("PushSubscription", "auth"), do: dgettext("domain_map", "authentication secret")
  defp own_field("PushSubscription", "expires_at"), do: dgettext("domain_map", "expires at")
  defp own_field("PushSubscription", "user_agent"), do: dgettext("domain_map", "browser")

  defp own_field("PushSubscription", "last_success_at"),
    do: dgettext("domain_map", "last success")

  defp own_field("PushSubscription", "last_failure_at"),
    do: dgettext("domain_map", "last failure")

  defp own_field("PushSubscription", "failure_reason"),
    do: dgettext("domain_map", "failure reason")

  defp own_field("PushSubscription", "locale"), do: dgettext("domain_map", "device language")

  defp own_field("GmailRefreshToken", "provider"), do: dgettext("domain_map", "provider")

  defp own_field("GmailRefreshToken", "refresh_token"),
    do: dgettext("domain_map", "refresh token")

  defp own_field("Profile", "username"), do: dgettext("domain_map", "username")
  defp own_field("Profile", "profile_picture_url"), do: dgettext("domain_map", "profile picture")
  defp own_field("Profile", "sharing"), do: dgettext("domain_map", "sharing")
  defp own_field("Profile", "notice_push"), do: dgettext("domain_map", "push of notices")
  defp own_field("Profile", "kind"), do: dgettext("domain_map", "person or process")

  defp own_field("Group", "group_picture_url"), do: dgettext("domain_map", "group picture")

  defp own_field("Group", "description_name") do
    dgettext("domain_map", "name of the default description")
  end

  defp own_field("Group", "home_page"), do: dgettext("domain_map", "home page")
  defp own_field("Group", "has_public_chat"), do: dgettext("domain_map", "public chat")

  defp own_field("Group", "description_for_guests"),
    do: dgettext("domain_map", "description open to guests")

  defp own_field("Group", "is_direct"), do: dgettext("domain_map", "direct conversation")
  defp own_field("Group", "is_root"), do: dgettext("domain_map", "root")
  defp own_field("Group", "is_root_public"), do: dgettext("domain_map", "public from the root")
  defp own_field("Group", "inherits_members"), do: dgettext("domain_map", "inherits members")
  defp own_field("Group", "last_value_at"), do: dgettext("domain_map", "newest value at")
  defp own_field("Group", "published_at"), do: dgettext("domain_map", "published at")
  defp own_field("Group", "preset"), do: dgettext("domain_map", "ready setup")
  defp own_field("Group", "latitude"), do: dgettext("domain_map", "latitude on a map")
  defp own_field("Group", "longitude"), do: dgettext("domain_map", "longitude on a map")
  defp own_field("Group", "pin_icon"), do: dgettext("domain_map", "pin on a map")
  defp own_field("Group", "external_key"), do: dgettext("domain_map", "an app's own key")
  defp own_field("Group", "area"), do: dgettext("domain_map", "area on a map, as its border")
  defp own_field("Group", "route"), do: dgettext("domain_map", "route on a map, as its line")

  defp own_field("Group", "name_folded"),
    do: dgettext("domain_map", "name as a search reads it, in Latin and without diacritics")

  defp own_field("Group", "area_size"), do: dgettext("domain_map", "size of the area")
  defp own_field("Group", "area_west"), do: dgettext("domain_map", "western edge of the area")
  defp own_field("Group", "area_south"), do: dgettext("domain_map", "southern edge of the area")
  defp own_field("Group", "area_east"), do: dgettext("domain_map", "eastern edge of the area")
  defp own_field("Group", "area_north"), do: dgettext("domain_map", "northern edge of the area")
  defp own_field("Group", "area_span"), do: dgettext("domain_map", "width of the area on a map")

  defp own_field("Group", "route_length"),
    do: dgettext("domain_map", "length of the route, in metres")

  defp own_field("Group", "route_west"), do: dgettext("domain_map", "western edge of the route")
  defp own_field("Group", "route_south"), do: dgettext("domain_map", "southern edge of the route")
  defp own_field("Group", "route_east"), do: dgettext("domain_map", "eastern edge of the route")
  defp own_field("Group", "route_north"), do: dgettext("domain_map", "northern edge of the route")
  defp own_field("Group", "route_span"), do: dgettext("domain_map", "width of the route on a map")
  defp own_field("Group", "parent_id"), do: dgettext("domain_map", "parent group")
  defp own_field("Group", "parent_value_id"), do: dgettext("domain_map", "value of the thread")

  defp own_field("Group", "home_alt_description_id"),
    do: dgettext("domain_map", "home description")

  defp own_field("Group", "member_count"), do: dgettext("domain_map", "member count")
  defp own_field("Group", "sub_group_count"), do: dgettext("domain_map", "sub-group count")
  defp own_field("Group", "viewer_is_member"), do: dgettext("domain_map", "viewer is a member")
  defp own_field("Group", "last_value"), do: dgettext("domain_map", "newest value, for a member")
  defp own_field("Group", "shortcut_id"), do: dgettext("domain_map", "shortcut it is listed by")

  defp own_field("GroupAccountInvitation", "account_id") do
    dgettext("domain_map", "invited account")
  end

  defp own_field("GroupAltDescription", "visible_role_keys") do
    dgettext("domain_map", "roles that see it")
  end

  defp own_field("GroupAltDescription", "for_guests"),
    do: dgettext("domain_map", "guests read it too")

  defp own_field("GroupJoinRequestApproval", "approved_at"),
    do: dgettext("domain_map", "approved at")

  defp own_field("GroupJoinRequestApproval", "approver_id"),
    do: dgettext("domain_map", "who approved")

  defp own_field("GroupMemberRole", "profile_id"), do: dgettext("domain_map", "member")
  defp own_field("GroupMemberRole", "role_key"), do: dgettext("domain_map", "role")

  defp own_field("GroupRole", "key"), do: dgettext("domain_map", "role key")
  defp own_field("GroupRole", "allowed"), do: dgettext("domain_map", "allowed permissions")
  defp own_field("GroupRole", "denied"), do: dgettext("domain_map", "denied permissions")
  defp own_field("GroupRole", "manifest_id"), do: dgettext("domain_map", "manifest")

  defp own_field("GroupValueRead", "last_read_value_id") do
    dgettext("domain_map", "last read value")
  end

  defp own_field("ProfileInvitation", "profile_id"), do: dgettext("domain_map", "shared profile")

  defp own_field("Value", "content"), do: dgettext("domain_map", "content")
  defp own_field("Value", "content_format"), do: dgettext("domain_map", "content format")

  defp own_field("Value", "content_folded"),
    do: dgettext("domain_map", "text as a search reads it, in Latin and without diacritics")

  defp own_field("Value", "is_data"), do: dgettext("domain_map", "app data")
  defp own_field("Value", "data"), do: dgettext("domain_map", "stored data")
  defp own_field("Value", "mentions"), do: dgettext("domain_map", "mentions")

  defp own_field("Value", "mentioned_profile_ids"),
    do: dgettext("domain_map", "mentioned profiles")

  defp own_field("Value", "link_preview"), do: dgettext("domain_map", "link preview")

  defp own_field("Value", "link_preview_dismissed") do
    dgettext("domain_map", "link preview dismissed")
  end

  defp own_field("Value", "alt_description_id"), do: dgettext("domain_map", "app description")
  defp own_field("Value", "collection"), do: dgettext("domain_map", "collection of app data")
  defp own_field("Value", "anonymous"), do: dgettext("domain_map", "anonymous when written")
  defp own_field("Value", "lock_version"), do: dgettext("domain_map", "revision")
  defp own_field("Value", "managed"), do: dgettext("domain_map", "score and grades")
  defp own_field("Value", "parent_id"), do: dgettext("domain_map", "replies to")

  defp own_field("ValueAttachment", "storage_key"), do: dgettext("domain_map", "place in storage")
  defp own_field("ValueAttachment", "filename"), do: dgettext("domain_map", "file name")
  defp own_field("ValueAttachment", "content_type"), do: dgettext("domain_map", "file type")
  defp own_field("ValueAttachment", "byte_size"), do: dgettext("domain_map", "size")
  defp own_field("ValueAttachment", "profile_id"), do: dgettext("domain_map", "who added it")

  defp own_field("AppProcess", "profile_id"), do: dgettext("domain_map", "profile of the process")

  defp own_field("AppProcess", "alt_description_id"),
    do: dgettext("domain_map", "app description")

  defp own_field("AppProcess", "collection"), do: dgettext("domain_map", "collection of app data")
  defp own_field("AppProcess", "owner_profile_id"), do: dgettext("domain_map", "owner")
  defp own_field("AppProcess", "active"), do: dgettext("domain_map", "active")
  defp own_field("AppProcess", "drawn"), do: dgettext("domain_map", "drawn in Potok")
  defp own_field("AppProcess", "graph"), do: dgettext("domain_map", "graph of a drawn process")
  defp own_field("AppProcess", "layout"), do: dgettext("domain_map", "places on the drawing")
  defp own_field("AppProcess", "lock_version"), do: dgettext("domain_map", "revision")
  defp own_field("AppProcess", "trigger"), do: dgettext("domain_map", "what starts it")

  defp own_field("AppProcess", "trigger_config"),
    do: dgettext("domain_map", "settings of what starts it")

  defp own_field("AppProcess", "next_run_at"), do: dgettext("domain_map", "next scheduled start")
  defp own_field("AppProcess", "entry_entity_id"), do: dgettext("domain_map", "entity it takes")

  defp own_field("AppProcess", "return_entity_id"),
    do: dgettext("domain_map", "entity it hands back")

  defp own_field("ValueProcess", "app_process_id"), do: dgettext("domain_map", "process")
  defp own_field("ValueProcess", "value_id"), do: dgettext("domain_map", "value that started it")

  defp own_field("ValueProcess", "subject_group_id"),
    do: dgettext("domain_map", "sub-group that started it")

  defp own_field("ValueProcess", "data"), do: dgettext("domain_map", "fields for its texts")
  defp own_field("ValueProcess", "status"), do: dgettext("domain_map", "status")

  defp own_field("ValueProcess", "element"),
    do: dgettext("domain_map", "where it stands in the graph")

  defp own_field("ValueProcess", "graph"), do: dgettext("domain_map", "graph it started with")
  defp own_field("ValueProcess", "groups"), do: dgettext("domain_map", "sub-groups it made")
  defp own_field("ValueProcess", "started_by_id"), do: dgettext("domain_map", "who started it")

  defp own_field("ValueProcess", "triggered_by_id"),
    do: dgettext("domain_map", "who set off its step")

  defp own_field("ValueProcess", "wake_at"), do: dgettext("domain_map", "when it wakes")
  defp own_field("ValueProcess", "steps"), do: dgettext("domain_map", "steps taken")
  defp own_field("ValueProcess", "error"), do: dgettext("domain_map", "why it stopped")
  defp own_field("ValueProcess", "log"), do: dgettext("domain_map", "decisions of people")
  defp own_field("ValueProcess", "awaiting_id"), do: dgettext("domain_map", "run it waits for")
  defp own_field("GroupField", "value"), do: dgettext("domain_map", "text it keeps")

  defp own_field("GroupField", "app_process_id"),
    do: dgettext("domain_map", "process that wrote it last")

  defp own_field("GroupEntity", "attributes"),
    do: dgettext("domain_map", "attributes and their types")

  defp own_field("GroupEntity", "lock_version"), do: dgettext("domain_map", "revision")

  defp own_field("ValueProcess", "depth"),
    do: dgettext("domain_map", "how many processes deep")

  defp own_field("ValueProcess", "results"),
    do: dgettext("domain_map", "what its waits brought back")

  defp own_field("ValueProcess", "vars"), do: dgettext("domain_map", "what its variables hold")

  defp own_field("ValueProcess", "asks_role"),
    do: dgettext("domain_map", "role its wait asks")

  defp own_field("ValueProcess", "asks_profile_id"),
    do: dgettext("domain_map", "person its wait asks")

  defp own_field("GroupMembership", "muted_until"),
    do: dgettext("domain_map", "until when the member silenced it")

  defp own_field("ValueReaction", "emoji"), do: dgettext("domain_map", "emoji")
  defp own_field("GroupReaction", "emoji"), do: dgettext("domain_map", "emoji")
  defp own_field("GroupBlock", "blocked_by_id"), do: dgettext("domain_map", "who blocked")
  defp own_field("GroupShortcut", "parent_id"), do: dgettext("domain_map", "group it stands in")
  defp own_field("GroupShortcut", "target_id"), do: dgettext("domain_map", "group it opens")

  defp own_field("Event", "title"), do: dgettext("domain_map", "title")
  defp own_field("Event", "location"), do: dgettext("domain_map", "location")
  defp own_field("Event", "place_group_id"), do: dgettext("domain_map", "group it takes place at")
  defp own_field("Event", "latitude"), do: dgettext("domain_map", "latitude of its point")
  defp own_field("Event", "longitude"), do: dgettext("domain_map", "longitude of its point")
  defp own_field("Event", "area"), do: dgettext("domain_map", "its area on a map, as its border")
  defp own_field("Event", "route"), do: dgettext("domain_map", "its route on a map, as its line")
  defp own_field("Event", "all_day"), do: dgettext("domain_map", "all day")
  defp own_field("Event", "starts_at"), do: dgettext("domain_map", "start")
  defp own_field("Event", "ends_at"), do: dgettext("domain_map", "end")
  defp own_field("Event", "time_zone"), do: dgettext("domain_map", "time zone")
  defp own_field("Event", "recurrence"), do: dgettext("domain_map", "repeats")
  defp own_field("Event", "recurrence_interval"), do: dgettext("domain_map", "repeat interval")
  defp own_field("Event", "recurrence_weekdays"), do: dgettext("domain_map", "repeat weekdays")
  defp own_field("Event", "recurrence_monthly"), do: dgettext("domain_map", "monthly repeat mode")
  defp own_field("Event", "recurrence_until"), do: dgettext("domain_map", "repeats until")
  defp own_field("Event", "excluded_dates"), do: dgettext("domain_map", "cancelled occurrences")
  defp own_field("Event", "reminder_minutes"), do: dgettext("domain_map", "organizer's reminders")

  defp own_field("Event", "reminded_through") do
    dgettext("domain_map", "reminders handled until")
  end

  defp own_field("Event", "next_reminder_at"), do: dgettext("domain_map", "next reminder")
  defp own_field("Event", "cancelled_at"), do: dgettext("domain_map", "cancelled at")
  defp own_field("Event", "sequence"), do: dgettext("domain_map", "schedule version")
  defp own_field("Event", "value_id"), do: dgettext("domain_map", "announcing value")
  defp own_field("Event", "start_date"), do: dgettext("domain_map", "start date")
  defp own_field("Event", "start_time"), do: dgettext("domain_map", "start time")
  defp own_field("Event", "end_date"), do: dgettext("domain_map", "end date")
  defp own_field("Event", "end_time"), do: dgettext("domain_map", "end time")

  defp own_field("Response", "occurs_on"), do: dgettext("domain_map", "occurrence date")
  defp own_field("Response", "status"), do: dgettext("domain_map", "answer")

  defp own_field("Poll", "question"), do: dgettext("domain_map", "question")
  defp own_field("Poll", "kind"), do: dgettext("domain_map", "one answer or several")
  defp own_field("Poll", "max_choices"), do: dgettext("domain_map", "most answers on a ballot")
  defp own_field("Poll", "allow_change"), do: dgettext("domain_map", "vote can change")
  defp own_field("Poll", "secret"), do: dgettext("domain_map", "secret")

  defp own_field("Poll", "allow_member_options") do
    dgettext("domain_map", "members can add answers")
  end

  defp own_field("Poll", "closes_at"), do: dgettext("domain_map", "deadline")
  defp own_field("Poll", "closed_at"), do: dgettext("domain_map", "ended at")

  defp own_field("Poll", "reminder_minutes"),
    do: dgettext("domain_map", "reminder before the end")

  defp own_field("Poll", "remind_at"), do: dgettext("domain_map", "reminder is due at")
  defp own_field("Poll", "last_nudged_at"), do: dgettext("domain_map", "last reminder by hand")
  defp own_field("Poll", "voter_role_keys"), do: dgettext("domain_map", "roles that vote")

  defp own_field("Poll", "results_role_keys"),
    do: dgettext("domain_map", "roles that see results")

  defp own_field("Poll", "details_role_keys"),
    do: dgettext("domain_map", "roles that see details")

  defp own_field("Poll", "results_when"), do: dgettext("domain_map", "results show from")
  defp own_field("Poll", "details_when"), do: dgettext("domain_map", "details show from")
  defp own_field("Poll", "quorum_percent"), do: dgettext("domain_map", "quorum")
  defp own_field("Poll", "majority"), do: dgettext("domain_map", "majority asked for")
  defp own_field("Poll", "eligible_count"), do: dgettext("domain_map", "how many could vote")
  defp own_field("Poll", "outcome"), do: dgettext("domain_map", "decision")
  defp own_field("Poll", "voters_count"), do: dgettext("domain_map", "how many voted")
  defp own_field("Poll", "winner_option_id"), do: dgettext("domain_map", "winning answer")
  defp own_field("Poll", "value_id"), do: dgettext("domain_map", "carrying value")
  defp own_field("Poll", "closes_local"), do: dgettext("domain_map", "deadline in local time")

  defp own_field("Value", "poll_view"),
    do: dgettext("domain_map", "what the viewer sees of its poll")

  defp own_field("Value", "process_trigger"),
    do: dgettext("domain_map", "who set the process going")

  defp own_field("PollOption", "text"), do: dgettext("domain_map", "text")
  defp own_field("PollOption", "votes_count"), do: dgettext("domain_map", "votes")

  defp own_field("PollBallot", "option_ids"), do: dgettext("domain_map", "chosen answers")
  defp own_field("PollBallot", "changed_at"), do: dgettext("domain_map", "vote changed at")

  defp own_field("MemberSetting", "reminder_minutes"), do: dgettext("domain_map", "own reminders")

  defp own_field("GroupFollow", "profile_id"), do: dgettext("domain_map", "follower")
  defp own_field("GroupFollow", "push"), do: dgettext("domain_map", "push to devices")

  defp own_field("GroupNotice", "creator_id"), do: dgettext("domain_map", "who sent it")
  defp own_field("GroupNotice", "body"), do: dgettext("domain_map", "text")
  defp own_field("GroupNotice", "recipients_count"), do: dgettext("domain_map", "how many got it")
  defp own_field("GroupNotice", "link_preview"), do: dgettext("domain_map", "link preview")

  defp own_field("GroupNoticeReceipt", "profile_id"), do: dgettext("domain_map", "recipient")
  defp own_field("GroupNoticeReceipt", "notice_id"), do: dgettext("domain_map", "notice")
  defp own_field("GroupNoticeReceipt", "read_at"), do: dgettext("domain_map", "read at")

  defp own_field("Tag", "owner_id"), do: dgettext("domain_map", "owner")

  defp own_field("Tagging", "tag_id"), do: dgettext("domain_map", "tag")
  defp own_field("Tagging", "added_by_id"), do: dgettext("domain_map", "who added it")
  defp own_field("Tagging", "attachment_id"), do: dgettext("domain_map", "file")

  defp own_field("CostHour", "hour"), do: dgettext("domain_map", "hour")
  defp own_field("CostHour", "category"), do: dgettext("domain_map", "what it pays for")
  defp own_field("CostHour", "item"), do: dgettext("domain_map", "which one")
  defp own_field("CostHour", "quantity"), do: dgettext("domain_map", "how much of it")
  defp own_field("CostHour", "amount_usd"), do: dgettext("domain_map", "cost in dollars")
  defp own_field("CostHour", "detail"), do: dgettext("domain_map", "what it was estimated from")

  defp own_field("Invoice", "month"), do: dgettext("domain_map", "month")
  defp own_field("Invoice", "amount_usd"), do: dgettext("domain_map", "billed in dollars")
  defp own_field("Invoice", "note"), do: dgettext("domain_map", "note")

  defp own_field(_entity, _column), do: nil

  defp common_field("id"), do: dgettext("domain_map", "identifier")
  defp common_field("inserted_at"), do: dgettext("domain_map", "created at")
  defp common_field("updated_at"), do: dgettext("domain_map", "last changed at")
  defp common_field("account_id"), do: dgettext("domain_map", "account")
  defp common_field("profile_id"), do: dgettext("domain_map", "profile")
  defp common_field("group_id"), do: dgettext("domain_map", "group")
  defp common_field("event_id"), do: dgettext("domain_map", "event")
  defp common_field("poll_id"), do: dgettext("domain_map", "poll")
  defp common_field("value_id"), do: dgettext("domain_map", "value")
  defp common_field("creator_id"), do: dgettext("domain_map", "creator")
  defp common_field("inviter_id"), do: dgettext("domain_map", "who invited")
  defp common_field("invitee_id"), do: dgettext("domain_map", "who is invited")
  defp common_field("requester_id"), do: dgettext("domain_map", "who asks to join")
  defp common_field("accepted_at"), do: dgettext("domain_map", "accepted at")
  defp common_field("name"), do: dgettext("domain_map", "name")
  defp common_field("description"), do: dgettext("domain_map", "description")
  defp common_field("description_format"), do: dgettext("domain_map", "description format")
  defp common_field("uses_api"), do: dgettext("domain_map", "is an app")
  defp common_field("position"), do: dgettext("domain_map", "order")
  defp common_field("is_public"), do: dgettext("domain_map", "public")
  defp common_field("inherited"), do: dgettext("domain_map", "inherited")
  defp common_field("tags"), do: dgettext("domain_map", "tags the viewer sees")
  defp common_field(_column), do: nil

  @doc """
  Splits a text into `{:text, text}`, `{:code, name}` and
  `{:entity, id, text}`.
  """
  def parts(text) do
    @markup
    |> Regex.split(text, include_captures: true, trim: true)
    |> Enum.map(&part/1)
  end

  defp part("`" <> rest), do: {:code, String.trim_trailing(rest, "`")}

  defp part("<" <> rest = text) do
    case Regex.run(~r/^([A-Z]\w+)>(.+)<\/\1>$/, rest) do
      [_, id, label] -> {:entity, id, label}
      nil -> {:text, text}
    end
  end

  defp part(text), do: {:text, text}

  def title, do: dgettext("domain_map", "The Potok domain model")

  def lead do
    dgettext(
      "domain_map",
      "All the entities and the links between them, as they stand in the code and in the database schema."
    )
  end

  def domain_name("account"), do: dgettext("domain_map", "Account and identity")
  def domain_name("profiles"), do: dgettext("domain_map", "Profiles")
  def domain_name("group"), do: dgettext("domain_map", "Group and roles")
  def domain_name("content"), do: dgettext("domain_map", "Content")
  def domain_name("calendar"), do: dgettext("domain_map", "Calendar")
  def domain_name("polls"), do: dgettext("domain_map", "Polls")
  def domain_name("notices"), do: dgettext("domain_map", "Following and notices")
  def domain_name("tags"), do: dgettext("domain_map", "Tags")
  def domain_name("joining"), do: dgettext("domain_map", "Joining a group")
  def domain_name("hosting"), do: dgettext("domain_map", "Hosting costs")

  def entity_name("Account"), do: dgettext("domain_map", "Account")
  def entity_name("AccountToken"), do: dgettext("domain_map", "Account token")
  def entity_name("PushSubscription"), do: dgettext("domain_map", "Push subscription")
  def entity_name("GmailRefreshToken"), do: dgettext("domain_map", "Gmail token")
  def entity_name("Profile"), do: dgettext("domain_map", "Profile")
  def entity_name("AccountProfile"), do: dgettext("domain_map", "Account–profile link")
  def entity_name("Group"), do: dgettext("domain_map", "Group")
  def entity_name("GroupManifest"), do: dgettext("domain_map", "Manifest")
  def entity_name("GroupRole"), do: dgettext("domain_map", "Role")
  def entity_name("GroupMembership"), do: dgettext("domain_map", "Membership")
  def entity_name("GroupMemberRole"), do: dgettext("domain_map", "Member role")
  def entity_name("GroupAltDescription"), do: dgettext("domain_map", "Alt. description")
  def entity_name("Value"), do: dgettext("domain_map", "Value")
  def entity_name("ValueAttachment"), do: dgettext("domain_map", "File")
  def entity_name("ValueReaction"), do: dgettext("domain_map", "Reaction")
  def entity_name("GroupReaction"), do: dgettext("domain_map", "Group reaction")
  def entity_name("GroupBlock"), do: dgettext("domain_map", "Block")
  def entity_name("GroupShortcut"), do: dgettext("domain_map", "Shortcut")
  def entity_name("GroupValueRead"), do: dgettext("domain_map", "Read marker")
  def entity_name("AppProcess"), do: dgettext("domain_map", "App process")
  def entity_name("ValueProcess"), do: dgettext("domain_map", "Process instance")
  def entity_name("GroupField"), do: dgettext("domain_map", "Group field")
  def entity_name("GroupEntity"), do: dgettext("domain_map", "Entity definition")
  def entity_name("Event"), do: dgettext("domain_map", "Event")
  def entity_name("Response"), do: dgettext("domain_map", "Event response")
  def entity_name("MemberSetting"), do: dgettext("domain_map", "Personal reminders")
  def entity_name("Poll"), do: dgettext("domain_map", "Poll")
  def entity_name("PollOption"), do: dgettext("domain_map", "Answer")
  def entity_name("PollBallot"), do: dgettext("domain_map", "Ballot")
  def entity_name("GroupFollow"), do: dgettext("domain_map", "Following")
  def entity_name("GroupNotice"), do: dgettext("domain_map", "Notice")
  def entity_name("GroupNoticeReceipt"), do: dgettext("domain_map", "Received notice")
  def entity_name("Tag"), do: dgettext("domain_map", "Tag")
  def entity_name("Tagging"), do: dgettext("domain_map", "Tagging")
  def entity_name("GroupInvitation"), do: dgettext("domain_map", "Group invitation")
  def entity_name("GroupAccountInvitation"), do: dgettext("domain_map", "Account invitation")
  def entity_name("ProfileInvitation"), do: dgettext("domain_map", "Profile invitation")
  def entity_name("GroupJoinRequest"), do: dgettext("domain_map", "Join request")
  def entity_name("GroupJoinRequestApproval"), do: dgettext("domain_map", "Approved request")
  def entity_name("CostHour"), do: dgettext("domain_map", "Hour of costs")
  def entity_name("Invoice"), do: dgettext("domain_map", "Invoice")

  defp entity_description("Account", _edges) do
    dgettext(
      "domain_map",
      "A person's identity: the email and password they log in with. It takes no part in groups, where a profile acts. An account remembers which profile it is using now, which profile gets the invitations sent to the account, and which profile invited it."
    )
  end

  defp entity_description("AccountToken", _edges) do
    dgettext(
      "domain_map",
      "Tokens of sessions and of links in emails, such as log-in, invitation and email change. Each token says what it is for."
    )
  end

  defp entity_description("PushSubscription", _edges) do
    dgettext(
      "domain_map",
      "One device or browser that receives notifications, through web push or FCM. It remembers the last successful send and the last error."
    )
  end

  defp entity_description("GmailRefreshToken", _edges) do
    dgettext(
      "domain_map",
      "A technical table with no links to the rest of the domain: the `OAuth` refresh token the app uses to send email through `Gmail`."
    )
  end

  defp entity_description("Profile", edges) do
    keys = Enum.filter(edges, &(&1.kind == :key))

    dgettext(
      "domain_map",
      "An account's face in groups: username, picture and description. The code does not distinguish purposes such as business, private or club. Everything that happens in a group is signed by a profile, so %{count} of the %{total} foreign keys point at this table. A profile either belongs to one account or several accounts share it. The profile of an app's process belongs to none.",
      count: Enum.count(keys, &(&1.to == "Profile")),
      total: length(keys)
    )
  end

  defp entity_description("AccountProfile", _edges) do
    dgettext(
      "domain_map",
      "A join table: which account may use which profile. A unique profile allows only one account. The code checks that, the database does not know about it."
    )
  end

  defp entity_description("Group", _edges) do
    dgettext(
      "domain_map",
      "The basic unit of Potok. One model covers the root, ordinary groups and sub-groups, direct conversations and threads. Exactly one group is the root, and every other has a parent and a creator."
    )
  end

  defp entity_description("GroupManifest", _edges) do
    dgettext(
      "domain_map",
      "The set of roles of a group. A group without its own manifest uses that of its nearest ancestor that has one. The root always has one."
    )
  end

  defp entity_description("GroupRole", _edges) do
    dgettext(
      "domain_map",
      "A role of a manifest. For each of the %{count} permissions it says allowed, denied or nothing, and a denial wins. The built-in ones are `admin`, which has everything, and `everyone`, which every member has.",
      count: length(GroupRole.permissions())
    )
  end

  defp entity_description("GroupMembership", _edges) do
    dgettext(
      "domain_map",
      "A profile is a member of a group. An inherited membership exists only through the parent group and leaves with the membership there."
    )
  end

  defp entity_description("GroupMemberRole", _edges) do
    dgettext(
      "domain_map",
      "A role given to a member in one group. In the database it points at the membership, so it cannot exist without one, although the schema in the code says it points at a profile. The role is kept as text, by its key, as it can come from an ancestor's manifest. `everyone` is never written here."
    )
  end

  defp entity_description("GroupAltDescription", _edges) do
    dgettext(
      "domain_map",
      "An additional description of a group next to the default one. Like it, it can be text or an app with its own data. It can be limited to certain roles, and without a limit everyone who sees the group's description sees it."
    )
  end

  defp entity_description("Value", _edges) do
    dgettext(
      "domain_map",
      "The content of a group. In a conversation it is a message, and as data of an app it does not appear in the conversation. A value can reply to another value, and a thread opened from a value is a group that points back at it."
    )
  end

  defp entity_description("ValueAttachment", _edges) do
    dgettext(
      "domain_map",
      "A file attached to a value. The bytes are in storage, and the row keeps what the browser reported about the file."
    )
  end

  defp entity_description("ValueReaction", _edges) do
    dgettext(
      "domain_map",
      "An emoji of one profile on a value. A profile cannot use the same emoji twice on the same value."
    )
  end

  defp entity_description("GroupReaction", _edges) do
    dgettext(
      "domain_map",
      "An emoji of one profile on a group, as on a story in a news feed. A profile cannot use the same emoji twice on the same group."
    )
  end

  defp entity_description("GroupBlock", _edges) do
    dgettext(
      "domain_map",
      "A profile a group has blocked. Until the block is lifted it does not write or react in the group's open chat, and cannot ask to join or be invited. Membership comes first: a member answers to their roles."
    )
  end

  defp entity_description("GroupShortcut", _edges) do
    dgettext(
      "domain_map",
      "A group shown among the sub-groups of another group too, as a shortcut on a computer: a tap opens it where it stands. It has no members, values or counts of its own. Deleting either group takes it along."
    )
  end

  defp entity_description("GroupValueRead", _edges) do
    dgettext(
      "domain_map",
      "How far a profile has read a group. Everything newer than the last read value is unread. That value is kept as a plain number, with no foreign key."
    )
  end

  defp entity_description("ValueProcess", _edges) do
    dgettext(
      "domain_map",
      "One run of a process: the graph it started with, the element it stands on and when it wakes next. What set it going is a value of a collection or a chat message, a new sub-group, or nothing for a run started by hand or by a schedule, which keeps the fields its texts read. A run another process started, by a call or a signal, is one level deeper than that one, shares its subject and keeps the fields it was given; a caller that waits for it points at it, and what each wait brought back stays with the run that waited. A value or a sub-group has at most one instance of each process that its trigger started. Deleting it or the process takes the instance along, and what it wrote stays."
    )
  end

  defp entity_description("GroupField", _edges) do
    dgettext(
      "domain_map",
      "A field the processes drawn in a group keep for each other: a step sets it, or adds a number to it, and every drawn process of the group reads it. A group has at most 50, each name once. Deleting the group takes them along, and the process that wrote one last may go first."
    )
  end

  defp entity_description("GroupEntity", _edges) do
    dgettext(
      "domain_map",
      "What the data of the processes drawn in a group looks like, as its editors define it: a name and up to 30 attributes, each with the type of what it holds. An attribute holds a text, a number, a yes or no, a date, a date and time, one of the choices it lists, or another entity of the group, and may be a list of them. Entities nest at most four deep and never in a circle. A group has at most 50, each name once in any letter case, and one that another holds, or that a process drawn in the group keeps a variable of, cannot be deleted. Deleting the group takes them along."
    )
  end

  defp entity_description("AppProcess", _edges) do
    dgettext(
      "domain_map",
      "The process of one collection of an app, with the profile that signs what it does and its owner, the editor who saved its rule. Removing the rule makes it inactive, and its profile stays as the author of what it wrote. A process an editor drew in Potok keeps its graph and the places of its steps here, where no save of the app reaches it; a collection has at most one process of the app's own, and may have drawn ones beside it."
    )
  end

  defp entity_description("Event", _edges) do
    dgettext(
      "domain_map",
      "An event in a group's calendar, once or repeating. The start and the end are those of the first occurrence, and repeats keep the local time of the event's time zone. A value can announce an event. Its place is words, and on a map the place of a group or a point, an area or a route of its own."
    )
  end

  defp entity_description("Response", _edges) do
    dgettext(
      "domain_map",
      "A member's answer for one occurrence, named by its local start date. Whoever declined gets no reminders for that occurrence."
    )
  end

  defp entity_description("Poll", _edges) do
    dgettext(
      "domain_map",
      "A question put to a vote in a group, with the rules of who votes, who sees the results and who sees the details. A value can carry a poll, and the two go together. When it ends it writes down how many could vote and what was decided, so that a later change of members leaves that as it was."
    )
  end

  defp entity_description("PollOption", _edges) do
    dgettext(
      "domain_map",
      "An answer of a poll, with its count of votes. In a secret poll that count is the only record of the votes. It has no timestamps, as the time of the last change would show what the last voter chose."
    )
  end

  defp entity_description("PollBallot", _edges) do
    dgettext(
      "domain_map",
      "That a profile voted, and for what. In a secret poll it holds no answers, so nothing ties a voter to one. Both profile and account stay empty when their rows are deleted, so a vote that was given stays counted."
    )
  end

  defp entity_description("GroupFollow", _edges) do
    dgettext(
      "domain_map",
      "A profile follows a group, to receive its notices. Anyone who sees the group may follow it, a public one without being a member. It says whether the group's notices push to the follower's devices."
    )
  end

  defp entity_description("GroupNotice", _edges) do
    dgettext(
      "domain_map",
      "A notice a group sent to those who follow it: one text, never edited. It remembers who sent it, how many followers it reached and the preview of its first link. Deleting it deletes it for everyone who received it."
    )
  end

  defp entity_description("GroupNoticeReceipt", _edges) do
    dgettext(
      "domain_map",
      "A notice that reached one profile, and whether it was read. It is written when the notice is sent, for every follower who sees the group then, so it stays after unfollowing. Unread ones make the counter of notices."
    )
  end

  defp entity_description("MemberSetting", _edges) do
    dgettext(
      "domain_map",
      "A member's own reminders for every occurrence, in place of the organizer's. An empty list turns them off, and without a row the member gets the event's reminders."
    )
  end

  defp entity_description("Tag", _edges) do
    dgettext(
      "domain_map",
      "A tag without an owner is public and part of one vocabulary for the whole app. A tag with an owner is private and only that profile sees it."
    )
  end

  defp entity_description("Tagging", _edges) do
    dgettext(
      "domain_map",
      "One tag on one item. Exactly one of the five target columns is set, and the database checks that."
    )
  end

  defp entity_description("GroupInvitation", _edges) do
    dgettext(
      "domain_map",
      "A profile invites another profile to a group. Accepting it creates the membership."
    )
  end

  defp entity_description("GroupAccountInvitation", _edges) do
    dgettext(
      "domain_map",
      "An invitation to a group for an account that has no profile yet. When the account gets its first profile, it becomes an ordinary group invitation and this row is deleted."
    )
  end

  defp entity_description("ProfileInvitation", _edges) do
    dgettext(
      "domain_map",
      "An invitation for one more account to connect to a shared profile. Accepting it adds a row to the account–profile link."
    )
  end

  defp entity_description("GroupJoinRequest", _edges) do
    dgettext(
      "domain_map",
      "A profile asks to join a group. An accepted request is deleted, and an approval stays in its place."
    )
  end

  defp entity_description("GroupJoinRequestApproval", _edges) do
    dgettext(
      "domain_map",
      "A lasting record of who admitted whom to a group and when. It is created in the same transaction that deletes the request and creates the membership."
    )
  end

  defp entity_description("CostHour", _edges) do
    dgettext(
      "domain_map",
      "A technical table with no links to the rest of the domain: what one hour of one thing Potok runs on cost at `Fly.io`, a machine, the database, the stored files, the IP addresses or the data sent out, estimated by Potok itself from what `Fly.io` reports and its price list."
    )
  end

  defp entity_description("Invoice", _edges) do
    dgettext(
      "domain_map",
      "What `Fly.io` actually billed for one month, copied from the invoice, so the estimate of that month stands next to the real sum."
    )
  end

  @doc "A check of the database in words; nil for one nobody wrote down."
  def check_text("groups_root_private_check"),
    do: dgettext("domain_map", "The root is not public.")

  def check_text("groups_root_parent_check") do
    dgettext("domain_map", "The root has no parent, every other group does.")
  end

  def check_text("groups_root_creator_check") do
    dgettext("domain_map", "The root has no creator, every other group does.")
  end

  def check_text("groups_root_public_requires_public_check") do
    dgettext("domain_map", "A group public from the root must be public.")
  end

  def check_text("groups_inherits_members_check") do
    dgettext("domain_map", "The root and direct groups do not inherit members.")
  end

  def check_text("groups_thread_inherits_members_check") do
    dgettext("domain_map", "A thread always inherits members.")
  end

  def check_text("group_shortcuts_not_self_check") do
    dgettext("domain_map", "A shortcut never opens the group it stands in.")
  end

  def check_text("groups_location_check") do
    dgettext(
      "domain_map",
      "A place on a map has both coordinates, each within its range, or neither."
    )
  end

  def check_text("groups_external_key_check") do
    dgettext("domain_map", "An app's key for a group has from 1 to 64 characters.")
  end

  def check_text("groups_area_check") do
    dgettext("domain_map", "An area on a map always has its pin as well.")
  end

  def check_text("groups_route_check") do
    dgettext(
      "domain_map",
      "A route on a map always has its pin as well, and a place is never an area and a route at once."
    )
  end

  def check_text("group_alt_descriptions_for_guests_check") do
    dgettext("domain_map", "A description only some roles see never goes to guests.")
  end

  def check_text("group_member_roles_role_key_check") do
    dgettext("domain_map", "The role `everyone` is not written here.")
  end

  def check_text("taggings_one_target"), do: dgettext("domain_map", "Exactly one target.")

  def check_text("group_events_ends_after_start") do
    dgettext("domain_map", "The end is not before the start.")
  end

  def check_text("group_events_recurrence_interval_check") do
    dgettext("domain_map", "The repeat interval is from 1 to 99.")
  end

  def check_text("group_events_place_check") do
    dgettext(
      "domain_map",
      "An event's point has both coordinates, each within its range, or neither, and an event at a group's place has no point of its own."
    )
  end

  def check_text("group_events_shape_check") do
    dgettext(
      "domain_map",
      "An event's area or route always has its pin as well, and an event never has an area and a route at once."
    )
  end

  def check_text("polls_max_choices_check"), do: dgettext("domain_map", "At least one answer.")

  def check_text("polls_quorum_percent_check") do
    dgettext("domain_map", "A quorum is between 1 and 100 percent.")
  end

  def check_text("polls_voters_count_check") do
    dgettext("domain_map", "The number of voters is never negative.")
  end

  def check_text("polls_secret_check") do
    dgettext(
      "domain_map",
      "A secret poll takes no change of a vote and no answers from members, and shows results only at the end."
    )
  end

  def check_text("poll_options_votes_count_check") do
    dgettext("domain_map", "The number of votes is never negative.")
  end

  def check_text("group_notices_body_check") do
    dgettext("domain_map", "The text has 1 to 2,000 characters, and not only spaces.")
  end

  def check_text("value_attachments_byte_size_check") do
    dgettext("domain_map", "The size is not negative.")
  end

  def check_text("app_processes_collection_check") do
    dgettext("domain_map", "The collection is named as an app names its own.")
  end

  def check_text("app_processes_drawn_graph_check") do
    dgettext("domain_map", "Only a process drawn in Potok keeps a graph here.")
  end

  def check_text("app_processes_trigger_collection_check") do
    dgettext("domain_map", "Only a process that starts on a new value hangs on a collection.")
  end

  def check_text("app_processes_public_check") do
    dgettext("domain_map", "Only a process drawn in Potok that another calls can be public.")
  end

  def check_text("app_processes_trigger_check") do
    dgettext(
      "domain_map",
      "A process starts on a value, a message, a sub-group, a schedule, by hand, when another process calls it or on a signal."
    )
  end

  def check_text("group_fields_name_check") do
    dgettext("domain_map", "The name has 1 to 40 characters.")
  end

  def check_text("group_fields_value_check") do
    dgettext("domain_map", "The text has at most 1,000 characters.")
  end

  def check_text("group_entities_name_check") do
    dgettext("domain_map", "The name has 1 to 40 characters.")
  end

  def check_text("group_entities_attributes_check") do
    dgettext("domain_map", "The attributes are kept as a list.")
  end

  def check_text("value_processes_depth_check") do
    dgettext("domain_map", "A run is never less than zero processes deep.")
  end

  def check_text("values_collection_check") do
    dgettext(
      "domain_map",
      "Only app data has a collection, named with small letters, digits, - and _."
    )
  end

  def check_text("hosting_cost_hours_amount_check") do
    dgettext("domain_map", "Neither the cost nor the amount is negative.")
  end

  def check_text("hosting_invoices_month_check") do
    dgettext("domain_map", "A month is written as its first day.")
  end

  def check_text("hosting_invoices_amount_check") do
    dgettext("domain_map", "The sum is not negative, and the note has up to 500 characters.")
  end

  def check_text(_name), do: nil

  @doc "The short names on the arrows of the core view."
  def core_labels do
    %{
      uses: dgettext("domain_map", "uses"),
      writes: dgettext("domain_map", "writes"),
      carries: dgettext("domain_map", "carries"),
      is_member: dgettext("domain_map", "is a member"),
      in_group: dgettext("domain_map", "in a group"),
      holds_roles: dgettext("domain_map", "holds roles"),
      by_key: dgettext("domain_map", "by key"),
      contains: dgettext("domain_map", "contains"),
      opens_thread: dgettext("domain_map", "opens a thread"),
      descriptions: dgettext("domain_map", "descriptions"),
      app_data: dgettext("domain_map", "app data"),
      calendar: dgettext("domain_map", "calendar"),
      has_manifest: dgettext("domain_map", "has a manifest"),
      defines: dgettext("domain_map", "defines"),
      sub_group: dgettext("domain_map", "sub-group"),
      sub_group_of: dgettext("domain_map", "of a group"),
      reply: dgettext("domain_map", "reply"),
      reply_to: dgettext("domain_map", "to a value")
    }
  end

  defp labels do
    %{
      core: core_labels(),
      keys: Map.new(2..8, &{&1, key_count(&1)}),
      close: dgettext("domain_map", "Close"),
      keys_here: dgettext("domain_map", "Keys of this table"),
      no_keys: dgettext("domain_map", "This table points at nothing."),
      pointing_here: dgettext("domain_map", "Pointing here"),
      nobody: dgettext("domain_map", "Nothing."),
      deleting: dgettext("domain_map", "Deleting a row in the database"),
      blocked_by: dgettext("domain_map", "Blocked by:"),
      cascades: dgettext("domain_map", "Takes with it:"),
      clears: dgettext("domain_map", "Clears the fields:"),
      nothing_else: dgettext("domain_map", "Nothing else changes."),
      fields: dgettext("domain_map", "Fields"),
      virtual: dgettext("domain_map", "Virtual fields, not in the database"),
      rules: dgettext("domain_map", "Rules in the database"),
      unique: dgettext("domain_map", "Unique"),
      source: dgettext("domain_map", "Source"),
      table: dgettext("domain_map", "table"),
      primary: dgettext("domain_map", "primary"),
      key: dgettext("domain_map", "key"),
      cascade: dgettext("domain_map", "cascades"),
      nilify: dgettext("domain_map", "clears the field"),
      restrict: dgettext("domain_map", "blocks"),
      soft: dgettext("domain_map", "soft"),
      legend_cascade: dgettext("domain_map", "deletes with it"),
      legend_nilify: dgettext("domain_map", "clears the field"),
      legend_restrict: dgettext("domain_map", "blocks deleting"),
      legend_soft: dgettext("domain_map", "soft link, no key"),
      legend_hubs: dgettext("domain_map", "key to Profile, Group"),
      tag_note: dgettext("domain_map", "goes on everything marked #"),
      core_description:
        dgettext(
          "domain_map",
          "The core of the domain: an account uses profiles, a profile is a member of groups, a group contains values, and a value opens a thread, which is a group again."
        ),
      tables_description:
        dgettext(
          "domain_map",
          "All the tables of the domain by area, with their foreign keys and soft links."
        )
    }
  end

  defp key_count(count) do
    dngettext("domain_map", "%{count} key", "%{count} keys", count)
  end

  def stats(counts) do
    [
      {counts.entities, dngettext("domain_map", "entity", "entities", counts.entities)},
      {counts.domains, dngettext("domain_map", "area", "areas", counts.domains)},
      {counts.keys, dngettext("domain_map", "foreign key", "foreign keys", counts.keys)},
      {counts.soft, dngettext("domain_map", "soft link", "soft links", counts.soft)}
    ]
  end

  def caption(:core, _counts) do
    dgettext(
      "domain_map",
      "A group contains values, and a value opens a thread, which is a group again. That is why sub-groups and threads share one model. The arrows read as sentences, from subject to object. These are the main entities, and all of them are under All tables."
    )
  end

  def caption(:tables, counts) do
    dgettext(
      "domain_map",
      "An arrow goes from the table holding the key to the table the key points at. %{count} of the %{total} keys go to Profile and Group, so they are hidden behind the marks P and G. Select an entity to see all its links. Its neighbours then show the column that joins them.",
      count: counts.hub_keys,
      total: counts.keys
    )
  end

  def caption(:soft, _counts) do
    dgettext(
      "domain_map",
      "Only soft links are shown. They point at another table with text, a number or a list. The database does not check them, so whether they are right depends on the code."
    )
  end

  def views_label, do: dgettext("domain_map", "View")
  def areas_label, do: dgettext("domain_map", "Areas")

  def view_name(:core), do: dgettext("domain_map", "Core")
  def view_name(:tables), do: dgettext("domain_map", "All tables")

  def only_soft_links(count) do
    dgettext("domain_map", "Only soft links (%{count})", count: count)
  end

  def all_links(count), do: dgettext("domain_map", "All links (%{count})", count: count)

  def swipe_hint, do: dgettext("domain_map", "The diagram scrolls left and right.")

  def overview do
    %{
      title: dgettext("domain_map", "Overview"),
      hint:
        dgettext(
          "domain_map",
          "Select an entity on the diagram and its fields, links and rules appear here."
        ),
      blocking: dgettext("domain_map", "Keys that block deleting"),
      blocking_hint:
        dgettext(
          "domain_map",
          "These keys do not let a row be deleted while something uses it. The others delete the dependent rows or clear the field."
        ),
      soft: dgettext("domain_map", "Soft links"),
      soft_hint:
        dgettext(
          "domain_map",
          "They point at another table, but the database does not check them."
        ),
      composite: dgettext("domain_map", "Composite keys"),
      composite_hint:
        dgettext(
          "domain_map",
          "A key over two columns holds both rows in the same group. The schema in the code does not show that."
        )
    }
  end

  @doc "What a description can do as an app: an overview, not a guide to building one."
  def apps do
    %{
      title: dgettext("domain_map", "What a description can do as an app"),
      lead:
        dgettext(
          "domain_map",
          "A group's description does not have to be text. The default description and every <GroupAltDescription>alternative description</GroupAltDescription> can be an app: a program written by members who may edit the group, which runs on the group's page, in a frame of its own, for everyone who opens it."
        ),
      flow: [
        {dgettext("domain_map", "The app"), dgettext("domain_map", "asks")},
        {dgettext("domain_map", "Potok checks the permissions"), dgettext("domain_map", "saves")},
        {dgettext("domain_map", "The group's values"), dgettext("domain_map", "live")},
        {dgettext("domain_map", "Members who have it open"), nil}
      ],
      capabilities: [
        %{
          icon: "hero-circle-stack",
          title: dgettext("domain_map", "Keeps its own data"),
          text:
            dgettext(
              "domain_map",
              "Each app has its own <Value>values</Value>, apart from the other apps of the group. It can search them, sort them, count them, add them up and read them page by page, the newest first if it likes."
            )
        },
        %{
          icon: "hero-bolt",
          title: dgettext("domain_map", "Works live"),
          text:
            dgettext(
              "domain_map",
              "A new value reaches right away, with no refresh, everyone who has the app open and may see it."
            )
        },
        %{
          icon: "hero-squares-2x2",
          title: dgettext("domain_map", "Sees the other apps"),
          text:
            dgettext(
              "domain_map",
              "It can also read the values of the group's other apps, except those kept under rules, and it writes only to its own."
            )
        },
        %{
          icon: "hero-clipboard-document-check",
          title: dgettext("domain_map", "Collects answers by its own rules"),
          text:
            dgettext(
              "domain_map",
              "An app can keep its <Value>values</Value> under rules its editors set: which <GroupRole>roles</GroupRole> write and which read everything, one answer per person, changing one's own answer, a deadline, anonymous answers and, in a public group, answers from signed-in non-members. Potok also scores a quiz by a key only the editors see, counts the answers for a summary, keeps the files sent with them in two sub-groups of the app's group, and sends a push about each new answer to whoever asks for it. That is how a group becomes a form."
            )
        },
        %{
          icon: "hero-cog-6-tooth",
          title: dgettext("domain_map", "Runs a process"),
          text:
            dgettext(
              "domain_map",
              "A collection's rule can carry the graph of a process, which Potok checks as the app saves it and runs for every new <Value>value</Value>: messages, sub-groups and pushes signed by the process's own <Profile>profile</Profile>, tasks for the people of a role, deadlines and timers. The app lists the <ValueProcess>instances</ValueProcess> of the values its viewer may read, lets whoever holds a task's role finish it, and lets its editors take a failed one up again or cancel one. Each move reaches the app live. Of the processes the group's editors draw in Potok, the app sees what waits for its viewer, opens a form of theirs in Potok's own dialog and may finish a decision, and opens the Start of one the viewer may start by hand the same way; their drawings stay out of its sight."
            )
        },
        %{
          icon: "hero-newspaper",
          title: dgettext("domain_map", "Reads the groups below it"),
          text:
            dgettext(
              "domain_map",
              "It can list the <Group>groups</Group> under one of its sub-groups, all of them or those of a chosen period, show their descriptions and take the viewer to their chat or their page. A link can open it on one of those groups. That is how a group becomes a news feed, with one story in each group."
            )
        },
        %{
          icon: "hero-face-smile",
          title: dgettext("domain_map", "Gathers reactions and comments"),
          text:
            dgettext(
              "domain_map",
              "For each <Group>group</Group> below it, it gets the number of messages in its chat and its <GroupReaction>reactions</GroupReaction>. It can add the viewer's reaction and open the sharing of the group's link. That is how a story in a feed gets comments, reactions and a share button."
            )
        },
        %{
          icon: "hero-map",
          title: dgettext("domain_map", "Shows its groups on a map"),
          text:
            dgettext(
              "domain_map",
              "It gets the <Group>groups</Group> right under it that have a place on a map, with the pin each one shows, and whoever may make a sub-group there can add one where they tap. A tap on a pin opens that group's description over the app, where its own app, a form or a poll, works with that group's rights. Among them, groups that cover an area come with their borders, groups that run along a route with their lines and lengths, and each place with the areas it lies in or passes through, so the app draws the areas and routes and shows only the groups inside one area. A map of more than 2000 places gets only what its view shows, which the server gathers into numbered circles as on the root's map, filtered by name and by the pins the groups show. That is how a group becomes a map. The root needs no such app: it has a map of its own."
            )
        },
        %{
          icon: "hero-folder-plus",
          title: dgettext("domain_map", "Keeps the groups below it"),
          text:
            dgettext(
              "domain_map",
              "For a viewer who may edit its group, an app can make <Group>groups</Group> right under it, change them and take them back, and put them on a map with a pin. A new one opens its chat if the app's group has. It can also make up to a hundred at once, all or none, each with a key of its own, so that the same list brought in again makes no duplicates: that is how the rows of an open dataset become groups on a map. That is how one app writes what another shows, and a feed gets its editors' desk."
            )
        },
        %{
          icon: "hero-identification",
          title: dgettext("domain_map", "Knows who is looking"),
          text:
            dgettext(
              "domain_map",
              "It gets the viewer's <Profile>profile</Profile> and their <GroupRole>roles</GroupRole> in the group, so it can show different things to different members."
            )
        },
        %{
          icon: "hero-pencil-square",
          title: dgettext("domain_map", "Changes itself"),
          text:
            dgettext(
              "domain_map",
              "An app can rewrite its own description, when the viewer may edit the group."
            )
        },
        %{
          icon: "hero-eye",
          title: dgettext("domain_map", "Reaches those it is meant for"),
          text:
            dgettext(
              "domain_map",
              "An <GroupAltDescription>alternative description</GroupAltDescription> can be limited to certain <GroupRole>roles</GroupRole>, and it can be the page a group opens on."
            )
        },
        %{
          icon: "hero-moon",
          title: dgettext("domain_map", "Fits in"),
          text:
            dgettext(
              "domain_map",
              "It follows the light or dark theme, and keeps each viewer's settings in their browser."
            )
        },
        %{
          icon: "hero-chart-bar",
          title: dgettext("domain_map", "Shows the group's polls"),
          text:
            dgettext(
              "domain_map",
              "It reads the <Poll>polls</Poll> of its group as far as their rules show them to the viewer, hears when one changes, and opens Potok's own form and voting over itself."
            )
        },
        %{
          icon: "hero-share",
          title: dgettext("domain_map", "Speaks for itself"),
          text:
            dgettext(
              "domain_map",
              "An app in the default description decides what the card of a shared link says about the group. A link into the app that names a public group it reaches, such as a story of a feed, gets that group's card, marked with the app's name and picture."
            )
        },
        %{
          icon: "hero-globe-alt",
          title: dgettext("domain_map", "Opens to guests"),
          text:
            dgettext(
              "domain_map",
              "Where a public <Group>group</Group> opens its description to guests, its app runs for people without an account too. It then lists the public groups below it and shows the descriptions of those open to guests, maps them and reads public <Poll>polls</Poll>, and a tap on a group opens its text over the app. That is how a feed or a map can be read by anyone with the link."
            )
        }
      ],
      limits_title: dgettext("domain_map", "Where it stops"),
      limits: [
        dgettext(
          "domain_map",
          "An app runs apart from Potok's page, so it gets only what Potok hands it."
        ),
        dgettext("domain_map", "The server checks every call again, whatever the app asks for."),
        dgettext(
          "domain_map",
          "Members read and save values, and so do signed-in non-members where an app's rules open that to them in a public group. Rules can narrow it further, and the number of saves is limited."
        ),
        dgettext(
          "domain_map",
          "A guest saves, reacts and votes in nothing. Of an app's values it gets only the settings and counts that public rules show everyone."
        ),
        dgettext(
          "domain_map",
          "Potok checks who answers, when, how many times and how much, not what an answer says."
        ),
        dgettext(
          "domain_map",
          "Below its group it sees only what the viewer sees, and no further than one level under a direct sub-group."
        ),
        dgettext(
          "domain_map",
          "It writes to groups only for a viewer who may edit its own group, only right under it, and it neither deletes a group nor makes one an app."
        ),
        dgettext(
          "domain_map",
          "A reaction is the exception: an app adds it for any viewer who may react, only to a group below it, and the viewer can take it back."
        ),
        dgettext(
          "domain_map",
          "It does not vote and does not change a poll: a vote can be final, so that takes place on Potok's own page."
        ),
        dgettext(
          "domain_map",
          "The data of an app goes with its description, and it can be deleted from the group's settings."
        )
      ]
    }
  end

  def mechanisms_title, do: dgettext("domain_map", "What holds the domain together")

  def mechanisms do
    [
      %{
        title:
          dgettext(
            "domain_map",
            "The account is the identity, the profile is the face in a group"
          ),
        text:
          dgettext(
            "domain_map",
            "<Account>The account</Account> is the identity: an email and a password. Everything in groups is done by a <Profile>profile</Profile>. One account can have several profiles, say a business, a private and a club one. The code does not tell them apart by purpose, only unique from shared. A shared profile is used by every account that accepts a <ProfileInvitation>profile invitation</ProfileInvitation>."
          )
      },
      %{
        title: dgettext("domain_map", "A thread is an ordinary group"),
        text:
          dgettext(
            "domain_map",
            "A <Group>group</Group> opened from a <Value>value</Value> is a thread. One value has at most one thread, and a thread always inherits members. There is one root, with no parent and no creator. All other groups have both, even direct conversations, which sit right under the root."
          )
      },
      %{
        title: dgettext("domain_map", "How permissions come about"),
        text:
          dgettext(
            "domain_map",
            "The group's <GroupManifest>manifest</GroupManifest> applies or, if it has none, that of its nearest ancestor. Every member has `everyone`, so that <GroupRole>role</GroupRole> is not stored, and `admin` has everything. With the other roles a permission holds when at least one allows it and none denies it. `everyone` can only allow. A <GroupReaction>reaction to a group</GroupReaction> also reaches past the members: while `everyone` may react, so may a signed-in profile that is not a member of a public group, unless it is <GroupBlock>blocked</GroupBlock> there."
          )
      },
      %{
        title: dgettext("domain_map", "A poll carries its own rules"),
        text:
          dgettext(
            "domain_map",
            "A <Poll>poll</Poll> names the <GroupRole>roles</GroupRole> that vote, that see the results and that see the details, and the organizer and those who manage polls always see them. Once a <PollBallot>ballot</PollBallot> is in, what voters saw no longer changes, except the deadline. One account gives one vote, whichever of its profiles it uses, and a profile several accounts share votes on its own. A secret poll keeps no answers on its ballots, only the count of each <PollOption>answer</PollOption> grows, so neither the group's admins nor an app can see who voted for what. No counts show before its end, and a finished one is not opened again. A public poll also takes the votes of signed-in non-members of a public group. Deleting the <Value>value</Value> that carries a poll deletes the poll."
          )
      },
      %{
        title: dgettext("domain_map", "A group sends notices to those who follow it"),
        text:
          dgettext(
            "domain_map",
            "A profile can follow a <Group>group</Group> it sees, a public one without being a member: that is a <GroupFollow>following</GroupFollow>. The root, direct conversations and threads are not followed. Whoever holds the permission to send notices sends a <GroupNotice>notice</GroupNotice>, and `admin` holds it as it holds every permission. The notice is written as a <GroupNoticeReceipt>received notice</GroupNoticeReceipt> for every follower who sees the group at that moment, never for its author, so it stays after unfollowing, and a later follower finds the older ones on the group's page. Unread received notices make their own counter, apart from unread messages, and opening the list of notices or the group's notices reads them. A push goes out while both the following and the profile allow it. Deleting a notice takes it from everyone who received it. The preview of a notice's first link comes a moment after it is sent, and whoever may delete the notice may remove the preview, for everyone. At the root, the groups a profile follows stay on its lists and on the map of groups while the other public groups are hidden, and its sub-groups can be narrowed to them."
          )
      },
      %{
        title: dgettext("domain_map", "A public group can open its chat"),
        text:
          dgettext(
            "domain_map",
            "While a <Group>group</Group> is public, its chat can reach past the members. A signed-in profile that is not a member then reads its <Value>values</Value> and files, and writes and reacts as far as `everyone` may. It sends no files, opens no threads and has a limit on how much it writes. Its message pushes only to those it mentions or answers, and a reply reaches it the same way. A <GroupBlock>block</GroupBlock> stops one profile from writing and reacting there, asking to join or being invited. A member answers to their roles, so blocking one also removes them from the group."
          )
      },
      %{
        title: dgettext("domain_map", "A public group can open its description to guests"),
        text:
          dgettext(
            "domain_map",
            "Anyone with the link of a public <Group>group</Group> sees its name, its picture and a piece of its description, without an account. Whoever may edit the group can open the whole description to such guests, and then each <GroupAltDescription>alternative description</GroupAltDescription> marked for them goes along; one that only some <GroupRole>roles</GroupRole> see never does. A description that is an app runs for guests too, and only reads: the public groups below it, the descriptions of those open to guests, a map of them, public <Poll>polls</Poll> and what public rules show. The chat, the members and who reacted stay behind the login, and search engines do not list the page. A group that stops being public closes it, and keeps the choice for when it opens again."
          )
      },
      %{
        title: dgettext("domain_map", "Unread is measured from one marker"),
        text:
          dgettext(
            "domain_map",
            "A <GroupValueRead>read marker</GroupValueRead> holds, for one profile in one group, the last <Value>value</Value> it has read, and everything newer is unread. Only members have one, and a chat opened while still empty gets one too. Opening the chat moves the marker to the newest value, and the line that shows where the unread values begin stands where the marker was before. A group's newest value shows in the lists only to its members, as only their pages hear of new values. A search of the chat finds what the chat shows: a member's also takes the threads it is in, and someone reading an open chat from outside does not find announcements of events that are not public."
          )
      },
      %{
        title: dgettext("domain_map", "A member can silence a group"),
        text:
          dgettext(
            "domain_map",
            "A <GroupMembership>membership</GroupMembership> remembers until when its member silenced the group: an hour, eight hours, a week or until they turn it on again. Until then nothing that goes to everyone reaches them as a push: new values, polls, events, an app's notices, a process's push to everyone. What is meant for them still does: a mention, an answer to their value, a reaction, a process asking them or their role. The group's unread values leave the home badge and the sums of the groups above it, while its own row still shows them, in grey. The threads of a silenced group are silent too."
          )
      },
      %{
        title: dgettext("domain_map", "Members are inherited down the tree"),
        text:
          dgettext(
            "domain_map",
            "A group can inherit members: it then holds all the members of its parent and their roles. Those rows in <GroupMembership>memberships</GroupMembership> and <GroupMemberRole>member roles</GroupMemberRole> are marked as inherited and leave with the membership in the parent. Members added in the group itself stay. When a group stops inheriting, the inherited rows become its own and nobody falls out. The exception is an app withdrawing a group: the inherited members then leave and the direct ones stay."
          )
      },
      %{
        title: dgettext("domain_map", "A shortcut shows a group in one more place"),
        text:
          dgettext(
            "domain_map",
            "A <GroupShortcut>shortcut</GroupShortcut> puts a <Group>group</Group> that stands deeper in the tree among the sub-groups of another group, the root as well, and a tap opens it where it stands. Whoever may make sub-groups there places one to a group they see, and it shows only to those who see that group, by the same rule as the other sub-groups. The row shows the group itself, with its newest value and what is unread in it, but the counts above it hold that unread once, where the group stands. It never leads to the root, a thread, a direct conversation or an app's record, nor to a group already standing there. Its author or an admin of the group it stands in removes it, which leaves the group as it is. Apps do not see shortcuts among the sub-groups."
          )
      },
      %{
        title: dgettext("domain_map", "A preset only fills in a new group"),
        text:
          dgettext(
            "domain_map",
            "A new <Group>group</Group> can start from a preset: chat, folder, feed, polls, form, map or page. A preset sets what any group can have, so all of it can be changed later. The group keeps only the preset's name: its avatar shows that kind while the group still fits it, and the list of sub-groups can be narrowed to one kind. A feed is two groups, one with the Feed app and one below it with FeedCreator, and each keeps its own copy of its app, so a new version reaches only the feeds made after it. A group for polls, a form and a map keep a copy of their app the same way, and a form gets its two groups for files only once it needs them. The root offers no map, as it has one of its own."
          )
      },
      %{
        title: dgettext("domain_map", "A group can stand on a map"),
        text:
          dgettext(
            "domain_map",
            "A <Group>group</Group> can have a place: both coordinates or neither, set by whoever may edit it, with a pin picked from a list or the one of its kind, and a picked pin keeps the kind's mark in its corner, as the group's picture does. A map app shows the places of the groups right under its own, each to whoever sees that group. A group added from the map is an ordinary sub-group, made by whoever may make one there. The map's pictures come through Potok, so the map service does not see who is looking. The root has no map app but a map of its own: the places of every group the viewer sees, at any depth, which the server gathers into numbered circles where they stand close, narrowed by the filters of the sub-groups, by the pins the groups show and by when a group appeared or was last written in, at any time until the viewer picks a time frame. A search by a group's name, there and among the sub-groups, takes no notice of diacritics or of a name written in Latin or Cyrillic."
          )
      },
      %{
        title: dgettext("domain_map", "Records stay on their own map"),
        text:
          dgettext(
            "domain_map",
            "A <Group>group</Group> an app made with a key of its own is a record, such as one row of an open dataset brought in with thousands of others. The key is set once and is unique under its parent, so bringing the same list in again makes no duplicates. A record is an ordinary group, seen by whoever may see it, but it stands only on its own map: the root's map and the place picker of events leave records out, and the unread counts of the profile that brought them in do not follow them. Pages hear of a hundred records made at once as of one change."
          )
      },
      %{
        title: dgettext("domain_map", "A place can be an area"),
        text:
          dgettext(
            "domain_map",
            "A <Group>group</Group>'s place can be an area instead of a point, as a local community covers its streets: a border drawn on the map or brought from a GeoJSON file, set by whoever may edit the group. The area keeps a pin, which the server puts inside it by itself. An area holds a group when it holds that group's pin, so every place shows the areas around it, smallest first, and an area inside a bigger one lies in it too. Each viewer sees only the areas of the groups they see. On the root's map an area is only the shape of its group: the filters keep it or leave it out like any group, and once it is wide enough it also shows its border, under the pins. An area that holds others whose borders show inside it gets a wide soft band under every border, so its own border shows where theirs lie on it. A tap on the map lists the areas there, and a filter keeps only the groups inside chosen areas, which stay outlined."
          )
      },
      %{
        title: dgettext("domain_map", "A place can be a route"),
        text:
          dgettext(
            "domain_map",
            "A <Group>group</Group>'s place can also be a route, as a walk, a race, a march or a bike path runs: a line drawn on the map or brought from a GPX, KML or GeoJSON file, set by whoever may edit the group. A place is a point, an area or a route, never an area and a route at once. The route keeps its pin at its start, where people meet, which the server puts there by itself, and the map marks its end with a ring. A route lies in every area it passes through, not only in the one it starts in, so its page lists those areas and the filter by area keeps it. On the root's map a route is only the shape of its group, as an area is: the filters keep it or leave it out, and once it is wide enough its line is drawn over the areas, under the pins, in a layer of its own; a tap on the line opens the group, and a link to the map can show one route, whatever the filters."
          )
      },
      %{
        title: dgettext("domain_map", "A group's description can be an app"),
        text:
          dgettext(
            "domain_map",
            "The default description and every <GroupAltDescription>alternative description</GroupAltDescription> can be an app. Its data are <Value>values</Value> marked as data, and each of them knows which app it belongs to and which of the app's collections holds it. A composite key holds them in the same group, and deleting an alternative description deletes its data too."
          )
      },
      %{
        title: dgettext("domain_map", "An app's data carry their own rules"),
        text:
          dgettext(
            "domain_map",
            "An app's settings are one <Value>value</Value> of its own: the app's data, a secret part only its editors read, and the rules of its other collections, which Potok holds to on every call. A rule names the <GroupRole>roles</GroupRole> that write and those that read everything; everyone else reads only what they wrote, and those who may edit the group always read all. A collection without a rule is closed the same way. One answer per person counts one account once, as a poll does. An answer written while its collection was anonymous never shows its author to anyone but the author, though its time shows, and whoever rewrites the app's code could still get around it. Files sent with answers are values with a <ValueAttachment>file</ValueAttachment> in two sub-groups of the app's group: a closed one, whose members alone open them, and one that inherits the members. Whoever sent a file can always open it."
          )
      },
      %{
        title: dgettext("domain_map", "An app's process signs with a profile of its own"),
        text:
          dgettext(
            "domain_map",
            "Every <Value>value</Value> and every <Group>group</Group> but the root has a creator, so what an app's process does is signed by a <Profile>profile</Profile> of its own, which belongs to no <Account>account</Account>. It comes with the rule that gives a collection of the app a process, as an <AppProcess>app process</AppProcess> owned by the editor who saved that rule, and it joins the app's group with what `everyone` may do there. Nobody logs in as it or picks it, nobody mentions or invites it or opens a direct conversation with it, it is not counted among the members, and groups that inherit members do not take it in. Removing the rule makes the process inactive and takes it out of the group, and its values keep their author. It writes only in the app's group and in the sub-groups it made itself, as far as its permissions there go. In a sub-group it makes it is a plain member, and people are the admins: its owner, while the owner still edits the app, and whoever set the process going. It pushes to the people of a role only with the right to mention roles. In the app's group nobody removes or blocks it, as its rule takes it in and out; in the sub-groups it makes, people may."
          )
      },
      %{
        title: dgettext("domain_map", "A value sets an app's process going"),
        text:
          dgettext(
            "domain_map",
            "When a <Value>value</Value> comes to a collection whose process has a graph, a <ValueProcess>process instance</ValueProcess> starts in the same transaction, with a copy of the graph, so changing the rule later leaves it as it was. Each element runs in a transaction of its own together with the instance's move to the next, so what it writes happens once. The instance waits on a task until someone holding the task's role picks an outcome or the deadline passes, and on a timer until it is due; a scheduler on every server takes forward those whose time has come. An action that fails leaves the instance failed where it stopped, for an editor to take up again, and removing the rule cancels the instances that run or wait. Nobody learns from a process who wrote an anonymous value."
          )
      },
      %{
        title: dgettext("domain_map", "Editors can draw a process in Potok"),
        text:
          dgettext(
            "domain_map",
            "Besides the process an app writes into its rules, the editors of a group can draw processes of their own in Potok, as <AppProcess>app processes</AppProcess> that keep their graph outside any app's settings. One starts on a new value of a collection of an app, on a member's chat message holding one of its words or mentioning its role, on a sub-group made one at a time (not a record, a thread or what a process makes), on a schedule, when someone holding its role starts it by hand with a title and a text, when another process drawn in the group calls it, or on a signal one sends. An app replaces its settings whole when it saves them, so it could never keep a drawing safe; this way it neither sees nor overwrites them, and its own process runs beside them. A drawing is kept only when an instance could finish it, with roles the group has, and starts switched off. What its texts and conditions say are expressions over the names it has, such as what set it going and what a decision ended with, checked when it is kept, so a drawing that names what is not there is refused. One kept before expressions is turned into them when its editor opens it, and an instance reads the language of the graph it started with. A drawing may also declare variables, each with the type of what it holds, a plain one or an <GroupEntity>entity</GroupEntity> of the group: a step sets one to what an expression gives, every instance keeps its own, and the drawing is kept with the entities as they were then, so an instance under way reads them the same after one changes. A step may also go through a list an item at a time, with steps of its own for each: it reads the list once, on its way in, at most 200 items, and hands each to those steps by a name. So that a drawing that runs in a circle stops, an instance takes at most 25 steps in a row without waiting, counted anew for each item, and 5,000 in its life; after 100 it gives way to the others, and the steps that write outside it (a message, a sub-group, a push, a field of the group, a signal, a call) are 60 a minute for a process at most. Switched on, its profile joins the group and each of these starts a <ValueProcess>process instance</ValueProcess> of it; a change applies to the instances that start after it, and switching it off cancels those that run or wait. The app knows nothing of their tasks, so the people of a task's role finish them on the group's Processes tab, where they see a <Value>value</Value> only as far as they may read it. Deleting the app takes the processes drawn on its collections along."
          )
      },
      %{
        title: dgettext("domain_map", "What a process takes is an entity"),
        text:
          dgettext(
            "domain_map",
            "A <AppProcess>process</AppProcess> drawn in Potok that starts on a call, on a signal, by hand or on a value may take an <GroupEntity>entity</GroupEntity> of its group. A call then hands it that entity's attributes, each a value of its type and every required one a value, checked when the caller is saved and again when the call is made, against the entity as the called process was saved with it; a call that does not fit fails where it stands and starts nothing. A process started by hand asks for the attributes in a form, lists and the entities it holds included. A signal is waited for with an entity, and a process sends it only with the entity those who wait for it expect, where someone does: whoever waits says what it waits for. A drawing whose entity changed since it was saved, or whose calls and signals no longer fit those they talk to, runs on as it was saved, and its editors are told to look it over."
          )
      },
      %{
        title: dgettext("domain_map", "A called process can hand an entity back"),
        text:
          dgettext(
            "domain_map",
            "A <AppProcess>process</AppProcess> that others call may name an <GroupEntity>entity</GroupEntity> of its group that it hands back. Each of its ends then fills it in, an attribute at a time, checked when the process is saved, and the caller reads it under the call's id, in its own group or in another: the process hands over exactly that and nothing else. One that names none hands back only the end it reached, and to a caller of its own group what it was given and what its waits brought back. An end whose values do not fit when the run gets there fails that run, and the caller waits for it as for any run it called."
          )
      },
      %{
        title: dgettext("domain_map", "A process asks a person with a form"),
        text:
          dgettext(
            "domain_map",
            "A step of a drawing may be a form: it stops the <ValueProcess>process instance</ValueProcess> until a person fills in an <GroupEntity>entity</GroupEntity>, each attribute as its type, a list a row per item and an entity it holds as a group of its own, as the drawing was saved with it. It may say something first, and start with something in some attributes, worked out from what the instance holds when the form is opened; the person may change it, and what they send counts. It asks whoever started the instance, or the people of a role, and only a member of the group answers, once. The form opens by itself only for the one who started the instance, and only when it was their own step that led to it: a message they wrote, a start by hand, a form before it. Reached after a wait or someone else's decision, and for a role, it waits on the group's Processes tab. What was filled in is read by the steps that follow, an attribute at a time, with who filled it in, and whoever filled it in sets off those steps. Nobody starts a process on a schedule, so its form asks a role, and an instance nobody started fails on a form that asks whoever did. While it waits for a person, on a form or a decision, an instance keeps whom it asks, so a group's page counts what waits for its viewer without reading every waiting instance, and counts again only on news that is theirs. The same count stands on the bar's hand beside the join requests the person may approve, the Requests page lists those tasks by group, and an amber mark stands on the rows of the groups they wait in and of those above them."
          )
      },
      %{
        title:
          dgettext(
            "domain_map",
            "A process is private to its group, or public up and down the tree"
          ),
        text:
          dgettext(
            "domain_map",
            "A drawn <AppProcess>process</AppProcess> that others call is private until an editor makes it public. A private one is called by the processes of its own <Group>group</Group> alone. A public one is called from the groups above its group and from those below it too, never from a branch beside it, and the editors there see its name and what it takes. The <ValueProcess>run</ValueProcess> such a call starts in another group gets what the call hands over and nothing else: it has no subject and nobody set it off, as the caller's value and people are no part of that group, and the caller hears only which end it reached. Callers of other groups do not keep a public process from being deleted or made private again: their calls then fail where they stand, their editors are told to look the drawing over, and a caller left waiting for a run that went with its group fails as one whose run was cancelled."
          )
      },
      %{
        title: dgettext("domain_map", "Processes talk to each other only on purpose"),
        text:
          dgettext(
            "domain_map",
            "What a process writes starts no other process: its messages and the sub-groups it makes set nothing going, so two processes never keep each other running by chance. A drawn process talks to another only by a step drawn for it. A call starts a drawn <AppProcess>process</AppProcess> that starts when another calls it, of the same group or a public one of a group above or below, and hands over what it takes; the <ValueProcess>run</ValueProcess> it starts is one level deeper, and in its own group it shares the caller's subject. A caller that waits goes on when that run ends, knowing which end it reached, or gives up at its deadline and cancels it. Cancelling a run cancels the run it waits for, and a run whose called run is cancelled stops, for an editor to take up again, which calls anew. A step can also keep a <GroupField>field of the group</GroupField>, which every drawn process of the group reads; adding to one takes its lock, so two runs never lose each other's count. A signal wakes the runs of the group's drawn processes that wait for it just then, at most 100, and starts the processes that start on it; nothing keeps it for a run that comes to wait later, and a wait may take only a signal sent on its own subject. Runs go at most three processes deep, and a process another one of its group calls cannot be deleted."
          )
      },
      %{
        title: dgettext("domain_map", "A picture in a description is a file in the chat"),
        text:
          dgettext(
            "domain_map",
            "A picture a description's template takes from the device is a <Value>value</Value> in the group's chat with its <ValueAttachment>file</ValueAttachment>, so it stays among the group's files. More people see a description than a chat, so the picture's address is signed and needs no login. Deleting that value also removes the picture from the description."
          )
      },
      %{
        title: dgettext("domain_map", "One tag, five kinds of items"),
        text:
          dgettext(
            "domain_map",
            "<Tagging>Tagging</Tagging> joins a <Tag>tag</Tag> with exactly one group, profile, event, value or file, and the database checks that. A tag without an owner is public. A tag with an owner is seen only by that profile."
          )
      },
      %{
        title: dgettext("domain_map", "How to get into a group"),
        text:
          dgettext(
            "domain_map",
            "A <GroupInvitation>group invitation</GroupInvitation> goes from profile to profile. If the invited account has no profile yet, an <GroupAccountInvitation>account invitation</GroupAccountInvitation> is kept, which becomes an ordinary invitation as soon as the account gets its first profile. A <GroupJoinRequest>join request</GroupJoinRequest> goes the other way. When accepted it is deleted, and an <GroupJoinRequestApproval>approved request</GroupJoinRequestApproval> stays with the name of whoever admitted the member."
          )
      },
      %{
        title: dgettext("domain_map", "An event's occurrence has no row of its own"),
        text:
          dgettext(
            "domain_map",
            "An <Event>event</Event> keeps the repeat rule. A single occurrence is named by its local start date, so an <Response>event response</Response> carries that date, and cancelled occurrences are listed on the event."
          )
      },
      %{
        title: dgettext("domain_map", "An event can take place at a group"),
        text:
          dgettext(
            "domain_map",
            "An <Event>event</Event>'s place is words, and it can also stand on the map: at the place of a <Group>group</Group> or at a place of its own, never both. A place of its own is a point, an area or a route, as a group's is, drawn the same way, and an area or a route keeps its pin. Only a group with a place that the author sees can be picked, and the event then stands where the group stands, even after the group moves. Whoever does not see that group sees only the words, and deleting the group leaves the words as well. A link from a group or from an event opens the root's map on its place, which stands out whatever the filters, and an event shows a card of its own there."
          )
      },
      %{
        title: dgettext("domain_map", "Potok estimates what it costs"),
        text:
          dgettext(
            "domain_map",
            "`Fly.io` gives no way to read its bills, so Potok estimates them itself. Every quarter of an hour it reads which machines run and how big they are, how big the database and the stored files are and how much data went out, and writes what each <CostHour>hour</CostHour> cost by the price list. The hours it missed, back to the start of the month, are filled in from `Fly.io`'s own metrics of those hours, which go back about ten days, and the rest from what runs now. Once a month is billed, one of the people who run Potok copies the sum from the <Invoice>invoice</Invoice>, and only they may. Anyone sees both on the costs page, even without an account."
          )
      }
    ]
  end
end
