defmodule PotokIdeWeb.GroupLive.Show.AccessCatalog do
  @moduledoc """
  What the access overview tells of a viewer, real or made up: each thing the
  group's page lets one do, by area, whether the viewer may, and why.

  Every verdict comes from the rule the page itself asks (`PageRules`,
  `Access`, `Polls.Rules`, `Events`, `Notices`, `GroupRequests`,
  `Polls.Effects`, `ValueRules`, `GroupMenu`), so the overview cannot say
  anything the page does not do. Only the reason is chosen here, and a test
  holds that it always points the same way as the verdict.

  A viewer is `%{access: %Access{}, profile: %Profile{} | nil, kind: kind}`.
  A made-up one (`viewer/2`) has an empty profile, which the rules only ask
  to tell a signed-in profile from a guest.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  alias PotokIde.Events
  alias PotokIde.Notices
  alias PotokIde.Polls.{Effects, Poll, Rules}
  alias PotokIde.Social.{Access, Group, GroupRequests, GroupRole, Profile, ValueRules}
  alias PotokIde.Storage
  alias PotokIdeWeb.GroupLive.Show.{GroupMenu, PageRules, RequestRules, RolesTab}

  @type kind :: :member | :outsider | :blocked | :guest
  @type spec :: {:member, [String.t()]} | :outsider | :blocked | :guest

  @areas [
    group: ~w(see_group read_description react_group follow edit_group manage_tags delete_group)a,
    messages: ~w(read_chat post attach react_chat open_threads mention_roles delete_values)a,
    membership:
      ~w(see_members ask invite decide_requests remove_members assign_roles change_roles propose_decisions)a,
    subgroups: ~w(see_subgroups create_subgroups)a,
    files: ~w(files_tab download)a,
    calendar: ~w(calendar create_events manage_events publish_events)a,
    polls: ~w(polls create_polls vote manage_polls publish_polls)a,
    more: ~w(send_notices processes draw_processes)a
  ]

  @doc "The areas in the order the overview shows them, each with its capabilities."
  def areas, do: @areas

  @doc "Every capability, in order."
  def capabilities, do: Enum.flat_map(@areas, &elem(&1, 1))

  @doc "The permissions whose holders the overview counts and names by role."
  def strong_permissions,
    do: [:remove_members, :delete_values, :edit_group, :manage_join_requests, :manage_polls]

  ## Viewers

  @doc """
  A made-up viewer under `manifest`: a member holding the role keys (and
  Everyone, which every member holds), a signed-in profile outside the group,
  one blocked there, or a guest with no account.
  """
  def viewer(manifest, {:member, keys}),
    do: %{
      access: Access.from_facts(manifest, {:member, keys}),
      profile: %Profile{},
      kind: :member
    }

  def viewer(manifest, :outsider),
    do: %{
      access: Access.from_facts(manifest, {:outsider, false}),
      profile: %Profile{},
      kind: :outsider
    }

  def viewer(manifest, :blocked),
    do: %{
      access: Access.from_facts(manifest, {:outsider, true}),
      profile: %Profile{},
      kind: :blocked
    }

  def viewer(manifest, :guest),
    do: %{access: Access.from_facts(manifest, {:outsider, false}), profile: nil, kind: :guest}

  @doc "The viewer of the page as they are."
  def real_viewer(%Access{} = access, profile) do
    kind =
      cond do
        is_nil(profile) -> :guest
        access.member? -> :member
        access.blocked? -> :blocked
        true -> :outsider
      end

    %{access: access, profile: profile, kind: kind}
  end

  @doc "The spec that would make the viewer: their own roles, or how they stand outside."
  def spec_of(%{kind: :member, access: access}),
    do: {:member, List.delete(access.role_keys, GroupRole.everyone_key())}

  def spec_of(%{kind: kind}), do: kind

  @doc """
  The columns of the table: Admin, each role of the manifest held alone (with
  Everyone, as every member holds it), Everyone, and for a public group
  someone outside it, a blocked profile and, where guests get a preview, a
  guest.
  """
  def columns(manifest, %Group{} = group) do
    members =
      for role <- manifest.roles do
        keys = if role.key == GroupRole.everyone_key(), do: [], else: [role.key]
        %{key: role.key, label: RolesTab.role_label(role), spec: {:member, keys}}
      end

    outsiders =
      if group.is_public,
        do: [
          %{key: "outsider", label: spec_label(:outsider, manifest), spec: :outsider},
          %{key: "blocked", label: spec_label(:blocked, manifest), spec: :blocked}
        ],
        else: []

    guests =
      if Group.guest_preview?(group),
        do: [%{key: "guest", label: spec_label(:guest, manifest), spec: :guest}],
        else: []

    members ++ outsiders ++ guests
  end

  @doc "The name of a spec: the roles it holds, or how it stands outside the group."
  def spec_label({:member, []}, _manifest), do: gettext("A new member (Everyone only)")

  def spec_label({:member, keys}, manifest) do
    manifest.roles
    |> Enum.filter(&(&1.key in keys))
    |> Enum.map_join(" + ", &RolesTab.role_label/1)
  end

  def spec_label(:outsider, _manifest), do: gettext("Someone outside the group")
  def spec_label(:blocked, _manifest), do: gettext("A blocked profile")
  def spec_label(:guest, _manifest), do: gettext("Guest, with no account")

  ## Labels

  @doc "The title of an area."
  def area_label(:group), do: gettext("The group")
  def area_label(:messages), do: gettext("Messages")
  def area_label(:membership), do: gettext("Members and roles")
  def area_label(:subgroups), do: gettext("Sub-groups")
  def area_label(:files), do: gettext("Files")
  def area_label(:calendar), do: gettext("Calendar")
  def area_label(:polls), do: dgettext("polls", "Polls")
  def area_label(:more), do: gettext("Notices, tags and processes")

  @doc "What a capability lets one do, in a few words."
  def label(:see_group), do: gettext("Sees the group")
  def label(:read_description), do: gettext("Reads its description")
  def label(:react_group), do: gettext("Reacts to the group")
  def label(:follow), do: gettext("Follows its notices")
  def label(:edit_group), do: gettext("Edits the group, its description and templates")
  def label(:manage_tags), do: gettext("Puts public tags")
  def label(:delete_group), do: gettext("Deletes the group")
  def label(:read_chat), do: gettext("Reads messages")
  def label(:post), do: gettext("Writes messages")
  def label(:attach), do: gettext("Sends files")
  def label(:react_chat), do: gettext("Reacts to messages")
  def label(:open_threads), do: gettext("Opens threads")
  def label(:mention_roles), do: gettext("Mentions roles")
  def label(:delete_values), do: gettext("Deletes others' messages")
  def label(:see_members), do: gettext("Sees the members and their roles")
  def label(:ask), do: gettext("Asks to join, or for roles")
  def label(:invite), do: gettext("Invites")
  def label(:decide_requests), do: gettext("Decides requests")
  def label(:remove_members), do: gettext("Removes and blocks members")
  def label(:assign_roles), do: gettext("Gives and takes roles")
  def label(:change_roles), do: gettext("Changes roles and permissions")
  def label(:propose_decisions), do: gettext("Puts roles to a vote")
  def label(:see_subgroups), do: gettext("Sees the sub-groups")
  def label(:create_subgroups), do: gettext("Creates sub-groups and shortcuts")
  def label(:files_tab), do: gettext("Has the Files tab")
  def label(:download), do: gettext("Downloads files from messages")
  def label(:calendar), do: gettext("Sees the calendar")
  def label(:create_events), do: gettext("Adds events")
  def label(:manage_events), do: gettext("Changes others' events")
  def label(:publish_events), do: gettext("Makes events public")
  def label(:polls), do: gettext("Sees the polls")
  def label(:create_polls), do: dgettext("polls", "Start polls")
  def label(:vote), do: gettext("Votes")
  def label(:manage_polls), do: dgettext("polls", "Manage polls")
  def label(:publish_polls), do: dgettext("polls", "Open polls to non-members")
  def label(:send_notices), do: gettext("Sends notices")
  def label(:processes), do: gettext("Sees the processes")
  def label(:draw_processes), do: gettext("Draws processes and edits apps")

  ## Checks

  @doc """
  Whether `viewer` may do what the capability names in `group`, and why:
  `{verdict, reason}`. `facts` are `PageRules.facts/1`, worked out once.
  """
  def check(capability, viewer, group, facts)

  def check(:see_group, %{kind: :guest}, group, _facts),
    do: verdict(Group.guest_preview?(group), :guest_preview, :no_guest_preview)

  def check(:see_group, viewer, group, _facts),
    do: verdict(PageRules.sees_group?(group, viewer.access), seen_reason(viewer), :private)

  def check(:read_description, %{kind: :guest}, group, _facts),
    do: verdict(Group.guest_description?(group), :guest_description, :no_guest_description)

  def check(:read_description, viewer, group, _facts),
    do: verdict(PageRules.sees_group?(group, viewer.access), seen_reason(viewer), :private)

  def check(:react_group, viewer, group, _facts) do
    ok = Access.can_react_to_group?(viewer.profile, viewer.access, group)

    cond do
      viewer.kind == :guest -> {false, :guest}
      viewer.kind == :member -> by(viewer, :react, ok, :not_here)
      true -> outsider_reason(viewer, group, :react, ok, group.is_public)
    end
  end

  def check(:follow, viewer, group, _facts) do
    ok = Notices.can_follow?(viewer.profile, group, viewer.access)

    cond do
      viewer.kind == :guest -> {false, :guest}
      not Notices.followable?(group) -> {ok, :not_here}
      true -> verdict(ok, seen_reason(viewer), :private)
    end
  end

  def check(:edit_group, viewer, group, facts),
    do:
      by(
        viewer,
        :edit_group,
        PageRules.tab("edit_group", group, viewer.access, facts) == "edit_group"
      )

  def check(:manage_tags, viewer, _group, _facts),
    do: by(viewer, :manage_tags, Access.can?(viewer.access, :manage_tags))

  def check(:delete_group, viewer, _group, _facts),
    do: admin_only(viewer, viewer.access.admin?)

  def check(:read_chat, %{kind: :guest}, _group, _facts), do: {false, :guest}

  def check(:read_chat, viewer, group, _facts) do
    ok = Access.can_read_chat?(viewer.access, group)

    cond do
      viewer.access.member? -> {ok, :member}
      true -> verdict(ok, :open_chat, :members_only)
    end
  end

  def check(:post, viewer, group, _facts),
    do:
      chat_check(
        viewer,
        group,
        :post_values,
        Access.can_post_in_chat?(viewer.profile, viewer.access, group)
      )

  def check(:react_chat, viewer, group, _facts),
    do:
      chat_check(
        viewer,
        group,
        :react,
        Access.can_react_in_chat?(viewer.profile, viewer.access, group)
      )

  def check(:attach, viewer, _group, _facts) do
    ok = PageRules.can_attach?(viewer.access)

    cond do
      viewer.kind == :guest -> {false, :guest}
      not viewer.access.member? -> {false, :members_only}
      not Storage.enabled?() -> {ok, :storage_off}
      true -> by(viewer, :attach_files, ok)
    end
  end

  def check(:open_threads, viewer, _group, _facts),
    do: by(viewer, :open_threads, Access.can?(viewer.access, :open_threads))

  def check(:mention_roles, viewer, _group, _facts),
    do: by(viewer, :mention_roles, Access.can?(viewer.access, :mention_roles))

  def check(:delete_values, viewer, _group, _facts),
    do: by(viewer, :delete_values, Access.can?(viewer.access, :delete_values))

  def check(:see_members, viewer, group, _facts) do
    ok = PageRules.members?(group, viewer.access)
    if viewer.kind == :guest, do: {false, :guest}, else: verdict(ok, :member, :members_only)
  end

  def check(:ask, %{kind: :guest}, _group, _facts), do: {false, :guest}

  def check(:ask, %{kind: :member} = viewer, group, _facts) do
    ok =
      GroupRequests.group_allowed?(group) and
        GroupRequests.requestable_roles(viewer.access, group) != []

    verdict(ok, :asks_roles, :nothing_to_ask)
  end

  def check(:ask, viewer, group, _facts) do
    ok = GroupRequests.may_ask_to_join?(viewer.access, group)

    cond do
      viewer.access.blocked? -> {ok, :blocked}
      true -> verdict(ok, :can_ask_to_join, :private)
    end
  end

  def check(:invite, viewer, group, facts) do
    ok =
      PageRules.tab("invite_profile", group, viewer.access, facts) == "invite_profile" and
        not is_nil(group.parent_id) and not group.is_direct

    by(viewer, :invite_members, ok)
  end

  def check(:decide_requests, viewer, group, _facts),
    do: by(viewer, :manage_join_requests, GroupRequests.may_decide?(viewer.access, group))

  def check(:remove_members, viewer, _group, _facts),
    do: by(viewer, :remove_members, Access.can?(viewer.access, :remove_members))

  # As the Members tab lets an admin give roles; where the group elects its
  # admins, Admin itself comes only by a decision.
  def check(:assign_roles, viewer, group, _facts) do
    ok = viewer.access.admin? and not group.is_direct

    cond do
      ok and group.elects_admins -> {true, :admin_but_elected}
      true -> admin_only(viewer, ok)
    end
  end

  # An admin changes the roles of the manifest in force once the group has a
  # manifest of its own, which an admin makes (`RolesTab`).
  def check(:change_roles, viewer, group, _facts) do
    ok = viewer.access.admin?
    own? = match?(%{group_id: id} when id == group.id, viewer.access.manifest)

    cond do
      ok and not own? -> {true, :admin_after_own_manifest}
      true -> admin_only(viewer, ok)
    end
  end

  def check(:propose_decisions, viewer, group, _facts) do
    ok = Effects.may_propose?(viewer.access, group)

    cond do
      viewer.kind == :guest -> {false, :guest}
      not viewer.access.member? -> {false, :members_only}
      not Effects.group_allowed?(group) -> {ok, :not_here}
      group.elects_admins -> by(viewer, :create_polls, ok)
      true -> admin_only(viewer, ok)
    end
  end

  def check(:see_subgroups, viewer, group, _facts) do
    ok =
      group
      |> GroupMenu.sections(viewer.access.member?, %{calendar?: false, polls?: false})
      |> Enum.any?(&(&1.key == "subgroups"))

    cond do
      viewer.kind == :guest -> {false, :guest}
      true -> verdict(ok, seen_reason(viewer), :private)
    end
  end

  def check(:create_subgroups, viewer, _group, _facts),
    do: by(viewer, :create_subgroups, Access.can?(viewer.access, :create_subgroups))

  def check(:files_tab, viewer, group, _facts) do
    ok = PageRules.files?(group, viewer.access)
    if viewer.kind == :guest, do: {false, :guest}, else: verdict(ok, :member, :members_only)
  end

  # As `Social.get_attachment_for_download/2`: members, and anyone signed in
  # where the chat is open.
  def check(:download, %{kind: :guest}, _group, _facts), do: {false, :guest}

  def check(:download, viewer, group, _facts) do
    ok = Access.can_read_chat?(viewer.access, group)

    if viewer.access.member?,
      do: {ok, :member},
      else: verdict(ok, :open_chat_files, :members_only)
  end

  def check(:calendar, %{kind: :guest}, _group, _facts), do: {false, :guest}

  def check(:calendar, viewer, group, facts) do
    ok = PageRules.calendar?(group, viewer.access, facts)

    cond do
      viewer.access.member? -> {ok, :member}
      group.is_public -> verdict(ok, :public_events, :no_public_events)
      true -> {ok, :private}
    end
  end

  def check(:create_events, viewer, group, _facts),
    do: by(viewer, :create_events, Events.can_create?(viewer.access, group))

  def check(:manage_events, viewer, _group, _facts),
    do:
      by(
        viewer,
        :manage_events,
        viewer.access.member? and Access.can?(viewer.access, :manage_events)
      )

  def check(:publish_events, viewer, group, _facts),
    do: by(viewer, :publish_events, Events.can_publish?(viewer.access, group), :not_here)

  def check(:polls, %{kind: :guest}, _group, _facts), do: {false, :guest}

  def check(:polls, viewer, group, facts) do
    ok = PageRules.polls_tab?(group, viewer.access, facts)

    cond do
      viewer.access.member? -> {ok, :member}
      group.is_public -> verdict(ok, :public_polls, :no_public_polls)
      true -> {ok, :private}
    end
  end

  def check(:create_polls, viewer, group, _facts),
    do: by(viewer, :create_polls, Rules.can_create?(viewer.access, group))

  # A poll that every member may vote in, open to non-members too: each poll
  # may narrow it further by its own rules.
  def check(:vote, viewer, group, _facts) do
    poll = %Poll{voter_role_keys: [GroupRole.everyone_key()], is_public: true}
    ok = is_nil(Rules.vote_block(poll, group, viewer.access, viewer.profile, DateTime.utc_now()))

    cond do
      viewer.kind == :member -> by(viewer, :vote_polls, ok)
      true -> outsider_reason(viewer, group, :vote_polls, ok, Group.guest_preview?(group))
    end
  end

  def check(:manage_polls, viewer, _group, _facts),
    do:
      by(
        viewer,
        :manage_polls,
        viewer.access.member? and Access.can?(viewer.access, :manage_polls)
      )

  def check(:publish_polls, viewer, group, _facts),
    do: by(viewer, :publish_polls, Rules.can_publish?(viewer.access, group), :not_public)

  def check(:send_notices, viewer, group, _facts),
    do: by(viewer, :send_notices, Notices.can_send?(viewer.access, group), :not_here)

  def check(:processes, viewer, group, facts) do
    ok = PageRules.processes?(group, viewer.access, facts)

    cond do
      viewer.kind == :guest -> {false, :guest}
      not viewer.access.member? -> {false, :members_only}
      ValueRules.manage?(viewer.access) -> by(viewer, :edit_group, ok)
      true -> verdict(ok, :has_apps, :no_apps)
    end
  end

  def check(:draw_processes, viewer, _group, _facts),
    do: by(viewer, :edit_group, ValueRules.manage?(viewer.access))

  # The verdict with the reason that points its way.
  defp verdict(true, yes, _no), do: {true, yes}
  defp verdict(false, _yes, no), do: {false, no}

  defp seen_reason(%{access: %Access{member?: true}}), do: :member
  defp seen_reason(_viewer), do: :public

  # A permission's verdict, told by the roles that give or deny it. When the
  # verdict turns on something besides the permission, `otherwise` says what.
  defp by(viewer, permission, ok, otherwise \\ :not_here) do
    cond do
      viewer.kind == :guest ->
        {false, :guest}

      not viewer.access.member? ->
        {false, :members_only}

      true ->
        case Access.explain(viewer.access, permission) do
          {^ok, why} -> {ok, {:explain, why}}
          {_other, _why} -> {ok, otherwise}
        end
    end
  end

  defp admin_only(viewer, ok) do
    cond do
      viewer.kind == :guest -> {false, :guest}
      not viewer.access.member? -> {false, :members_only}
      true -> verdict(ok, {:explain, :admin}, :admin_only)
    end
  end

  # Writing and reacting in the chat: members by their roles, others only in
  # an open chat, as far as Everyone allows.
  defp chat_check(viewer, group, permission, ok) do
    cond do
      viewer.kind == :guest -> {false, :guest}
      viewer.access.member? -> by(viewer, permission, ok)
      true -> outsider_reason(viewer, group, permission, ok, Group.open_chat?(group))
    end
  end

  # Someone outside the group: blocked, outside what is open to them, or as
  # far as Everyone allows.
  defp outsider_reason(viewer, group, permission, ok, open?) do
    cond do
      viewer.access.blocked? -> {ok, :blocked}
      not group.is_public -> {ok, :private}
      not open? -> {ok, :members_only}
      true -> verdict(ok, {:everyone, permission}, {:everyone_not, permission})
    end
  end

  @doc "Whether a reason speaks for the verdict (true) or against it (false)."
  def positive?({:explain, :admin}), do: true
  def positive?({:explain, {:allowed_by, _keys}}), do: true
  def positive?({:explain, _why}), do: false
  def positive?({:everyone, _permission}), do: true
  def positive?({:everyone_not, _permission}), do: false

  def positive?(reason)
      when reason in [
             :member,
             :public,
             :guest_preview,
             :guest_description,
             :open_chat,
             :open_chat_files,
             :asks_roles,
             :can_ask_to_join,
             :admin_but_elected,
             :admin_after_own_manifest,
             :public_events,
             :public_polls,
             :has_apps
           ],
      do: true

  def positive?(_reason), do: false

  ## Reasons in words

  @doc "Why, in a short sentence, with the names of the roles under `manifest`."
  def reason_text({:explain, :admin}, _manifest), do: gettext("Admin holds every permission.")

  def reason_text({:explain, {:allowed_by, keys}}, manifest),
    do: gettext("Allowed by %{roles}.", roles: role_names(keys, manifest))

  def reason_text({:explain, {:denied_by, deny, []}}, manifest),
    do: gettext("Denied by %{roles}.", roles: role_names(deny, manifest))

  def reason_text({:explain, {:denied_by, deny, allow}}, manifest) do
    gettext("Denied by %{roles}, and a denial wins over %{allowing}.",
      roles: role_names(deny, manifest),
      allowing: role_names(allow, manifest)
    )
  end

  def reason_text({:explain, :not_allowed}, _manifest),
    do: gettext("No role it holds allows it.")

  def reason_text({:explain, :not_member}, _manifest), do: gettext("Only members hold roles.")

  def reason_text({:everyone, _permission}, _manifest),
    do: gettext("It is open to non-members, as far as Everyone allows it.")

  def reason_text({:everyone_not, _permission}, _manifest),
    do: gettext("It is open to non-members, but Everyone does not allow it.")

  def reason_text(:member, _manifest), do: gettext("Every member does.")
  def reason_text(:public, _manifest), do: gettext("The group is public.")
  def reason_text(:private, _manifest), do: gettext("The group is private.")
  def reason_text(:members_only, _manifest), do: gettext("Only members.")
  def reason_text(:guest, _manifest), do: gettext("A guest has no profile, so no permissions.")
  def reason_text(:guest_preview, _manifest), do: gettext("Guests see a public group's card.")
  def reason_text(:no_guest_preview, _manifest), do: gettext("Guests see only public groups.")

  def reason_text(:guest_description, _manifest),
    do: gettext("The group opened its description to guests.")

  def reason_text(:no_guest_description, _manifest),
    do: gettext("Guests see the card and the start of the description.")

  def reason_text(:open_chat, _manifest), do: gettext("The chat is open to non-members.")

  def reason_text(:open_chat_files, _manifest),
    do: gettext("Only the files of the open chat's messages.")

  def reason_text(:blocked, _manifest), do: gettext("The profile is blocked in the group.")
  def reason_text(:admin_only, _manifest), do: gettext("Only an admin.")

  def reason_text(:admin_but_elected, _manifest),
    do: gettext("Every role but Admin, which only a decision of a poll gives and takes.")

  def reason_text(:admin_after_own_manifest, _manifest),
    do: gettext("Once the group has a manifest of its own, which an admin makes.")

  def reason_text(:not_here, _manifest), do: gettext("Not in this group.")
  def reason_text(:not_public, _manifest), do: gettext("Only in a public group.")
  def reason_text(:storage_off, _manifest), do: gettext("Files are switched off on this server.")

  def reason_text(:asks_roles, _manifest),
    do: gettext("The statute lets some roles be asked for.")

  def reason_text(:nothing_to_ask, _manifest),
    do: gettext("No role can be asked for that it does not hold.")

  def reason_text(:can_ask_to_join, _manifest),
    do: gettext("Anyone may ask to join a public group.")

  def reason_text(:public_events, _manifest), do: gettext("Only the public events.")
  def reason_text(:no_public_events, _manifest), do: gettext("The group has no public events.")
  def reason_text(:public_polls, _manifest), do: gettext("Only the public polls.")
  def reason_text(:no_public_polls, _manifest), do: gettext("The group has no public polls.")
  def reason_text(:has_apps, _manifest), do: gettext("The group has an app or a process.")
  def reason_text(:no_apps, _manifest), do: gettext("The group has no app or process yet.")

  defp role_names(keys, manifest) do
    manifest.roles
    |> Enum.filter(&(&1.key in keys))
    |> Enum.map_join(", ", &RolesTab.role_label/1)
  end

  ## The statute

  @doc """
  How each role but Everyone is had in `group`, as the statute says
  (`GroupRequests.mode/2`): `[%{role, mode, label, text}]`.
  """
  def statute(manifest, %Group{} = group) do
    for role <- manifest.roles, role.key != GroupRole.everyone_key() do
      mode = GroupRequests.mode(role, group)

      %{
        role: role,
        mode: mode,
        label: RequestRules.mode_label(:role, mode),
        text: RequestRules.rule_text(:role, mode, role.request_poll)
      }
    end
  end

  ## What the tab draws

  @doc "One viewer's capabilities by area: `[{area, [%{key, ok, reason}]}]`."
  def rows(viewer, group, facts) do
    for {area, keys} <- @areas do
      {area,
       for key <- keys do
         {ok, reason} = check(key, viewer, group, facts)
         %{key: key, ok: ok, reason: reason}
       end}
    end
  end

  @doc """
  The verdicts of every column for each capability:
  `[{area, [%{key, cells: [{ok, reason}]}]}]`, the cells in the order of
  `columns`.
  """
  def table(columns, manifest, group, facts) do
    viewers = Enum.map(columns, &viewer(manifest, &1.spec))

    for {area, keys} <- @areas do
      {area,
       for key <- keys do
         %{key: key, cells: Enum.map(viewers, &check(key, &1, group, facts))}
       end}
    end
  end

  @doc """
  Who holds Admin and each of `strong_permissions/0`: `[%{key, count,
  roles}]`. The people are counted from `AccessOverview.role_sets/1`, each set
  of roles worked out once by the same rules as anyone's access, so a role
  that denies is counted as it works; `roles` are those that give it.
  """
  def power(manifest, role_sets) do
    admin_roles = Enum.filter(manifest.roles, &(&1.key == GroupRole.admin_key()))

    [
      %{key: :admin, count: holders(manifest, role_sets, & &1.admin?), roles: admin_roles}
      | for permission <- strong_permissions() do
          %{
            key: permission,
            count: holders(manifest, role_sets, &Access.can?(&1, permission)),
            roles:
              Enum.filter(
                manifest.roles,
                &(&1.key == GroupRole.admin_key() or permission in &1.allowed)
              )
          }
        end
    ]
  end

  @doc "How many people the role sets of `role_sets` hold `spec` covers: those it would make, by their roles."
  def holders(manifest, role_sets, fun) when is_function(fun, 1) do
    role_sets
    |> Enum.filter(&fun.(Access.from_facts(manifest, {:member, &1.keys})))
    |> Enum.map(& &1.count)
    |> Enum.sum()
  end

  @doc """
  What the viewer would see of the group: the sections of its bar, which
  descriptions, which of the sub-groups the overview lists they would be in,
  where they vote and see results, what they write and read in the apps, and
  how many runs of processes wait on their roles. `overview` is
  `AccessOverview.load/3`; `facts` also hold `notices?`, whether the group has
  notices.
  """
  def sees(viewer, %Group{} = group, facts, overview) do
    access = viewer.access
    now = DateTime.utc_now()

    %{
      sections: sections(viewer, group, facts),
      alts: Enum.filter(overview.alts, &sees_alt?(viewer, group, &1)),
      children: in_children(viewer, overview.children.entries),
      polls:
        for poll <- overview.polls do
          %{
            poll: poll,
            vote: is_nil(Rules.vote_block(poll, group, access, viewer.profile, now)),
            results: Rules.results?(poll, group, access, viewer.profile, true, now)
          }
        end,
      collections:
        for app <- overview.apps, {collection, rule} <- Enum.sort(app.rules) do
          %{
            alt_id: app.alt_id,
            collection: collection,
            write: is_nil(ValueRules.write_block(rule, group, access, viewer.profile, now)),
            read_all: ValueRules.full_reader?(rule, access),
            summary: ValueRules.summary_reader?(rule, group, access)
          }
        end,
      waiting:
        if(access.member?,
          do: access.role_keys |> Enum.map(&Map.get(overview.waiting, &1, 0)) |> Enum.sum(),
          else: 0
        )
    }
  end

  defp sections(%{kind: :guest}, _group, _facts), do: []

  defp sections(viewer, group, facts) do
    GroupMenu.sections(group, viewer.access.member?, %{
      calendar?: PageRules.calendar?(group, viewer.access, facts),
      polls?: PageRules.polls_section?(group, viewer.access, facts),
      notices?: Map.get(facts, :notices?, false)
    })
  end

  defp sees_alt?(%{kind: :guest}, group, alt),
    do: Group.guest_description?(group) and alt.for_guests

  defp sees_alt?(viewer, group, alt),
    do:
      PageRules.sees_group?(group, viewer.access) and
        Access.sees_alt_description?(viewer.access, alt)

  # A member comes into a sub-group that inherits the parent's members, all of
  # them or those who hold a picked role; anyone who sees a public one sees it.
  defp in_children(%{kind: :member, access: access}, entries) do
    for child <- entries,
        child.inherits_members,
        child.inherit_role_keys in [nil, []] or
          Enum.any?(child.inherit_role_keys, &(&1 in access.role_keys)),
        do: child
  end

  defp in_children(_viewer, _entries), do: []
end
