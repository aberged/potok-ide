defmodule PotokIde.Social do
  @moduledoc """
  Social domain context.

  Owns Profiles, Groups, Values, and the relationships between them.
  """

  import Ecto.Query, warn: false
  require Logger

  alias Ecto.Multi
  alias PotokIde.CountMark
  alias PotokIde.History
  alias PotokIde.LinkPreviews
  alias PotokIde.Notices
  alias PotokIde.Presence
  alias PotokIde.Processes.Engine
  alias PotokIde.Polls
  alias PotokIde.Polls.Poll
  alias PotokIde.PushNotifications.Dispatch
  alias PotokIde.Repo
  alias PotokIde.Storage

  alias PotokIde.Accounts
  alias PotokIde.Accounts.Account
  alias PotokIde.Accounts.PushSubscription

  alias PotokIde.Social.{
    AccessHistory,
    Access,
    AccountProfile,
    AppBuilds,
    AppData,
    AppProcesses,
    AppScope,
    Discovery,
    EmailInvitations,
    Group,
    GroupAccountInvitation,
    GroupAltDescription,
    GroupAreas,
    GroupBlock,
    GroupInvitation,
    GroupJoinRequestApproval,
    GroupJoinRequest,
    GroupManifest,
    GroupMemberRole,
    GroupMembership,
    GroupMutes,
    GroupPins,
    GroupPresets,
    GroupRequests,
    GroupReaction,
    GroupRole,
    GroupRoleRequest,
    GroupRoutes,
    GroupShortcut,
    GroupValueRead,
    MemberInheritance,
    MapSql,
    Mentions,
    NameSearch,
    Notifications,
    PinnedGroups,
    Profile,
    ProfileBlocks,
    ProfileDetails,
    ProfileInvitation,
    ScheduledValue,
    Value,
    ValueAggregate,
    ValueAttachment,
    ValuePreview,
    ValueReaction,
    ValueReports,
    Visibility
  }

  # Who looks at what an app shows: a profile, or nil for a guest, a visitor
  # without an account at a group that opened its description to guests, who
  # sees the public groups only (`Visibility.plain_groups/1`).
  defguardp is_viewer(viewer) when is_nil(viewer) or is_struct(viewer, Profile)

  # A guest reads the places of a map app only, the direct sub-groups of one
  # group (`:parent_id`), never the root's map, which follows a profile's
  # memberships and the groups it follows.
  defguardp is_map_viewer(viewer, filters)
            when is_struct(viewer, Profile) or
                   (is_nil(viewer) and is_map_key(filters, :parent_id) and
                      is_integer(:erlang.map_get(:parent_id, filters)))

  def subscribe_account(%Account{id: account_id}) when is_integer(account_id) do
    Phoenix.PubSub.subscribe(PotokIde.PubSub, account_topic(account_id))
  end

  def subscribe_profile(%Profile{id: profile_id}) when is_integer(profile_id) do
    Phoenix.PubSub.subscribe(PotokIde.PubSub, profile_topic(profile_id))
  end

  def unsubscribe_profile(%Profile{id: profile_id}) when is_integer(profile_id) do
    Phoenix.PubSub.unsubscribe(PotokIde.PubSub, profile_topic(profile_id))
  end

  def subscribe_group(%Group{id: group_id}) when is_integer(group_id) do
    Phoenix.PubSub.subscribe(PotokIde.PubSub, group_topic(group_id))
  end

  @doc """
  Subscribes the caller to what changes the unread values of a group's members:
  `{:group_value_unread, unread}` and `{:group_members_unread_changed, group_id}`.
  Pages subscribe to their profile's groups (`member_group_ids/1`), so a value
  takes one broadcast however many members the group has, and reaches only
  those who have a page open.
  """
  def subscribe_group_unread(group_id) when is_integer(group_id) do
    Phoenix.PubSub.subscribe(PotokIde.PubSub, group_unread_topic(group_id))
  end

  def unsubscribe_group_unread(group_id) when is_integer(group_id) do
    Phoenix.PubSub.unsubscribe(PotokIde.PubSub, group_unread_topic(group_id))
  end

  @doc """
  Subscribes the caller to `{:presence_changed, topic, key, online?}` for one
  profile in `group` and returns whether that profile is online there now.
  """
  def watch_group_presence(%Group{} = group, profile_id) when is_integer(profile_id) do
    topic = group_presence_topic(group)
    key = Integer.to_string(profile_id)
    # Subscribing first means a change between the two calls still arrives.
    :ok = Phoenix.PubSub.subscribe(PotokIde.PubSub, Presence.key_topic(topic, key))
    Presence.online?(topic, key)
  end

  def track_group_presence(pid, %Group{} = group, %Profile{} = profile) when is_pid(pid) do
    Presence.track(pid, group_presence_topic(group), Integer.to_string(profile.id), %{
      profile_id: profile.id,
      username: profile.username,
      online_at: System.system_time(:second)
    })
  end

  def untrack_group_presence(pid, %Group{} = group, %Profile{id: profile_id}) when is_pid(pid) do
    untrack_group_presence(pid, group, profile_id)
  end

  def untrack_group_presence(pid, %Group{} = group, profile_id)
      when is_pid(pid) and is_integer(profile_id) do
    Presence.untrack(pid, group_presence_topic(group), Integer.to_string(profile_id))
  end

  def list_online_profile_ids_for_group(%Group{} = group) do
    group
    |> group_presence_topic()
    |> Presence.list()
    |> Map.keys()
    |> Enum.reduce(MapSet.new(), fn key, acc ->
      case Integer.parse(key) do
        {profile_id, ""} -> MapSet.put(acc, profile_id)
        _ -> acc
      end
    end)
  end

  # ---------
  # Root group
  # ---------

  def get_root_group! do
    Repo.get_by!(Group, is_root: true)
  end

  @doc "The root group's id."
  def root_group_id do
    Repo.one!(from(g in Group, where: g.is_root, select: g.id))
  end

  # ---------
  # Profiles
  # ---------

  def get_profile(id), do: Repo.get(Profile, id)

  def get_profile!(id), do: Repo.get!(Profile, id)

  @doc """
  Loads the picture column (excluded from regular queries via `load_in_query: false`)
  into an already fetched profile or group.
  """
  def load_picture(%Profile{id: id} = profile) do
    url =
      from(p in Profile, where: p.id == ^id, select: p.profile_picture_url)
      |> Repo.one()

    %{profile | profile_picture_url: url}
  end

  def load_picture(%Group{id: id} = group) do
    url =
      from(g in Group, where: g.id == ^id, select: g.group_picture_url)
      |> Repo.one()

    %{group | group_picture_url: url}
  end

  def load_picture(nil), do: nil

  @doc """
  The group with its area or route (`Group.area`, `Group.route`) and the
  route's length, which regular queries leave out.
  """
  def load_area(%Group{id: id} = group) do
    {area, route, length} =
      from(g in Group, where: g.id == ^id, select: {g.area, g.route, g.route_length})
      |> Repo.one()

    %{group | area: area, route: route, route_length: length}
  end

  @doc "Minimal data needed to serve a profile avatar: `%{id, username, picture_url}` or nil."
  def get_profile_avatar_source(id) do
    from(p in Profile,
      where: p.id == ^id,
      # A deleted person keeps no initials of theirs: "?".
      select: %{
        id: p.id,
        name: fragment("CASE WHEN ? = 'deleted' THEN '' ELSE ? END", p.kind, p.username),
        picture_url: p.profile_picture_url
      }
    )
    |> Repo.one()
  end

  @doc """
  Minimal data needed to serve a group avatar: `%{id, name, picture_url,
  guest_preview?}` or nil. `guest_preview?` says whether guests see the group
  (`Group.guest_preview?/1`).
  """
  def get_group_avatar_source(id) do
    from(g in Group,
      where: g.id == ^id,
      select:
        struct(g, [
          :id,
          :name,
          :group_picture_url,
          :is_public,
          :is_root,
          :is_direct,
          :parent_value_id
        ])
    )
    |> Repo.one()
    |> case do
      nil ->
        nil

      group ->
        %{
          id: group.id,
          name: group.name,
          picture_url: group.group_picture_url,
          guest_preview?: Group.guest_preview?(group)
        }
    end
  end

  @doc "A hash of the group's picture, nil without one. Does not load the picture."
  def group_picture_hash(id) when is_integer(id) do
    from(g in Group,
      where: g.id == ^id and g.group_picture_url != "",
      select: fragment("md5(?)", g.group_picture_url)
    )
    |> Repo.one()
  end

  def create_profile(attrs) do
    root_group = get_root_group!()

    Multi.new()
    |> Multi.insert(:profile, Profile.changeset(%Profile{}, attrs))
    |> Multi.insert(:root_membership, fn %{profile: profile} ->
      GroupMembership.changeset(%GroupMembership{}, %{
        group_id: root_group.id,
        profile_id: profile.id
      })
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{profile: profile}} -> {:ok, profile}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  def create_profile_for_account(%Account{} = account, attrs) do
    root_group = get_root_group!()

    Multi.new()
    |> Multi.run(:account_already_has_profiles, fn repo, _changes ->
      {:ok,
       repo.exists?(
         from(account_profile in AccountProfile,
           where: account_profile.account_id == ^account.id,
           select: 1
         )
       )}
    end)
    |> Multi.insert(:profile, Profile.changeset(%Profile{}, attrs))
    |> Multi.insert(:account_profile, fn %{profile: profile} ->
      AccountProfile.changeset(%AccountProfile{}, %{
        account_id: account.id,
        profile_id: profile.id
      })
    end)
    |> Multi.insert(:root_membership, fn %{profile: profile} ->
      GroupMembership.changeset(%GroupMembership{}, %{
        group_id: root_group.id,
        profile_id: profile.id
      })
    end)
    |> Multi.run(:update_account_profiles, fn repo, %{profile: profile} ->
      changes =
        %{}
        |> maybe_put_profile_reference(
          :current_profile_id,
          account.current_profile_id,
          profile.id
        )
        |> maybe_put_profile_reference(
          :default_profile_id,
          account.default_profile_id,
          profile.id
        )

      if changes == %{} do
        {:ok, account}
      else
        account
        |> Ecto.Changeset.change(changes)
        |> repo.update()
      end
    end)
    |> Multi.run(:initial_direct_group, fn repo,
                                           %{
                                             profile: profile,
                                             account_already_has_profiles: already_has_profiles
                                           } ->
      maybe_create_initial_direct_group(repo, root_group, account, profile, already_has_profiles)
    end)
    |> Repo.transaction()
    |> case do
      {:ok,
       %{
         profile: profile,
         update_account_profiles: updated_account,
         initial_direct_group: initial_direct_group
       }} ->
        broadcast_initial_direct_group(initial_direct_group, root_group, account)
        broadcast_account_profiles_updated(updated_account)
        {:ok, profile}

      {:ok, %{profile: profile, initial_direct_group: initial_direct_group}} ->
        broadcast_initial_direct_group(initial_direct_group, root_group, account)
        broadcast_account_profiles_updated(account)
        {:ok, profile}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc "Whether the account has a profile, its own or one shared with it."
  def account_has_profiles?(%Account{} = account) do
    Repo.exists?(
      from(account_profile in AccountProfile,
        where: account_profile.account_id == ^account.id,
        select: 1
      )
    )
  end

  @doc """
  The oldest invitation still waiting for an account that has no profile yet,
  with its group and inviter, or nil. Only the first invitation to an address
  sends an email, so this is the one the email told of.
  """
  def first_pending_account_invitation(%Account{} = account) do
    account |> pending_group_account_invitations_query() |> limit(1) |> Repo.one()
  end

  @doc """
  Creates the account's first profile from an invitation's link and takes it
  into the group of `first_pending_account_invitation/1`, as the button that
  creates it says (`EmailInvitations.accept/3`). Any other invitation waits
  for the account on Invitations.

  Returns `{:ok, profile, group}`, where the group is nil when there was no
  invitation or it no longer holds, or `{:error, changeset}`.
  """
  def create_profile_from_invitation(%Account{} = account, attrs) do
    invitation = first_pending_account_invitation(account)

    with {:ok, profile} <- create_profile_for_account(account, attrs) do
      {:ok, profile, join_invited_group(account, profile, invitation)}
    end
  end

  defp join_invited_group(_account, _profile, nil), do: nil

  defp join_invited_group(account, profile, %GroupAccountInvitation{} = invitation) do
    case EmailInvitations.accept(account, invitation, profile) do
      {:ok, group} -> group
      {:error, _gone_or_refused} -> nil
    end
  end

  @doc """
  Saves the profile's form for an account that holds it. `details`, when
  given, are its details as the form sends them, by key
  (`PotokIde.Social.ProfileDetails.changesets/4`), saved with it. Returns
  `{:error, changeset}` for the profile's own fields and
  `{:error, {:details, changesets}}` when only a detail is wrong.
  """
  def update_profile_for_account(%Account{} = account, profile_id, attrs, details \\ nil)
      when is_integer(profile_id) do
    case get_profile_for_account(account, profile_id) do
      nil ->
        {:error, :not_found}

      profile ->
        allowed = ProfileDetails.allowed_group_ids(profile)

        changeset =
          profile
          |> load_picture()
          |> Profile.changeset(attrs, allowed_group_ids: allowed)
          |> keep_shared_while_held()

        detail_changesets =
          details &&
            ProfileDetails.changesets(
              profile,
              ProfileDetails.list_fields(profile),
              details,
              allowed
            )

        cond do
          not changeset.valid? ->
            {:error, Map.put(changeset, :action, :update)}

          detail_changesets && not ProfileDetails.valid?(detail_changesets) ->
            {:error, {:details, detail_changesets}}

          true ->
            Repo.transaction(fn ->
              case Repo.update(changeset) do
                {:ok, updated} ->
                  if detail_changesets, do: ProfileDetails.save!(Repo, detail_changesets)
                  updated

                {:error, changeset} ->
                  Repo.rollback(changeset)
              end
            end)
            |> case do
              {:ok, updated_profile} = ok ->
                broadcast_account_profiles_updated(account)
                broadcast_profile_updated(updated_profile)
                ok

              error ->
                error
            end
        end
    end
  end

  # A profile several accounts hold stays shared: as a unique one each of
  # them would vote through it on their own account (`Identity`).
  defp keep_shared_while_held(%Ecto.Changeset{} = changeset) do
    with :unique <- Ecto.Changeset.get_change(changeset, :sharing),
         holders when holders > 1 <-
           Repo.aggregate(
             from(ap in AccountProfile, where: ap.profile_id == ^changeset.data.id),
             :count
           ) do
      Ecto.Changeset.add_error(changeset, :sharing, "is held by several accounts")
    else
      _ -> changeset
    end
  end

  def add_profile_to_account(%Profile{} = profile, %Account{} = account) do
    case link_profile_to_account(Repo, profile, account) do
      {:ok, %AccountProfile{}} = ok ->
        broadcast_account_profiles_updated(account)
        ok

      other ->
        other
    end
  end

  def invite_profile_to_profile(
        %Account{} = inviter_account,
        %Profile{} = inviter,
        %Profile{} = profile,
        %Profile{} = invitee
      ) do
    cond do
      profile.sharing != :shared ->
        {:error, :profile_not_shared}

      is_nil(get_profile_for_account(inviter_account, profile.id)) ->
        {:error, :inviter_not_linked}

      inviter.id == invitee.id ->
        {:error, :cannot_invite_self}

      true ->
        %ProfileInvitation{}
        |> ProfileInvitation.changeset(%{
          profile_id: profile.id,
          inviter_id: inviter.id,
          invitee_id: invitee.id
        })
        |> Repo.insert()
        |> case do
          {:ok, _invitation} = ok ->
            broadcast_profile_share_invitations_updated(invitee)
            broadcast_pending_invitations_count_updated(invitee)
            notify_profile_invitee_of_shared_profile_invitation(inviter, profile, invitee)
            ok

          error ->
            error
        end
    end
  end

  def accept_profile_invitation(
        %ProfileInvitation{} = invitation,
        %Profile{} = invitee,
        %Account{} = invitee_account
      ) do
    invitation = Repo.preload(invitation, [:profile, :inviter])

    if invitation.invitee_id != invitee.id do
      {:error, :invitee_mismatch}
    else
      Multi.new()
      |> Multi.update(:invitation, ProfileInvitation.accept_changeset(invitation))
      |> Multi.run(:account_profile, fn repo, _changes ->
        link_profile_to_account(repo, invitation.profile, invitee_account)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{invitation: accepted_invitation}} ->
          broadcast_profile_share_invitations_updated(invitee)
          broadcast_pending_invitations_count_updated(invitee)
          broadcast_account_profiles_updated(invitee_account)

          notify_profile_inviter_of_shared_profile_acceptance(
            invitation,
            invitee,
            invitee_account
          )

          {:ok, accepted_invitation}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  # ---------
  # Groups
  # ---------

  def get_group!(id) do
    Group
    |> Repo.get!(id)
    |> maybe_preload_group_members()
  end

  @doc """
  The group when `profile` can see it: a member, or anyone for a public group.
  A guest (nil) sees the groups it gets a preview of (`get_public_group/1`).
  """
  def get_visible_group(nil, id) when is_integer(id), do: get_public_group(id)

  def get_visible_group(%Profile{} = profile, id) when is_integer(id) do
    case Repo.get(Group, id) do
      %Group{} = group -> if group.is_public or member_of_group?(profile, group), do: group
      nil -> nil
    end
  end

  @doc """
  The group when guests can see a preview of it (`PotokIdeWeb.PublicPreview`):
  a public one, but never the root, a direct chat or a thread.
  """
  def get_public_group(id) when is_integer(id) do
    group = Repo.get(Group, id)

    if group && Group.guest_preview?(group), do: group
  end

  @doc """
  The group a link in a value names, whoever may see it, for a card that the
  page then shows only to those who may (`PotokIdeWeb.FormLinks`): never the
  root, a direct chat or a thread.
  """
  def get_linked_group(id) when is_integer(id) do
    case Repo.get(Group, id) do
      %Group{is_root: false, is_direct: false, parent_value_id: nil} = group -> group
      _other -> nil
    end
  end

  @doc "Which of `group_ids` `profile` is a member of, inherited or not, as a MapSet."
  def member_group_ids_among(%Profile{id: profile_id}, group_ids) when is_list(group_ids) do
    from(gm in GroupMembership,
      where: gm.profile_id == ^profile_id and gm.group_id in ^group_ids,
      select: gm.group_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  def member_group_ids_among(_profile, _group_ids), do: MapSet.new()

  def create_group(%Profile{} = creator, %Group{} = parent, attrs) do
    with {:ok, attrs} <- checked_group_attrs(creator, parent, Map.new(attrs)),
         {:ok, group} <- insert_group_with_creator(creator, parent, attrs) do
      start_subgroup_processes(group, parent, creator)
      {:ok, group}
    end
  end

  # A sub-group made one at a time starts the processes drawn in its parent
  # on new sub-groups (`Processes.Engine.start_on_subgroup/3`); records,
  # threads, an app's file groups and a process's sub-groups never come here.
  defp start_subgroup_processes(group, parent, creator) do
    {:ok, started} = Repo.transaction(fn -> Engine.start_on_subgroup(group, parent, creator) end)
    if started != [], do: PotokIde.Processes.Scheduler.nudge()
    started
  end

  @doc """
  Creates a group from a preset of `GroupPresets` with all that goes with it,
  or nothing at all. `choices` are what the viewer picked. Returns the group
  and, for a feed, the `.feed` below it, which is where its author writes.

  Nobody hears of a group before it all stands, so the news goes out last.

  `place` puts the group on a map at once (`"latitude"`, `"longitude"` and
  `"pin_icon"`), as a map app does when someone adds a place there.

  The group starts with its kind's picture (`GroupPresets.picture/1`), unless
  `opts` has `picture: false`.

  A preset `parent` does not offer (`GroupPresets.allowed?/2`) gives
  `{:error, :preset_not_allowed}`.
  """
  def create_group_from_preset(
        %Profile{} = creator,
        %Group{} = parent,
        preset,
        choices,
        place \\ %{},
        opts \\ []
      ) do
    if GroupPresets.allowed?(preset, parent),
      do: insert_from_preset(creator, parent, preset, choices, place, opts),
      else: {:error, :preset_not_allowed}
  end

  defp insert_from_preset(creator, parent, preset, choices, place, opts) do
    attrs =
      preset
      |> GroupPresets.attrs(choices, picture: Keyword.get(opts, :picture, true))
      |> Map.merge(Map.take(place, ["latitude", "longitude", "pin_icon"]))

    Repo.transaction(fn ->
      with {:ok, group, created} <-
             insert_preset_group(
               creator,
               parent,
               attrs,
               [],
               GroupPresets.preset(preset)
             ),
           {:ok, feed, feed_created} <- insert_preset_feed(creator, group, preset) do
        # An import (`opts[:processes]` false) starts none.
        started =
          if Keyword.get(opts, :processes, true),
            do: Engine.start_on_subgroup(group, parent, creator),
            else: []

        {group, feed, created ++ feed_created, started}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {group, feed, created, started}} ->
        Enum.each(created, fn {parent, group, changes} ->
          broadcast_group_created(creator, parent, group, changes)
        end)

        if started != [], do: PotokIde.Processes.Scheduler.nudge()
        {:ok, %{group: group, feed: feed}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Makes groups under `parent` the way a preset does, with `taken` permissions
  taken from `everyone` in a manifest of each one's own, and runs `fun` with
  them in the same transaction: what an app needs to keep its files
  (`PotokIde.Social.AppFiles`). Returns `{:ok, fun's result}`.
  """
  def create_groups_quietly(%Profile{} = creator, %Group{} = parent, attrs_list, taken, fun)
      when is_list(attrs_list) and is_function(fun, 1) do
    Repo.transaction(fn ->
      made =
        Enum.map(attrs_list, fn attrs ->
          case insert_preset_group(creator, parent, attrs, taken) do
            {:ok, group, created} -> {group, created}
            {:error, reason} -> Repo.rollback(reason)
          end
        end)

      {fun.(Enum.map(made, &elem(&1, 0))), Enum.flat_map(made, &elem(&1, 1))}
    end)
    |> case do
      {:ok, {result, created}} ->
        Enum.each(created, fn {parent, group, changes} ->
          broadcast_group_created(creator, parent, group, changes)
        end)

        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Makes a sub-group of `parent` where only its editors add groups, as a site
  keeps its sections (`AppApi`, `create_child` with `editors_only`): in a
  manifest of its own, `everyone` loses `create_subgroups`, as in a feed's
  `.feed`, and every role that may edit the group (`edit_group`) gets it,
  unless that role denies it outright. Without the second step an editor who
  is not an admin could not write there. All of it or nothing.

  The manifest is a copy: a role added above later reaches the group only
  when an admin adds it there too.
  """
  def create_editors_only_group(%Profile{} = creator, %Group{} = parent, attrs) do
    Repo.transaction(fn ->
      with {:ok, group, created} <-
             insert_preset_group(
               creator,
               parent,
               Map.new(attrs),
               GroupPresets.taken_from_everyone_in_feed()
             ),
           :ok <- give_editors(creator, group, :create_subgroups) do
        {group, created}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, {group, created}} ->
        Enum.each(created, fn {parent, group, changes} ->
          broadcast_group_created(creator, parent, group, changes)
        end)

        {:ok, group}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The group's manifest is its own by now (`take_from_everyone/3`).
  defp give_editors(%Profile{} = creator, %Group{} = group, permission) do
    group
    |> Access.effective_manifest()
    |> Map.fetch!(:roles)
    |> Enum.filter(fn role ->
      role.key not in [GroupRole.admin_key(), GroupRole.everyone_key()] and
        :edit_group in role.allowed and permission not in role.allowed and
        permission not in role.denied
    end)
    |> Enum.reduce_while(:ok, fn role, :ok ->
      case set_group_role_permission(creator, group, role.key, permission, :allow) do
        {:ok, _role} -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  @doc """
  Makes `children` under `parent` in one transaction, all or none: what an app
  brings in by the hundred (`AppApi`, `create_children`). Each child is attrs
  as for `create_group/3`, with an optional `"external_key"`, the app's own
  key, unique under `parent` and set once. A child whose key `parent` holds
  already is not made again, so a list sent twice makes no duplicates.

  Returns `{:ok, [%{id, key, created?}]}` in the order given, `{:error,
  {:invalid, index, changeset}}` for the first child that cannot be saved,
  `{:error, :conflict}` when another call took a key in between, or the
  refusal of `create_group/3`, checked once for all.

  Pages hear of it once, with one `child_group_changed` for the parent. The
  creator's pages do not hear of the memberships in groups with a key:
  records are not followed for unread (`member_group_ids/1`), and a message
  for each of thousands would hold up the very page that brings them in.
  """
  def create_children(%Profile{} = creator, %Group{} = parent, children)
      when is_list(children) do
    with {:ok, base} <- checked_group_attrs(creator, parent, %{}) do
      keys = for %{"external_key" => key} when is_binary(key) <- children, do: key

      Repo.transaction(fn ->
        existing = existing_child_keys(parent.id, keys)

        children
        |> Enum.with_index()
        |> Enum.map(fn {attrs, index} ->
          key = Map.get(attrs, "external_key")

          case existing do
            %{^key => id} when is_binary(key) ->
              {%{id: id, key: key, created?: false}, nil}

            _new ->
              attrs = attrs |> Map.delete("external_key") |> Map.merge(base)
              insert_child_quietly(creator, parent, attrs, key, index)
          end
        end)
      end)
      |> case do
        {:ok, rows} ->
          broadcast_children_created(creator, parent, for({_row, made} <- rows, made, do: made))
          {:ok, Enum.map(rows, &elem(&1, 0))}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp existing_child_keys(_parent_id, []), do: %{}

  defp existing_child_keys(parent_id, keys) do
    from(g in Group,
      where: g.parent_id == ^parent_id and g.external_key in ^Enum.uniq(keys),
      select: {g.external_key, g.id}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp insert_child_quietly(creator, parent, attrs, key, index) do
    case insert_group_quietly(creator, parent, attrs, nil, key) do
      {:ok, group, changes} ->
        {%{id: group.id, key: key, created?: true}, {group, changes}}

      {:error, %Ecto.Changeset{} = changeset} ->
        if external_key_taken?(changeset),
          do: Repo.rollback(:conflict),
          else: Repo.rollback({:invalid, index, changeset})

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp external_key_taken?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {:external_key, {_message, opts}} -> opts[:constraint] == :unique
      _other -> false
    end)
  end

  # One message to the parent's pages for the whole call, and the creator's
  # memberships only for groups that are not records.
  defp broadcast_children_created(_creator, _parent, []), do: :ok

  defp broadcast_children_created(%Profile{} = creator, %Group{} = parent, made) do
    groups = Enum.map(made, &elem(&1, 0))

    broadcast_child_group_changed(
      parent.id,
      %Group{
        id: hd(groups).id,
        is_public: Enum.any?(groups, & &1.is_public),
        inherits_members: Enum.any?(groups, & &1.inherits_members),
        creator_id: creator.id
      },
      :created
    )

    for %Group{external_key: nil, id: id} <- groups,
        do: broadcast_group_membership_changed(creator.id, id, :added)

    made |> Enum.flat_map(&elem(&1, 1)) |> broadcast_inheritance_changes()
  end

  defp insert_preset_feed(%Profile{} = creator, %Group{} = group, "feed") do
    insert_preset_group(
      creator,
      group,
      GroupPresets.feed_attrs(group),
      GroupPresets.taken_from_everyone_in_feed()
    )
  end

  defp insert_preset_feed(_creator, _group, _preset), do: {:ok, nil, []}

  # `preset` is the one the group is made from, nil for what comes with it.
  defp insert_preset_group(%Profile{} = creator, %Group{} = parent, attrs, taken, preset \\ nil) do
    with {:ok, attrs} <- checked_group_attrs(creator, parent, attrs),
         {:ok, group, changes} <- insert_group_quietly(creator, parent, attrs, preset),
         :ok <- take_from_everyone(creator, group, taken) do
      {:ok, group, [{parent, group, changes}]}
    end
  end

  # In a manifest of the group's own, as the one it inherits is shared.
  defp take_from_everyone(_creator, _group, []), do: :ok

  defp take_from_everyone(%Profile{} = creator, %Group{} = group, permissions) do
    with {:ok, _manifest} <- create_own_group_manifest(creator, group) do
      Enum.reduce_while(permissions, :ok, fn permission, :ok ->
        case set_group_role_permission(
               creator,
               group,
               GroupRole.everyone_key(),
               permission,
               :neutral
             ) do
          {:ok, _role} -> {:cont, :ok}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
    end
  end

  defp checked_group_attrs(%Profile{} = creator, %Group{} = parent, attrs) do
    cond do
      not member_of_group?(creator, parent) ->
        {:error, :not_a_member_of_parent_group}

      not Access.can?(creator, parent, :create_subgroups) ->
        {:error, :not_permitted}

      # A thread group may only point at a chat value of its own parent.
      not chat_value_in_group?(Map.get(attrs, "parent_value_id"), parent.id) ->
        {:error, :invalid_parent_value}

      true ->
        {:ok,
         attrs
         |> Map.put("creator_id", creator.id)
         |> Map.put("parent_id", parent.id)
         |> Map.put_new("is_direct", false)
         |> Map.put_new("is_root", false)}
    end
  end

  @doc """
  Makes a sub-group for an app's process, inside the transaction of the step
  that does it (`PotokIde.Social.ProcessActions`). The process is a plain
  member and `admin_ids`, people, are the admins: a profile without an account
  cannot run a group. Returns `{:ok, group, announce}`: nobody hears of the
  group until the step commits and calls `announce`.
  """
  def insert_process_group(
        %Profile{kind: :process} = process,
        %Group{} = parent,
        attrs,
        admin_ids
      )
      when is_list(admin_ids) and admin_ids != [] do
    with {:ok, attrs} <- checked_group_attrs(process, parent, Map.new(attrs)),
         {:ok, group, changes} <-
           insert_group_quietly(process, parent, attrs, nil, nil, admins: admin_ids) do
      {:ok, group,
       fn ->
         broadcast_group_created(process, parent, group, changes)
         Enum.each(admin_ids, &broadcast_group_membership_changed(&1, group.id, :added))
       end}
    end
  end

  defp insert_group_with_creator(%Profile{} = creator, %Group{} = parent, attrs) do
    with {:ok, group, changes} <- insert_group_quietly(creator, parent, attrs) do
      broadcast_group_created(creator, parent, group, changes)
      {:ok, group}
    end
  end

  defp broadcast_group_created(%Profile{} = creator, %Group{} = parent, group, changes) do
    broadcast_child_group_changed(parent.id, group, :created)
    broadcast_group_membership_changed(creator.id, group.id, :added)
    broadcast_inheritance_changes(changes)
  end

  # A new group has no sub-groups yet, so only one that inherits has members to
  # take in (`MemberInheritance.sync/3`, which finds nothing for any other).
  # Asking anyway walks every inheriting group in the table: 12 ms a group
  # among 35,000 records, too slow for groups made by the hundred.
  defp inherit_new(repo, %Group{inherits_members: true, id: id}),
    do: MemberInheritance.sync(repo, id)

  defp inherit_new(_repo, %Group{}), do: []

  # The creator is a direct member and admin, unless `opts` name the `admins`
  # (`insert_process_group/4`); an inheriting group then gets the parent's
  # members. It tells nobody: `broadcast_group_created/4` follows. `key` is the
  # app's own (`create_children/3`), set once like `preset`.
  defp insert_group_quietly(
         %Profile{} = creator,
         %Group{} = parent,
         attrs,
         preset \\ nil,
         key \\ nil,
         opts \\ []
       ) do
    changeset =
      %Group{}
      |> Group.changeset(attrs)
      |> Ecto.Changeset.put_change(:preset, preset)
      |> Ecto.Changeset.put_change(:external_key, key)
      |> validate_inheritance_parent(parent.id)
      |> validate_inherit_role_keys(parent.id)

    Multi.new()
    |> Multi.insert(:group, changeset)
    |> Multi.insert(:membership, fn %{group: group} ->
      GroupMembership.changeset(%GroupMembership{}, %{
        group_id: group.id,
        profile_id: creator.id
      })
    end)
    |> insert_admins(creator, Keyword.get(opts, :admins))
    |> Multi.run(:inheritance, fn repo, %{group: group} -> {:ok, inherit_new(repo, group)} end)
    |> Repo.transaction()
    |> case do
      {:ok, %{group: group, inheritance: changes}} ->
        {:ok, group, changes}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  def get_or_create_direct_group(%Profile{id: profile_id}, %Profile{id: profile_id}) do
    {:error, :same_profile}
  end

  # Nobody writes to a process directly; its link is open to any id.
  def get_or_create_direct_group(%Profile{kind: kind}, %Profile{kind: other_kind})
      when :process in [kind, other_kind] do
    {:error, :process_profile}
  end

  # A deleted person is written to no more (`PotokIde.Accounts.Deletion`).
  def get_or_create_direct_group(%Profile{kind: kind}, %Profile{kind: other_kind})
      when :deleted in [kind, other_kind] do
    {:error, :deleted_profile}
  end

  def get_or_create_direct_group(%Profile{} = current_profile, %Profile{} = other_profile) do
    root_group = get_root_group!()

    case find_direct_group(Repo, root_group, current_profile, other_profile) do
      # A closed one too: what was written stays readable (`ProfileBlocks`).
      %Group{} = group ->
        {:ok, group}

      nil ->
        if ProfileBlocks.between?(current_profile.id, other_profile.id),
          do: {:error, :blocked},
          else: insert_direct_group(root_group, current_profile, other_profile)
    end
  end

  defp insert_direct_group(%Group{} = root_group, %Profile{} = current_profile, other_profile) do
    attrs = %{
      "name" => direct_group_name(current_profile, other_profile),
      "description" => "",
      "description_format" => :markdown,
      "home_page" => :chat,
      "has_public_chat" => true,
      "is_direct" => true,
      "is_public" => false,
      "creator_id" => current_profile.id,
      "parent_id" => root_group.id,
      "is_root" => false
    }

    Multi.new()
    |> Multi.insert(:group, Group.changeset(%Group{}, attrs))
    |> Multi.insert(:current_membership, fn %{group: group} ->
      GroupMembership.changeset(%GroupMembership{}, %{
        group_id: group.id,
        profile_id: current_profile.id
      })
    end)
    |> Multi.insert(:other_membership, fn %{group: group} ->
      GroupMembership.changeset(%GroupMembership{}, %{
        group_id: group.id,
        profile_id: other_profile.id
      })
    end)
    |> insert_admin_role(current_profile)
    |> Repo.transaction()
    |> case do
      # Only the two can see it: their pages count their unread values
      # again on the news of the membership, which also brings the chat
      # into their list. Every other page on the root used to reload.
      {:ok, %{group: group}} ->
        broadcast_group_membership_changed(current_profile.id, group.id, :added)
        broadcast_group_membership_changed(other_profile.id, group.id, :added)
        {:ok, group}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  def update_group(%Profile{} = editor, %Group{} = group, attrs) do
    if not Access.can?(editor, group, :edit_group) do
      {:error, :not_permitted}
    else
      changeset =
        group
        |> load_picture()
        |> load_area()
        |> Group.update_changeset(Map.new(attrs))
        |> validate_home_alt_description(group)
        |> validate_inheritance_parent(group.parent_id)
        |> validate_inherit_role_keys(group.parent_id)
        |> mark_published(group)
        |> GroupAreas.put_pin()
        |> GroupRoutes.put_pin()

      Multi.new()
      |> Multi.update(:group, changeset)
      |> Multi.run(:inheritance, fn repo, %{group: updated_group} ->
        {:ok, switch_inheritance(repo, editor, group, updated_group)}
      end)
      |> Multi.run(:history, fn repo, %{group: updated_group} ->
        {:ok, record_settings(repo, editor, group, updated_group, %{})}
      end)
      |> History.transaction(actor: editor)
      |> case do
        {:ok, %{group: updated_group, inheritance: changes}} ->
          broadcast_group_updated(updated_group)

          if updated_group.parent_id do
            broadcast_child_group_changed(updated_group.parent_id, updated_group, :updated)
          end

          broadcast_shortcut_parents(shortcut_parent_ids(group.id), updated_group, :updated)
          broadcast_inheritance_changes(changes)
          {:ok, updated_group}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  # The settings that let people in or out, as the access history keeps
  # them: one row for all that changed at once, with each old and new value.
  @access_settings [
    :is_public,
    :has_public_chat,
    :description_for_guests,
    :inherits_members,
    :inherit_role_keys
  ]

  defp record_settings(repo, editor, %Group{} = before, %Group{} = after_change, extra) do
    changed =
      for field <- @access_settings,
          Map.get(before, field) != Map.get(after_change, field),
          into: %{},
          do: {field, [Map.get(before, field), Map.get(after_change, field)]}

    if changed != %{} do
      AccessHistory.record!(repo, before.id, :settings_changed,
        actor: editor && editor.id,
        data: Map.merge(changed, extra)
      )
    end

    :ok
  end

  @doc """
  Whether admins of `group` come and go only by decisions of polls, read from
  the database, as a page may hold the group from before a switch.
  """
  def elects_admins?(%Group{id: group_id}) do
    Repo.exists?(from(g in Group, where: g.id == ^group_id and g.elects_admins))
  end

  @doc """
  Lets `group` elect its admins from now on: only an admin may, and the
  admins it has stay, for the time being, until an election that replaces the
  holders (`effect_replace`) or a decision takes the role from them. Switching
  it off takes a decision (`end_elections/2`), or the elected admins could
  keep their places by switching it off.
  """
  def set_elects_admins(%Profile{} = actor, %Group{} = group, true) do
    cond do
      group.is_root or group.is_direct or not is_nil(group.parent_value_id) ->
        {:error, :not_allowed}

      not Access.admin?(actor, group) ->
        {:error, :not_permitted}

      true ->
        {:ok, _} =
          History.transaction([actor: actor], fn ->
            {count, _rows} =
              Repo.update_all(from(g in Group, where: g.id == ^group.id and not g.elects_admins),
                set: [elects_admins: true, updated_at: DateTime.utc_now(:second)]
              )

            if count > 0, do: AccessHistory.record!(Repo, group, :elections_on, actor: actor.id)
          end)

        broadcast_group_updated(group)
        {:ok, %{group | elects_admins: true}}
    end
  end

  def set_elects_admins(%Profile{}, %Group{}, false), do: {:error, :elected_mode}

  @doc """
  Sets how a request to join `group` is decided (`Group.join_mode` and, for
  a mode that votes, its `join_poll`). It is the group's rule, so only an
  admin sets it, and never at the root, in a direct conversation or in a
  thread.
  """
  def set_join_rule(%Profile{} = actor, %Group{} = group, attrs) do
    cond do
      group.is_root or group.is_direct or not is_nil(group.parent_value_id) ->
        {:error, :not_allowed}

      not Access.admin?(actor, group) ->
        {:error, :not_permitted}

      true ->
        History.transaction([actor: actor], fn ->
          case group |> Group.join_changeset(attrs) |> Repo.update() do
            {:ok, updated} ->
              if updated.join_mode != group.join_mode or updated.join_poll != group.join_poll do
                AccessHistory.record!(Repo, group, :join_rule_set,
                  actor: actor.id,
                  data: %{from: group.join_mode, to: updated.join_mode}
                )
              end

              updated

            {:error, changeset} ->
              Repo.rollback(changeset)
          end
        end)
        |> case do
          {:ok, updated} ->
            broadcast_group_updated(updated)
            {:ok, updated}

          error ->
            error
        end
    end
  end

  @doc """
  Gives `group` back to the founders' rule, in the caller's transaction, as a
  decision of a poll does it (`PotokIde.Polls.Effects`). The admins it has
  stay. Returns `{:ok, announce}`.
  """
  def end_elections(repo, %Group{id: group_id}, poll_id \\ nil) do
    repo.update_all(from(g in Group, where: g.id == ^group_id),
      set: [elects_admins: false, updated_at: DateTime.utc_now(:second)]
    )

    AccessHistory.record!(repo, group_id, :elections_off, poll: poll_id)

    {:ok, fn -> broadcast_group_updated(group_id) end}
  end

  @doc """
  What `GroupPresets.change_plan/4` needs to know of `group` for `editor`.
  Reads its parent, its alternative descriptions and a sub-group or two.
  """
  def group_kind_facts(%Profile{} = editor, %Group{} = group) do
    parent = group.parent_id && Repo.get(Group, group.parent_id)
    feed_name = GroupPresets.feed_group_name()

    %{
      parent: parent,
      alt_names:
        Repo.all(
          from(d in GroupAltDescription,
            where: d.group_id == ^group.id,
            select: fragment("lower(?)", d.name)
          )
        ),
      max_alts: max_alt_descriptions(),
      feed_child?: feed_child_id(group) != nil,
      file_group?: parent != nil and app_file_group?(parent, group.id),
      feed_part?: parent != nil and parent.uses_api and group.name == feed_name,
      can_create_subgroups?:
        member_of_group?(editor, group) and Access.can?(editor, group, :create_subgroups),
      picture: load_picture(group).group_picture_url
    }
  end

  @doc """
  What giving `group` the kind `key` would do, as `change_group_preset/4`
  would do it now: `{:ok, plan}` or `{:error, reason}` (`GroupPresets.change_plan/4`).
  """
  def preview_group_preset_change(%Profile{} = editor, %Group{} = group, key, park_name) do
    with :ok <- ensure_permission(editor, group, :edit_group) do
      GroupPresets.change_plan(group, key, group_kind_facts(editor, group), park_name)
    end
  end

  @doc """
  Gives `group` the kind `key` (a preset, or nil for none), as
  `GroupPresets.change_plan/4` says: what stood in its description goes to
  an alternative description for its editors, with everything its app kept
  (`AppScope.move/4`), and the kind's description, home page and picture
  come in. A feed gets its `.feed`.

  Returns `{:ok, %{group: group, plan: plan, parked: alt | nil, feed: group | nil}}`.
  """
  def change_group_preset(%Profile{} = editor, %Group{} = group, key, park_name)
      when is_binary(park_name) do
    with :ok <- ensure_permission(editor, group, :edit_group) do
      History.transaction([actor: editor, via: :kind], fn ->
        locked =
          from(g in Group, where: g.id == ^group.id, lock: "FOR UPDATE")
          |> Repo.one!()
          |> load_picture()

        AppData.lock_app(locked, nil)

        plan =
          case GroupPresets.change_plan(
                 locked,
                 key,
                 group_kind_facts(editor, locked),
                 park_name
               ) do
            {:ok, plan} -> plan
            {:error, reason} -> Repo.rollback(reason)
          end

        parked = park_default_description(editor, locked, plan.park)

        updated =
          case locked |> Ecto.Changeset.change(kind_changes(locked, plan)) |> Repo.update() do
            {:ok, updated} -> updated
            {:error, reason} -> Repo.rollback(reason)
          end

        # What stood there is its editors' alone from now on, as it was before too.
        if parked, do: History.close_description(updated, parked.visible_role_keys)

        {feed, created} =
          case plan.feed do
            :create ->
              case insert_preset_feed(editor, updated, "feed") do
                {:ok, feed, created} -> {feed, created}
                {:error, reason} -> Repo.rollback(reason)
              end

            _keep_or_reuse ->
              {nil, []}
          end

        {updated, plan, parked, feed, created}
      end)
      |> case do
        {:ok, {updated, plan, parked, feed, created}} ->
          broadcast_group_updated(updated)

          if updated.parent_id,
            do: broadcast_child_group_changed(updated.parent_id, updated, :updated)

          broadcast_shortcut_parents(shortcut_parent_ids(updated.id), updated, :updated)
          if parked, do: broadcast_alt_descriptions_updated(updated)

          Enum.each(created, fn {parent, group, changes} ->
            broadcast_group_created(editor, parent, group, changes)
          end)

          {:ok, %{group: updated, plan: plan, parked: parked, feed: feed}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # The old default, text or app, as an alternative only its editors see, with
  # everything filed under the default description.
  defp park_default_description(_editor, _group, nil), do: nil

  defp park_default_description(%Profile{} = editor, %Group{} = group, %{name: name}) do
    position =
      Repo.one(
        from(d in GroupAltDescription, where: d.group_id == ^group.id, select: max(d.position))
      )

    %GroupAltDescription{
      group_id: group.id,
      creator_id: editor.id,
      position: (position || -1) + 1
    }
    |> GroupAltDescription.changeset(%{
      "name" => name,
      "description" => group.description || "",
      "description_format" => group.description_format || :markdown,
      "uses_api" => group.uses_api,
      "visible_role_keys" => [GroupRole.admin_key()],
      "for_guests" => false
    })
    |> Repo.insert()
    |> case do
      {:ok, alt} ->
        :ok = AppScope.move(Repo, group.id, nil, alt.id)
        alt

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  defp kind_changes(%Group{} = group, plan) do
    home_page = if plan.home_page, do: [home_page: plan.home_page], else: []

    picture =
      if plan.picture == :replace,
        do: [group_picture_url: GroupPresets.picture(plan.key)],
        else: []

    [preset: plan.preset] ++ home_page ++ description_changes(group, plan) ++ picture
  end

  defp description_changes(_group, %{description: :app, key: key}) do
    attrs = GroupPresets.kind_attrs(key)

    [
      description: attrs["description"],
      description_format: :html,
      uses_api: true,
      description_name: nil,
      home_alt_description_id: nil
    ]
  end

  defp description_changes(_group, %{description: :clear}),
    do: [description: "", description_format: :markdown, uses_api: false, description_name: nil]

  defp description_changes(_group, %{description: :keep}), do: []

  @doc """
  Brings the app of `group`'s description (`alt`, nil for the default) to the
  newest build Potok has of it (`AppBuilds`). Only a copy Potok knows for one
  of its own apps is replaced, and only while the description is an app. Its
  data stay where they are, as the newer build is the same app.

  A Feed brings along the FeedCreator of its `.feed`, when that one is
  outdated too and the editor may edit it there.

  Returns `{:ok, %{group: group, alt: alt | nil, app: app, along: [group]}}`,
  or `{:error, :not_ours | :up_to_date | :not_permitted | :not_found}`.
  """
  def refresh_app(%Profile{} = editor, %Group{} = group, alt \\ nil) do
    with :ok <- ensure_permission(editor, group, :edit_group),
         :ok <- ensure_own_alt_description(group, alt) do
      History.transaction([actor: editor, via: :refresh], fn ->
        locked = repo_lock_group!(group)

        {updated_group, updated_alt, app} =
          case refresh_description(locked, alt) do
            {:ok, result} -> result
            {:error, reason} -> Repo.rollback(reason)
          end

        along =
          if is_nil(alt) and app == "potok-feed",
            do: refresh_feed_creator(editor, locked),
            else: []

        {updated_group, updated_alt, app, along}
      end)
      |> case do
        {:ok, {updated_group, updated_alt, app, along}} ->
          if updated_alt,
            do: broadcast_alt_descriptions_updated(updated_group),
            else: broadcast_group_updated(updated_group)

          Enum.each(along, &broadcast_group_updated/1)
          {:ok, %{group: updated_group, alt: updated_alt, app: app, along: along}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp repo_lock_group!(%Group{id: id}),
    do: Repo.one!(from(g in Group, where: g.id == ^id, lock: "FOR UPDATE"))

  defp refresh_description(%Group{} = group, nil) do
    with {:ok, app} <- outdated_app(group.uses_api, group.description),
         {:ok, updated} <-
           group
           |> Ecto.Changeset.change(
             description: AppBuilds.current_html(app),
             description_format: :html
           )
           |> Repo.update() do
      {:ok, {updated, nil, app}}
    end
  end

  defp refresh_description(%Group{} = group, %GroupAltDescription{id: alt_id}) do
    alt =
      Repo.one(
        from(d in GroupAltDescription,
          where: d.id == ^alt_id and d.group_id == ^group.id,
          lock: "FOR UPDATE"
        )
      )

    with %GroupAltDescription{} <- alt || {:error, :not_found},
         {:ok, app} <- outdated_app(alt.uses_api, alt.description),
         {:ok, updated} <-
           alt
           |> Ecto.Changeset.change(
             description: AppBuilds.current_html(app),
             description_format: :html
           )
           |> Repo.update() do
      {:ok, {group, updated, app}}
    end
  end

  # A description that is no app, or an app of someone's own, is left alone.
  defp outdated_app(true, description) when is_binary(description) do
    case AppBuilds.status(description) do
      {:outdated, app} -> {:ok, app}
      {:current, _app} -> {:error, :up_to_date}
      nil -> {:error, :not_ours}
    end
  end

  defp outdated_app(_uses_api, _description), do: {:error, :not_ours}

  defp refresh_feed_creator(%Profile{} = editor, %Group{} = feed) do
    with id when is_integer(id) <- feed_child_id(feed),
         %Group{} = desk <- Repo.get(Group, id),
         true <- Access.can?(editor, desk, :edit_group),
         {:ok, {updated, nil, "potok-feed-creator"}} <- refresh_description(desk, nil) do
      [updated]
    else
      _not_along -> []
    end
  end

  # The `.feed` Feed reads is the oldest one, whoever sees it.
  defp feed_child_id(%Group{id: id}) do
    from(g in Group,
      where:
        g.parent_id == ^id and g.name == ^GroupPresets.feed_group_name() and
          is_nil(g.parent_value_id) and g.is_direct == false,
      order_by: [asc: g.id],
      limit: 1,
      select: g.id
    )
    |> Repo.one()
  end

  defp app_file_group?(%Group{} = parent, id), do: id in app_file_group_ids(parent)

  # A draft that opens up reaches its readers now, however long it waited; one
  # that turns back into a draft has not been published until it opens again.
  defp mark_published(changeset, %Group{} = group) do
    draft? =
      Group.draft?(
        Ecto.Changeset.get_field(changeset, :is_public),
        Ecto.Changeset.get_field(changeset, :inherits_members),
        Ecto.Changeset.get_field(changeset, :inherit_role_keys)
      )

    case {Group.draft?(group), draft?} do
      {true, false} ->
        Ecto.Changeset.put_change(changeset, :published_at, DateTime.utc_now(:second))

      {false, true} ->
        Ecto.Changeset.put_change(changeset, :published_at, nil)

      _same ->
        changeset
    end
  end

  @doc """
  Gives the groups an app keeps below `group` the `flags` it passes
  (`"has_public_chat"`, `"description_for_guests"`) where they differ: its
  direct sub-groups but apps and its file groups, and the groups right under
  those, as a site keeps sections and their articles. Each goes through
  `update_group/3`, so one that `editor` may not edit is skipped. Returns
  `%{updated: count, skipped: count}`.
  """
  def align_children_access(%Profile{} = editor, %Group{} = group, flags) when is_map(flags) do
    file_ids = app_file_group_ids(group)

    section_ids =
      visible_plain_groups(editor)
      |> where([g], g.parent_id == ^group.id and not g.uses_api and g.id not in ^file_ids)
      |> select([g], g.id)
      |> Repo.all()

    has_public_chat = Map.fetch!(flags, "has_public_chat")
    for_guests = Map.fetch!(flags, "description_for_guests")

    visible_plain_groups(editor)
    |> where([g], g.id in ^section_ids or g.parent_id in ^section_ids)
    |> where(
      [g],
      g.has_public_chat != ^has_public_chat or g.description_for_guests != ^for_guests
    )
    |> order_by([g], asc: g.id)
    |> Repo.all()
    |> Enum.reduce(%{updated: 0, skipped: 0}, fn target, counts ->
      case update_group(editor, target, flags) do
        {:ok, _group} -> Map.update!(counts, :updated, &(&1 + 1))
        {:error, _reason} -> Map.update!(counts, :skipped, &(&1 + 1))
      end
    end)
  end

  @doc """
  Closes a group again: it turns private, stops inheriting and the inherited
  members leave with their roles. Switching inheritance off in `update_group/3`
  is the other way, where nobody falls out. Direct members stay, and so does
  `editor`, who keeps the group they closed.
  """
  def withdraw_group(%Profile{} = editor, %Group{} = group) do
    if not Access.can?(editor, group, :edit_group) do
      {:error, :not_permitted}
    else
      changeset =
        group
        |> Group.update_changeset(%{
          is_public: false,
          is_root_public: false,
          inherits_members: false
        })
        |> Ecto.Changeset.put_change(:published_at, nil)

      Multi.new()
      |> Multi.update(:group, changeset)
      |> Multi.run(:inheritance, fn repo, %{group: withdrawn} ->
        {:ok, MemberInheritance.drop_inherited(repo, withdrawn.id, editor.id)}
      end)
      |> Multi.run(:history, fn repo, %{group: withdrawn} ->
        {:ok, record_settings(repo, editor, group, withdrawn, %{withdrawn: true})}
      end)
      |> History.transaction(actor: editor)
      |> case do
        {:ok, %{group: withdrawn, inheritance: changes}} ->
          broadcast_group_updated(withdrawn)

          if withdrawn.parent_id do
            broadcast_child_group_changed(withdrawn.parent_id, withdrawn, :updated)
          end

          broadcast_shortcut_parents(shortcut_parent_ids(group.id), withdrawn, :updated)
          broadcast_inheritance_changes(changes)
          {:ok, withdrawn}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  # Starting to inherit brings in the parent's members; stopping keeps them
  # all, as direct members. Other roles to inherit by send away whoever no
  # longer holds one of them, but not the editor who changed them.
  defp switch_inheritance(
         repo,
         _editor,
         %Group{inherits_members: false},
         %Group{inherits_members: true} = group
       ),
       do: MemberInheritance.sync(repo, group.id)

  defp switch_inheritance(
         repo,
         _editor,
         %Group{inherits_members: true},
         %Group{inherits_members: false} = group
       ) do
    :ok = MemberInheritance.release(repo, group.id)
    []
  end

  defp switch_inheritance(
         repo,
         %Profile{} = editor,
         %Group{inherits_members: true, inherit_role_keys: old_keys},
         %Group{inherits_members: true, inherit_role_keys: keys} = group
       )
       when old_keys != keys,
       do: MemberInheritance.refilter(repo, group.id, editor.id)

  defp switch_inheritance(_repo, _editor, _group, _updated_group), do: []

  @doc """
  Whether the group can be set to inherit members: not the root, a direct
  group or one of the root's children, which would hold every profile.
  """
  def inherits_members_option?(%Group{is_root: true}), do: false
  def inherits_members_option?(%Group{is_direct: true}), do: false
  def inherits_members_option?(%Group{parent_id: parent_id}), do: not root_group_id?(parent_id)

  defp validate_inheritance_parent(changeset, parent_id) do
    Ecto.Changeset.validate_change(changeset, :inherits_members, fn _field, inherits? ->
      if inherits? and root_group_id?(parent_id),
        do: [inherits_members: "is not available for groups in the root group"],
        else: []
    end)
  end

  # A group inherits by roles of its parent's manifest, never by "everyone"
  # (`Group` turns that into no roles). Only a change is checked.
  defp validate_inherit_role_keys(changeset, parent_id) do
    Ecto.Changeset.validate_change(changeset, :inherit_role_keys, fn _field, keys ->
      known = parent_id |> Access.inheritable_roles() |> Enum.map(& &1.key)

      if keys -- known == [],
        do: [],
        else: [inherit_role_keys: "is not a role of the parent group"]
    end)
  end

  defp root_group_id?(group_id) when is_integer(group_id),
    do: Repo.exists?(from(g in Group, where: g.id == ^group_id and g.is_root))

  defp root_group_id?(nil), do: false

  @doc """
  Updates only the description of a group. Sub-group lists never show the
  description, so unlike `update_group/3` this neither notifies the parent
  nor triggers a full reload in the group's own subscribers.
  """
  def update_group_description(%Profile{} = editor, %Group{} = group, attrs) do
    if not Access.can?(editor, group, :edit_group) do
      {:error, :not_permitted}
    else
      attrs =
        attrs
        |> Map.new(fn {key, value} -> {to_string(key), value} end)
        |> Map.take(["description", "description_format"])

      group
      |> Group.update_changeset(attrs)
      |> History.update(actor: editor)
      |> case do
        {:ok, updated_group} ->
          broadcast_group_description_updated(updated_group)
          {:ok, updated_group}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp validate_home_alt_description(changeset, %Group{id: group_id}) do
    Ecto.Changeset.validate_change(changeset, :home_alt_description_id, fn _field, id ->
      if Repo.exists?(
           from(d in GroupAltDescription, where: d.id == ^id and d.group_id == ^group_id)
         ),
         do: [],
         else: [home_alt_description_id: "is not a description of this group"]
    end)
  end

  # ---------
  # Alternative descriptions
  #
  # Extra descriptions (text or apps) next to the default one on the group.
  # Every change broadcasts `{:alt_descriptions_updated, group_id}`.

  @max_alt_descriptions 20

  def max_alt_descriptions, do: @max_alt_descriptions

  @doc "The group's alternative descriptions in display order."
  def list_alt_descriptions(%Group{id: group_id}) do
    from(d in GroupAltDescription,
      where: d.group_id == ^group_id,
      order_by: [asc: d.position, asc: d.id]
    )
    |> Repo.all()
  end

  # What a guest's list of descriptions needs; the text is read for the one on
  # screen only, as an app's can run to hundreds of kilobytes.
  @guest_alt_fields [:id, :group_id, :name, :uses_api, :for_guests, :visible_role_keys, :position]

  @doc """
  The alternative descriptions guests may read, in display order and without
  their text: marked for guests, seen by everyone, and not empty. Whether the
  group opened its own description to them is the caller's to ask
  (`Group.guest_description?/1`).
  """
  def list_guest_alt_descriptions(%Group{id: group_id}) do
    from(d in GroupAltDescription,
      where: d.group_id == ^group_id and d.for_guests,
      where: fragment("cardinality(?) = 0", d.visible_role_keys),
      where: fragment("? ~ '[^[:space:]]'", d.description),
      order_by: [asc: d.position, asc: d.id],
      select: struct(d, ^@guest_alt_fields)
    )
    |> Repo.all()
  end

  @doc """
  Whether guests still read description `alt_id` of group `group_id`, nil for
  the default (`Group.guest_description?/1`, and the alternative's own mark).
  Reads only the flags, for a guest's page that asks again now and then.
  """
  def guest_description_open?(group_id, alt_id) when is_integer(group_id) do
    group =
      from(g in Group,
        where: g.id == ^group_id,
        select:
          struct(g, [
            :id,
            :is_public,
            :is_root,
            :is_direct,
            :parent_value_id,
            :description_for_guests
          ])
      )
      |> Repo.one()

    group != nil and Group.guest_description?(group) and guest_alt_open?(group_id, alt_id)
  end

  defp guest_alt_open?(_group_id, nil), do: true

  defp guest_alt_open?(group_id, alt_id) when is_integer(alt_id) do
    Repo.exists?(
      from(d in GroupAltDescription,
        where: d.id == ^alt_id and d.group_id == ^group_id and d.for_guests,
        where: fragment("cardinality(?) = 0", d.visible_role_keys)
      )
    )
  end

  def get_alt_description(%Group{id: group_id}, id) do
    Repo.get_by(GroupAltDescription, id: id, group_id: group_id)
  end

  def change_alt_description(%GroupAltDescription{} = alt_description, attrs \\ %{}) do
    GroupAltDescription.changeset(alt_description, attrs)
  end

  @doc "Adds an alternative description after the existing ones."
  def create_alt_description(%Profile{} = editor, %Group{} = group, attrs) do
    with :ok <- ensure_permission(editor, group, :edit_group) do
      Multi.new()
      |> Multi.run(:lock, fn repo, _changes -> lock_group(repo, group) end)
      |> Multi.run(:position, fn repo, _changes ->
        {count, max_position} =
          repo.one(
            from(d in GroupAltDescription,
              where: d.group_id == ^group.id,
              select: {count(), max(d.position)}
            )
          )

        if count >= @max_alt_descriptions,
          do: {:error, :too_many_alt_descriptions},
          else: {:ok, (max_position || -1) + 1}
      end)
      |> Multi.insert(:alt_description, fn %{position: position} ->
        %GroupAltDescription{group_id: group.id, creator_id: editor.id, position: position}
        |> GroupAltDescription.changeset(attrs)
      end)
      |> Multi.run(:history, fn repo, %{alt_description: created} ->
        {:ok, record_alt_visibility(repo, editor, group, %GroupAltDescription{}, created)}
      end)
      |> History.transaction(actor: editor)
      |> case do
        {:ok, %{alt_description: alt_description}} ->
          broadcast_alt_descriptions_updated(group)
          {:ok, alt_description}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  def update_alt_description(
        %Profile{} = editor,
        %Group{} = group,
        %GroupAltDescription{} = alt_description,
        attrs
      ) do
    with :ok <- ensure_permission(editor, group, :edit_group),
         :ok <- ensure_own_alt_description(group, alt_description) do
      History.transaction([actor: editor], fn ->
        case alt_description |> GroupAltDescription.changeset(attrs) |> Repo.update() do
          {:ok, updated} ->
            record_alt_visibility(Repo, editor, group, alt_description, updated)
            updated

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, updated} ->
          broadcast_alt_descriptions_updated(group)
          {:ok, updated}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Who sees an alternative description is access too: a change of its roles
  # or of guests seeing it is kept. A new one open to all says nothing new.
  defp record_alt_visibility(repo, editor, group, before, after_change) do
    if before.visible_role_keys != after_change.visible_role_keys or
         before.for_guests != after_change.for_guests do
      AccessHistory.record!(repo, group, :alt_visibility_set,
        actor: editor.id,
        data: %{
          alt: after_change.name,
          roles: after_change.visible_role_keys,
          guests: after_change.for_guests
        }
      )
    end

    :ok
  end

  @doc """
  Deletes an alternative description together with its app's data values.
  A home pointer to it falls back to the default description.
  """
  def delete_alt_description(
        %Profile{} = editor,
        %Group{} = group,
        %GroupAltDescription{} = alt_description
      ) do
    with :ok <- ensure_permission(editor, group, :edit_group),
         :ok <- ensure_own_alt_description(group, alt_description) do
      {:ok, deleted} =
        History.delete(alt_description, [actor: editor],
          allow_stale: true,
          timeout: History.bulk_timeout()
        )

      broadcast_alt_descriptions_updated(group)
      {:ok, deleted}
    end
  end

  @doc """
  Puts a deleted alternative description back, as it was (`PotokIde.History`),
  under its own id, after the others. Who saw it then sees it again.
  """
  def restore_alt_description(%Profile{} = editor, %Group{} = group, id, creator_id, attrs)
      when is_integer(id) and is_map(attrs) do
    with :ok <- ensure_permission(editor, group, :edit_group) do
      History.transaction([actor: editor], fn ->
        {:ok, _} = lock_group(Repo, group)

        {count, position} =
          Repo.one(
            from(d in GroupAltDescription,
              where: d.group_id == ^group.id,
              select: {count(), max(d.position)}
            )
          )

        if count >= @max_alt_descriptions, do: Repo.rollback(:too_many_alt_descriptions)

        %GroupAltDescription{
          id: id,
          group_id: group.id,
          creator_id: creator_id,
          position: (position || -1) + 1
        }
        |> GroupAltDescription.changeset(attrs)
        |> Ecto.Changeset.unique_constraint(:id, name: :group_alt_descriptions_pkey)
        |> Repo.insert()
        |> case do
          {:ok, alt} ->
            record_alt_visibility(Repo, editor, group, %GroupAltDescription{}, alt)
            alt

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)
      |> case do
        {:ok, alt} ->
          broadcast_alt_descriptions_updated(group)
          {:ok, alt}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc "Swaps an alternative description with its neighbour in `direction`."
  def move_alt_description(
        %Profile{} = editor,
        %Group{} = group,
        %GroupAltDescription{} = alt_description,
        direction
      )
      when direction in [:up, :down] do
    with :ok <- ensure_permission(editor, group, :edit_group),
         :ok <- ensure_own_alt_description(group, alt_description) do
      Multi.new()
      |> Multi.run(:lock, fn repo, _changes -> lock_group(repo, group) end)
      |> Multi.run(:move, fn repo, _changes ->
        move_in_order(repo, group, alt_description.id, direction)
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{move: :moved}} ->
          broadcast_alt_descriptions_updated(group)
          {:ok, :moved}

        {:ok, %{move: :unchanged}} ->
          {:ok, :unchanged}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  # Renumbers the whole list, so positions that ever got equal still move.
  defp move_in_order(repo, group, id, direction) do
    alt_descriptions =
      repo.all(
        from(d in GroupAltDescription,
          where: d.group_id == ^group.id,
          order_by: [asc: d.position, asc: d.id],
          select: %{id: d.id, position: d.position}
        )
      )

    index = Enum.find_index(alt_descriptions, &(&1.id == id))
    neighbour_index = if direction == :up, do: (index || 0) - 1, else: (index || 0) + 1

    cond do
      index == nil ->
        {:error, :not_found}

      neighbour_index < 0 or neighbour_index >= length(alt_descriptions) ->
        {:ok, :unchanged}

      true ->
        current = Enum.at(alt_descriptions, index)
        neighbour = Enum.at(alt_descriptions, neighbour_index)

        alt_descriptions
        |> List.replace_at(index, neighbour)
        |> List.replace_at(neighbour_index, current)
        |> Enum.with_index()
        |> Enum.each(fn {%{id: id, position: old}, position} ->
          if old != position do
            repo.update_all(from(d in GroupAltDescription, where: d.id == ^id),
              set: [position: position]
            )
          end
        end)

        {:ok, :moved}
    end
  end

  @doc """
  Makes an alternative description the group's default by swapping their
  contents: the old default takes the alternative's place in the list, and
  each app takes what it keeps along (`AppScope.swap/4`). One limited to some
  roles is refused, since the default is visible to everyone who sees the
  group, unless `open: true` says the editor agreed to show it to everyone.

  Guests keep what they saw of the old default: it goes to the list marked
  for them when the group had opened its description to them. The one that
  becomes the default then reaches them too, whatever its own mark said.

  `default_name` names the old default in the list when it had no name of
  its own (its label then came from the page's locale).
  """
  def promote_alt_description(
        %Profile{} = editor,
        %Group{} = group,
        %GroupAltDescription{} = alt_description,
        default_name,
        opts \\ []
      )
      when is_binary(default_name) do
    open? = Keyword.get(opts, :open, false)

    with :ok <- ensure_permission(editor, group, :edit_group),
         :ok <- ensure_own_alt_description(group, alt_description) do
      Multi.new()
      |> Multi.run(:group, fn repo, _changes ->
        {:ok, repo.one!(from(g in Group, where: g.id == ^group.id, lock: "FOR UPDATE"))}
      end)
      |> Multi.run(:alt_description, fn repo, _changes ->
        case repo.one(
               from(d in GroupAltDescription,
                 where: d.id == ^alt_description.id and d.group_id == ^group.id,
                 lock: "FOR UPDATE"
               )
             ) do
          nil -> {:error, :not_found}
          %GroupAltDescription{visible_role_keys: []} = locked -> {:ok, locked}
          %GroupAltDescription{} = locked when open? -> {:ok, locked}
          %GroupAltDescription{} -> {:error, :alt_description_restricted}
        end
      end)
      |> Multi.update(:updated_alt_description, fn %{group: old, alt_description: alt} ->
        alt
        |> Ecto.Changeset.change(
          name: old.description_name || default_name,
          description: old.description || "",
          description_format: old.description_format,
          uses_api: old.uses_api,
          visible_role_keys: [],
          for_guests: old.description_for_guests
        )
        |> Ecto.Changeset.unique_constraint(:name,
          name: :group_alt_descriptions_group_id_lower_name_index,
          message: "is already used by another description"
        )
      end)
      |> Multi.update(:updated_group, fn %{group: old, alt_description: alt} ->
        Ecto.Changeset.change(old,
          description_name: alt.name,
          description: alt.description,
          description_format: alt.description_format,
          uses_api: alt.uses_api,
          home_alt_description_id:
            if(old.home_alt_description_id == alt.id, do: nil, else: old.home_alt_description_id)
        )
      end)
      |> Multi.run(:app_data, fn repo, %{alt_description: alt} ->
        # Always the default's lock first, so two swaps never wait on each other.
        AppData.lock_app(group, nil)
        AppData.lock_app(group, alt.id)
        {:ok, AppScope.swap(repo, group.id, nil, alt.id)}
      end)
      |> History.transaction(actor: editor)
      |> case do
        {:ok, %{updated_group: updated_group, updated_alt_description: updated}} ->
          broadcast_alt_descriptions_updated(group)
          {:ok, updated_group, updated}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  defp ensure_own_alt_description(_group, nil), do: :ok

  defp ensure_own_alt_description(%Group{id: group_id}, %GroupAltDescription{group_id: group_id}),
    do: :ok

  defp ensure_own_alt_description(_group, _alt_description), do: {:error, :not_found}

  defp lock_group(repo, %Group{id: group_id}) do
    case repo.one(from(g in Group, where: g.id == ^group_id, lock: "FOR UPDATE", select: g.id)) do
      nil -> {:error, :not_found}
      id -> {:ok, id}
    end
  end

  def delete_group(%Profile{} = profile, %Group{} = group) do
    cond do
      group.is_root ->
        {:error, :cannot_delete_root_group}

      not member_of_group?(profile, group) ->
        {:error, :not_a_group_member}

      not Access.admin?(profile, group) ->
        {:error, :not_permitted}

      Repo.exists?(from child in Group, where: child.parent_id == ^group.id, select: 1) ->
        {:error, :group_has_children}

      true ->
        remove_group(group, actor: profile)
    end
  end

  @doc """
  Deletes a group that has no sub-groups, with its files, without asking who
  may: `delete_group/2` asks first, and `PotokIde.Accounts.Deletion` decides it
  for the groups that go with a deleted account. Callers make sure it has no
  sub-groups, and say who does it (`PotokIde.History`).
  """
  def remove_group(%Group{} = group, signature) when is_list(signature) do
    parent_id = group.parent_id
    # Its shortcuts go with it, so the groups that hold them are read first.
    shortcut_parent_ids = shortcut_parent_ids(group.id)

    # The group has no sub-groups, so its own values, sent and scheduled, hold
    # all the files that go with it. The scheduled ones go first, so one being
    # sent meanwhile is waited for before the group is touched.
    Multi.new()
    |> Multi.delete_all(
      :scheduled,
      from(s in ScheduledValue, where: s.group_id == ^group.id, select: s.files)
    )
    |> Multi.delete_all(
      :attachments,
      from(a in ValueAttachment, where: a.group_id == ^group.id, select: a.storage_key)
    )
    |> Multi.delete(:group, group)
    |> History.transaction(signature)
    |> case do
      {:ok,
       %{
         group: deleted_group,
         scheduled: {_scheduled_count, files},
         attachments: {_count, storage_keys}
       }} ->
        Storage.delete_later(storage_keys ++ ScheduledValue.storage_keys(files))
        broadcast_group_deleted(deleted_group.id, parent_id)

        if parent_id do
          broadcast_child_group_changed(parent_id, deleted_group, :deleted)
        end

        broadcast_shortcut_parents(shortcut_parent_ids, deleted_group, :deleted)
        {:ok, deleted_group}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  Places a shortcut to the group `target_id` in `parent`, where it stands as
  one of its sub-groups (`GroupShortcut`). It takes what making a sub-group
  there takes, and a target the profile sees (`shortcut_target?/2`).

  Returns `{:error, :already_listed}` when `parent` already has one to it.
  """
  def create_group_shortcut(%Profile{} = profile, %Group{} = parent, target_id)
      when is_integer(target_id) do
    target = Repo.one(from(g in Visibility.plain_groups(profile), where: g.id == ^target_id))

    cond do
      parent.is_direct or not member_of_group?(profile, parent) ->
        {:error, :not_a_member_of_parent_group}

      not Access.can?(profile, parent, :create_subgroups) ->
        {:error, :not_permitted}

      not shortcut_target?(target, parent) ->
        {:error, :invalid_target}

      true ->
        %GroupShortcut{parent_id: parent.id, target_id: target.id, creator_id: profile.id}
        |> GroupShortcut.changeset()
        |> Repo.insert()
        |> case do
          {:ok, shortcut} ->
            broadcast_child_group_changed(parent.id, target, :created)
            {:ok, shortcut}

          {:error, %Ecto.Changeset{errors: errors}} ->
            case errors[:target_id] do
              {_message, opts} when is_list(opts) ->
                if opts[:constraint] == :unique,
                  do: {:error, :already_listed},
                  else: {:error, :invalid_target}

              nil ->
                {:error, :invalid_target}
            end
        end
    end
  end

  # What a shortcut may open: a plain group (no thread, no direct
  # conversation) the profile sees, which is neither the root, an app's record,
  # the group the shortcut stands in, nor already one of its sub-groups.
  defp shortcut_target?(nil, _parent), do: false

  defp shortcut_target?(%Group{} = target, %Group{} = parent),
    do:
      not target.is_root and is_nil(target.external_key) and target.id != parent.id and
        target.parent_id != parent.id

  @doc """
  The shortcut `shortcut_id` when `profile` sees the group it stands in, and
  whether it may take it away (`:removable?`); nil otherwise. A row's menu
  reads it in the folder view too, where it may stand in any folder.
  """
  def get_group_shortcut(%Profile{} = profile, shortcut_id) when is_integer(shortcut_id) do
    with %GroupShortcut{} = shortcut <- Repo.get(GroupShortcut, shortcut_id),
         %Group{} = parent <- get_visible_group(profile, shortcut.parent_id) do
      %{shortcut: shortcut, removable?: removes_shortcut?(profile, shortcut, parent)}
    else
      nil -> nil
    end
  end

  # Its author, or an admin of the group it stands in.
  defp removes_shortcut?(
         %Profile{id: profile_id},
         %GroupShortcut{creator_id: profile_id},
         _parent
       ),
       do: true

  defp removes_shortcut?(%Profile{} = profile, %GroupShortcut{}, %Group{} = parent),
    do: member_of_group?(profile, parent) and Access.admin?(profile, parent)

  @doc """
  Takes the shortcut `shortcut_id` away; its target stays as it is. Its
  author or an admin of the group it stands in may.
  """
  def delete_group_shortcut(%Profile{} = profile, shortcut_id) when is_integer(shortcut_id) do
    case get_group_shortcut(profile, shortcut_id) do
      nil ->
        {:error, :not_found}

      %{removable?: false} ->
        {:error, :not_permitted}

      %{shortcut: shortcut} ->
        {:ok, deleted} = History.delete(shortcut, actor: profile)
        target = Repo.get(Group, deleted.target_id)
        if target, do: broadcast_child_group_changed(deleted.parent_id, target, :deleted)
        {:ok, deleted}
    end
  end

  @doc """
  The groups a shortcut in `parent` may open for `profile`, those whose name
  holds `search` (`NameSearch`), at most `limit`: the plain groups it sees
  that `parent` does not hold yet, its own first. Without a search, only its
  own: the groups it would look for in a list where they do not stand.

  Each is `%{group: group, parent_name: name}`, with the name of the group it
  stands in when the profile sees that one and it is not the root.
  """
  def search_shortcut_targets(%Profile{} = profile, %Group{} = parent, search, limit \\ 20) do
    term = NameSearch.wide_term(search)

    from(g in Visibility.plain_groups(profile),
      left_join: m in GroupMembership,
      on: m.group_id == g.id and m.profile_id == ^profile.id,
      left_join: p in Group,
      on: p.id == g.parent_id,
      left_join: pm in GroupMembership,
      on: pm.group_id == p.id and pm.profile_id == ^profile.id,
      where: not g.is_root and is_nil(g.external_key),
      where: g.id != ^parent.id and g.parent_id != ^parent.id,
      where:
        g.id not in subquery(
          from(s in GroupShortcut, where: s.parent_id == ^parent.id, select: s.target_id)
        ),
      order_by: [
        asc: is_nil(m.group_id),
        desc_nulls_last: g.last_value_at,
        asc: fragment("lower(?)", g.name),
        asc: g.id
      ],
      limit: ^limit,
      select: %{
        group: g,
        parent_name:
          fragment(
            "CASE WHEN NOT ? AND (? OR ? IS NOT NULL) THEN ? END",
            p.is_root,
            p.is_public,
            pm.group_id,
            p.name
          )
      }
    )
    |> NameSearch.where_matches(term)
    |> then(fn query ->
      if term, do: query, else: where(query, [_g, m], not is_nil(m.group_id))
    end)
    |> Repo.all()
  end

  @doc """
  The targets of the shortcuts in `parent`, whether the viewer sees them or
  not: what a page whose list is not all loaded watches for values in.
  """
  def list_shortcut_target_ids(%Group{id: parent_id}) do
    Repo.all(from(s in GroupShortcut, where: s.parent_id == ^parent_id, select: s.target_id))
  end

  # The groups that hold a shortcut to the group `target_id`.
  defp shortcut_parent_ids(target_id) do
    Repo.all(from(s in GroupShortcut, where: s.target_id == ^target_id, select: s.parent_id))
  end

  # The groups that show `group` through a shortcut hear of it as its own
  # parent does, so their lists follow it.
  defp broadcast_shortcut_parents(parent_ids, %Group{} = group, change) do
    Enum.each(parent_ids, &broadcast_child_group_changed(&1, group, change))
  end

  def invite_profile_to_group(%Profile{} = inviter, %Group{} = group, %Profile{} = invitee) do
    cond do
      not member_of_group?(inviter, group) ->
        {:error, :inviter_not_a_member}

      group.is_direct ->
        {:error, :direct_group}

      not Access.can?(inviter, group, :invite_members) ->
        {:error, :not_permitted}

      inviter.id == invitee.id ->
        {:error, :cannot_invite_self}

      Access.blocked_in_group?(invitee.id, group.id) ->
        {:error, :blocked}

      true ->
        Multi.new()
        # A lapsed invitation of the same pair would hold the pending index.
        |> Multi.delete_all(
          :lapsed,
          from(i in GroupInvitation,
            where:
              i.group_id == ^group.id and i.invitee_id == ^invitee.id and is_nil(i.accepted_at) and
                i.inserted_at <= ^GroupInvitation.cutoff()
          )
        )
        |> Multi.insert(
          :invitation,
          GroupInvitation.changeset(%GroupInvitation{}, %{
            group_id: group.id,
            inviter_id: inviter.id,
            invitee_id: invitee.id
          })
        )
        |> Multi.delete_all(
          :join_requests,
          from(r in GroupJoinRequest,
            where: r.group_id == ^group.id and r.requester_id == ^invitee.id
          )
        )
        |> Repo.transaction()
        |> case do
          {:ok, %{invitation: invitation}} ->
            broadcast_profile_invitations_updated(invitee)
            broadcast_profile_group_join_requests_updated(invitee)
            broadcast_profile_invitations_updated(inviter)
            broadcast_group_join_request_updates_for_group(group)
            broadcast_group_members_changed(group, [:requests], profile_id: invitee.id)
            notify_profile_invitee_of_group_invitation(inviter, group, invitee)
            {:ok, invitation}

          {:error, :invitation, reason, _changes} ->
            {:error, reason}

          {:error, _step, reason, _changes} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Why `inviter` may not invite an account to `group`, or nil when it may.
  Checked before an invitation by email opens an account and sends the email.
  """
  def invitation_refusal(%Profile{} = inviter, %Group{} = group) do
    cond do
      not member_of_group?(inviter, group) -> :inviter_not_a_member
      group.is_direct -> :direct_group
      not Access.can?(inviter, group, :invite_members) -> :not_permitted
      true -> nil
    end
  end

  @doc """
  Invites `account` into `group` (`PotokIde.Social.EmailInvitations`): the
  account picks the profile that accepts. `email` is the address the inviter
  typed, which alone they see of it; without one they see none, as the
  account's own may have changed since. An invitation the same inviter sent
  before stays as it was, unless it lapsed. The account gets a push.

  Returns `{:ok, %GroupAccountInvitation{}}` or `{:error, reason}` for the
  inviter (`invitation_refusal/2`).
  """
  def invite_account_to_group(
        %Profile{} = inviter,
        %Group{} = group,
        %Account{} = account,
        email \\ nil
      ) do
    account = Accounts.get_account!(account.id)

    if reason = invitation_refusal(inviter, group) do
      {:error, reason}
    else
      Repo.delete_all(
        from(i in GroupAccountInvitation,
          where:
            i.group_id == ^group.id and i.account_id == ^account.id and
              i.inviter_id == ^inviter.id and i.inserted_at <= ^GroupInvitation.cutoff()
        )
      )

      %GroupAccountInvitation{}
      |> GroupAccountInvitation.changeset(%{
        group_id: group.id,
        inviter_id: inviter.id,
        account_id: account.id,
        email: email
      })
      |> Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:group_id, :account_id, :inviter_id]
      )
      |> case do
        {:ok, invitation} ->
          if invitation.id do
            broadcast_account_invitations_updated(account.id)
            EmailInvitations.notify(account, inviter, group)
          end

          {:ok, invitation}

        error ->
          error
      end
    end
  end

  @doc "Tells the account's pages that its invitations by email changed."
  def broadcast_account_invitations_updated(account_id) when is_integer(account_id) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      account_topic(account_id),
      {:account_invitations_updated, account_id}
    )
  end

  @doc "Tells a profile's pages that the invitations it sent or got changed."
  def broadcast_invitations_updated(profile_id) when is_integer(profile_id),
    do: broadcast_profile_invitations_updated(%Profile{id: profile_id})

  @doc "Sends `payload_for` as a push to the account's devices, apart from the caller."
  def notify_account(%Account{} = account, payload_for, context) do
    run_notification(fn ->
      deliver_account_push_notification(account, payload_for, context, nil)
    end)
  end

  def accept_group_invitation(%GroupInvitation{} = invitation, %Profile{} = invitee) do
    invitation = Repo.preload(invitation, [:group, :inviter])

    cond do
      invitation.invitee_id != invitee.id ->
        {:error, :invitee_mismatch}

      # A lapsed invitation is gone the moment someone tries it.
      GroupInvitation.expired?(invitation) ->
        Repo.delete_all(from(i in GroupInvitation, where: i.id == ^invitation.id))
        broadcast_profile_invitations_updated(invitee)
        {:error, :expired}

      true ->
        accept_live_group_invitation(invitation, invitee)
    end
  end

  @doc """
  Accepts `invitation` with `profile`, a profile of `account`. That is its
  invitee, or, for an invitation to a unique profile, another unique profile
  of the same account, which comes into the group in the invitee's place. The
  invitation then names `profile`, so the inviter sees who came in.

  Returns `{:ok, invitation}` or `{:error, reason}`, a reason of
  `accept_as_refusal/3` or `:expired`.
  """
  def accept_group_invitation_as(
        %GroupInvitation{} = invitation,
        %Account{} = account,
        %Profile{} = profile
      ) do
    invitation = Repo.preload(invitation, [:group, :inviter, :invitee])

    cond do
      invitation.invitee_id == profile.id and is_nil(get_profile_for_account(account, profile.id)) ->
        {:error, :not_held}

      invitation.invitee_id == profile.id ->
        accept_group_invitation(invitation, profile)

      reason = accept_as_refusal(invitation, account, profile) ->
        {:error, reason}

      GroupInvitation.expired?(invitation) ->
        Repo.delete_all(from(i in GroupInvitation, where: i.id == ^invitation.id))
        broadcast_profile_invitations_updated(invitation.invitee)
        {:error, :expired}

      true ->
        accept_live_group_invitation(invitation, profile)
    end
  end

  @doc """
  Why `profile` may not accept `invitation` in its invitee's place, or nil
  when it may: both are unique profiles of `account`, `profile` is a person,
  not yet a member and not blocked in the group.
  """
  def accept_as_refusal(
        %GroupInvitation{} = invitation,
        %Account{} = account,
        %Profile{} = profile
      ) do
    invitation = Repo.preload(invitation, [:group, :invitee])
    held = get_profile_for_account(account, profile.id)

    cond do
      reason = redirect_refusal(invitation, account) -> reason
      is_nil(held) -> :not_held
      held.sharing != :unique -> :not_unique
      held.kind != :person -> :not_person
      member_of_group?(held, invitation.group) -> :already_member
      Access.blocked_in_group?(held.id, invitation.group_id) -> :blocked
      true -> nil
    end
  end

  # Whether `account` may take `invitation` to another of its profiles: it
  # holds the invited profile, a unique one, so it is the only account that
  # does, and the invitation still waits.
  defp redirect_refusal(%GroupInvitation{} = invitation, %Account{} = account) do
    cond do
      not is_nil(invitation.accepted_at) -> :already_accepted
      invitation.group.is_direct -> :direct_group
      is_nil(get_profile_for_account(account, invitation.invitee_id)) -> :invitee_mismatch
      invitation.invitee.sharing != :unique -> :not_unique
      true -> nil
    end
  end

  @doc """
  The other unique profiles of `account` that could accept `invitation` in
  its invitee's place, each with why it cannot (`:member`, `:blocked`) or
  nil. Empty when the invitation is not one to a unique profile of `account`.
  """
  def invitation_profile_choices(%Account{} = account, %GroupInvitation{} = invitation) do
    invitation = Repo.preload(invitation, [:group, :invitee])

    if redirect_refusal(invitation, account) do
      []
    else
      profiles =
        account
        |> list_profiles_for_account()
        |> Enum.filter(
          &(&1.id != invitation.invitee_id and &1.sharing == :unique and &1.kind == :person)
        )

      ids = Enum.map(profiles, & &1.id)

      members =
        MapSet.new(
          Repo.all(
            from(m in GroupMembership,
              where: m.group_id == ^invitation.group_id and m.profile_id in ^ids,
              select: m.profile_id
            )
          )
        )

      blocked =
        MapSet.new(
          Repo.all(
            from(b in GroupBlock,
              where: b.group_id == ^invitation.group_id and b.profile_id in ^ids,
              select: b.profile_id
            )
          )
        )

      Enum.map(profiles, fn profile ->
        cond do
          MapSet.member?(members, profile.id) -> {profile, :member}
          MapSet.member?(blocked, profile.id) -> {profile, :blocked}
          true -> {profile, nil}
        end
      end)
    end
  end

  @doc """
  Makes a new unique profile for `account` and accepts `invitation`, one to a
  unique profile of the account, with it. The invitation is checked first, so
  one that no longer holds makes no profile.

  Returns `{:ok, profile, group}`, where the group is nil when the invitation
  failed after the profile was made, or `{:error, changeset | reason}`.
  """
  def create_profile_and_accept_invitation(
        %Account{} = account,
        %GroupInvitation{} = invitation,
        attrs
      ) do
    invitation = Repo.preload(invitation, [:group, :inviter, :invitee])

    cond do
      reason = redirect_refusal(invitation, account) ->
        {:error, reason}

      GroupInvitation.expired?(invitation) ->
        {:error, :expired}

      true ->
        attrs = attrs |> Map.new(fn {key, value} -> {to_string(key), value} end)

        with {:ok, profile} <-
               create_profile_for_account(account, Map.put(attrs, "sharing", "unique")) do
          case accept_group_invitation_as(invitation, account, profile) do
            {:ok, _accepted} -> {:ok, profile, invitation.group}
            {:error, _reason} -> {:ok, profile, nil}
          end
        end
    end
  end

  # `joining` comes into the group by `invitation`: its invitee, or a profile
  # taking its place (`accept_group_invitation_as/3`), which the invitation
  # then names. Any other invitation still waiting for `joining` in the group
  # goes, as it would never be accepted.
  defp accept_live_group_invitation(%GroupInvitation{} = invitation, %Profile{} = joining) do
    group_id = invitation.group_id

    other_invitations =
      from(i in GroupInvitation,
        where:
          i.group_id == ^group_id and i.invitee_id == ^joining.id and is_nil(i.accepted_at) and
            i.id != ^invitation.id
      )

    Multi.new()
    |> Multi.all(:other_inviter_ids, select(other_invitations, [i], i.inviter_id))
    |> Multi.delete_all(:other_invitations, other_invitations)
    |> Multi.update(:invitation, GroupInvitation.accept_changeset(invitation, joining.id))
    |> Multi.insert(:membership, fn _changes ->
      GroupMembership.changeset(%GroupMembership{}, %{group_id: group_id, profile_id: joining.id})
    end)
    |> Multi.delete_all(
      :join_requests,
      from(r in GroupJoinRequest,
        where: r.group_id == ^group_id and r.requester_id == ^joining.id
      )
    )
    |> Multi.run(:read_marker, fn repo, _changes ->
      read_history_on_join(repo, joining.id, group_id)
    end)
    |> Multi.run(:inheritance, fn repo, _changes ->
      {:ok, MemberInheritance.sync(repo, group_id, [joining.id])}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{invitation: inv, inheritance: changes, other_inviter_ids: other_inviter_ids}} ->
        broadcast_profile_invitations_updated(joining)

        if invitation.invitee_id != joining.id,
          do: broadcast_profile_invitations_updated(%Profile{id: invitation.invitee_id})

        broadcast_profile_group_join_requests_updated(joining)

        [invitation.inviter_id | other_inviter_ids]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.each(&broadcast_profile_invitations_updated(%Profile{id: &1}))

        broadcast_group_join_request_updates_for_group(invitation.group)

        broadcast_group_members_changed(invitation.group, [:members, :requests],
          profile_id: joining.id
        )

        broadcast_group_membership_changed(joining.id, group_id, :added)
        broadcast_inheritance_changes(changes)
        notify_profile_inviter_of_group_invitation_acceptance(invitation, joining)
        {:ok, inv}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  Deletes the group invitations that waited longer than
  `GroupInvitation.valid_days/0`, and the account invitations as old, which
  would only become such invitations. The hourly sweep calls it. Returns how
  many went.
  """
  def delete_expired_invitations do
    cutoff = GroupInvitation.cutoff()

    {invitations, _} =
      Repo.delete_all(
        from(i in GroupInvitation, where: is_nil(i.accepted_at) and i.inserted_at <= ^cutoff)
      )

    {account_invitations, _} =
      Repo.delete_all(from(i in GroupAccountInvitation, where: i.inserted_at <= ^cutoff))

    invitations + account_invitations
  end

  def delete_group_invitation(%GroupInvitation{} = invitation, %Profile{} = invitee) do
    if invitation.invitee_id != invitee.id do
      {:error, :invitee_mismatch}
    else
      case Repo.delete(invitation) do
        {:ok, deleted_invitation} ->
          broadcast_profile_invitations_updated(invitee)

          case Repo.get(Profile, invitation.inviter_id) do
            %Profile{} = inviter -> broadcast_profile_invitations_updated(inviter)
            nil -> :ok
          end

          {:ok, deleted_invitation}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def remove_group_member(%Profile{} = actor, %Group{} = group, member_profile_id)
      when is_integer(member_profile_id) do
    case Repo.get(Profile, member_profile_id) do
      nil ->
        {:error, :member_not_found}

      member ->
        remove_group_member(actor, group, member)
    end
  end

  def remove_group_member(%Profile{} = actor, %Group{} = group, %Profile{} = member) do
    actor_access = Access.for_profile(actor, group)
    member_access = Access.for_profile(member, group, manifest: actor_access.manifest)

    cond do
      group.is_root ->
        {:error, :cannot_remove_root_group_members}

      group.is_direct ->
        {:error, :direct_group}

      not Access.can?(actor_access, :remove_members) ->
        {:error, :not_permitted}

      not member_access.member? ->
        {:error, :not_a_group_member}

      # Its rule takes the process of an app in and out of the app's group.
      AppProcesses.app_process_of?(member, group) ->
        {:error, :process_profile}

      # Members held through the parent are removed there.
      Map.has_key?(Access.inherited_by_profile(group, [member.id]), member.id) ->
        {:error, :inherited_member}

      # Only admins remove admins, and a group never loses its last admin.
      member_access.admin? and not actor_access.admin? ->
        {:error, :not_permitted}

      # An elected admin goes only by a decision.
      member_access.admin? and elects_admins?(group) ->
        {:error, :elected_admin}

      member_access.admin? and Access.count_admins(group) <= 1 ->
        {:error, :last_admin}

      true ->
        drop_membership(group, member, fn repo ->
          AccessHistory.record!(repo, group, :member_removed,
            actor: actor.id,
            subject: member.id
          )
        end)
    end
  end

  @doc """
  `profile` leaves `group` of its own accord, under `leave_refusal/2`: its
  roles there go, and so do its places in the sub-groups that inherit it. An
  admin in a group that elects its admins may leave too, which resigns the
  role. The access history keeps it (`member_left`) with the roles it held.
  """
  def leave_group(%Profile{} = profile, %Group{} = group) do
    case leave_refusal(profile, group) do
      nil ->
        roles = held_roles(profile, group)

        drop_membership(group, profile, fn repo ->
          AccessHistory.record!(repo, group, :member_left,
            actor: profile.id,
            subject: profile.id,
            data: %{roles: roles}
          )
        end)

      reason ->
        {:error, reason}
    end
  end

  @doc """
  Why `profile` may not leave `group`, or nil when it may: there is no leaving
  the root, a direct conversation or a thread, whoever is held through the
  parent leaves there, an app's process goes with its app, and a group keeps
  its last admin.
  """
  def leave_refusal(%Profile{} = profile, %Group{} = group) do
    access = Access.for_profile(profile, group)

    cond do
      group.is_root ->
        :root_group

      group.is_direct ->
        :direct_group

      not is_nil(group.parent_value_id) ->
        :thread

      not access.member? ->
        :not_a_group_member

      AppProcesses.app_process_of?(profile, group) ->
        :process_profile

      Map.has_key?(Access.inherited_by_profile(group, [profile.id]), profile.id) ->
        :inherited_member

      access.admin? and Access.count_admins(group) <= 1 ->
        :last_admin

      true ->
        nil
    end
  end

  # The roles `profile` holds in `group`, by key and by their names now, for
  # the access history to tell after they are gone.
  defp held_roles(%Profile{id: profile_id}, %Group{} = group) do
    names = Map.new(Access.effective_manifest(group).roles, &{&1.key, &1.name})

    group
    |> Access.role_keys_by_profile([profile_id])
    |> Map.get(profile_id, [])
    |> Enum.map(&%{"key" => &1, "name" => Map.get(names, &1, &1)})
  end

  # The membership goes with its roles (composite foreign key), the read
  # marker, the messages that wait to go out, the places in the sub-groups that
  # inherit it and a request for roles that waits; `history` writes what
  # happened in the same transaction. What waits in those sub-groups goes when
  # its time comes (`PotokIde.Social.ScheduledValues`).
  defp drop_membership(%Group{} = group, %Profile{} = member, history) do
    Multi.new()
    |> Multi.delete_all(
      :membership,
      from(gm in GroupMembership,
        where: gm.group_id == ^group.id and gm.profile_id == ^member.id
      )
    )
    |> Multi.delete_all(
      :group_value_reads,
      from(gvr in GroupValueRead,
        where: gvr.group_id == ^group.id and gvr.profile_id == ^member.id
      )
    )
    |> Multi.delete_all(
      :scheduled,
      from(s in ScheduledValue,
        where: s.group_id == ^group.id and s.profile_id == ^member.id,
        select: s.files
      )
    )
    |> Multi.run(:inheritance, fn repo, _changes ->
      {:ok, MemberInheritance.sync(repo, group.id, [member.id])}
    end)
    |> Multi.run(:history, fn repo, _changes -> {:ok, history.(repo)} end)
    |> Repo.transaction()
    |> case do
      {:ok, %{inheritance: changes, scheduled: {_count, files}}} ->
        Storage.delete_later(ScheduledValue.storage_keys(files))
        broadcast_group_members_changed(group, [:members], profile_id: member.id)
        broadcast_group_membership_changed(member.id, group.id, :removed)
        broadcast_inheritance_changes(changes)
        {:ok, member}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc """
  Blocks `profile` in the group, for those who may remove members: it can no
  longer write or react in an open chat, ask to join or be invited, and what it
  has asked or been invited to goes. A member is removed first, under the rules
  of `remove_group_member/3`, as membership comes before a block. Its values stay.
  """
  def block_from_group(%Profile{} = actor, %Group{} = group, %Profile{} = profile) do
    cond do
      group.is_root or group.is_direct ->
        {:error, :not_permitted}

      actor.id == profile.id ->
        {:error, :cannot_block_self}

      not Access.can?(actor, group, :remove_members) ->
        {:error, :not_permitted}

      # A stopped process would come back with its rule, block or not.
      AppProcesses.app_process_of?(profile, group) ->
        {:error, :process_profile}

      true ->
        with :ok <- remove_blocked_member(actor, group, profile) do
          insert_group_block(actor, group, profile)
        end
    end
  end

  defp remove_blocked_member(%Profile{} = actor, %Group{} = group, %Profile{} = profile) do
    if member_of_group?(profile, group) do
      with {:ok, _member} <- remove_group_member(actor, group, profile), do: :ok
    else
      :ok
    end
  end

  defp insert_group_block(%Profile{} = actor, %Group{} = group, %Profile{} = profile) do
    block = %GroupBlock{group_id: group.id, profile_id: profile.id, blocked_by_id: actor.id}

    Multi.new()
    |> Multi.insert(:block, block,
      on_conflict: :nothing,
      conflict_target: [:group_id, :profile_id]
    )
    |> Multi.delete_all(
      :join_requests,
      from(r in GroupJoinRequest,
        where: r.group_id == ^group.id and r.requester_id == ^profile.id
      )
    )
    |> Multi.delete_all(
      :invitations,
      from(i in GroupInvitation,
        where: i.group_id == ^group.id and i.invitee_id == ^profile.id and is_nil(i.accepted_at)
      )
    )
    |> Multi.run(:history, fn repo, %{block: inserted} ->
      if inserted.id do
        AccessHistory.record!(repo, group, :member_blocked, actor: actor.id, subject: profile.id)
      end

      {:ok, :ok}
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{block: block}} ->
        Access.forget([group.id])
        broadcast_group_members_changed(group, [:requests, :blocks], profile_id: profile.id)
        broadcast_profile_invitations_updated(profile)
        broadcast_profile_group_join_requests_updated(profile)
        broadcast_group_join_request_updates_for_group(group)
        {:ok, block}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  @doc "Lifts the block on the profile, for those who may remove members."
  def unblock_from_group(%Profile{} = actor, %Group{} = group, profile_id)
      when is_integer(profile_id) do
    if Access.can?(actor, group, :remove_members) do
      {:ok, _} =
        Repo.transaction(fn ->
          {count, _rows} =
            from(b in GroupBlock, where: b.group_id == ^group.id and b.profile_id == ^profile_id)
            |> Repo.delete_all()

          if count > 0 do
            AccessHistory.record!(Repo, group, :member_unblocked,
              actor: actor.id,
              subject: profile_id
            )
          end
        end)

      Access.forget([group.id])
      broadcast_group_members_changed(group, [:blocks], profile_id: profile_id)
      :ok
    else
      {:error, :not_permitted}
    end
  end

  @doc "The group's blocks with their profiles, the newest first."
  def list_group_blocks(%Group{id: group_id}) do
    from(b in GroupBlock,
      where: b.group_id == ^group_id,
      order_by: [desc: b.inserted_at, desc: b.id],
      preload: :profile
    )
    |> Repo.all()
  end

  @doc """
  `requester` asks to join `group`, with no roles and nothing said: see
  `PotokIde.Social.GroupRequests.request_access/4` for both.
  """
  def request_group_access(%Profile{} = requester, %Group{} = group),
    do: GroupRequests.request_access(requester, group, %{})

  @doc """
  Why `requester` may not ask to join `group` now, or `:ok`: the group is
  not public, they are in already or invited, or blocked there.
  """
  def may_ask_to_join(%Profile{} = requester, %Group{} = group) do
    cond do
      not group.is_public -> {:error, :group_not_public}
      member_of_group?(requester, group) -> {:error, :already_a_member}
      pending_group_invitation_for_profile?(group, requester) -> {:error, :already_invited}
      Access.blocked_in_group?(requester.id, group.id) -> {:error, :blocked}
      true -> :ok
    end
  end

  @doc """
  Tells the pages that the requests of `group` changed, the requester's own
  and those of everyone who manages them.
  """
  def broadcast_requests_changed(%Group{} = group, %Profile{} = requester) do
    broadcast_group_members_changed(group, [:requests], profile_id: requester.id)
    broadcast_profile_group_join_requests_updated(requester)
    broadcast_group_join_request_updates_for_group(group)
    :ok
  end

  def list_pending_group_join_requests(%Group{} = group) do
    from(r in GroupJoinRequest,
      where: r.group_id == ^group.id,
      order_by: [desc: r.inserted_at, desc: r.id],
      preload: [:requester]
    )
    |> Repo.all()
  end

  @doc """
  How many requests of `group` wait for whoever decides them: requests to
  join not in a vote, and members' requests for roles.
  """
  def count_pending_group_join_requests(%Group{} = group) do
    from(r in subquery(waiting_requests_query()),
      where: r.group_id == ^group.id,
      select: count()
    )
    |> Repo.one()
  end

  # The groups of the requests that wait for whoever decides, a row each: a
  # request to join while no vote decides it, and a member's request for
  # roles, which holds only what waits.
  defp waiting_requests_query do
    joins = from(r in GroupJoinRequest, where: is_nil(r.poll_id), select: %{group_id: r.group_id})
    roles = from(r in GroupRoleRequest, select: %{group_id: r.group_id})
    union_all(joins, ^roles)
  end

  def list_pending_group_join_requests_for_approver(%Profile{} = approver) do
    requests =
      from(r in GroupJoinRequest,
        join: gm in GroupMembership,
        on: gm.group_id == r.group_id and gm.profile_id == ^approver.id,
        order_by: [desc: r.inserted_at, desc: r.id],
        preload: [:requester, :group]
      )
      |> Repo.all()
      |> with_direct_members()

    approvable_ids =
      requests
      |> Enum.map(& &1.group)
      |> Enum.uniq_by(& &1.id)
      |> approvable_group_ids(approver)

    Enum.filter(requests, &MapSet.member?(approvable_ids, &1.group_id))
  end

  def count_pending_group_join_requests_for_approver(%Profile{} = approver) do
    from(r in subquery(waiting_requests_query()),
      join: gm in GroupMembership,
      on: gm.group_id == r.group_id and gm.profile_id == ^approver.id,
      group_by: r.group_id,
      select: {r.group_id, count()}
    )
    |> Repo.all()
    |> approvable_join_request_total(approver)
  end

  # Join request counts per group the approver belongs to, summed over the
  # groups where they may manage requests. Groups are only loaded when there
  # are requests at all.
  defp approvable_join_request_total([], _approver), do: 0

  defp approvable_join_request_total(counts, %Profile{} = approver) do
    counts = Map.new(counts)

    approvable_ids =
      from(g in Group, where: g.id in ^Map.keys(counts))
      |> Repo.all()
      |> approvable_group_ids(approver)

    counts
    |> Enum.filter(fn {group_id, _count} -> MapSet.member?(approvable_ids, group_id) end)
    |> Enum.reduce(0, fn {_group_id, count}, total -> total + count end)
  end

  @doc """
  The header badges in one query: pending invitations, what waits for the
  profile under Requests (requests to join and for roles it may decide,
  `count_pending_group_join_requests/1`, the tasks of
  drawn processes that wait for it, `PotokIde.Processes.waiting_sql/1`, and
  the open reports of the groups it is an admin of, `ValueReports.open_count/1`),
  unread values (the root group's count) and unread notices. The same
  numbers as `count_pending_invitations/1`,
  `count_pending_group_join_requests_for_approver/1` with
  `PotokIde.Processes.waiting_total/1`, `count_root_group_unread_values/1`
  and `PotokIde.Notices.unread_snapshot/1`; the approver's groups are only
  loaded when some of them have join requests.
  `root_unread_as_of` and `unread_notices_as_of` are what the counts hold
  (`PotokIde.CountMark`, see `root_group_unread_snapshot/1`).

  `unread: false` leaves the unread count out (0, `as_of` nil), for pages
  that count unread values themselves.
  """
  def nav_counts(profile, opts \\ [])

  def nav_counts(nil, _opts),
    do: %{
      pending_invitations: 0,
      account_invitations: 0,
      pending_group_join_requests: 0,
      root_unread: 0,
      root_unread_as_of: nil,
      unread_notices: 0,
      unread_notices_as_of: nil,
      member_group_ids: nil,
      muted_group_ids: nil,
      pinned_group_ids: nil
    }

  def nav_counts(%Profile{id: profile_id} = profile, opts) do
    unread? = Keyword.get(opts, :unread, true)

    account_id =
      case Keyword.get(opts, :account) do
        %Account{id: id} -> id
        _none -> nil
      end

    unread_sql =
      if unread? do
        """
        (
          SELECT COALESCE(SUM(u.unread), 0)::bigint
          FROM group_memberships gm
          LEFT JOIN group_value_reads gvr
            ON gvr.profile_id = gm.profile_id AND gvr.group_id = gm.group_id
          #{capped_unread_sql("gm", "gvr")}
          WHERE gm.profile_id = $1
            AND gm.group_id IS DISTINCT FROM (SELECT r.id FROM groups r WHERE r.is_root)
            AND NOT #{GroupMutes.muted_sql()}
        ),
        #{CountMark.ids_sql("values")}
        """
      else
        "0::bigint, NULL::bigint[]"
      end

    sql = """
    SELECT
      (SELECT COUNT(*) FROM group_invitations WHERE invitee_id = $1 AND accepted_at IS NULL
         AND inserted_at > now() - make_interval(days => #{GroupInvitation.valid_days()})) +
      (SELECT COUNT(*) FROM profile_invitations WHERE invitee_id = $1 AND accepted_at IS NULL),
      (SELECT COUNT(*) FROM group_account_invitations WHERE account_id = $2
         AND inserted_at > now() - make_interval(days => #{GroupInvitation.valid_days()})),
      (
        SELECT COALESCE(array_agg(ARRAY[r.group_id, r.request_count]), '{}')
        FROM (
          SELECT w.group_id, COUNT(*) AS request_count
          FROM (
            SELECT jr.group_id FROM group_join_requests jr WHERE jr.poll_id IS NULL
            UNION ALL
            SELECT rr.group_id FROM group_role_requests rr
          ) w
          JOIN group_memberships gm ON gm.group_id = w.group_id AND gm.profile_id = $1
          GROUP BY w.group_id
        ) r
      ),
      (
        SELECT COALESCE(array_agg(gm.group_id), '{}')
        FROM group_memberships gm
        JOIN groups g ON g.id = gm.group_id
        WHERE gm.profile_id = $1 AND NOT g.is_root AND g.external_key IS NULL
      ),
      (
        SELECT COALESCE(array_agg(gm.group_id), '{}')
        FROM group_memberships gm
        WHERE gm.profile_id = $1 AND #{GroupMutes.muted_sql()}
      ),
      (SELECT COALESCE(array_agg(p.group_id), '{}') FROM pinned_groups p WHERE p.profile_id = $1),
      #{unread_sql},
      #{Notices.unread_count_sql("$1")},
      #{Notices.notice_mark_sql()},
      (SELECT COUNT(*) FROM (#{PotokIde.Processes.waiting_sql("$1")}) w),
      (
        SELECT COUNT(*) FROM value_reports vr
        JOIN group_member_roles r
          ON r.group_id = vr.group_id AND r.profile_id = $1 AND r.role_key = '#{GroupRole.admin_key()}'
        WHERE vr.dismissed_at IS NULL
      )
    """

    case Repo.query(sql, [profile_id, account_id],
           cache_statement: "social_nav_counts_v12_#{unread?}"
         ) do
      {:ok,
       %{
         rows: [
           [
             invitations,
             account_invitations,
             join_request_counts,
             member_group_ids,
             muted_group_ids,
             pinned_group_ids,
             unread,
             unread_as_of,
             unread_notices,
             unread_notices_as_of,
             waiting,
             reports
           ]
         ]
       }} ->
        %{
          pending_invitations: invitations + account_invitations,
          account_invitations: account_invitations,
          pending_group_join_requests:
            join_request_counts
            |> Enum.map(fn [group_id, count] -> {group_id, count} end)
            |> approvable_join_request_total(profile)
            |> Kernel.+(waiting + reports),
          root_unread: unread,
          root_unread_as_of: CountMark.from_ids(unread_as_of),
          unread_notices: unread_notices,
          unread_notices_as_of: CountMark.from_ids(unread_notices_as_of),
          member_group_ids: member_group_ids,
          muted_group_ids: muted_group_ids,
          pinned_group_ids: pinned_group_ids
        }

      {:error, _reason} ->
        nav_counts(nil, opts)
    end
  end

  @doc "The groups the profile silenced, their threads included (`GroupMutes`)."
  defdelegate muted_group_ids(profile), to: GroupMutes

  @doc "Until when the profile silenced `group` (or a thread's conversation); nil if not."
  defdelegate group_muted_until(profile, group), to: GroupMutes, as: :muted_until

  @doc """
  The groups whose values count as unread for the profile: its memberships,
  without the root and without records (`Group.external_key`), which an app
  brings in by the thousand and nobody writes in. `nav_counts/2` has them
  too, for a page that loads those.
  """
  def member_group_ids(%Profile{id: profile_id}) do
    from(gm in GroupMembership,
      join: g in assoc(gm, :group),
      where: gm.profile_id == ^profile_id and not g.is_root and is_nil(g.external_key),
      select: gm.group_id
    )
    |> Repo.all()
  end

  defp approvable_group_ids(groups, %Profile{} = approver) do
    approver
    |> Access.for_profile_in_groups(groups)
    |> Enum.filter(fn {_group_id, access} -> Access.can?(access, :manage_join_requests) end)
    |> MapSet.new(fn {group_id, _access} -> group_id end)
  end

  def list_pending_group_join_request_counts(groups) when is_list(groups) do
    group_ids =
      groups
      |> Enum.map(& &1.id)
      |> Enum.uniq()

    case group_ids do
      [] ->
        %{}

      _ ->
        from(r in subquery(waiting_requests_query()),
          where: r.group_id in ^group_ids,
          group_by: r.group_id,
          select: {r.group_id, count()}
        )
        |> Repo.all()
        |> Map.new()
    end
  end

  def list_approved_group_join_requests_for_approver(%Profile{} = approver, opts \\ []) do
    import Ecto.Query, only: [from: 2]

    limit = normalize_query_limit(opts[:limit])
    offset = normalize_query_offset(opts[:offset])
    search = normalize_request_search_query(opts[:search])

    from(a in GroupJoinRequestApproval,
      join: g in assoc(a, :group),
      join: requester in assoc(a, :requester),
      where: a.approver_id == ^approver.id,
      where: ^approved_request_name_search_dynamic(search),
      order_by: [desc: a.approved_at, desc: a.id],
      offset: ^offset,
      preload: [:requester, :group]
    )
    |> maybe_limit(limit)
    |> Repo.all()
    |> with_direct_members()
  end

  def count_approved_group_join_requests_for_approver(%Profile{} = approver, opts \\ []) do
    import Ecto.Query, only: [from: 2]

    search = normalize_request_search_query(opts[:search])

    from(a in GroupJoinRequestApproval,
      join: g in assoc(a, :group),
      join: requester in assoc(a, :requester),
      where: a.approver_id == ^approver.id,
      where: ^approved_request_name_search_dynamic(search),
      select: count(a.id)
    )
    |> Repo.one()
  end

  def list_approved_group_join_requests_for_requester(%Profile{} = requester, opts \\ []) do
    limit = normalize_query_limit(opts[:limit])
    offset = normalize_query_offset(opts[:offset])
    search = normalize_request_search_query(opts[:search])

    refs =
      from(x in subquery(request_history_union_query(requester, search)),
        order_by: [desc: x.sort_at, desc: x.rank, desc: x.id],
        select: {x.kind, x.id}
      )
      |> maybe_limit(limit)
      |> maybe_offset(offset)
      |> Repo.all()

    load_request_history_entries(refs)
  end

  def count_approved_group_join_requests_for_requester(%Profile{} = requester, opts \\ []) do
    search = normalize_request_search_query(opts[:search])

    from(x in subquery(request_history_union_query(requester, search)), select: count())
    |> Repo.one()
  end

  def get_pending_group_join_request(%Profile{} = requester, %Group{} = group) do
    from(r in GroupJoinRequest,
      where: r.group_id == ^group.id and r.requester_id == ^requester.id
    )
    |> Repo.one()
  end

  @doc """
  Admits whoever asked to join `group` with `request_id`, as
  `PotokIde.Social.GroupRequests.decide/4` does with no choice for the roles
  asked for: they wait for later, or go to a vote where the rule says so.
  Returns the new member.
  """
  def accept_group_join_request(%Profile{} = actor, %Group{} = group, request_id)
      when is_integer(request_id) do
    with %GroupJoinRequest{} = request <- get_group_join_request(group, request_id),
         {:ok, _parts} <-
           GroupRequests.decide(actor, group, {:join, request_id}, %{"admission" => "admit"}) do
      {:ok, Repo.get!(Profile, request.requester_id)}
    else
      nil -> {:error, :request_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Admits the requester of `request` to `group`, in the caller's transaction:
  the membership, the chat's history read, their invitations and the request
  gone, a record of who admitted them (`approval`: `%{approver_id:}`, or
  `%{poll_id:}` for a vote) and the members of sub-groups it brings along.
  Returns `{:ok, inheritance_changes}` for `announce_admission/3`, or
  `{:error, reason}` before anything is written.
  """
  def admit_member(repo, %Group{} = group, %GroupJoinRequest{} = request, approval) do
    profile_id = request.requester_id

    %GroupMembership{}
    |> GroupMembership.changeset(%{group_id: group.id, profile_id: profile_id})
    |> repo.insert()
    |> case do
      {:ok, _membership} ->
        repo.delete_all(from(r in GroupJoinRequest, where: r.id == ^request.id))
        {:ok, _read} = read_history_on_join(repo, profile_id, group.id)

        repo.delete_all(
          from(i in GroupInvitation,
            where:
              i.group_id == ^group.id and i.invitee_id == ^profile_id and is_nil(i.accepted_at)
          )
        )

        %GroupJoinRequestApproval{}
        |> GroupJoinRequestApproval.changeset(
          Map.merge(
            %{
              group_id: group.id,
              requester_id: profile_id,
              approved_at: DateTime.utc_now(:second)
            },
            approval
          )
        )
        |> repo.insert!()

        AccessHistory.record!(repo, group, :member_admitted,
          actor: approval[:approver_id],
          subject: profile_id,
          poll: approval[:poll_id]
        )

        {:ok, MemberInheritance.sync(repo, group.id, [profile_id])}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Tells the pages that `admit_member/4` committed; returns the new member."
  def announce_admission(%Group{} = group, profile_id, changes) do
    requester = Repo.get!(Profile, profile_id)
    broadcast_group_members_changed(group, [:members, :requests], profile_id: requester.id)
    broadcast_profile_invitations_updated(requester)
    broadcast_profile_group_join_requests_updated(requester)
    broadcast_group_join_request_updates_for_group(group)
    broadcast_group_membership_changed(requester.id, group.id, :added)
    broadcast_inheritance_changes(changes)
    requester
  end

  @doc "Sends `payload_for` (`Social.Notifications`) to the devices of `profile`'s accounts."
  def notify_profile(%Profile{} = profile, payload_for, context) do
    run_notification(fn ->
      profile
      |> recipient_accounts_for_profile_notification()
      |> Enum.each(&deliver_profile_notification(&1, payload_for, context, profile.id))
    end)
  end

  @doc "Refuses the request to join `group` with `request_id`, with nothing said."
  def reject_group_join_request(%Profile{} = actor, %Group{} = group, request_id)
      when is_integer(request_id) do
    with %GroupJoinRequest{} = request <- get_group_join_request(group, request_id),
         {:ok, _parts} <-
           GroupRequests.decide(actor, group, {:join, request_id}, %{"admission" => "refuse"}) do
      {:ok, request}
    else
      nil -> {:error, :request_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # ---------
  # Values
  # ---------

  def get_value!(id), do: Repo.get!(Value, id)

  @doc """
  Loads a single value with the associations the values tab renders, or nil.
  Its reactions say nothing of a viewer (`mine?` is false): pages put that
  back themselves.
  """
  def get_value_for_display(id) when is_integer(id) do
    from(v in Value, where: v.id == ^id, preload: ^value_display_preloads())
    |> Repo.one()
    |> put_display_extras()
  end

  # What a value shows beyond its preloads: who set off its process and its
  # reactions, with `viewer_id`'s marked when one is given.
  defp put_display_extras(values, viewer_id \\ nil)
  defp put_display_extras(nil, _viewer_id), do: nil

  defp put_display_extras(%Value{} = value, viewer_id),
    do: hd(put_display_extras([value], viewer_id))

  defp put_display_extras(values, viewer_id) when is_list(values) do
    values = put_process_triggers(values)

    summaries =
      values
      |> Enum.reject(& &1.is_data)
      |> Enum.map(& &1.id)
      |> value_reaction_summaries(viewer_id)

    Enum.map(values, &%{&1 | reaction_summary: Map.get(summaries, &1.id, [])})
  end

  @doc """
  The reactions of each of `value_ids` as `%{value_id => [reaction]}`, as
  `group_reaction_summaries/2` gives them for groups: one entry per emoji in
  the order it was first used, with `:emoji`, `:key`, `:count`, `:names` (the
  first 20) and `:mine?` (`viewer_id`'s, false for nil). One query, none for
  no ids.
  """
  def value_reaction_summaries([], _viewer_id), do: %{}

  def value_reaction_summaries(value_ids, viewer_id) when is_list(value_ids) do
    from(r in ValueReaction,
      join: p in assoc(r, :profile),
      where: r.value_id in ^value_ids,
      group_by: [r.value_id, r.emoji],
      order_by: [asc: min(r.id)],
      select:
        {r.value_id,
         %{
           emoji: r.emoji,
           count: count(r.id),
           mine?:
             fragment("COALESCE(bool_or(? = ?), false)", r.profile_id, type(^viewer_id, :id)),
           names: fragment("(array_agg(? ORDER BY ?))[1:20]", p.username, r.id)
         }}
    )
    |> Repo.all()
    |> Enum.group_by(
      fn {value_id, _reaction} -> value_id end,
      fn {_value_id, reaction} ->
        Map.put(reaction, :key, Base.encode16(reaction.emoji, case: :lower))
      end
    )
  end

  # Who set off the step of an app's process that posted each value, for the
  # line under its name (`Value.process_trigger`): one query for them all.
  defp put_process_triggers(nil), do: nil
  defp put_process_triggers(%Value{} = value), do: hd(put_process_triggers([value]))

  defp put_process_triggers(values) when is_list(values) do
    ids =
      for %Value{managed: %{"process" => %{"triggered_by" => id}}} <- values,
          is_integer(id),
          uniq: true,
          do: id

    profiles =
      if ids == [],
        do: %{},
        else: from(p in Profile, where: p.id in ^ids) |> Repo.all() |> Map.new(&{&1.id, &1})

    Enum.map(values, fn
      %Value{managed: %{"process" => %{"triggered_by" => id}}} = value ->
        %{value | process_trigger: Map.get(profiles, id)}

      value ->
        value
    end)
  end

  # Everything `Components.value_message/1` renders for a chat value: the
  # replied-to value with its author for the quote (or its files when it has
  # no text), the value's files, its thread and the event or poll it announced.
  # A poll comes without its answers and counts: broadcasts carry these values,
  # and `Polls.put_views/5` reads what each viewer sees. An author that is an
  # app's process comes with it, for its name (`Profile.display_name/1`).
  defp value_display_preloads do
    [
      :thread,
      :event,
      :poll,
      creator: :app_process,
      attachments: attachments_in_order(),
      parent: [:event, creator: :app_process, attachments: attachments_in_order()]
    ]
  end

  defp attachments_in_order, do: from(a in ValueAttachment, order_by: [asc: a.id])

  @unread_cap 100

  # What someone outside the group may do in an open chat, which is not much to
  # hold back a person and enough to hold back a loop. See also `Value`.
  @outsider_values_per_minute 10
  @outsider_edit_interval_seconds 10
  @outsider_mention_pushes 5

  @doc """
  Posts a chat value. `attachments` are files already in `PotokIde.Storage`,
  as maps with `:storage_key`, `:filename`, `:content_type` and `:byte_size`;
  they come from the upload, never from `attrs`. A value with files may have
  no text.
  """
  def create_value(%Profile{} = creator, %Group{} = group, attrs, attachments \\ []) do
    attrs = Map.new(attrs)

    cond do
      data_value_attrs?(attrs) and attachments == [] ->
        create_data_value(creator, group, attrs)

      data_value_attrs?(attrs) ->
        {:error, :invalid_attachments}

      true ->
        create_chat_value(creator, group, attrs, attachments)
    end
  end

  defp create_chat_value(%Profile{} = creator, %Group{} = group, attrs, attachments) do
    with {:ok, value, announce} <- insert_chat_value(creator, group, attrs, attachments, []) do
      announce.()
      {:ok, value}
    end
  end

  @doc """
  Writes a chat value signed by an app's process, inside the transaction of
  the step that does it (`PotokIde.Social.ProcessActions`), with where it
  comes from in `managed`. Returns `{:ok, value, announce}`: no page and no
  device hears of the value until the step commits and calls `announce`.
  """
  def insert_process_value(%Profile{kind: :process} = process, %Group{} = group, attrs, managed)
      when is_map(managed) do
    insert_chat_value(process, group, Map.new(attrs), [], managed: managed)
  end

  @doc """
  Writes a chat value its author scheduled, inside the transaction that takes
  it from what waits (`PotokIde.Social.ScheduledValues`). Returns
  `{:ok, value, announce}`, as `insert_process_value/4`. With
  `unattended: true` the author may not be looking, so it does not mark as
  read what others wrote before it.
  """
  def insert_scheduled_value(
        %Profile{} = creator,
        %Group{} = group,
        attrs,
        attachments,
        unattended: unattended?
      )
      when is_boolean(unattended?) do
    insert_chat_value(creator, group, attrs, attachments, unattended: unattended?)
  end

  @doc """
  A push from an app's process to the members of `group` holding `role_key`
  (`PotokIde.Social.ProcessActions`). Returns how many people it is for and
  the function that sends it, to call once the step commits. `url` is where
  the push leads, the group by default. A push to everyone passes by those
  who silenced the group; one to a role reaches them.
  """
  def process_push(
        %Profile{kind: :process} = process,
        %Group{} = group,
        role_key,
        text,
        tag,
        url \\ nil
      )
      when is_binary(role_key) and is_binary(text) do
    profile_ids = Access.profile_ids_with_role(group, role_key) -- muted_for(group, role_key)
    payload_for = Notifications.process_push(process, group, text, tag, url)

    {length(profile_ids),
     fn ->
       run_notification(fn ->
         from(ap in AccountProfile, where: ap.profile_id in ^profile_ids, select: ap.account_id)
         |> Dispatch.subscriptions_by_account()
         |> Dispatch.deliver_localized("process push", group.id, payload_for)
       end)
     end}
  end

  defp muted_for(group, "everyone"), do: Repo.all(GroupMutes.muted_profile_ids(group))
  defp muted_for(_group, _role_key), do: []

  # The checks and the writes of a chat value. What its pages and devices are
  # told comes back as a function, to call once the writes are committed.
  defp insert_chat_value(%Profile{} = creator, %Group{} = group, attrs, attachments, opts) do
    access = Access.for_profile(creator, group)

    cond do
      not Access.can_read_chat?(access, group) ->
        {:error, :not_a_member_of_group}

      not Access.can_post_in_chat?(creator, access, group) ->
        {:error, :not_permitted}

      attachments != [] and not Access.can?(access, :attach_files) ->
        {:error, :not_permitted}

      length(attachments) > Storage.max_files() ->
        {:error, :too_many_attachments}

      # The reply quote shows the parent's content, so it must be a chat
      # value the group's members can already read.
      not chat_value_in_group?(Map.get(attrs, "parent_id"), group.id) ->
        {:error, :invalid_parent}

      not access.member? and outsider_at_limit?(creator, group) ->
        {:error, :too_many_values}

      true ->
        attrs =
          attrs
          |> Map.put("creator_id", creator.id)
          |> Map.put("group_id", group.id)

        changeset =
          %Value{managed: opts[:managed]}
          |> Value.changeset(attrs, attachments?: attachments != [])
          |> limit_outsider(access)
          |> put_mentions(creator, group)

        Multi.new()
        |> Multi.run(:mentioned, fn repo, _changes ->
          {:ok,
           join_mentioned(
             repo,
             group,
             Ecto.Changeset.get_field(changeset, :mentioned_profile_ids)
           )}
        end)
        |> Multi.insert(:value, changeset)
        |> Multi.run(:attachments, fn repo, %{value: value} ->
          insert_value_attachments(repo, value, attachments)
        end)
        |> Multi.run(:mark_creator_read, fn repo, %{value: value} ->
          if opts[:unattended] == true and unread_before?(repo, creator, value),
            do: {:ok, :unchanged},
            else: upsert_group_value_read(repo, creator.id, group.id, value.id)
        end)
        |> Multi.run(:group_last_value_at, fn repo, %{value: value} ->
          {:ok, set_group_last_value_at(repo, group.id, value.inserted_at)}
        end)
        # A member's message starts the processes drawn on messages it holds
        # the words of (`Processes.Engine.start_on_message/3`).
        |> Multi.run(:processes, fn _repo, %{value: value} ->
          {:ok, if(access.member?, do: Engine.start_on_message(value, group, creator), else: [])}
        end)
        |> Repo.transaction()
        |> case do
          {:ok, %{value: value, processes: started, mentioned: mentioned}} ->
            value = value |> Repo.preload(value_display_preloads()) |> put_display_extras()

            {:ok, value,
             fn ->
               broadcast_inheritance_changes(mentioned)
               broadcast_value_created(group, value)
               broadcast_group_value_unread(creator, group, value)
               notify_group_members_of_new_value(creator, group, value, access)
               schedule_link_preview(value)
               if started != [], do: PotokIde.Processes.Scheduler.nudge()
             end}

          {:error, _step, reason, _changes} ->
            {:error, reason}
        end
    end
  end

  # Whether `creator` has something by others to read before `value`. Moving
  # the marker past it would read it for them, so a value sent in their absence
  # then counts as unread along with it.
  defp unread_before?(repo, %Profile{id: profile_id}, %Value{id: value_id, group_id: group_id}) do
    last_read_id =
      from(r in GroupValueRead,
        where: r.profile_id == ^profile_id and r.group_id == ^group_id,
        select: r.last_read_value_id
      )
      |> repo.one() || 0

    from(v in Value,
      where:
        v.group_id == ^group_id and v.is_data == false and v.id > ^last_read_id and
          v.id < ^value_id and v.creator_id != ^profile_id
    )
    |> repo.exists?()
  end

  # Those a message in a thread mentions come in before it is written, so it
  # counts as unread for them and pushes them (`join_thread/2`).
  defp join_mentioned(repo, %Group{parent_value_id: value_id, id: thread_id}, [_ | _] = ids)
       when not is_nil(value_id),
       do: MemberInheritance.join(repo, thread_id, ids)

  defp join_mentioned(_repo, _group, _profile_ids), do: []

  defp limit_outsider(changeset, %Access{member?: true}), do: changeset
  defp limit_outsider(changeset, %Access{}), do: Value.outsider_changeset(changeset)

  # Counted in the database, so the limit holds over a reconnect and across nodes.
  defp outsider_at_limit?(%Profile{id: profile_id}, %Group{id: group_id}) do
    since = DateTime.add(DateTime.utc_now(), -60, :second)

    from(v in Value,
      where:
        v.group_id == ^group_id and v.is_data == false and v.creator_id == ^profile_id and
          v.inserted_at >= ^since,
      select: count()
    )
    |> Repo.one() >= @outsider_values_per_minute
  end

  # An edit reaches everyone on the page as a new value does, and fetches links
  # again. Link previews are written past `updated_at`, so it only moves on an
  # edit and the first correction of a new value always goes through.
  defp edited_just_now?(%Value{id: value_id}) do
    since = DateTime.add(DateTime.utc_now(), -@outsider_edit_interval_seconds, :second)

    Repo.exists?(
      from(v in Value,
        where: v.id == ^value_id and v.updated_at > v.inserted_at and v.updated_at > ^since
      )
    )
  end

  @doc """
  Posts the chat value that announces a calendar event or a poll. It counts as
  unread like any chat value, but takes no @mentions or link preview, and
  members get `payload_for`'s push (it gets a device's locale) instead of the
  generic one. `link` gets the repo and the value inside the transaction and
  points the event or poll at it. `push_context` names it in the logs.

  With `by_rule: true` the group's rule posts it in the creator's name, as a
  poll a request raises (`PotokIde.Social.GroupRequests`): the creator's
  right to post does not count then.
  """
  def post_announcement(
        %Profile{} = creator,
        %Group{} = group,
        content,
        link,
        payload_for,
        push_context,
        opts \\ []
      )
      when is_function(link, 2) and is_map(payload_for) do
    if opts[:by_rule] == true or Access.can?(creator, group, :post_values) do
      changeset =
        %Value{link_preview_dismissed: true}
        |> Value.changeset(%{
          "content" => content,
          "content_format" => :markdown,
          "creator_id" => creator.id,
          "group_id" => group.id
        })

      Multi.new()
      |> Multi.insert(:value, changeset)
      |> Multi.run(:event, fn repo, %{value: value} -> link.(repo, value) end)
      |> Multi.run(:mark_creator_read, fn repo, %{value: value} ->
        upsert_group_value_read(repo, creator.id, group.id, value.id)
      end)
      |> Multi.run(:group_last_value_at, fn repo, %{value: value} ->
        {:ok, set_group_last_value_at(repo, group.id, value.inserted_at)}
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{value: value}} ->
          value = Repo.preload(value, value_display_preloads())
          broadcast_value_created(group, value)
          broadcast_group_value_unread(creator, group, value)

          run_notification(fn ->
            group
            |> push_subscriptions_for_group_value(creator)
            |> Dispatch.deliver_localized(push_context, group.id, payload_for)
          end)

          {:ok, value}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    else
      {:error, :not_permitted}
    end
  end

  @doc "Sends a chat value to its viewers again, e.g. after its event changed."
  def refresh_value(nil), do: :ok
  def refresh_value(value_id) when is_integer(value_id), do: broadcast_values_updated([value_id])

  defp insert_value_attachments(repo, %Value{} = value, attachments) do
    Enum.reduce_while(attachments, {:ok, []}, fn file, {:ok, inserted} ->
      %ValueAttachment{
        value_id: value.id,
        group_id: value.group_id,
        profile_id: value.creator_id,
        storage_key: Map.fetch!(file, :storage_key)
      }
      |> ValueAttachment.changeset(Map.take(file, [:filename, :content_type, :byte_size]))
      |> repo.insert()
      |> case do
        {:ok, attachment} -> {:cont, {:ok, [attachment | inserted]}}
        {:error, changeset} -> {:halt, {:error, changeset}}
      end
    end)
  end

  @doc """
  Inserts an app (data) value. Data values never count as unread and never
  notify anyone, so this skips the read marker, the per-member unread
  broadcasts and push notifications that chat values trigger.

  `alt_description` is the app it belongs to: nil for the default
  description's app.
  """
  def create_data_value(%Profile{} = creator, %Group{} = group, attrs, alt_description \\ nil) do
    cond do
      not member_of_group?(creator, group) ->
        {:error, :not_a_member_of_group}

      ensure_own_alt_description(group, alt_description) != :ok ->
        {:error, :not_found}

      true ->
        insert_data_value(creator, group, attrs, alt_description)
    end
  end

  defp insert_data_value(creator, group, attrs, alt_description) do
    attrs =
      attrs
      |> Map.new(fn {key, value} -> {to_string(key), value} end)
      |> Map.merge(%{"is_data" => true, "creator_id" => creator.id, "group_id" => group.id})

    %Value{alt_description_id: alt_description && alt_description.id}
    |> Value.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, value} ->
        value = %{value | creator: creator}
        broadcast_data_value_created(group, value)
        {:ok, value}

      error ->
        error
    end
  end

  defp data_value_attrs?(attrs) do
    Map.get(attrs, "is_data", Map.get(attrs, :is_data)) in [true, "true"]
  end

  # True when `value_id` is empty or names a chat value of the group.
  defp chat_value_in_group?(value_id, _group_id) when value_id in [nil, ""], do: true

  defp chat_value_in_group?(value_id, group_id) do
    case Integer.parse(to_string(value_id)) do
      {id, ""} ->
        Repo.exists?(
          from(v in Value, where: v.id == ^id and v.group_id == ^group_id and v.is_data == false)
        )

      _ ->
        false
    end
  end

  @doc """
  Updates the content of the profile's own value. Only `content` and
  `content_format` can change, so an edit never moves a value or changes what
  it replies to. Replies are re-broadcast so their quotes show the new text.
  An author outside the group edits under the rules it wrote by: only while it
  may write, and within the limits of an open chat.
  """
  def update_value(%Profile{} = profile, %Value{} = value, attrs) do
    cond do
      value.creator_id != profile.id ->
        {:error, :not_value_creator}

      # Its card shows the event or poll, which is changed where it lives.
      announcement?(value) ->
        {:error, :announcement}

      true ->
        group = Repo.get!(Group, value.group_id)
        access = Access.for_profile(profile, group)

        cond do
          # A closed direct conversation stays as it was (`ProfileBlocks`).
          access.closed? -> {:error, :not_permitted}
          access.member? -> do_update_value(profile, group, access, value, attrs)
          not Access.can_post_in_chat?(profile, access, group) -> {:error, :not_permitted}
          edited_just_now?(value) -> {:error, :too_many_values}
          true -> do_update_value(profile, group, access, value, attrs)
        end
    end
  end

  defp announcement?(%Value{id: value_id}) do
    Repo.exists?(from(e in PotokIde.Events.Event, where: e.value_id == ^value_id)) or
      Repo.exists?(from(p in Poll, where: p.value_id == ^value_id))
  end

  defp do_update_value(profile, group, access, value, attrs) do
    attrs = Map.take(Map.new(attrs), ["content", "content_format", :content, :content_format])

    # Mentions follow the new text, but an edit notifies nobody. A value
    # with files may lose its text.
    value
    |> Value.changeset(attrs, attachments?: value_has_attachments?(value))
    |> limit_outsider(access)
    |> put_mentions(profile, group)
    |> reset_link_preview(value)
    |> History.update(actor: profile)
    |> case do
      {:ok, updated_value} ->
        # Someone an edit mentions in a thread comes in, as with a new one.
        if group.parent_value_id && updated_value.mentioned_profile_ids != [],
          do: join_thread_profiles(group, updated_value.mentioned_profile_ids)

        # Read again rather than preloaded: `value` may predate its link
        # preview, which is written outside of edits.
        updated_value =
          get_value_for_display(updated_value.id) ||
            updated_value
            |> Repo.preload(value_display_preloads(), force: true)
            |> put_display_extras()

        broadcast_value_updated(updated_value)
        broadcast_values_updated(reply_ids(updated_value))
        maybe_broadcast_last_value_edited(group, updated_value)
        schedule_link_preview(updated_value)
        {:ok, updated_value}

      error ->
        error
    end
  end

  def delete_value(%Profile{} = profile, %Value{} = value) do
    cond do
      value.creator_id != profile.id and
          not Access.can?(profile, Repo.get!(Group, value.group_id), :delete_values) ->
        {:error, :not_value_creator}

      # A decision that changes roles is the record of what the group decided.
      carries_decision?(value) ->
        {:error, :decision}

      true ->
        remove_value(value, actor: profile)
    end
  end

  @doc """
  Deletes a reported value for an admin who handles its report
  (`ValueReports.delete_value/2`), who may lack the role in a thread it is
  in. A decision stays, as with `delete_value/2`.
  """
  def moderate_value(%Profile{} = admin, %Value{} = value) do
    if carries_decision?(value),
      do: {:error, :decision},
      else: remove_value(value, actor: admin)
  end

  defp carries_decision?(%Value{id: value_id}) do
    Repo.exists?(
      from(p in Poll,
        where:
          p.value_id == ^value_id and not is_nil(p.effect) and
            (p.voters_count > 0 or not is_nil(p.closed_at))
      )
    )
  end

  @doc """
  Deletes a value for whoever already may: `delete_value/2`, or a poll deleted
  with its message. A poll the value carries goes with it. `signature` says who
  did it (`PotokIde.History`).
  """
  def remove_value(%Value{} = value, signature) when is_list(signature) do
    # Read before the delete: `values.parent_id` is nilified with it, and the
    # poll is deleted with it.
    reply_ids = reply_ids(value)
    poll = Repo.one(from(p in Poll, where: p.value_id == ^value.id))
    # Its reports go with it; their admins count again after.
    report_group_ids = ValueReports.open_group_ids(value.id)

    Multi.new()
    |> Multi.delete_all(
      :attachments,
      from(a in ValueAttachment, where: a.value_id == ^value.id, select: a.storage_key)
    )
    |> Multi.delete(:value, value)
    |> Multi.run(:waiting_run, fn _repo, _changes ->
      {:ok, if(poll, do: Engine.poll_deleted(poll), else: [])}
    end)
    |> Multi.run(:group_last_value_at, fn repo, _changes ->
      # The newest by id, which grows with the time of writing: the chat's
      # index on (group_id, id) answers it from its end.
      latest =
        from(v in Value,
          where: v.group_id == ^value.group_id and v.is_data == false,
          order_by: [desc: v.id],
          limit: 1,
          select: v.inserted_at
        )
        |> repo.one()

      set_group_last_value_at(repo, value.group_id, latest)
      {:ok, latest}
    end)
    |> History.transaction(signature)
    |> case do
      {:ok,
       %{
         value: deleted_value,
         attachments: {_count, storage_keys},
         waiting_run: announcements,
         group_last_value_at: last_value_at
       }} ->
        Storage.delete_later(storage_keys)
        Enum.each(announcements, & &1.())
        broadcast_value_deleted(deleted_value)
        broadcast_group_value_removed(deleted_value)
        maybe_broadcast_last_value_removed(deleted_value, last_value_at)
        broadcast_values_updated(reply_ids)
        if poll, do: Polls.broadcast_deleted(poll)
        ValueReports.reports_changed(report_group_ids)
        {:ok, deleted_value}

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # A list row shows the group's newest value (`ValuePreview`), so an edit of
  # that one goes to the members' pages, which only change the row.
  defp maybe_broadcast_last_value_edited(%Group{is_root: true}, _value), do: :ok

  defp maybe_broadcast_last_value_edited(%Group{} = group, %Value{} = value) do
    if latest_group_value_id(group) == value.id do
      broadcast_group_last_value_changed(
        group.id,
        ValuePreview.from_value(value),
        value.inserted_at
      )
    end

    :ok
  end

  # Deleting the newest value puts the one before it, or nothing, in the
  # group's row, so a deleted text does not linger in the lists.
  defp maybe_broadcast_last_value_removed(%Value{is_data: true}, _last_value_at), do: :ok

  defp maybe_broadcast_last_value_removed(%Value{id: id, group_id: group_id}, last_value_at) do
    preview = Map.get(last_chat_previews([group_id]), group_id)

    if preview == nil or preview.value_id < id do
      broadcast_group_last_value_changed(group_id, preview, last_value_at)
    end

    :ok
  end

  defp broadcast_group_last_value_changed(group_id, preview, last_value_at) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      group_unread_topic(group_id),
      {:group_last_value_changed, group_id, preview, last_value_at}
    )
  end

  # `groups.last_value_at` orders the sub-groups list. `update_all` leaves
  # `updated_at` alone, which the group avatar URL uses as its cache buster.
  defp set_group_last_value_at(repo, group_id, last_value_at) do
    {count, _} =
      from(g in Group, where: g.id == ^group_id)
      |> repo.update_all(set: [last_value_at: last_value_at])

    count
  end

  defp value_has_attachments?(%Value{attachments: attachments}) when is_list(attachments),
    do: attachments != []

  defp value_has_attachments?(%Value{id: value_id}),
    do: Repo.exists?(from(a in ValueAttachment, where: a.value_id == ^value_id))

  # Chat values only: data values never mention anyone.
  defp put_mentions(%Ecto.Changeset{} = changeset, %Profile{} = author, %Group{} = group) do
    if Ecto.Changeset.get_field(changeset, :is_data) do
      changeset
    else
      {mentions, profile_ids} =
        changeset
        |> Ecto.Changeset.get_field(:content)
        |> Mentions.resolve(author, group)

      Ecto.Changeset.change(changeset, mentions: mentions, mentioned_profile_ids: profile_ids)
    end
  end

  # A chat's page knows its viewer, so a value's link to a form may get a card
  # only the form's members see (`LinkPreviews.visible/2`), and a link to a
  # message one only those who may read it see (`PotokIdeWeb.MessageLinks`).
  @value_links [closed_forms: true, message_links: true]

  # An edit that changes the first link drops the old link's preview; the
  # new one is fetched once the edit is saved. Forced, since `value` may have
  # been read before its preview was written.
  defp reset_link_preview(%Ecto.Changeset{} = changeset, %Value{} = value) do
    new_url =
      changeset |> Ecto.Changeset.get_field(:content) |> LinkPreviews.first_url(@value_links)

    if new_url == LinkPreviews.first_url(value.content, @value_links),
      do: changeset,
      else: Ecto.Changeset.force_change(changeset, :link_preview, nil)
  end

  # The preview of a value's first link comes later: the page is fetched off
  # the caller, then every viewer is sent the value again with its card. A
  # link to a form may get a card only the form's members see: the chat's
  # page shows it to them alone (`LinkPreviews.visible/2`).
  defp schedule_link_preview(%Value{is_data: true}), do: :ok
  defp schedule_link_preview(%Value{link_preview_dismissed: true}), do: :ok
  defp schedule_link_preview(%Value{link_preview: %{}}), do: :ok

  defp schedule_link_preview(%Value{id: value_id, content: content}) do
    case LinkPreviews.first_url(content, @value_links) do
      nil -> :ok
      url -> LinkPreviews.run(fn -> fetch_value_link_preview(value_id, url) end)
    end
  end

  # Kept only while the value still leads with `url`: the text it was
  # fetched for must not have been edited or the preview dismissed meanwhile.
  # `updated_at` stays, since a preview is not an edit.
  defp fetch_value_link_preview(value_id, url) do
    with {:ok, preview} <- LinkPreviews.fetch(url, @value_links),
         %Value{is_data: false, link_preview_dismissed: false} = value <-
           Repo.get(Value, value_id),
         ^url <- LinkPreviews.first_url(value.content, @value_links),
         {1, _} <-
           from(v in Value,
             where:
               v.id == ^value_id and v.content == ^value.content and
                 v.link_preview_dismissed == false
           )
           |> Repo.update_all(set: [link_preview: preview]),
         %Value{} = updated_value <- get_value_for_display(value_id) do
      broadcast_value_updated(updated_value)
    end

    :ok
  end

  @doc """
  Hides the link preview of the profile's own value for good: later edits
  do not fetch another one.
  """
  def dismiss_value_link_preview(%Profile{} = profile, %Value{} = value) do
    if value.creator_id != profile.id do
      {:error, :not_value_creator}
    else
      from(v in Value, where: v.id == ^value.id)
      |> Repo.update_all(set: [link_preview: nil, link_preview_dismissed: true])

      case get_value_for_display(value.id) do
        nil ->
          {:error, :not_found}

        updated_value ->
          broadcast_value_updated(updated_value)
          {:ok, updated_value}
      end
    end
  end

  defp reply_ids(%Value{id: value_id}) do
    from(v in Value, where: v.parent_id == ^value_id and v.is_data == false, select: v.id)
    |> Repo.all()
  end

  # Re-sends values whose rendering depends on another row: replies quote
  # their parent, and a value shows a link to its thread.
  defp broadcast_values_updated([]), do: :ok

  defp broadcast_values_updated(value_ids) do
    from(v in Value, where: v.id in ^value_ids, preload: ^value_display_preloads())
    |> Repo.all()
    |> put_display_extras()
    |> Enum.each(&broadcast_value_updated/1)
  end

  @doc """
  Opens the thread of chat `value`: the sub-group of the value's group that
  points at it through `parent_value_id`. The first call creates it as a
  chat-first group named by `attrs["name"]` that inherits the members of
  `group`; later calls return it. Viewers of `group` are sent the value again
  so its thread link appears.
  """
  def get_or_create_value_thread(%Profile{} = profile, %Group{} = group, %Value{} = value, attrs) do
    cond do
      value.group_id != group.id or value.is_data ->
        {:error, :value_not_found}

      group.is_direct or group.is_root ->
        {:error, :threads_not_supported}

      not member_of_group?(profile, group) ->
        {:error, :not_a_member_of_group}

      thread = get_value_thread(value) ->
        {:ok, thread}

      not Access.can?(profile, group, :open_threads) ->
        {:error, :not_permitted}

      true ->
        create_value_thread(profile, group, value, attrs)
    end
  end

  defp get_value_thread(%Value{id: value_id}) do
    Repo.one(from(g in Group, where: g.parent_value_id == ^value_id))
  end

  # The thread inherits from `group`, lazily: it starts with whoever opens
  # it and the author of `value`, and takes in the group's other members as
  # they take part (`join_thread/2`).
  defp create_value_thread(%Profile{} = profile, %Group{} = group, %Value{} = value, attrs) do
    group_attrs = %{
      "name" => Map.get(Map.new(attrs), "name"),
      "description" => "",
      "description_format" => :markdown,
      "home_page" => :chat,
      "is_public" => group.is_public,
      "is_direct" => false,
      "is_root" => false,
      "inherits_members" => true,
      "creator_id" => profile.id,
      "parent_id" => group.id,
      "parent_value_id" => value.id
    }

    case insert_group_with_creator(profile, group, group_attrs) do
      {:ok, thread} ->
        if value.creator_id != profile.id,
          do: join_thread(%Profile{id: value.creator_id}, thread)

        broadcast_values_updated([value.id])
        {:ok, thread}

      {:error, %Ecto.Changeset{} = changeset} ->
        # Someone else opened the thread first: the unique index kept theirs.
        case {Keyword.has_key?(changeset.errors, :parent_value_id), get_value_thread(value)} do
          {true, %Group{} = thread} -> {:ok, thread}
          _ -> {:error, changeset}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Takes the profile into thread `thread` when it is a member of the thread's
  group and not of the thread yet: a thread counts and pushes only for those
  who take part (opened it, wrote in it, wrote the value it was opened on,
  or were mentioned in it). They come in as inherited members, with the
  roles they hold in the group and the thread read up to now
  (`MemberInheritance.join/3`). Anything else is left alone. Returns `:ok`.
  """
  def join_thread(%Profile{} = profile, %Group{parent_value_id: value_id} = thread)
      when not is_nil(value_id) do
    if member_of_group?(profile, thread),
      do: :ok,
      else: join_thread_profiles(thread, [profile.id])
  end

  def join_thread(_profile, _group), do: :ok

  defp join_thread_profiles(%Group{id: thread_id}, profile_ids) do
    {:ok, changes} =
      Repo.transaction(fn -> MemberInheritance.join(Repo, thread_id, profile_ids) end)

    broadcast_inheritance_changes(changes)
    :ok
  end

  @doc """
  The chat value a thread group was started from, with its author, when the
  profile can read the group the value lives in; nil otherwise.
  """
  def get_thread_origin(%Profile{} = profile, %Group{parent_value_id: value_id})
      when is_integer(value_id) do
    from(v in Value,
      join: g in assoc(v, :group),
      where: v.id == ^value_id and v.is_data == false,
      preload: [creator: :app_process, attachments: ^attachments_in_order(), group: g]
    )
    |> Repo.one()
    |> case do
      %Value{group: group} = value ->
        if group.is_public or member_of_group?(profile, group), do: value

      nil ->
        nil
    end
  end

  def get_thread_origin(_profile, _group), do: nil

  @doc """
  Whether `value_id` is a chat value of group `group_id`, for a link to it
  (`PotokIdeWeb.MessageLinks.ref/1`), whoever may read it: never one of the
  root or an app's data value.
  """
  def linked_chat_value?(group_id, value_id) when is_integer(group_id) and is_integer(value_id) do
    Repo.exists?(
      from(v in Value,
        join: g in assoc(v, :group),
        where:
          v.id == ^value_id and v.group_id == ^group_id and v.is_data == false and
            g.is_root == false
      )
    )
  end

  @doc """
  The chat values among `value_ids` that `profile` may read, for the cards of
  links to them (`PotokIdeWeb.MessageLinks`), as `%{value_id => {value,
  picture?}}`. A member of the value's group reads it, and so does anyone in
  an open chat, but for the announcement of an event that is not public,
  which the chat hides from them. A member of the group a thread was opened
  in reads the thread's values too, as opening the link takes them in
  (`join_thread/2`), but gets no picture: `/files` gives one only to the
  thread's members (`get_attachment_for_download/2`). Values come with their
  author, group (a direct conversation with its two members, for its name),
  event and files. Two queries, three with a direct conversation, none for
  no ids.
  """
  def readable_linked_values(_profile, []), do: %{}

  def readable_linked_values(%Profile{} = profile, value_ids) when is_list(value_ids) do
    values =
      from(v in Value,
        join: g in assoc(v, :group),
        where: v.id in ^value_ids and v.is_data == false and g.is_root == false,
        preload: [:event, group: g, creator: :app_process, attachments: ^attachments_in_order()]
      )
      |> Repo.all()

    asked =
      values
      |> Enum.flat_map(fn %Value{group: group} ->
        if group.parent_value_id, do: [group.id, group.parent_id], else: [group.id]
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    members = member_group_ids_among(profile, asked)

    readable =
      for value <- values, sees = linked_value_sight(value, members), do: {value, sees}

    directs =
      for {%Value{group: %Group{is_direct: true} = group}, _sees} <- readable,
          uniq: true,
          do: group

    named = directs |> Repo.preload(:members) |> Map.new(&{&1.id, &1})

    Map.new(readable, fn {value, sees} ->
      {value.id, {%{value | group: Map.get(named, value.group_id, value.group)}, sees == :all}}
    end)
  end

  def readable_linked_values(_profile, _value_ids), do: %{}

  # How much of a linked value `members` (the viewer's groups among the
  # value's group and the one above a thread) lets the viewer see.
  defp linked_value_sight(%Value{group: group} = value, members) do
    cond do
      MapSet.member?(members, group.id) ->
        :all

      Group.open_chat?(group) ->
        if match?(%PotokIde.Events.Event{is_public: false}, value.event), do: nil, else: :all

      not is_nil(group.parent_value_id) and MapSet.member?(members, group.parent_id) ->
        :text

      true ->
        nil
    end
  end

  @doc """
  Adds the profile's `emoji` reaction to a chat value, or removes it when the
  profile already reacted with that emoji. A profile can hold several
  different emoji on the same value. Returns the value reloaded for display
  and broadcasts it as a `:value_updated` so every viewer re-renders it.
  """
  def toggle_value_reaction(%Profile{} = profile, %Group{} = group, %Value{} = value, emoji) do
    access = Access.for_profile(profile, group)

    cond do
      value.group_id != group.id or value.is_data ->
        {:error, :value_not_found}

      not is_binary(emoji) ->
        {:error, :invalid_emoji}

      not Access.can_read_chat?(access, group) ->
        {:error, :not_a_member_of_group}

      not Access.can_react_in_chat?(profile, access, group) ->
        {:error, :not_permitted}

      true ->
        existing =
          from(r in ValueReaction,
            where: r.value_id == ^value.id and r.profile_id == ^profile.id and r.emoji == ^emoji
          )

        result =
          if Repo.exists?(existing) do
            Repo.delete_all(existing)
            :ok
          else
            %ValueReaction{value_id: value.id, profile_id: profile.id}
            |> ValueReaction.changeset(%{emoji: emoji})
            # A double click races the existence check; the unique index settles it.
            |> Repo.insert(on_conflict: :nothing)
          end

        case {result, get_value_for_display(value.id)} do
          {{:error, %Ecto.Changeset{}} = error, _value} ->
            error

          {_result, nil} ->
            {:error, :value_not_found}

          {_result, %Value{} = updated_value} ->
            broadcast_value_reacted(updated_value, %{
              actor_id: profile.id,
              emoji: emoji,
              added?: result != :ok
            })

            # As with a reaction to a group, someone outside it pushes nobody.
            if access.member?,
              do: notify_value_creator_of_reaction(result, profile, group, updated_value)

            {:ok, updated_value}
        end
    end
  end

  @doc """
  Adds the profile's `emoji` reaction to a group, or removes it when the
  profile already reacted with that emoji. Who may is
  `Access.can_react_to_group?/3`. Returns `{:ok, reactions}`, the group's entry
  of `group_reaction_summaries/2`, and tells the group's pages.

  Nobody gets a push: a post read by many people would send its author one
  after another, and the number is on the post anyway.
  """
  def toggle_group_reaction(%Profile{} = profile, %Group{} = group, emoji) do
    access = Access.for_profile(profile, group)

    cond do
      not is_binary(emoji) ->
        {:error, :invalid_emoji}

      not Access.can_react_to_group?(profile, access, group) ->
        {:error, :not_permitted}

      true ->
        existing =
          from(r in GroupReaction,
            where: r.group_id == ^group.id and r.profile_id == ^profile.id and r.emoji == ^emoji
          )

        result =
          if Repo.exists?(existing) do
            Repo.delete_all(existing)
            :ok
          else
            %GroupReaction{group_id: group.id, profile_id: profile.id}
            |> GroupReaction.changeset(%{emoji: emoji})
            # A double click races the existence check; the unique index settles it.
            |> Repo.insert(on_conflict: :nothing)
          end

        case result do
          {:error, %Ecto.Changeset{}} = error ->
            error

          _changed ->
            summaries = Map.get(group_reaction_summaries([group.id], profile), group.id, [])

            broadcast_group_reactions_updated(group, summaries, %{
              actor_id: profile.id,
              emoji: emoji,
              added?: result != :ok
            })

            {:ok, summaries}
        end
    end
  end

  @doc """
  The reactions of each of `group_ids` as `%{group_id => [reaction]}`, a group
  without any left out. One entry per emoji, in the order the emoji was first
  used on the group: `:emoji`, `:key` (safe in a DOM id), `:count`, `:mine?` and
  `:names`, the first 20 who used it. `profile` may be nil.
  """
  def group_reaction_summaries(group_ids, profile) when is_list(group_ids) do
    profile_id = profile && profile.id

    from(r in GroupReaction,
      join: p in assoc(r, :profile),
      where: r.group_id in ^group_ids,
      group_by: [r.group_id, r.emoji],
      order_by: [asc: min(r.id)],
      select:
        {r.group_id,
         %{
           emoji: r.emoji,
           count: count(r.id),
           mine?:
             fragment("COALESCE(bool_or(? = ?), false)", r.profile_id, type(^profile_id, :id)),
           names: fragment("(array_agg(? ORDER BY ?))[1:20]", p.username, r.id)
         }}
    )
    |> Repo.all()
    |> Enum.group_by(
      fn {group_id, _reaction} -> group_id end,
      fn {_group_id, reaction} ->
        Map.put(reaction, :key, Base.encode16(reaction.emoji, case: :lower))
      end
    )
  end

  @doc """
  The chat values of each of `group_ids` as `%{group_id => count}`, a group
  without any left out. A thread is a group of its own, so what is said in one
  does not count.
  """
  def group_comment_counts(group_ids) when is_list(group_ids) do
    from(v in Value,
      where: v.group_id in ^group_ids and v.is_data == false,
      group_by: v.group_id,
      select: {v.group_id, count(v.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Deletes the data values of one app of the group: the default
  description's (nil) or an alternative description's.
  """
  def delete_group_data_values(%Profile{} = actor, %Group{} = group, alt_description \\ nil) do
    with :ok <- ensure_permission(actor, group, :edit_group),
         :ok <- ensure_own_alt_description(group, alt_description) do
      {:ok, {deleted_count, _}} =
        History.transaction([actor: actor], fn ->
          from(v in Value,
            where: v.group_id == ^group.id and v.is_data == true
          )
          |> filter_data_value_scope({:app, alt_description && alt_description.id})
          |> Repo.delete_all(timeout: History.bulk_timeout())
        end)

      if deleted_count > 0 do
        broadcast_group_updated(group)
        # An app open meanwhile starts over: its config may be gone with the rest.
        PotokIde.Social.AppData.broadcast(group, :cleared, %{
          alt_id: alt_description && alt_description.id,
          collection: nil
        })
      end

      {:ok, deleted_count}
    end
  end

  # ---------
  # Roles
  # ---------

  @doc "What `profile` may do in `group`; see `PotokIde.Social.Access`."
  def get_group_access(profile, %Group{} = group), do: Access.for_profile(profile, group)

  def change_group_role(%GroupRole{} = role, attrs \\ %{}), do: GroupRole.changeset(role, attrs)

  @doc """
  Adds a custom role to the group's own manifest. Only admins of the group
  that owns the manifest change it; the root manifest is fixed.
  """
  def create_group_role(%Profile{} = actor, %Group{} = group, attrs) do
    with {:ok, manifest} <- editable_manifest(actor, group) do
      position = manifest.roles |> Enum.map(& &1.position) |> Enum.max(fn -> 0 end)

      Repo.transaction(fn ->
        %GroupRole{manifest_id: manifest.id, key: Ecto.UUID.generate(), position: position + 1}
        |> GroupRole.changeset(take_role_attrs(attrs))
        |> Repo.insert()
        |> record_role_change(group, actor, :role_added, fn role -> %{role: role.name} end)
      end)
      |> case do
        {:ok, role} ->
          broadcast_manifest_updated(manifest)
          {:ok, role}

        error ->
          error
      end
    end
  end

  def rename_group_role(%Profile{} = actor, %Group{} = group, role_key, attrs) do
    with {:ok, manifest} <- editable_manifest(actor, group),
         {:ok, role} <- fetch_custom_role(manifest, role_key) do
      Repo.transaction(fn ->
        role
        |> GroupRole.changeset(take_role_attrs(attrs))
        |> Repo.update()
        |> record_role_change(group, actor, :role_renamed, fn renamed ->
          if renamed.name != role.name, do: %{from: role.name, to: renamed.name}
        end)
      end)
      |> case do
        {:ok, role} ->
          broadcast_manifest_updated(manifest)
          {:ok, role}

        error ->
          error
      end
    end
  end

  # Inside a transaction: the role written, or a rollback with what went
  # wrong. `data` gives the row's data from the role, or nil when nothing
  # worth keeping changed.
  defp record_role_change({:ok, role}, group, actor, kind, data) do
    case data.(role) do
      nil ->
        role

      data ->
        AccessHistory.record!(Repo, group, kind, actor: actor.id, role_key: role.key, data: data)
        role
    end
  end

  defp record_role_change({:error, changeset}, _group, _actor, _kind, _data),
    do: Repo.rollback(changeset)

  defp take_role_attrs(attrs) do
    attrs
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.take(["name"])
  end

  @doc """
  Sets whether the role allows (`:allow`), denies (`:deny`) or says nothing
  about (`:neutral`) a permission. "admin" always holds every permission and
  "everyone" can only allow.
  """
  def set_group_role_permission(%Profile{} = actor, %Group{} = group, role_key, permission, state)
      when state in [:allow, :deny, :neutral] do
    with {:ok, manifest} <- editable_manifest(actor, group),
         {:ok, role} <- fetch_role(manifest, role_key),
         :ok <- validate_permission_change(role, permission, state) do
      allowed = List.delete(role.allowed, permission)
      denied = List.delete(role.denied, permission)

      {allowed, denied} =
        case state do
          :allow -> {[permission | allowed], denied}
          :deny -> {allowed, [permission | denied]}
          :neutral -> {allowed, denied}
        end

      Repo.transaction(fn ->
        role
        |> GroupRole.permissions_changeset(
          sort_permissions(allowed),
          sort_permissions(denied)
        )
        |> Repo.update()
        |> record_role_change(group, actor, :permission_set, fn updated ->
          from = permission_state(role, permission)
          to = permission_state(updated, permission)
          if from != to, do: %{role: role.name, permission: permission, from: from, to: to}
        end)
      end)
      |> case do
        {:ok, role} ->
          broadcast_manifest_updated(manifest)
          {:ok, role}

        error ->
          error
      end
    end
  end

  @doc """
  Sets how a role of the group's own manifest is had (`GroupRole.request_mode`
  and, for a mode that votes, its `request_poll`), as an admin writes the
  statute. In a group that elects its admins, Admin is had only by a vote,
  if at all.
  """
  def set_role_request_rule(%Profile{} = actor, %Group{} = group, role_key, attrs) do
    with {:ok, manifest} <- editable_manifest(actor, group),
         {:ok, role} <- fetch_role(manifest, role_key) do
      changeset = GroupRole.request_changeset(role, attrs)

      if role.key == GroupRole.admin_key() and elects_admins?(group) and
           Ecto.Changeset.get_field(changeset, :request_mode) in [:approve, :choose] do
        {:error, :elected_role}
      else
        Repo.transaction(fn ->
          changeset
          |> Repo.update()
          |> record_role_change(group, actor, :request_rule_set, fn updated ->
            if updated.request_mode != role.request_mode or
                 updated.request_poll != role.request_poll,
               do: %{role: role.name, from: role.request_mode, to: updated.request_mode}
          end)
        end)
        |> case do
          {:ok, role} ->
            broadcast_manifest_updated(manifest)
            {:ok, role}

          error ->
            error
        end
      end
    end
  end

  defp permission_state(%GroupRole{} = role, permission) do
    cond do
      permission in role.allowed -> :allow
      permission in role.denied -> :deny
      true -> :neutral
    end
  end

  defp validate_permission_change(%GroupRole{key: key}, permission, state) do
    cond do
      permission not in GroupRole.permissions() -> {:error, :invalid_permission}
      key == GroupRole.admin_key() -> {:error, :builtin_role}
      key == GroupRole.everyone_key() and state == :deny -> {:error, :invalid_permission}
      true -> :ok
    end
  end

  defp sort_permissions(permissions) do
    Enum.filter(GroupRole.permissions(), &(&1 in permissions))
  end

  @doc """
  Deletes a custom role together with its assignments in every group that
  uses the manifest. Groups with a copy of the manifest keep their own.
  """
  def delete_group_role(%Profile{} = actor, %Group{} = group, role_key) do
    with {:ok, manifest} <- editable_manifest(actor, group),
         {:ok, role} <- fetch_custom_role(manifest, role_key) do
      group_ids = Access.group_ids_using_manifest(manifest)

      Multi.new()
      |> Multi.delete(:role, role)
      |> Multi.delete_all(
        :assignments,
        from(r in GroupMemberRole, where: r.group_id in ^group_ids and r.role_key == ^role.key)
      )
      |> Multi.run(:history, fn repo, %{assignments: {count, _rows}} ->
        {:ok,
         AccessHistory.record!(repo, group, :role_removed,
           actor: actor.id,
           role_key: role.key,
           data: %{role: role.name, assignments: count}
         )}
      end)
      |> Multi.run(:inheritance, fn repo, _changes ->
        {:ok, forget_inherited_roles(repo, group_ids, [role.key])}
      end)
      |> Multi.run(:requests, fn repo, _changes ->
        {:ok, forget_requested_roles(repo, group_ids, [role.key])}
      end)
      |> Repo.transaction()
      |> case do
        {:ok, %{role: role, inheritance: inheritance}} ->
          broadcast_group_roles_updated(group_ids)
          broadcast_forgotten_roles(inheritance)
          {:ok, role}

        {:error, _step, reason, _changes} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Gives a group that inherits its manifest a copy of it to change. Role keys
  are kept, so every assignment stays valid.
  """
  def create_own_group_manifest(%Profile{} = actor, %Group{} = group) do
    access = Access.for_profile(actor, group)

    cond do
      group.is_direct ->
        {:error, :direct_group}

      not access.admin? ->
        {:error, :not_permitted}

      Access.own_manifest?(group, access.manifest) ->
        {:error, :own_manifest}

      true ->
        now = DateTime.utc_now(:second)

        Multi.new()
        |> Multi.insert(:manifest, %GroupManifest{group_id: group.id})
        |> Multi.run(:history, fn repo, _changes ->
          {:ok, AccessHistory.record!(repo, group, :manifest_copied, actor: actor.id)}
        end)
        |> Multi.insert_all(:roles, GroupRole, fn %{manifest: manifest} ->
          Enum.map(access.manifest.roles, fn role ->
            role
            |> Map.take([:key, :name, :allowed, :denied, :position, :request_mode, :request_poll])
            |> Map.merge(%{manifest_id: manifest.id, inserted_at: now, updated_at: now})
          end)
        end)
        |> Repo.transaction()
        |> case do
          {:ok, %{manifest: manifest}} ->
            broadcast_manifest_updated(manifest)
            {:ok, Access.effective_manifest(group)}

          {:error, _step, reason, _changes} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Drops the group's own manifest so it inherits again. Assignments of roles
  the inherited manifest does not have are deleted, except "admin".
  """
  def revert_to_inherited_group_manifest(%Profile{} = actor, %Group{} = group) do
    with {:ok, manifest} <- editable_manifest(actor, group) do
      group_ids = Access.group_ids_using_manifest(manifest)

      Repo.transaction(fn ->
        Repo.delete_all(from(m in GroupManifest, where: m.id == ^manifest.id))

        kept_keys = [
          GroupRole.admin_key()
          | Enum.map(Access.load_effective_manifest(group).roles, & &1.key)
        ]

        from(r in GroupMemberRole,
          where: r.group_id in ^group_ids and r.role_key not in ^kept_keys
        )
        |> Repo.delete_all()

        gone_keys = Enum.map(manifest.roles, & &1.key) -- kept_keys
        AccessHistory.record!(Repo, group, :manifest_dropped, actor: actor.id)
        forget_requested_roles(Repo, group_ids, gone_keys)
        forget_inherited_roles(Repo, group_ids, gone_keys)
      end)
      |> case do
        {:ok, inheritance} ->
          broadcast_group_roles_updated(group_ids)
          broadcast_forgotten_roles(inheritance)
          {:ok, Access.effective_manifest(group)}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # In the history of the sub-groups it is the group above that did it, and not
  # a person their members may not know.
  defp forget_inherited_roles(repo, group_ids, keys) do
    History.within([actor: nil, via: :parent], fn ->
      MemberInheritance.forget_roles(repo, group_ids, keys)
    end)
  end

  # Roles gone from a statute are no longer asked for: the requests that wait
  # forget them, and a member's request left with none goes.
  defp forget_requested_roles(_repo, _group_ids, []), do: :ok

  defp forget_requested_roles(repo, group_ids, keys) do
    repo.delete_all(
      from(r in GroupRoleRequest,
        where: r.group_id in ^group_ids and fragment("?::text[] <@ ?::text[]", r.role_keys, ^keys)
      )
    )

    for table <- ["group_join_requests", "group_role_requests"] do
      repo.query!(
        """
        UPDATE #{table}
           SET role_keys = ARRAY(SELECT k FROM unnest(role_keys) k WHERE k <> ALL($2::text[]))
         WHERE group_id = ANY($1::bigint[]) AND role_keys::text[] && $2::text[]
        """,
        [group_ids, keys]
      )
    end

    :ok
  end

  # The sub-groups whose roles to inherit by lost a role
  # (`MemberInheritance.forget_roles/3`): their pages and their parents' lists
  # read them again, and the members who came or went are told.
  defp broadcast_forgotten_roles({changes, group_ids}) do
    broadcast_inheritance_changes(changes)

    if group_ids != [] do
      from(g in Group, where: g.id in ^group_ids)
      |> Repo.all()
      |> Enum.each(fn group ->
        broadcast_group_updated(group)
        broadcast_child_group_changed(group.parent_id, group, :updated)
      end)
    end

    :ok
  end

  defp editable_manifest(%Profile{} = actor, %Group{} = group) do
    access = Access.for_profile(actor, group)

    cond do
      group.is_root -> {:error, :root_manifest_is_fixed}
      not access.admin? -> {:error, :not_permitted}
      not Access.own_manifest?(group, access.manifest) -> {:error, :manifest_is_inherited}
      true -> {:ok, access.manifest}
    end
  end

  defp fetch_role(%GroupManifest{roles: roles}, role_key) do
    case Enum.find(roles, &(&1.key == role_key)) do
      %GroupRole{} = role -> {:ok, role}
      nil -> {:error, :role_not_found}
    end
  end

  defp fetch_custom_role(manifest, role_key) do
    case fetch_role(manifest, role_key) do
      {:ok, role} -> if GroupRole.builtin?(role), do: {:error, :builtin_role}, else: {:ok, role}
      error -> error
    end
  end

  defp broadcast_manifest_updated(%GroupManifest{} = manifest) do
    manifest
    |> Access.group_ids_using_manifest()
    |> broadcast_group_roles_updated()
  end

  @doc """
  Gives a member of the group one of the effective manifest's roles. Only
  the group's admins assign roles; "everyone" is implicit. In a group that
  elects its admins (`Group.elects_admins`), Admin comes only by a decision
  (`PotokIde.Polls.Effects`).
  """
  def assign_group_member_role(%Profile{} = actor, %Group{} = group, profile_id, role_key)
      when is_integer(profile_id) and is_binary(role_key) do
    with {:ok, _access} <- ensure_role_assignable(actor, group, profile_id, role_key) do
      Repo.transaction(fn ->
        put_member_role(Repo, group, profile_id, role_key, actor: actor.id)
      end)
      |> case do
        {:ok, {:ok, member_role, announce}} ->
          announce.()
          {:ok, member_role}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def unassign_group_member_role(%Profile{} = actor, %Group{} = group, profile_id, role_key)
      when is_integer(profile_id) and is_binary(role_key) do
    with {:ok, access} <- ensure_role_assignable(actor, group, profile_id, role_key) do
      member_access =
        Access.for_profile(%Profile{id: profile_id}, group, manifest: access.manifest)

      inherited_keys = Map.get(Access.inherited_by_profile(group, [profile_id]), profile_id, [])

      cond do
        # Roles held through the parent are taken there.
        role_key in inherited_keys ->
          {:error, :inherited_role}

        role_key == GroupRole.admin_key() and member_access.admin? and
            Access.count_admins(group) <= 1 ->
          {:error, :last_admin}

        true ->
          Repo.transaction(fn ->
            drop_member_roles(Repo, group, [profile_id], role_key, actor: actor.id)
          end)
          |> case do
            {:ok, {:ok, announce}} ->
              announce.()
              :ok

            {:error, reason} ->
              {:error, reason}
          end
      end
    end
  end

  @doc """
  Gives `profile_id` the role `role_key` in `group`, in the caller's
  transaction, with no check: for `assign_group_member_role/4`, which checked
  the actor, for a decision of a poll (`PotokIde.Polls.Effects`), whose id
  `by[:poll]` the role then keeps, and for a granted request. A role the
  member holds of their own keeps being theirs, by the decision when one gave
  it; one held through the parent stays as it is. Inheriting groups below
  follow. A role the member did not hold of their own goes into the access
  history, with `by[:actor]` or `by[:poll]` as who gave it.

  Returns `{:ok, member_role, announce}`: nobody hears of it until the
  caller commits and calls `announce`.
  """
  def put_member_role(repo, %Group{} = group, profile_id, role_key, by \\ [])
      when is_integer(profile_id) and is_binary(role_key) do
    poll_id = by[:poll]

    held? =
      repo.exists?(
        from(r in GroupMemberRole,
          where:
            r.group_id == ^group.id and r.profile_id == ^profile_id and r.role_key == ^role_key and
              not r.inherited
        )
      )

    member_role = %GroupMemberRole{
      group_id: group.id,
      profile_id: profile_id,
      role_key: role_key,
      poll_id: poll_id
    }

    on_conflict =
      if poll_id,
        do:
          from(r in GroupMemberRole,
            where: not r.inherited,
            update: [set: [poll_id: ^poll_id]]
          ),
        else: :nothing

    repo.insert!(member_role,
      on_conflict: on_conflict,
      conflict_target: [:group_id, :profile_id, :role_key]
    )

    if not held? do
      AccessHistory.record!(repo, group, :role_given,
        actor: by[:actor],
        subject: profile_id,
        role_key: role_key,
        poll: poll_id,
        data: if(by[:via], do: %{via: by[:via]}, else: %{})
      )
    end

    changes = MemberInheritance.sync(repo, group.id, [profile_id])
    {:ok, member_role, roles_announcement(group, changes)}
  end

  @doc """
  Takes `role_key` from those of `profile_ids` who hold it of their own in
  `group`, in the caller's transaction, with no check (see
  `put_member_role/5`). Roles held through the parent stay. Each role taken
  goes into the access history, as `by` says. Returns `{:ok, announce}`.
  """
  def drop_member_roles(repo, %Group{} = group, profile_ids, role_key, by \\ [])
      when is_list(profile_ids) and is_binary(role_key) do
    {_count, taken} =
      repo.delete_all(
        from(r in GroupMemberRole,
          where:
            r.group_id == ^group.id and r.profile_id in ^profile_ids and
              r.role_key == ^role_key and not r.inherited,
          select: r.profile_id
        )
      )

    for profile_id <- taken do
      AccessHistory.record!(repo, group, :role_taken,
        actor: by[:actor],
        subject: profile_id,
        role_key: role_key,
        poll: by[:poll]
      )
    end

    changes = MemberInheritance.sync(repo, group.id, profile_ids)
    {:ok, roles_announcement(group, changes)}
  end

  defp roles_announcement(%Group{id: group_id}, changes) do
    fn ->
      broadcast_group_roles_updated([group_id])
      broadcast_inheritance_changes(changes)
    end
  end

  defp ensure_role_assignable(%Profile{} = actor, %Group{} = group, profile_id, role_key) do
    access = Access.for_profile(actor, group)
    role_keys = Enum.map(access.manifest.roles, & &1.key)

    cond do
      group.is_direct ->
        {:error, :direct_group}

      not access.admin? ->
        {:error, :not_permitted}

      role_key == GroupRole.everyone_key() or role_key not in role_keys ->
        {:error, :role_not_found}

      # Elected admins come and go by decisions alone.
      role_key == GroupRole.admin_key() and elects_admins?(group) ->
        {:error, :elected_role}

      not member_of_group?(%Profile{id: profile_id}, group) ->
        {:error, :not_a_group_member}

      true ->
        {:ok, access}
    end
  end

  @doc """
  Suggestions for an `@` mention typed in the group's composer: members whose
  username starts with `query` and, when the profile may mention roles, the
  matching roles of the effective manifest.
  """
  def list_mention_candidates(%Profile{} = profile, %Group{} = group, query)
      when is_binary(query) do
    access = Access.for_profile(profile, group)
    query = query |> String.trim() |> String.downcase() |> String.slice(0, 32)

    if Access.can_post_in_chat?(profile, access, group) do
      roles = mention_role_candidates(access, group, query)
      profiles = mention_profile_candidates(profile, group, query, 8 - length(roles))
      roles ++ profiles
    else
      []
    end
  end

  defp mention_role_candidates(%Access{} = access, %Group{} = group, query) do
    group = Mentions.reach(group)

    if Access.can?(access, :mention_roles) do
      counts = Access.role_member_counts(group)

      access.manifest.roles
      |> Enum.filter(&String.starts_with?(String.downcase(&1.name), query))
      |> Enum.take(3)
      |> Enum.map(fn role ->
        count =
          if role.key == GroupRole.everyone_key(),
            do: count_group_members(group),
            else: Map.get(counts, role.key, 0)

        %{kind: :role, key: role.key, name: role.name, member_count: count}
      end)
    else
      []
    end
  end

  # In a thread, the members of its group: a mention takes them in.
  defp mention_profile_candidates(%Profile{} = profile, %Group{} = group, query, limit) do
    group = Mentions.reach(group)
    pattern = String.replace(query, ~r/[\\%_]/, "\\\\\\0") <> "%"

    from(p in Profile,
      join: gm in GroupMembership,
      on: gm.profile_id == p.id,
      where:
        gm.group_id == ^group.id and p.id != ^profile.id and p.kind == :person and
          ilike(p.username, ^pattern),
      order_by: [asc: fragment("lower(?)", p.username)],
      limit: ^limit,
      select: %{kind: :profile, id: p.id, name: p.username, updated_at: p.updated_at}
    )
    |> Repo.all()
  end

  # ---------
  # Queries
  # ---------

  def list_profiles_for_account(%Account{} = account) do
    import Ecto.Query, only: [from: 2]

    from(p in Profile,
      join: ap in AccountProfile,
      on: ap.profile_id == p.id,
      where: ap.account_id == ^account.id,
      order_by: [asc: p.username]
    )
    |> Repo.all()
  end

  def list_invitable_profiles_for_group(
        %Profile{} = inviter,
        %Group{} = group,
        search_term,
        opts \\ []
      )
      when is_binary(search_term) do
    normalized_search_term = NameSearch.wide_term(search_term)

    if is_nil(normalized_search_term) do
      []
    else
      limit = Keyword.get(opts, :limit, 6)
      like_search_term = "%#{normalized_search_term}%"
      prefix_search_term = "#{normalized_search_term}%"

      from(p in Profile,
        as: :profile,
        left_join: gm in GroupMembership,
        on: gm.profile_id == p.id and gm.group_id == ^group.id,
        left_join: gi in GroupInvitation,
        on:
          gi.invitee_id == p.id and gi.group_id == ^group.id and
            is_nil(gi.accepted_at) and gi.inserted_at > ^GroupInvitation.cutoff(),
        where:
          p.id != ^inviter.id and p.kind == :person and is_nil(gm.profile_id) and
            is_nil(gi.id) and ilike(p.username, ^like_search_term),
        order_by: [
          asc:
            fragment(
              "CASE WHEN lower(?) LIKE lower(?) THEN 0 ELSE 1 END",
              p.username,
              ^prefix_search_term
            ),
          asc: p.username
        ],
        limit: ^limit
      )
      |> Discovery.where_listable(inviter)
      |> Discovery.where_not_blocked(group)
      |> Repo.all()
    end
  end

  def get_profile_by_username(username) when is_binary(username) do
    Repo.one(from(p in Profile, where: p.username == ^username and p.kind != :deleted))
  end

  def get_account_current_profile(%Account{} = account) do
    get_account_profile(account, account.current_profile_id) ||
      get_account_profile(account, account.default_profile_id)
  end

  def get_account_default_profile(%Account{} = account) do
    get_account_profile(account, account.default_profile_id)
  end

  def list_child_groups(%Group{} = group) do
    import Ecto.Query, only: [from: 2]

    from(g in Group, where: g.parent_id == ^group.id, order_by: [asc: g.name])
    |> Repo.all()
  end

  def list_group_path(%Group{} = group) do
    ancestor_ids = ancestor_group_ids(group)

    groups_by_id =
      from(g in Group, where: g.id in ^ancestor_ids)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    Enum.map(ancestor_ids, &Map.get(groups_by_id, &1)) |> Enum.reject(&is_nil/1)
  end

  # Ids from the root down to (and including) `group`, in one recursive query.
  defp ancestor_group_ids(%Group{id: group_id}) do
    sql = """
    WITH RECURSIVE path AS (
      SELECT g.id, g.parent_id, 0 AS depth
      FROM groups g
      WHERE g.id = $1
      UNION ALL
      SELECT parent.id, parent.parent_id, path.depth + 1
      FROM groups parent
      JOIN path ON parent.id = path.parent_id
    )
    SELECT id FROM path ORDER BY depth DESC
    """

    case Repo.query(sql, [group_id], cache_statement: "social_ancestor_group_ids") do
      {:ok, %{rows: rows}} -> Enum.map(rows, fn [id] -> id end)
      {:error, _reason} -> [group_id]
    end
  end

  defp maybe_put_profile_reference(changes, _field, current_value, _profile_id)
       when not is_nil(current_value) do
    changes
  end

  defp maybe_put_profile_reference(changes, field, nil, profile_id) do
    Map.put(changes, field, profile_id)
  end

  defp get_account_profile(%Account{} = account, profile_id) when is_integer(profile_id) do
    import Ecto.Query, only: [from: 2]

    from(p in Profile,
      join: ap in AccountProfile,
      on: ap.profile_id == p.id,
      where: p.id == ^profile_id and ap.account_id == ^account.id,
      select: p
    )
    |> Repo.one()
  end

  defp get_account_profile(%Account{}, _profile_id), do: nil

  @doc """
  The path from the root down to `group` (see `list_group_path/1`), keeping
  only the groups the profile can see: the group itself, public ones and its
  memberships. The root's path is the root alone, so it costs no query.
  """
  def list_visible_group_path_for_profile(%Group{} = group, nil), do: [group]

  def list_visible_group_path_for_profile(%Group{parent_id: nil} = group, %Profile{}),
    do: maybe_preload_group_members([group])

  def list_visible_group_path_for_profile(%Group{} = group, %Profile{} = profile) do
    fields = Group.__schema__(:query_fields)

    # The ancestors with their columns and the membership, in one statement.
    sql = """
    WITH RECURSIVE path AS (
      SELECT g.id, g.parent_id, 0 AS depth
      FROM groups g
      WHERE g.id = $1
      UNION ALL
      SELECT parent.id, parent.parent_id, path.depth + 1
      FROM groups parent
      JOIN path ON parent.id = path.parent_id
    )
    SELECT #{group_columns_sql(fields)},
      EXISTS (
        SELECT 1 FROM group_memberships gm WHERE gm.group_id = g.id AND gm.profile_id = $2
      )
    FROM path
    JOIN groups g ON g.id = path.id
    ORDER BY path.depth DESC
    """

    %{rows: rows} =
      Repo.query!(sql, [group.id, profile.id], cache_statement: "social_visible_group_path")

    rows
    |> Enum.flat_map(fn row ->
      {path_group, [member?]} = load_group_row(fields, row)

      if path_group.id == group.id or path_group.is_public or member?,
        do: [path_group],
        else: []
    end)
    |> maybe_preload_group_members()
  end

  @child_group_relations ~w(member creator follower)

  @doc """
  Child groups of `group` the profile can see, most active first. Options:
  `:is_direct` and `:is_thread` (true or false keep only those groups, nil
  keeps both; thread groups are the ones started from a chat value),
  `:search` on the name, `:preset` for the groups of one kind (a key of
  `GroupPresets.filter_keys/0`, by what `GroupPresets.shown/1` gives),
  `:relation` for the groups the profile is a member of (`"member"`, also by
  inheritance), made (`"creator"`) or follows (`"follower"`), `public: false`
  to leave out the public groups the profile is not in, but those it follows
  and those with one of its memberships or followed groups below them, and
  `:limit` / `:offset`.

  The root also lists the groups no other list leads to, whose parent the
  profile cannot see (`detached_group_ids/1`), even if they are threads.

  The targets of the group's shortcuts (`GroupShortcut`) stand among them
  by the same rule, the filters taking the target, each with its
  `shortcut_id`; a group the list holds already never stands in it twice.
  """
  def list_child_groups_for_profile(%Group{} = group, %Profile{} = profile, opts \\ []) do
    {groups, _rest} = child_group_rows(group, profile, opts, false)
    groups
  end

  @doc "Counts what `list_child_groups_for_profile/3` returns, with the same filters."
  def count_child_groups_for_profile(%Group{} = group, %Profile{} = profile, opts \\ []) do
    public? = public_children?(opts)

    %{rows: [[count]]} =
      Repo.query!(
        "#{visible_children_sql(public?)} SELECT COUNT(*) FROM visible_children",
        visible_children_params(group, profile, opts),
        cache_statement: "social_count_child_groups_#{public?}"
      )

    count
  end

  @doc """
  The ids `list_child_groups_for_profile/3` would return, in the same order.
  Takes the same options, plus `:unread_overview` to reuse one the caller
  already loaded with `unread_overview/1`.
  """
  def list_child_group_ids_for_profile(%Group{} = group, %Profile{} = profile, opts \\ []) do
    ordered_child_group_ids_for_profile(group, profile, opts)
  end

  @doc """
  A page of `list_child_groups_for_profile/3` with the count of everything it
  pages through (`count_child_groups_for_profile/3`), in one query:
  `{groups, total}`. Takes the options of `list_child_group_ids_for_profile/3`
  but `:offset`.
  """
  def list_child_groups_page_for_profile(%Group{} = group, %Profile{} = profile, opts \\ []) do
    opts = Keyword.delete(opts, :offset)
    {groups, totals} = child_group_rows(group, profile, opts, true)

    # The count comes with the rows, so an empty page means nothing to count
    # unless the page itself was empty by asking for no rows.
    total =
      case {totals, normalize_query_limit(opts[:limit])} do
        {[[total] | _], _limit} -> total
        {[], 0} -> count_child_groups_for_profile(group, profile, opts)
        {[], _limit} -> 0
      end

    {groups, total}
  end

  @doc """
  The direct sub-group of `group` called exactly `name` that the profile can
  see. Names are not unique, so the oldest such group wins. Threads and direct
  conversations do not count.
  """
  def get_visible_child_group_by_name(%Group{} = group, profile, name)
      when is_viewer(profile) and is_binary(name) do
    visible_plain_groups(profile)
    |> where([g], g.parent_id == ^group.id and g.name == ^name)
    |> order_by([g], asc: g.id)
    |> limit(1)
    |> Repo.one()
  end

  @doc "Which of `ids` are direct sub-groups of `group`, of any kind."
  def child_group_ids(%Group{id: parent_id}, ids) when is_list(ids) do
    case for id <- ids,
             is_integer(id) and id > 0 and id < 9_223_372_036_854_775_807,
             uniq: true,
             do: id do
      [] ->
        []

      ids ->
        from(g in Group, where: g.parent_id == ^parent_id and g.id in ^ids, select: g.id)
        |> Repo.all()
    end
  end

  @doc """
  The direct sub-group `id` of `group`, when the profile can see it. Threads
  and direct conversations do not count.
  """
  def get_visible_child_group(%Group{} = group, profile, id)
      when is_viewer(profile) and is_integer(id) do
    visible_plain_groups(profile)
    |> where([g], g.id == ^id and g.parent_id == ^group.id)
    |> Repo.one()
  end

  # What a pin on a map needs (`GroupPins`), and the picture's version.
  @placed_fields GroupAreas.fields()

  @doc """
  The direct sub-groups of `group` the profile can see that have a place on a
  map, oldest first, as `{groups, truncated?}`: what a map shows. Threads and
  direct conversations do not count. Only what a pin needs is loaded.
  """
  def list_visible_placed_children(%Group{} = group, profile, limit)
      when is_viewer(profile) and is_integer(limit) and limit > 0 do
    rows =
      visible_plain_groups(profile)
      |> where([g], g.parent_id == ^group.id and not is_nil(g.latitude))
      |> order_by([g], asc: g.id)
      |> limit(^(limit + 1))
      |> select([g], struct(g, ^@placed_fields))
      |> Repo.all()

    {Enum.take(rows, limit), length(rows) > limit}
  end

  @doc """
  Whether `group` has more than `limit` of what `list_visible_placed_children/3`
  lists: too many for a map to take at once, so it reads by view.
  """
  def placed_children_more_than?(%Group{} = group, profile, limit)
      when is_viewer(profile) and is_integer(limit) and limit >= 0 do
    visible_plain_groups(profile)
    |> where([g], g.parent_id == ^group.id and not is_nil(g.latitude))
    |> offset(^limit)
    |> limit(1)
    |> select([g], g.id)
    |> Repo.one()
    |> is_integer()
  end

  @doc """
  The group `id` the sheet of `parent`'s page may open, when the profile can
  see it: under the root any group, as the root's map shows them all, under
  any other group one of its direct sub-groups (`get_visible_child_group/3`).
  Threads, direct conversations and the root itself do not count.
  """
  def get_visible_group_below(%Group{is_root: true}, %Profile{} = profile, id)
      when is_integer(id) do
    visible_plain_groups(profile)
    |> where([g], g.id == ^id and not g.is_root)
    |> Repo.one()
  end

  def get_visible_group_below(%Group{} = parent, %Profile{} = profile, id) when is_integer(id),
    do: get_visible_child_group(parent, profile, id)

  # The root's map: every group with a place the profile sees, at any depth.
  # A statement that runs out of time gives up rather than hold a connection.
  @map_timeout_ms 4_000
  @map_max_cells 2_000
  @map_max_drawn 300
  # A route is drawn as a line, its casing, a wider line to tap and a ring at
  # its end, so fewer of them than borders.
  @map_max_routes 150
  # Web Mercator ends here; a place nearer a pole is drawn on that edge.
  @mercator_max_lat 85.0511287798
  # The tones of pins (`GroupPins`) a cluster counts, in this order.
  @map_tones [:kind, :places, :community, :nature, :reports, :alert]

  @doc """
  What the root's map shows in the box `[west, south, east, north]` at `zoom`,
  out of one set of groups, the ones the filters keep, points, areas and
  routes alike:

  * `places`: each group alone in its cell of a grid about 64 pixels wide,
    with the fields of `list_visible_placed_children/3`;
  * `clusters`: every other cell, `%{count, lat, lng, bounds: [[south, west],
    [north, east]], tones: %{tone => count}}`;
  * `areas`: while `:shapes?` is on, the areas wide enough at `zoom` to be
    drawn as borders (`GroupAreas.min_span/1`), biggest first, at most 300,
    with their boxes (`GroupAreas.bbox/1`). Only their borders: their pins
    are in the cells like any other, so an area past the 300 still shows;
  * `routes`: while `:routes?` is on, the routes wide enough at `zoom` to be
    drawn as lines, by the same measure, widest first, at most 150, with
    their boxes (`GroupRoutes.bbox/1`) and lengths. Their pins, at their
    starts, are in the cells too;
  * `total`: the groups in the box, by pin, by border or by line;
  * `truncated`: whether the box had more cells than a view takes.

  Returns `{:ok, view}` or `{:error, :timeout}`.

  The groups are every group with a place the profile sees anywhere below the
  root, threads and direct conversations aside (`Visibility.listed_sql/2`):
  its memberships, and the public groups, all of them with `public?: true`,
  otherwise those it follows and those on the way to one of its memberships
  or followed groups. `filters` narrow them, areas as much as points:

  * `:search` on the name (`NameSearch`);
  * `:preset`, a kind as in `list_child_groups_for_profile/3`, `"none"` or
    `"app"`, and `:relation`, the profile's memberships, own groups or
    followed groups;
  * `:pins`, keys of `Group.pin_icon` (`GroupPins.keys/0`), with `"kind"` for
    the groups that show their kind;
  * `:areas`, only the groups inside one of these areas (`GroupAreas`), not
    the areas themselves: a route is inside an area it passes through;
  * `:from` (counts in) and `:to` (does not) on `:time`: `:created`, when the
    group took its place in a feed, or `:active`, its newest value, where a
    group never written in stays out;
  * `:places?` false keeps only the shapes whose layer is on: the areas
    (`:shapes?`), the routes (`:routes?`) or both; the areas alone when
    neither is.

  A map app passes `:parent_id` for the direct sub-groups of its group, and
  only then may the profile be nil, a guest, who sees the public ones.
  """
  def list_map_cells(profile, filters, bbox, zoom)
      when is_map_viewer(profile, filters) and is_integer(zoom) do
    with {:ok, [rows]} <- map_queries([map_view_query(profile, filters, bbox, zoom)]) do
      {:ok, map_view(rows)}
    end
  end

  @doc """
  How many groups the root's map holds under `filters` (as in
  `list_map_cells/4`), wherever they stand, and the box around them and their
  areas, nil for none: `{:ok, %{count, bounds}}` or `{:error, :timeout}`.
  """
  def map_extent(%Profile{} = profile, filters) do
    with {:ok, [rows]} <- map_queries([map_extent_query(profile, filters)]) do
      {:ok, map_extent_result(rows)}
    end
  end

  @doc """
  `map_extent/2` and, for a `view` (`%{bbox, zoom}`), `list_map_cells/4` in
  one transaction, as a change of filters needs both: `{:ok, %{extent,
  view}}`, `view` nil without one, or `{:error, :timeout}`.
  """
  def load_map(profile, filters, view) when is_map_viewer(profile, filters) do
    queries =
      [map_extent_query(profile, filters)] ++
        if view,
          do: [map_view_query(profile, Map.put(filters, :zoom, view.zoom), view.bbox, view.zoom)],
          else: []

    with {:ok, [extent | rest]} <- map_queries(queries) do
      {:ok,
       %{
         extent: map_extent_result(extent),
         view: if(rest == [], do: nil, else: map_view(hd(rest)))
       }}
    end
  end

  @doc """
  The groups of the root's map under `filters` whose pins stand inside
  `bounds` (`[[south, west], [north, east]]`, edges included), by name: what
  a cluster that cannot spread any further holds. `{:ok, {groups,
  more?}}` with at most `limit` groups, or `{:error, :timeout}`.
  """
  def list_map_spot(profile, filters, [[south, west], [north, east]], limit)
      when is_map_viewer(profile, filters) and is_integer(limit) and limit > 0 do
    box = %{
      south: to_float(south),
      north: to_float(north),
      west: to_float(west),
      east: to_float(east)
    }

    {cte, values} = map_placed(:spot, profile, filters, box)

    sql =
      cte <>
        "SELECT p.id FROM placed p ORDER BY lower(p.name), p.id LIMIT $limit"

    with {:ok, [rows]} <- map_queries([MapSql.bind(sql, Map.put(values, :limit, limit + 1))]) do
      ids = rows |> Enum.map(&hd/1) |> Enum.take(limit)
      by_id = Map.new(placed_groups(ids), &{&1.id, &1})

      {:ok, {Enum.flat_map(ids, &List.wrap(by_id[&1])), length(rows) > limit}}
    end
  end

  @doc """
  The areas the root's map draws as borders at `zoom` that cover the point
  `{lat, lng}`, out of the groups the filters keep, smallest first, at most
  `limit`: what a tap on the map lists. `{:ok, groups}` or `{:error,
  :timeout}`.
  """
  def list_map_areas_at(%Profile{} = profile, filters, {lat, lng}, zoom, limit)
      when is_number(lat) and is_number(lng) and is_integer(zoom) do
    filters = Map.merge(filters, %{shapes?: true, zoom: zoom})
    {cte, values} = map_placed(:here, profile, filters, %{lat: lat * 1.0, lng: lng * 1.0})
    sql = cte <> "SELECT p.id FROM placed p ORDER BY p.area_size, p.id LIMIT $limit"

    with {:ok, [rows]} <- map_queries([MapSql.bind(sql, Map.put(values, :limit, limit))]) do
      ids = Enum.map(rows, &hd/1)
      by_id = Map.new(placed_groups(ids), &{&1.id, &1})
      {:ok, Enum.flat_map(ids, &List.wrap(by_id[&1]))}
    end
  end

  @doc """
  How many of `group`'s direct sub-groups with a place the profile may see
  show each pin, as a map app's pin filter offers them: an icon's key
  (`GroupPins`), `"picture"`, or `"kind"` for those that show their kind.
  `{:ok, [{pin, count}]}`, the most shown first, or `{:error, :timeout}`.
  """
  def count_child_places_by_pin(%Group{} = group, profile) when is_viewer(profile) do
    pins =
      from(g in visible_plain_groups(profile),
        where: g.parent_id == ^group.id and not is_nil(g.latitude),
        select: %{
          pin:
            fragment(
              "CASE WHEN ? = ANY(?::text[]) THEN ? ELSE 'kind' END",
              g.pin_icon,
              ^GroupPins.keys(),
              g.pin_icon
            )
        }
      )

    Repo.with_statement_timeout(
      @map_timeout_ms,
      fn ->
        from(p in subquery(pins), group_by: p.pin, select: {p.pin, count()})
        |> Repo.all()
        |> Enum.sort_by(fn {pin, count} -> {-count, pin} end)
      end,
      jit: false
    )
  end

  defp map_view_query(profile, filters, bbox, zoom) do
    cells_per_axis = 4.0 * Integer.pow(2, zoom |> max(0) |> min(24))
    lat = "LEAST(GREATEST(p.latitude, -#{@mercator_max_lat}), #{@mercator_max_lat})"
    [south, north, west, east, west2, east2] = map_bbox_params(bbox)
    box = %{south: south, north: north, west: west, east: east, west2: west2, east2: east2}
    filters = Map.put(filters, :zoom, zoom)
    {cte, values} = map_placed(:view, profile, filters, box)

    tones =
      Enum.map_join(@map_tones, ", ", &"count(*) FILTER (WHERE p.tone = '#{&1}')")

    sql =
      cte <>
        """
        SELECT * FROM (
          SELECT 'c' AS kind, count(*) AS n, avg(p.latitude), avg(p.longitude),
            min(p.latitude), max(p.latitude), min(p.longitude), max(p.longitude), min(p.id),
            ARRAY[#{tones}]::bigint[]
          FROM placed p
          WHERE p.in_box
          GROUP BY floor((p.longitude + 180.0) / 360.0 * $cells::float8),
            floor((1.0 - ln(tan(radians(#{lat})) + 1.0 / cos(radians(#{lat}))) / pi()) / 2.0
              * $cells::float8)
          ORDER BY count(*) DESC
          LIMIT #{@map_max_cells + 1}
        ) c
        UNION ALL
        SELECT 'a', NULL, NULL, NULL, NULL, NULL, NULL, NULL, d.id, NULL
        FROM (
          SELECT p.id FROM placed p
          WHERE p.drawn
          ORDER BY p.area_size DESC, p.id
          LIMIT #{@map_max_drawn}
        ) d
        UNION ALL
        SELECT 'r', NULL, NULL, NULL, NULL, NULL, NULL, NULL, r.id, NULL
        FROM (
          SELECT p.id FROM placed p
          WHERE p.route_drawn
          ORDER BY p.route_span DESC, p.id
          LIMIT #{@map_max_routes}
        ) r
        UNION ALL
        SELECT 't', count(*), NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL FROM placed p
        """

    MapSql.bind(sql, Map.put(values, :cells, cells_per_axis))
  end

  defp map_view(rows) do
    cells = for ["c" | cell] <- rows, do: cell
    kept = Enum.take(cells, @map_max_cells)
    drawn_ids = for ["a", _, _, _, _, _, _, _, id, _] <- rows, do: id
    route_ids = for ["r", _, _, _, _, _, _, _, id, _] <- rows, do: id
    [total] = for ["t", count | _] <- rows, do: count
    single_ids = for [1, _, _, _, _, _, _, id, _] <- kept, do: id
    by_id = Map.new(placed_groups(single_ids ++ drawn_ids ++ route_ids), &{&1.id, &1})

    clusters =
      for [count, lat, lng, south, north, west, east, _id, tones] <- kept, count > 1 do
        %{
          count: count,
          lat: lat,
          lng: lng,
          bounds: [[south, west], [north, east]],
          tones: @map_tones |> Enum.zip(tones) |> Enum.reject(&(elem(&1, 1) == 0)) |> Map.new()
        }
      end

    %{
      places: Enum.flat_map(single_ids, &List.wrap(by_id[&1])),
      clusters: clusters,
      areas: Enum.flat_map(drawn_ids, &List.wrap(by_id[&1])),
      routes: Enum.flat_map(route_ids, &List.wrap(by_id[&1])),
      total: total,
      truncated: length(cells) > @map_max_cells
    }
  end

  defp map_extent_query(profile, filters) do
    {cte, values} =
      map_placed(:extent, profile, Map.drop(filters, [:shapes?, :routes?]), %{})

    sql =
      cte <>
        """
        SELECT count(*),
          min(COALESCE(p.area_south, p.route_south, p.latitude)),
          max(COALESCE(p.area_north, p.route_north, p.latitude)),
          min(COALESCE(p.area_west, p.route_west, p.longitude)),
          max(COALESCE(p.area_east, p.route_east, p.longitude))
        FROM placed p
        """

    MapSql.bind(sql, values)
  end

  defp map_extent_result([[count, south, north, west, east]]),
    do: %{count: count, bounds: if(count > 0, do: [[south, west], [north, east]])}

  # The groups `ids` with what a pin needs and, for an area or a route, its
  # box, and a route's length.
  defp placed_groups([]), do: []

  defp placed_groups(ids) do
    fields =
      @placed_fields ++ GroupAreas.box_fields() ++ GroupRoutes.box_fields() ++ [:route_length]

    from(g in Group, where: g.id in ^ids, select: struct(g, ^fields)) |> Repo.all()
  end

  # Runs `{sql, params}` queries in one transaction with a time limit.
  defp map_queries(queries) do
    Repo.with_statement_timeout(
      @map_timeout_ms,
      fn -> Enum.map(queries, fn {sql, params} -> Repo.query!(sql, params).rows end) end,
      jit: false
    )
  end

  defp map_time(filters) do
    if Map.get(filters, :time) == :active, do: :active, else: :created
  end

  # The groups of the root's map under `filters`, as a `placed` table for
  # the query that follows, with `$name` parameters (`MapSql`), and their
  # values: `{sql, values}`. Only the filters picked are in the SQL.
  #
  # With `:parent_id` they are the direct sub-groups of that group the
  # profile may see instead, records among them: what a map app shows. The
  # root's map leaves records (`Group.external_key`) out.
  #
  # `scope` says which of the filters a query wants:
  #
  # * `:view`: in a box (`box` values), by pin or, for an area drawn as a
  #   border or a route drawn as a line, by the shape itself reaching into
  #   it; `in_box` marks the pins in it, which the cells take;
  # * `:spot`: by pin inside the bounds of a cluster;
  # * `:here`: areas drawn at the zoom that cover a point (`lat`, `lng`);
  # * `:extent`: wherever they stand.
  #
  # `drawn` marks the areas wide enough at the filters' `:zoom` to be drawn
  # as borders, while `:shapes?` is on, and `route_drawn` the routes wide
  # enough to be drawn as lines, while `:routes?` is; otherwise each is a pin.
  # A guest's NULL profile leaves the membership tables empty, so only public
  # groups pass `Visibility.may_see_sql/2`, with the same SQL text.
  defp map_placed(scope, profile, filters, extra) do
    profile_id = profile && profile.id
    zoom = Map.get(filters, :zoom)
    shapes? = scope != :extent and Map.get(filters, :shapes?) == true and is_integer(zoom)
    routes? = scope != :extent and Map.get(filters, :routes?) == true and is_integer(zoom)
    places? = scope == :extent or Map.get(filters, :places?) != false
    parent_id = Map.get(filters, :parent_id)

    search =
      if parent_id,
        do: normalize_group_search_term(Map.get(filters, :search)),
        else: NameSearch.wide_term(Map.get(filters, :search))

    kind = normalize_preset_filter(Map.get(filters, :preset))
    relation = normalize_relation_filter(Map.get(filters, :relation))
    from = map_moment(Map.get(filters, :from))
    to = map_moment(Map.get(filters, :to))
    areas = map_area_filter(Map.get(filters, :areas))
    {pins, kind_pin?} = map_pin_filter(Map.get(filters, :pins))
    time = map_time(filters)

    moment =
      case time do
        :active -> "g.last_value_at"
        :created -> "COALESCE(g.published_at, g.inserted_at)"
      end

    conditions =
      [
        "g.latitude IS NOT NULL",
        if(parent_id, do: "g.parent_id = $parent::bigint", else: "g.parent_id IS NOT NULL"),
        !parent_id && "g.external_key IS NULL",
        "g.parent_value_id IS NULL",
        "g.is_direct = FALSE",
        if(parent_id,
          do: Visibility.may_see_sql("g", "$profile"),
          else: Visibility.listed_sql("g", Map.get(filters, :public?) == true)
        ),
        !places? &&
          map_shapes_only_sql(
            Map.get(filters, :shapes?) == true,
            Map.get(filters, :routes?) == true
          ),
        search && NameSearch.sql("g", "$search"),
        kind && "#{shown_kind_sql("g")} = $kind::text",
        relation == "creator" && "g.creator_id = $profile",
        relation == "member" && "g.id IN (SELECT group_id FROM mine)",
        relation == "follower" && "g.id IN (SELECT group_id FROM followed)",
        time == :active && "g.last_value_at IS NOT NULL",
        from && "#{moment} >= $from::timestamp",
        to && "#{moment} < $to::timestamp",
        map_pins_sql(pins, kind_pin?),
        areas && "g.id <> ALL($areas::bigint[])",
        areas && map_inside_areas_sql(is_nil(parent_id)),
        map_scope_sql(scope, shapes?, routes?)
      ]
      |> Enum.filter(& &1)

    drawn = if shapes?, do: "COALESCE(g.area_span >= $min_span::float8, FALSE)", else: "FALSE"

    route_drawn =
      if routes?, do: "COALESCE(g.route_span >= $min_span::float8, FALSE)", else: "FALSE"

    in_box = if scope == :view, do: map_view_pin_sql(), else: "TRUE"

    sql = """
    WITH RECURSIVE #{sub_group_memberships_sql("$profile")},
    placed AS MATERIALIZED (
      SELECT g.id, g.name, g.latitude, g.longitude, g.area_size,
        g.area_west, g.area_south, g.area_east, g.area_north,
        g.route_west, g.route_south, g.route_east, g.route_north, g.route_span,
        #{drawn} AS drawn, #{route_drawn} AS route_drawn, #{in_box} AS in_box,
        #{map_tone_sql("g")} AS tone
      FROM groups g
      WHERE #{Enum.join(conditions, "\n    AND ")}
    )
    """

    values =
      Map.merge(extra, %{
        profile: profile_id,
        parent: parent_id,
        search: search,
        kind: kind,
        from: from,
        to: to,
        areas: areas,
        pins: pins,
        known_pins: GroupPins.keys(),
        min_span: if(shapes? or routes?, do: GroupAreas.min_span(zoom))
      })

    {sql, values}
  end

  # With the places' layer off: the groups whose shape has its layer on.
  defp map_shapes_only_sql(true, true), do: "(g.area IS NOT NULL OR g.route IS NOT NULL)"
  defp map_shapes_only_sql(false, true), do: "g.route IS NOT NULL"
  defp map_shapes_only_sql(_shapes?, false), do: "g.area IS NOT NULL"

  defp map_scope_sql(:extent, _shapes?, _routes?), do: nil

  defp map_scope_sql(:spot, _shapes?, _routes?) do
    "g.latitude BETWEEN $south::float8 AND $north::float8" <>
      " AND g.longitude BETWEEN $west::float8 AND $east::float8"
  end

  defp map_scope_sql(:here, true, _routes?) do
    "g.area_span >= $min_span::float8" <>
      " AND ST_Intersects(g.area, ST_SetSRID(ST_MakePoint($lng::float8, $lat::float8), 4326))"
  end

  defp map_scope_sql(:view, shapes?, routes?) do
    case for {true, column} <- [{shapes?, "area"}, {routes?, "route"}],
             do: map_view_shape_sql(column) do
      [] -> map_view_pin_sql()
      shapes -> "(" <> Enum.join([map_view_pin_sql() | shapes], " OR ") <> ")"
    end
  end

  # An area's border or a route's line (`column`) drawn at the zoom that
  # reaches into the view's box, or its second range across the antimeridian.
  defp map_view_shape_sql(column) do
    "(g.#{column}_span >= $min_span::float8" <>
      " AND (g.#{column} && ST_MakeEnvelope($west, $south, $east, $north, 4326)" <>
      " OR ($west2::float8 IS NOT NULL" <>
      " AND g.#{column} && ST_MakeEnvelope($west2, $south, $east2, $north, 4326))))"
  end

  # A pin inside the view's box, or its second range across the antimeridian.
  defp map_view_pin_sql do
    "(g.latitude BETWEEN $south::float8 AND $north::float8" <>
      " AND (g.longitude BETWEEN $west::float8 AND $east::float8" <>
      " OR ($west2::float8 IS NOT NULL" <>
      " AND g.longitude BETWEEN $west2::float8 AND $east2::float8)))"
  end

  # A group inside one of the chosen areas the profile may see: its pin is,
  # and for an area, it is the smaller one; a route also when it only passes
  # through (its pin is its start). One join from the areas to the pins
  # (`groups_pin_index`) and one to the routes (`groups_route_index`), not
  # one test per group.
  defp map_inside_areas_sql(root?) do
    # The root's map reads the pins through `groups_pin_index`, which holds no records.
    records = if root?, do: " AND p.external_key IS NULL", else: ""

    """
    g.id IN (
      SELECT p.id FROM groups fa
      JOIN groups p ON p.latitude IS NOT NULL#{records}
        AND ST_Intersects(fa.area, ST_SetSRID(ST_MakePoint(p.longitude, p.latitude), 4326))
        AND (p.area_size IS NULL OR p.area_size < fa.area_size)
      WHERE fa.id = ANY($areas::bigint[]) AND fa.area IS NOT NULL
        AND #{Visibility.may_see_sql("fa", "$profile")}
      UNION ALL
      SELECT p.id FROM groups fa
      JOIN groups p ON p.route IS NOT NULL AND ST_Intersects(fa.area, p.route)
      WHERE fa.id = ANY($areas::bigint[]) AND fa.area IS NOT NULL
        AND #{Visibility.may_see_sql("fa", "$profile")})
    """
  end

  # The pins a group must show one of: keys of `Group.pin_icon`, and with
  # "kind" the groups that show their kind (no pin, or one the list lost).
  defp map_pins_sql([], false), do: nil
  defp map_pins_sql(_keys, false), do: "g.pin_icon = ANY($pins::text[])"

  defp map_pins_sql([], true),
    do: "(g.pin_icon IS NULL OR g.pin_icon <> ALL($known_pins::text[]))"

  defp map_pins_sql(_keys, true) do
    "(g.pin_icon = ANY($pins::text[]) OR g.pin_icon IS NULL" <>
      " OR g.pin_icon <> ALL($known_pins::text[]))"
  end

  defp map_pin_filter([_ | _] = keys) do
    keys = Enum.filter(keys, &is_binary/1)
    {Enum.filter(keys, &(&1 in GroupPins.keys())), "kind" in keys}
  end

  defp map_pin_filter(_none), do: {[], false}

  # The tone of a group's pin (`GroupPins`): its icon's, or "kind".
  defp map_tone_sql(table) do
    whens =
      GroupPins.icons()
      |> Enum.group_by(&elem(&1, 2), &elem(&1, 0))
      |> Enum.map_join(" ", fn {tone, keys} ->
        "WHEN #{table}.pin_icon IN (#{Enum.map_join(keys, ", ", &"'#{&1}'")}) THEN '#{tone}'"
      end)

    "CASE #{whens} ELSE 'kind' END"
  end

  defp map_area_filter([_ | _] = ids), do: Enum.filter(ids, &is_integer/1)
  defp map_area_filter(_none), do: nil

  defp map_moment(%DateTime{} = moment),
    do: moment |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_naive()

  defp map_moment(_none), do: nil

  @doc """
  The box `[west, south, east, north]` as a map sees it, where a view across
  the antimeridian or wider than the world has longitudes past 180: `[south,
  north, west, east, west2, east2]`, with a second range of longitude (or nils)
  for a box across the antimeridian.
  """
  def map_bbox_params([west, south, east, north]) do
    [west, south, east, north] = Enum.map([west, south, east, north], &to_float/1)
    {south, north} = {south |> max(-90.0) |> min(90.0), north |> max(-90.0) |> min(90.0)}
    {south, north} = {min(south, north), max(south, north)}

    if east - west >= 360.0 do
      [south, north, -180.0, 180.0, nil, nil]
    else
      {west, east} = {wrap_longitude(west), wrap_longitude(east)}

      if west <= east,
        do: [south, north, west, east, nil, nil],
        else: [south, north, west, 180.0, -180.0, east]
    end
  end

  defp wrap_longitude(lng), do: lng - 360.0 * Float.floor((lng + 180.0) / 360.0)

  defp to_float(number) when is_integer(number), do: number * 1.0
  defp to_float(number) when is_float(number), do: number

  # A group's place in a feed: when it opened up, or was made already open.
  defmacrop feed_time(group) do
    quote do
      fragment("COALESCE(?, ?)", unquote(group).published_at, unquote(group).inserted_at)
    end
  end

  @doc """
  A page of the sub-groups of `group` the profile can see, newest first, as
  `{groups, has_more?}`, without threads and direct conversations. A group that
  stayed closed for a while counts from when it opened up.

  This order moves only when a group opens up, which paging through it needs:
  `list_child_groups_for_profile/3` sorts by unread values and activity, so its
  order changes while someone reads. Options: `:limit`, `:before_id`, the id of
  the last group of the previous page, and `:from` and `:to`, the moments
  between which a group took its place: `:from` counts in, `:to` does not.
  `:except` leaves out groups by id, such as those an app keeps its files in
  (`app_file_group_ids/1`).
  """
  def list_visible_child_groups_newest_first(%Group{} = group, profile, opts)
      when is_viewer(profile) do
    limit = Keyword.fetch!(opts, :limit)

    rows =
      feed_groups(group, profile, opts)
      |> order_by([g], desc: feed_time(g), desc: g.id)
      |> limit(^(limit + 1))
      |> before_group(opts[:before_id])
      |> Repo.all()

    {Enum.take(rows, limit), length(rows) > limit}
  end

  @doc """
  The part of `list_visible_child_groups_newest_first/3` around the group `id`,
  which can lie any number of pages down: up to `:limit` newer groups, that
  group and up to `:limit` older ones, as `{groups, has_more?, has_newer?}`. A
  group the list does not hold gives its first page. Takes `:from` and `:to` too.
  """
  def list_visible_child_groups_around(%Group{} = group, profile, id, opts)
      when is_viewer(profile) and is_integer(id) do
    limit = Keyword.fetch!(opts, :limit)
    groups = feed_groups(group, profile, opts)

    case groups |> where([g], g.id == ^id) |> Repo.one() do
      nil ->
        {rows, has_more?} = list_visible_child_groups_newest_first(group, profile, opts)
        {rows, has_more?, false}

      %Group{} = target ->
        older =
          groups
          |> order_by([g], desc: feed_time(g), desc: g.id)
          |> limit(^(limit + 1))
          |> before_group(target.id)
          |> Repo.all()

        newer =
          groups
          |> order_by([g], asc: feed_time(g), asc: g.id)
          |> limit(^(limit + 1))
          |> after_group(target)
          |> Repo.all()

        {Enum.reverse(Enum.take(newer, limit)) ++ [target | Enum.take(older, limit)],
         length(older) > limit, length(newer) > limit}
    end
  end

  defp feed_groups(group, profile, opts) do
    visible_plain_groups(profile)
    |> where([g], g.parent_id == ^group.id)
    |> placed_from(opts[:from])
    |> placed_before(opts[:to])
    |> except_groups(opts[:except])
  end

  defp except_groups(query, ids) when ids in [nil, []], do: query
  defp except_groups(query, ids), do: where(query, [g], g.id not in ^ids)

  @doc """
  The sub-groups of `group` that its apps keep their files in (`AppFiles`),
  under any of its descriptions: their configs name them.
  """
  def app_file_group_ids(%Group{id: id}) do
    from(v in Value,
      where: v.group_id == ^id and v.is_data == true and v.collection == "config",
      select: fragment("? -> 'files'", v.data)
    )
    |> Repo.all()
    |> Enum.flat_map(fn
      %{} = files -> files |> Map.values() |> Enum.filter(&is_integer/1)
      _none -> []
    end)
    |> Enum.uniq()
  end

  defp after_group(query, %Group{id: id} = target) do
    time = feed_moment(target.published_at || target.inserted_at)

    where(
      query,
      [g],
      fragment(
        "(?, ?) > (?, ?)",
        feed_time(g),
        g.id,
        type(^time, :naive_datetime),
        type(^id, :integer)
      )
    )
  end

  defp placed_from(query, nil), do: query

  defp placed_from(query, %DateTime{} = from) do
    where(query, [g], feed_time(g) >= type(^feed_moment(from), :naive_datetime))
  end

  defp placed_before(query, nil), do: query

  defp placed_before(query, %DateTime{} = to) do
    where(query, [g], feed_time(g) < type(^feed_moment(to), :naive_datetime))
  end

  defp feed_moment(%DateTime{} = moment) do
    moment |> DateTime.truncate(:second) |> DateTime.to_naive()
  end

  defp before_group(query, nil), do: query

  # A group deleted since the last page has no place left, and its id comes closest.
  defp before_group(query, before_id) do
    from(g in Group, where: g.id == ^before_id, select: feed_time(g))
    |> Repo.one()
    |> case do
      nil ->
        where(query, [g], g.id < ^before_id)

      time ->
        where(
          query,
          [g],
          fragment(
            "(?, ?) < (?, ?)",
            feed_time(g),
            g.id,
            type(^time, :naive_datetime),
            type(^before_id, :integer)
          )
        )
    end
  end

  @doc """
  The group `id`, when it sits under a direct sub-group of `group` and the
  profile can see both: what `list_visible_child_groups_newest_first/3` can
  list under what `get_visible_child_group_by_name/3` finds.
  """
  def get_visible_grandchild_group(%Group{} = group, profile, id)
      when is_viewer(profile) and is_integer(id) do
    parents =
      visible_plain_groups(profile)
      |> where([g], g.parent_id == ^group.id)
      |> select([g], g.id)

    visible_plain_groups(profile)
    |> where([g], g.id == ^id and g.parent_id in subquery(parents))
    |> Repo.one()
  end

  @doc """
  The group `id` an app of `group` reaches for the profile: one of its direct
  sub-groups or a group under one, both seen by the profile. A nil profile is
  a guest, who sees public groups only, so the group in between must be
  public too.
  """
  def get_visible_child_or_grandchild_group(%Group{} = group, profile, id)
      when is_viewer(profile) and is_integer(id) do
    get_visible_child_group(group, profile, id) ||
      get_visible_grandchild_group(group, profile, id)
  end

  # Groups the profile can see, the rule of `visible_children_sql/1`, without
  # threads and direct conversations.
  defp visible_plain_groups(profile) when is_viewer(profile),
    do: Visibility.plain_groups(profile)

  @doc """
  The groups content shared from another app can go to, most recently active
  first: the profile's memberships that have a chat (not the root, no
  threads) and let it post values. Options: `:search` on the name, or on the
  other member's username in a direct conversation, and `:limit` (30).
  Parents come preloaded, and the members of direct conversations.
  """
  def list_share_target_groups(%Profile{} = profile, opts \\ []) do
    from(g in Group,
      as: :group,
      join: gm in GroupMembership,
      on: gm.group_id == g.id and gm.profile_id == ^profile.id,
      where: not is_nil(g.parent_id) and is_nil(g.parent_value_id),
      order_by: [desc_nulls_last: g.last_value_at, desc: g.inserted_at, desc: g.id],
      limit: ^(opts[:limit] || 30),
      preload: [:parent]
    )
    |> filter_share_targets(profile, normalize_group_search_term(opts[:search]))
    |> Repo.all()
    |> then(fn groups ->
      access = Access.for_profile_in_groups(profile, groups)
      Enum.filter(groups, &Access.can?(access[&1.id], :post_values))
    end)
    |> maybe_preload_group_members()
  end

  defp filter_share_targets(query, _profile, nil), do: query

  defp filter_share_targets(query, %Profile{id: profile_id}, search) do
    pattern = "%#{search}%"

    other_member_matches =
      from(m in GroupMembership,
        join: p in Profile,
        on: p.id == m.profile_id,
        where:
          m.group_id == parent_as(:group).id and m.profile_id != ^profile_id and
            ilike(p.username, ^pattern),
        select: 1
      )

    from(g in query,
      where:
        fragment("? LIKE '%' || potok_fold(?) || '%'", g.name_folded, ^search) or
          (g.is_direct and exists(other_member_matches))
    )
  end

  # The ordered sub-groups with their columns and list details in one query,
  # and per group the columns after them: the count of all (`count?`) or none.
  # The order, the page and the count work on narrow rows; only the page's
  # groups are read in full (sorting every visible group's full row measured
  # slower than the two queries this replaces).
  defp child_group_rows(group, profile, opts, count?) do
    limit = normalize_query_limit(opts[:limit])
    offset = normalize_query_offset(opts[:offset])
    fields = Group.__schema__(:query_fields)
    total = if count?, do: ", COUNT(*) OVER () AS total", else: ""
    public? = public_children?(opts)

    sql = """
    WITH page AS (
      #{ordered_child_groups_query("vc.id, vc.shortcut_id, COALESCE(uc.unread_count, 0) AS unread#{total}", limit, offset, public?)}
    )
    SELECT #{group_columns_sql(fields)},
      details.member_count, details.sub_group_count, details.is_member, page.shortcut_id#{if count?, do: ", page.total", else: ""}
    FROM page
    JOIN groups g ON g.id = page.id
    #{child_group_details_sql()}
    ORDER BY page.unread DESC, g.last_value_at DESC NULLS LAST, g.inserted_at DESC, g.id DESC
    """

    %{rows: rows} =
      Repo.query!(sql, ordered_child_groups_params(group, profile, opts, limit, offset),
        cache_statement:
          "social_child_groups_#{count?}_#{limit != nil}_#{offset != nil}_#{public?}"
      )

    {groups, rest} =
      rows
      |> Enum.map(&load_child_group_row(fields, &1))
      |> Enum.unzip()

    {groups |> maybe_preload_group_members() |> put_last_values(), rest}
  end

  # The newest value of each listed group whose chat the profile reads as a
  # member, direct conversations included. An open chat lets outsiders read
  # too, but its row would not follow it: only members' pages hear of values.
  defp put_last_values(groups) do
    previews = last_chat_previews(for g <- groups, g.is_direct or g.viewer_is_member, do: g.id)
    Enum.map(groups, &%{&1 | last_value: Map.get(previews, &1.id)})
  end

  @doc """
  The newest chat value of each of `group_ids` as a `ValuePreview`, by group
  id; groups without one are left out. The caller decides who may read them.
  One query, each group's newest value found through its chat id index.
  """
  def last_chat_previews([]), do: %{}

  def last_chat_previews(group_ids) when is_list(group_ids) do
    sql = """
    SELECT g.id, v.id, v.creator_id, p.username, v.content, v.content_format,
      ARRAY(SELECT a.filename FROM value_attachments a WHERE a.value_id = v.id ORDER BY a.id)
    FROM unnest($1::bigint[]) AS g(id)
    CROSS JOIN LATERAL (
      SELECT id, creator_id, content, content_format
      FROM values
      WHERE group_id = g.id AND is_data = FALSE
      ORDER BY id DESC
      LIMIT 1
    ) v
    JOIN profiles p ON p.id = v.creator_id
    """

    %{rows: rows} = Repo.query!(sql, [group_ids], cache_statement: "social_last_chat_previews")

    Map.new(rows, fn [group_id, value_id, creator_id, author, content, format, filenames] ->
      {group_id,
       ValuePreview.from_columns(value_id, creator_id, author, content, format, filenames)}
    end)
  end

  # What the sub-groups list shows below each group; direct conversations get
  # NULLs. The sub-groups count by the rule of `sub_group_counts_sql/1`: the
  # ones profile $2 can see, threads only when the page shows them ($5), and
  # the shortcuts to groups it sees that are not among them.
  defp child_group_details_sql do
    """
    LEFT JOIN LATERAL (
      SELECT
        g.member_count AS member_count,
        (
          SELECT COUNT(*) FROM groups k
          WHERE k.parent_id = g.id
            AND k.is_direct = FALSE
            AND ($5::boolean IS DISTINCT FROM FALSE OR k.parent_value_id IS NULL)
            AND (k.is_public OR EXISTS (
              SELECT 1 FROM group_memberships km WHERE km.group_id = k.id AND km.profile_id = $2
            ))
        ) + (
          SELECT COUNT(*) FROM groups k
          WHERE k.id = ANY(#{shortcut_targets_sql("g.id")})
            AND k.parent_id <> g.id
            AND k.is_direct = FALSE
            AND k.parent_value_id IS NULL
            AND (k.is_public OR EXISTS (
              SELECT 1 FROM group_memberships km WHERE km.group_id = k.id AND km.profile_id = $2
            ))
        ) AS sub_group_count,
        EXISTS (
          SELECT 1 FROM group_memberships gm WHERE gm.group_id = g.id AND gm.profile_id = $2
        ) AS is_member
      WHERE NOT g.is_direct
    ) details ON TRUE
    """
  end

  defp load_child_group_row(fields, row) do
    {group, [member_count, sub_group_count, member?, shortcut_id | rest]} =
      load_group_row(fields, row)

    {%{
       group
       | listed_member_count: member_count,
         sub_group_count: sub_group_count,
         viewer_is_member: member?,
         shortcut_id: shortcut_id
     }, rest}
  end

  defp ordered_child_group_ids_for_profile(%Group{} = group, %Profile{} = profile, opts) do
    limit = normalize_query_limit(opts[:limit])
    offset = normalize_query_offset(opts[:offset])
    public? = public_children?(opts)

    %{rows: rows} =
      Repo.query!(
        ordered_child_group_ids_query(limit, offset, public?),
        ordered_child_groups_params(group, profile, opts, limit, offset),
        cache_statement: "social_child_group_ids_#{limit != nil}_#{offset != nil}_#{public?}"
      )

    Enum.map(rows, fn [group_id] -> group_id end)
  end

  defp ordered_child_groups_params(group, profile, opts, limit, offset) do
    # Only children with something unread below them sort by it; the counts
    # come from the overview instead of a walk down every child's sub-tree.
    # Every group with something unread goes, not only the sub-groups: a
    # shortcut's row is its target's, wherever that one stands.
    {unread_ids, unread_counts} =
      (opts[:unread_overview] || unread_overview(profile)).groups
      |> Enum.filter(fn {_id, info} -> info.subtree > 0 end)
      |> Enum.map(fn {id, info} -> {id, info.subtree} end)
      |> Enum.unzip()

    visible_children_params(group, profile, opts)
    |> Kernel.++([unread_ids, unread_counts])
    |> maybe_append_query_param(limit)
    |> maybe_append_query_param(offset)
  end

  # The `groups g` columns `Repo.load/2` makes a `Group` of.
  defp group_columns_sql(fields),
    do: Enum.map_join(fields, ", ", &"g.#{Group.__schema__(:field_source, &1)}")

  # A `Group` from a row that starts with `group_columns_sql/1`, and the
  # row's other columns.
  defp load_group_row(fields, row) do
    {values, rest} = Enum.split(row, length(fields))
    {Repo.load(Group, {fields, values}), rest}
  end

  # The `WITH` head that defines `visible_children`: the sub-groups of $1 that
  # profile $2 can see, its memberships plus the public ones, filtered by $3
  # (direct), $4 (name search), $5 (thread), $7 (kind) and $8 (member,
  # creator or follower). Without `public?`, only the public ones it follows
  # or on the way to a membership or a follow further down (`member_paths`).
  # The root adds the detached groups, $6
  # (`detached_group_ids/1`, empty elsewhere), which $5 leaves alone as
  # threads have no switch there. They come as ids so no page pays for
  # finding them: the walk up to the root inside this statement would make
  # Postgres JIT-compile it on every group page.
  # The memberships are read first, behind OFFSET 0: the cached generic plan
  # would otherwise walk every child of the group to probe them, and the root
  # is the parent of every direct conversation.
  defp visible_children_sql(public?) do
    own_filters =
      "($3::boolean IS NULL OR g.is_direct = $3)" <>
        " AND ($4::text IS NULL OR #{NameSearch.sql("g", "$4")})" <>
        " AND ($7::text IS NULL OR #{shown_kind_sql("g")} = $7)" <>
        " AND ($8::text IS NULL OR ($8 = 'creator' AND g.creator_id = $2)" <>
        " OR ($8 = 'member' AND EXISTS (" <>
        "SELECT 1 FROM group_memberships rm WHERE rm.group_id = g.id AND rm.profile_id = $2))" <>
        " OR ($8 = 'follower' AND EXISTS (" <>
        "SELECT 1 FROM group_follows rf WHERE rf.group_id = g.id AND rf.profile_id = $2)))"

    filters = "#{own_filters} AND ($5::boolean IS NULL OR (g.parent_value_id IS NOT NULL) = $5)"
    public_filter = if public?, do: "", else: " AND g.id IN (SELECT id FROM member_paths)"

    """
    #{visible_children_head(public?)} visible_children AS (
      SELECT g.id, g.inserted_at, g.last_value_at, NULL::bigint AS shortcut_id
      FROM (
        SELECT gm.group_id FROM group_memberships gm WHERE gm.profile_id = $2 OFFSET 0
      ) m
      JOIN groups g ON g.id = m.group_id
      WHERE g.parent_id = $1
        AND #{filters}

      UNION

      SELECT g.id, g.inserted_at, g.last_value_at, NULL::bigint
      FROM groups g
      WHERE g.parent_id = $1
        AND g.is_public = TRUE
        AND #{filters}#{public_filter}

      UNION

      SELECT g.id, g.inserted_at, g.last_value_at, NULL::bigint
      FROM groups g
      WHERE g.id = ANY($6::bigint[])
        AND #{own_filters}

      UNION

      #{shortcut_children_sql(own_filters, public_filter)}
    )
    """
  end

  # The fourth part of `visible_children`: the targets of $1's shortcuts that
  # profile $2 can see, by the rule of the list's own sub-groups (a membership,
  # or public and, with the root's switch off, on the way to one). A target
  # the list already holds, as a sub-group or a detached group ($6), is left
  # out, so no group stands in a list twice and its rows keep the group's id.
  # Shortcuts never lead to threads or direct conversations, so $5 does not
  # concern them. The targets come as `= ANY(ARRAY(...))`, which Postgres
  # reads by the key of each: a join let a generic plan walk the whole groups
  # key in order to find them (`shortcut_targets_sql/1`).
  defp shortcut_children_sql(own_filters, public_filter) do
    """
    SELECT g.id, g.inserted_at, g.last_value_at, s.id
    FROM groups g
    JOIN group_shortcuts s ON s.parent_id = $1 AND s.target_id = g.id
    WHERE g.id = ANY(#{shortcut_targets_sql("$1")})
      AND g.parent_id <> $1
      AND NOT (g.id = ANY($6::bigint[]))
      AND g.is_direct = FALSE
      AND g.parent_value_id IS NULL
      AND #{own_filters}
      AND (EXISTS (
        SELECT 1 FROM group_memberships sm WHERE sm.group_id = g.id AND sm.profile_id = $2
      ) OR (g.is_public#{public_filter}))
    """
  end

  # `GroupPresets.shown/1` in SQL: the preset of group `alias` while the group
  # still fits it, else NULL.
  # The kind a kind filter compares: the shown preset, "app" for any other
  # app, "none" otherwise, as `GroupPins.kind/1` names it.
  defp shown_kind_sql(alias),
    do:
      "COALESCE(#{shown_preset_sql(alias)}, CASE WHEN #{alias}.uses_api THEN 'app' ELSE 'none' END)"

  defp shown_preset_sql(alias) do
    apps = Enum.map_join(GroupPresets.app_keys(), ", ", &"'#{&1}'")

    "CASE WHEN (#{alias}.preset IN (#{apps})) = #{alias}.uses_api THEN #{alias}.preset END"
  end

  defp normalize_preset_filter(preset) when is_atom(preset) and not is_nil(preset),
    do: normalize_preset_filter(Atom.to_string(preset))

  defp normalize_preset_filter(preset) do
    if preset in GroupPresets.filter_keys(), do: preset
  end

  @doc """
  What `:relation` takes in the sub-group lists: the profile's memberships,
  its own groups or the groups it follows.
  """
  def child_group_relations, do: @child_group_relations

  defp normalize_relation_filter(relation) do
    if relation in @child_group_relations, do: relation
  end

  defp visible_children_head(true), do: "WITH"

  defp visible_children_head(false) do
    memberships = "SELECT gm.group_id FROM group_memberships gm WHERE gm.profile_id = $2"
    "WITH RECURSIVE #{member_paths_sql("$2", memberships)},"
  end

  # The groups no sub-groups list leads to although a membership of the
  # profile is at or below them: ones it can see, whose parent it cannot. Being
  # invited straight into a sub-group, or removed from a private parent, leaves
  # such a group, and only the root can list it. They are the groups
  # `hang_from_root/1` moves, so the lists and the unread counts agree.
  # Without records (`records?: false`) the walk starts from the
  # memberships that are not records apps keep as groups.
  defp detached_group_ids(%Profile{id: profile_id}, records? \\ true) do
    groups = member_group_chain(profile_id, records?)

    for {id, group} <- hang_from_root(groups), group.parent_id != groups[id].parent_id, do: id
  end

  defp public_children?(opts), do: Keyword.get(opts, :public, true) != false

  defp visible_children_params(%Group{} = group, %Profile{} = profile, opts) do
    [
      group.id,
      profile.id,
      normalize_boolean_filter(opts[:is_direct]),
      normalize_group_search_term(opts[:search]),
      normalize_boolean_filter(opts[:is_thread]),
      if(group.is_root, do: detached_group_ids(profile), else: []),
      normalize_preset_filter(opts[:preset]),
      normalize_relation_filter(opts[:relation])
    ]
  end

  @doc """
  Sorts sub-groups the way `list_child_group_ids_for_profile/3` orders them,
  with the unread counts of an `unread_overview/1` result, for a page that
  keeps its list in memory.
  """
  def sort_child_groups(groups, %{groups: unread}) do
    Enum.sort_by(groups, &child_group_sort_key(&1, unread), :desc)
  end

  # The ORDER BY of `ordered_child_groups_query/4`: unread first, then the
  # newest value (groups without one last), the newest group and the id.
  defp child_group_sort_key(%Group{} = group, unread) do
    {
      get_in(unread, [group.id, :subtree]) || 0,
      if(group.last_value_at, do: DateTime.to_unix(group.last_value_at, :microsecond), else: -1),
      DateTime.to_unix(group.inserted_at, :microsecond),
      group.id
    }
  end

  defp ordered_child_group_ids_query(limit, offset, public?),
    do: ordered_child_groups_query("vc.id", limit, offset, public?)

  # Unread counts arrive as $9 / $10; the newest chat value comes from
  # `groups.last_value_at`, kept up to date by `create_value/4` and
  # `delete_value/2`. `sort_child_groups/2` sorts the same way in memory.
  defp ordered_child_groups_query(select, limit, offset, public?) do
    """
    #{visible_children_sql(public?)}
    SELECT #{select}
    FROM visible_children vc
    LEFT JOIN UNNEST($9::bigint[], $10::bigint[]) AS uc(group_id, unread_count)
      ON uc.group_id = vc.id
    ORDER BY
      COALESCE(uc.unread_count, 0) DESC,
      vc.last_value_at DESC NULLS LAST,
      vc.inserted_at DESC,
      vc.id DESC#{ordered_child_group_pagination_sql(limit, offset)}
    """
  end

  defp ordered_child_group_pagination_sql(limit, offset) do
    []
    |> maybe_add_limit_sql(limit)
    |> maybe_add_offset_sql(limit, offset)
    |> Enum.join()
  end

  # $1..$10 are the filters and unread counts of `ordered_child_group_ids_query/3`.
  defp maybe_add_limit_sql(parts, limit) when is_integer(limit), do: parts ++ [" LIMIT $11"]
  defp maybe_add_limit_sql(parts, _limit), do: parts

  defp maybe_add_offset_sql(parts, limit, offset)
       when is_integer(limit) and is_integer(offset),
       do: parts ++ [" OFFSET $12"]

  defp maybe_add_offset_sql(parts, nil, offset) when is_integer(offset),
    do: parts ++ [" OFFSET $11"]

  defp maybe_add_offset_sql(parts, _limit, _offset), do: parts

  defp maybe_append_query_param(params, value) when is_integer(value), do: params ++ [value]
  defp maybe_append_query_param(params, _value), do: params

  defp normalize_query_limit(limit) when is_integer(limit) and limit >= 0, do: limit
  defp normalize_query_limit(_limit), do: nil

  defp normalize_query_offset(offset) when is_integer(offset) and offset >= 0, do: offset
  defp normalize_query_offset(_offset), do: nil

  defp normalize_boolean_filter(true), do: true
  defp normalize_boolean_filter(false), do: false
  defp normalize_boolean_filter(_), do: nil

  # A term every group search takes (`NameSearch.term/1`): trimmed, short,
  # with LIKE's own characters escaped.
  defp normalize_group_search_term(search_term), do: NameSearch.term(search_term)

  @doc "The people among the group's members: processes of apps are not counted (`AppProcesses`)."
  def list_group_members(%Group{} = group, opts \\ []) do
    import Ecto.Query, only: [from: 2]

    from(p in Profile,
      join: gm in GroupMembership,
      on: gm.profile_id == p.id,
      where: gm.group_id == ^group.id and p.kind == :person,
      order_by: [asc: p.username]
    )
    |> holding_role(opts[:role])
    |> maybe_paginate(opts)
    |> Repo.all()
  end

  # Members who hold the role in the group, through the parent too. Everyone
  # is every member, as it is never stored.
  defp holding_role(query, role_key) when role_key in [nil, "everyone"], do: query

  defp holding_role(query, role_key) when is_binary(role_key) do
    from([p, gm] in query,
      join: r in GroupMemberRole,
      on: r.group_id == gm.group_id and r.profile_id == gm.profile_id and r.role_key == ^role_key
    )
  end

  @doc """
  How many people belong to the group: the column Postgres keeps
  (`Group.member_count`), read again, as a struct in hand may be older. The
  root keeps 0 there, so its people are counted. With `role:`, only those who
  hold that role are counted.
  """
  def count_group_members(group, opts \\ [])

  def count_group_members(%Group{} = group, role: role_key)
      when is_binary(role_key) and role_key != "everyone" do
    from(p in Profile,
      join: gm in GroupMembership,
      on: gm.profile_id == p.id,
      where: gm.group_id == ^group.id and p.kind == :person,
      select: count(gm.profile_id)
    )
    |> holding_role(role_key)
    |> Repo.one()
  end

  def count_group_members(%Group{is_root: true} = group, _opts) do
    from(gm in GroupMembership,
      join: p in Profile,
      on: p.id == gm.profile_id,
      where: gm.group_id == ^group.id and p.kind == :person,
      select: count(gm.profile_id)
    )
    |> Repo.one()
  end

  def count_group_members(%Group{id: group_id}, _opts) do
    from(g in Group, where: g.id == ^group_id, select: g.member_count)
    |> Repo.one()
    |> Kernel.||(0)
  end

  def list_first3_group_members(%Group{} = group) do
    import Ecto.Query, only: [from: 2]

    from(p in Profile,
      join: gm in GroupMembership,
      on: gm.profile_id == p.id,
      where: gm.group_id == ^group.id and p.kind == :person,
      limit: 3
    )
    |> Repo.all()
  end

  @doc """
  How many unread values a group counts at most: a group with more shows
  "99+", and nothing counts past it, so a member who never opens a busy group
  costs every count no more than this many rows.
  """
  def unread_cap, do: @unread_cap

  # `u.unread`: the unread chat values of membership `gm` with marker `gvr`,
  # up to `unread_cap/0`, read along the index of a group's chat by id.
  defp capped_unread_sql(gm, gvr) do
    """
    CROSS JOIN LATERAL (
      SELECT COUNT(*)::bigint AS unread
      FROM (
        SELECT 1 FROM values v
        WHERE v.group_id = #{gm}.group_id
          AND v.is_data = FALSE
          AND v.id > COALESCE(#{gvr}.last_read_value_id, 0)
        LIMIT #{@unread_cap}
      ) capped
    ) u
    """
  end

  # The profile whose reactions a page of values marks as its own.
  defp viewer_id(opts) do
    case Keyword.get(opts, :viewer) do
      %Profile{id: id} -> id
      _none -> nil
    end
  end

  def list_group_values(%Group{} = group, opts \\ []) do
    import Ecto.Query, only: [from: 2]

    from(v in Value,
      where: v.group_id == ^group.id and v.is_data == false,
      order_by: [asc: v.id],
      preload: ^value_display_preloads()
    )
    |> maybe_paginate(opts)
    |> Repo.all()
    |> put_display_extras(viewer_id(opts))
  end

  @doc """
  Keyset page of chat values: the newest `limit` values older than
  `before_id` (or the newest overall), oldest first. With `after_id`, the
  oldest `limit` values newer than it instead. Fetches one extra row to tell
  whether more values exist that way, so no count query is needed.
  """
  def list_group_values_page(%Group{} = group, opts \\ []) do
    limit = Keyword.get(opts, :limit, 20)

    query =
      from(v in Value,
        where: v.group_id == ^group.id and v.is_data == false,
        limit: ^(limit + 1),
        preload: ^value_display_preloads()
      )

    case opts[:after_id] do
      after_id when is_integer(after_id) ->
        rows =
          from(v in query, where: v.id > ^after_id, order_by: [asc: v.id])
          |> Repo.all()

        {rows |> Enum.take(limit) |> put_display_extras(viewer_id(opts)), length(rows) > limit}

      nil ->
        rows =
          from(v in query, order_by: [desc: v.id])
          |> maybe_before_id(opts[:before_id])
          |> Repo.all()

        {rows |> Enum.take(limit) |> Enum.reverse() |> put_display_extras(viewer_id(opts)),
         length(rows) > limit}
    end
  end

  defp maybe_before_id(query, before_id) when is_integer(before_id),
    do: from(v in query, where: v.id < ^before_id)

  defp maybe_before_id(query, _before_id), do: query

  @doc """
  The chat values around `value_id`, oldest first: up to `older` values
  before it, the value itself and up to `newer` values after it. Returns
  `{values, older?, newer?}`, or nil when it is not a chat value of the group.
  Two keyset pages, however far back the value is.
  """
  def list_group_values_around(%Group{} = group, value_id, opts \\ [])
      when is_integer(value_id) do
    older = Keyword.get(opts, :older, 10)
    newer = Keyword.get(opts, :newer, 20)

    # `after_id` is exclusive, so starting one id lower takes the value first.
    viewer = Keyword.get(opts, :viewer)

    case list_group_values_page(group, after_id: value_id - 1, limit: newer + 1, viewer: viewer) do
      {[%Value{id: ^value_id} | _] = from_value, newer?} ->
        {before, older?} =
          list_group_values_page(group, before_id: value_id, limit: older, viewer: viewer)

        {before ++ from_value, older?, newer?}

      _ ->
        nil
    end
  end

  @value_search_limit 20
  @value_search_timeout_ms 3_000
  @max_value_id 9_223_372_036_854_775_807

  @doc """
  The chat values of `group` whose text holds `term` (a `NameSearch.term/1`),
  newest first, with their creators: `{:ok, {values, more?}}`, or
  `{:error, :timeout}` when the search takes too long. Texts compare folded
  (`values.content_folded`), so case, diacritics and script do not count.

  Options:
  * `:threads_for`, a profile that is a member: also the threads right below
    the group, whose values have the thread as `group_id` (a member may open
    any of them);
  * `:outsider`, someone reading an open chat from outside: leaves out the
    announcements of events that are not public, as the chat hides them;
  * `:before_id`, to page on from the oldest value found; `:limit`.

  Each chat is read from its newest value through the chat id index, so a
  word that turns up often stops early, and one found nowhere reads the whole
  chat: ~30 ms for 100,000 values, as the text is folded already.
  """
  def search_group_values(%Group{} = group, term, opts \\ []) when is_binary(term) do
    limit = Keyword.get(opts, :limit, @value_search_limit)
    before_id = Keyword.get(opts, :before_id) || @max_value_id
    outsider? = Keyword.get(opts, :outsider, false)

    Repo.with_statement_timeout(
      @value_search_timeout_ms,
      fn ->
        group_ids = [group.id | value_search_thread_ids(group, opts[:threads_for])]

        %{rows: rows} =
          Repo.query!(value_search_sql(outsider?), [group_ids, before_id, term, limit + 1],
            cache_statement: "social_search_group_values_#{outsider?}"
          )

        {ids, more} = rows |> List.flatten() |> Enum.split(limit)

        by_id =
          from(v in Value, where: v.id in ^ids, preload: [creator: :app_process])
          |> Repo.all()
          |> Map.new(&{&1.id, &1})

        {ids |> Enum.map(&by_id[&1]) |> Enum.reject(&is_nil/1), more != []}
      end,
      jit: false
    )
  end

  defp value_search_thread_ids(_group, nil), do: []

  # Every thread right below the group, for a member of the group: they may
  # open any of them, and opening one takes them in (`join_thread/2`).
  defp value_search_thread_ids(%Group{id: group_id}, %Profile{id: profile_id}) do
    from(g in Group,
      join: m in GroupMembership,
      on: m.group_id == g.parent_id and m.profile_id == ^profile_id,
      where: g.parent_id == ^group_id and not is_nil(g.parent_value_id),
      select: g.id
    )
    |> Repo.all()
  end

  # Each chat from its newest value down, then the newest of all of them.
  defp value_search_sql(outsider?) do
    hidden_events =
      if outsider?,
        do:
          "AND NOT EXISTS (SELECT 1 FROM group_events e WHERE e.value_id = x.id AND NOT e.is_public)",
        else: ""

    """
    SELECT v.id
    FROM unnest($1::bigint[]) AS g(id)
    CROSS JOIN LATERAL (
      SELECT x.id
      FROM values x
      WHERE x.group_id = g.id
        AND x.is_data = FALSE
        AND x.id < $2
        AND x.content_folded LIKE '%' || potok_fold($3::text) || '%'
        #{hidden_events}
      ORDER BY x.id DESC
      LIMIT $4
    ) v
    ORDER BY v.id DESC
    LIMIT $4
    """
  end

  @doc """
  Keyset page of the files attached in the group, newest first, with their
  uploaders and enough of their values to tell a chat message from an app's
  data value (`attachment_value_query/0`). Returns `{attachments, more?}` like
  `list_group_values_page/2`. `search` and `kind` narrow the files
  (`filter_attachments/2`).
  """
  def list_group_attachments(%Group{} = group, opts \\ []) do
    limit = Keyword.get(opts, :limit, 30)

    rows =
      from(a in ValueAttachment,
        where: a.group_id == ^group.id,
        order_by: [desc: a.id],
        limit: ^(limit + 1),
        preload: [:profile, value: ^attachment_value_query()]
      )
      |> maybe_before_id(opts[:before_id])
      |> filter_attachments(opts)
      |> Repo.all()

    {Enum.take(rows, limit), length(rows) > limit}
  end

  @doc """
  A file of the group with its uploader, as `list_group_attachments/2` lists
  it with the same `opts`: nil when the file is not among them.
  """
  def get_group_attachment(%Group{id: group_id}, attachment_id, opts \\ [])
      when is_integer(attachment_id) do
    from(a in ValueAttachment,
      where: a.id == ^attachment_id and a.group_id == ^group_id,
      preload: [:profile, value: ^attachment_value_query()]
    )
    |> filter_attachments(opts)
    |> Repo.one()
  end

  # The files whose name holds `search`, folded as the other searches, and of
  # one `kind` (`ValueAttachment.kind/1`). The name is folded once, in
  # `filename_folded`, and the search here (`TextFold.fold/1`, the same as
  # `potok_fold/1`), so no row is folded per search. `strpos` rather than
  # LIKE, so `_` and `%` in a name are only themselves.
  defp filter_attachments(query, opts) do
    query =
      case opts[:search] && PotokIde.TextFold.fold(opts[:search]) do
        search when is_binary(search) and search != "" ->
          where(query, [a], fragment("strpos(?, ?) > 0", a.filename_folded, ^search))

        _none ->
          query
      end

    case opts[:kind] do
      nil -> query
      kind -> where(query, ^ValueAttachment.kind_condition(kind))
    end
  end

  # A file's value as the Files tab needs it: whether it is a chat message,
  # which the file links to, or an app's data value (`AppFiles`), in no chat.
  defp attachment_value_query, do: from(v in Value, select: [:id, :is_data])

  @doc """
  The attachment when the profile reads the chat it was posted in: a member of
  the group, or anyone in an open chat, where it is on the page. A file sent
  to an app (`AppFiles`) also opens for whoever sent it, who need not be a
  member of the group that keeps it. nil otherwise.
  """
  def get_attachment_for_download(%Profile{} = profile, attachment_id)
      when is_integer(attachment_id) do
    attachment =
      from(a in ValueAttachment,
        join: g in assoc(a, :group),
        where: a.id == ^attachment_id,
        preload: [group: g]
      )
      |> Repo.one()

    if attachment &&
         (Group.open_chat?(attachment.group) or member_of_group?(profile, attachment.group) or
            own_app_file?(profile, attachment)),
       do: attachment
  end

  def get_attachment_for_download(_profile, _attachment_id), do: nil

  defp own_app_file?(
         %Profile{id: profile_id},
         %ValueAttachment{profile_id: profile_id} = attachment
       ) do
    Repo.exists?(
      from(v in Value, where: v.id == ^attachment.value_id and v.collection == "files")
    )
  end

  defp own_app_file?(_profile, _attachment), do: false

  @doc "A file by id, for a caller that has settled access already."
  def get_attachment(attachment_id), do: Repo.get(ValueAttachment, attachment_id)

  @group_tree_max_depth 10
  @group_tree_max_groups 500
  @attachment_tree_max_files 1000

  # `group` and the sub-groups below it the profile can see, the same rule as
  # the sub-groups tab (members, or public groups), skipping direct
  # conversations. Breadth first, so `group` comes first; the walk stops at
  # #{@group_tree_max_depth} levels and #{@group_tree_max_groups} groups.
  # Returns `{rows, truncated?}`.
  defp visible_group_tree_rows(%Group{} = group, profile_id) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        """
        WITH RECURSIVE tree AS (
          SELECT g.id, g.parent_id, g.name, g.parent_value_id, g.is_public, 0 AS depth
          FROM groups g
          WHERE g.id = $1

          UNION ALL

          SELECT c.id, c.parent_id, c.name, c.parent_value_id, c.is_public, t.depth + 1
          FROM groups c
          JOIN tree t ON c.parent_id = t.id
          WHERE t.depth < $3
            AND c.is_direct = FALSE
            AND (
              c.is_public = TRUE
              OR EXISTS (
                SELECT 1 FROM group_memberships gm
                WHERE gm.group_id = c.id AND gm.profile_id = $2
              )
            )
        )
        SELECT
          t.id,
          t.parent_id,
          t.name,
          t.parent_value_id IS NOT NULL,
          t.is_public,
          EXISTS (
            SELECT 1 FROM group_memberships gm
            WHERE gm.group_id = t.id AND gm.profile_id = $2
          )
        FROM tree t
        ORDER BY t.depth, t.id
        LIMIT $4
        """,
        [group.id, profile_id, @group_tree_max_depth, @group_tree_max_groups + 1]
      )

    groups =
      rows
      |> Enum.take(@group_tree_max_groups)
      |> Enum.map(fn [id, parent_id, name, thread?, public?, member?] ->
        %{
          id: id,
          parent_id: parent_id,
          name: name,
          thread?: thread?,
          public?: public?,
          member?: member?
        }
      end)

    {groups, length(rows) > @group_tree_max_groups}
  end

  @sub_group_search_max_groups 5000
  @sub_group_search_max_matches 100
  @sub_group_search_timeout_ms 3_000

  @doc """
  A page of the sub-groups below each of `parents` the profile can see, for
  the folder view of the sub-groups tab: the groups the tab lists (members,
  or public groups; no direct conversations), sorted by name. A nil profile
  sees only public groups.

  `parents` are `{parent_id, limit, after}`: up to `limit` folders sorting
  after `after`, the `%{id, name}` of the last folder already shown, or nil
  for the first page. Options: `threads?: false` leaves out threads, and
  `public?: false` the public groups the profile is not in, but those it
  follows and those with one of its memberships or followed groups below
  them, and `records?: false` the records apps keep as groups
  (`external_key`), also as memberships, so a folder of nothing but records
  shows none.

  Returns `%{parent_id => {folders, more?}}`, an entry per parent. Each
  folder is `%{id, name, thread?, public?, member?, child_count,
  thread_child_count, shortcut_id}`: how many sub-groups the folder view
  shows below it, its shortcuts among them, and how many of the sub-groups
  below it are threads, shown or not. A shortcut's target comes as a leaf with
  its `shortcut_id` and no counts: it opens where it stands.
  """
  def list_sub_group_folders(profile, parents, opts \\ [])

  def list_sub_group_folders(_profile, [], _opts), do: %{}

  def list_sub_group_folders(profile, parents, opts) do
    records? = Keyword.get(opts, :records?, true)

    sql = """
    WITH RECURSIVE #{sub_group_memberships_sql("$5", records?)}
    SELECT p.parent_id, f.id, f.name, f.is_thread, f.is_public, f.is_member,
      CASE WHEN f.shortcut_id IS NULL THEN counts.child_count ELSE 0 END,
      CASE WHEN f.shortcut_id IS NULL THEN counts.thread_child_count ELSE 0 END,
      f.shortcut_id
    FROM UNNEST($1::bigint[], $2::integer[], $3::text[], $4::bigint[])
      AS p(parent_id, page_limit, after_name, after_id)
    CROSS JOIN LATERAL (
      SELECT v.id, v.name, v.is_thread, v.is_public, v.is_member, v.shortcut_id
      FROM (
        SELECT g.id, g.name, g.parent_value_id IS NOT NULL AS is_thread, g.is_public,
          TRUE AS is_member, NULL::bigint AS shortcut_id
        FROM mine
        JOIN groups g ON g.id = mine.group_id
        WHERE g.parent_id = p.parent_id AND #{sub_group_filter_sql("g", records?)}

        UNION

        SELECT g.id, g.name, g.parent_value_id IS NOT NULL, g.is_public,
          g.id IN (SELECT group_id FROM mine), NULL::bigint
        FROM groups g
        WHERE g.parent_id = p.parent_id AND #{sub_group_public_sql("g")}
          AND #{sub_group_filter_sql("g", records?)}

        UNION

        SELECT g.id, g.name, g.parent_value_id IS NOT NULL, g.is_public,
          g.id IN (SELECT group_id FROM mine), NULL::bigint
        FROM groups g
        WHERE g.id = ANY($8::bigint[])
          AND g.is_direct = FALSE#{record_filter_sql("g", records?)}
          AND p.parent_id = (SELECT r.id FROM groups r WHERE r.is_root)

        UNION

        SELECT g.id, g.name, FALSE, g.is_public, g.id IN (SELECT group_id FROM mine), s.id
        FROM groups g
        JOIN group_shortcuts s ON s.parent_id = p.parent_id AND s.target_id = g.id
        WHERE g.id = ANY(#{shortcut_targets_sql("p.parent_id")})
          AND #{shortcut_folder_sql("g", "p.parent_id")}
          AND NOT (g.id = ANY($8::bigint[])
            AND p.parent_id = (SELECT r.id FROM groups r WHERE r.is_root))
      ) v
      WHERE p.after_id IS NULL OR (lower(v.name), v.id) > (lower(p.after_name), p.after_id)
      ORDER BY lower(v.name), v.id
      LIMIT p.page_limit + 1
    ) f
    #{sub_group_counts_sql("f", records?)}
    ORDER BY p.parent_id, lower(f.name), f.id
    """

    params = [
      Enum.map(parents, &elem(&1, 0)),
      Enum.map(parents, &elem(&1, 1)),
      Enum.map(parents, fn {_parent_id, _limit, last} -> last && last.name end),
      Enum.map(parents, fn {_parent_id, _limit, last} -> last && last.id end),
      profile && profile.id,
      Keyword.get(opts, :threads?, true),
      Keyword.get(opts, :public?, true),
      detached_ids_below(profile, Enum.map(parents, &elem(&1, 0)), records?)
    ]

    %{rows: rows} =
      Repo.query!(sql, params, cache_statement: "social_sub_group_folders_#{records?}")

    folders_by_parent = Enum.group_by(rows, &hd/1, &sub_group_folder(tl(&1)))

    Map.new(parents, fn {parent_id, limit, _after} ->
      folders = Map.get(folders_by_parent, parent_id, [])
      {parent_id, {Enum.take(folders, limit), length(folders) > limit}}
    end)
  end

  @doc """
  The sub-groups below `group` the profile can see whose name contains
  `search`, and the folders on the way to them: folders of
  `list_sub_group_folders/3` with their `parent_id`, sorted by name. The
  search walks down breadth first through #{@sub_group_search_max_groups}
  sub-groups at most and keeps the first #{@sub_group_search_max_matches}
  matches; `{folders, truncated?}` tells whether it cut either. Takes the
  options of `list_sub_group_folders/3`, where threads leave out what is
  below them too, and `:preset` and `:relation`, which keep the matches of
  one kind, or the profile's memberships, own groups or followed groups, as in
  `list_child_groups_for_profile/3`: with either, `search` may be nil.
  """
  def search_sub_group_folders(%Group{} = group, profile, search, opts \\ []) do
    filters = %{
      term: normalize_group_search_term(search),
      preset: normalize_preset_filter(opts[:preset]),
      relation: normalize_relation_filter(opts[:relation])
    }

    if filters == %{term: nil, preset: nil, relation: nil},
      do: {[], false},
      else: run_sub_group_search(group, profile, filters, opts)
  end

  defp run_sub_group_search(group, profile, filters, opts) do
    records? = Keyword.get(opts, :records?, true)

    visible =
      "#{sub_group_filter_sql("g", records?)}" <>
        " AND (g.id IN (SELECT group_id FROM mine) OR #{sub_group_public_sql("g")})"

    kind = shown_kind_sql("g")

    sql = """
    WITH RECURSIVE #{sub_group_memberships_sql("$5", records?)},
    tree AS (
      SELECT g.id, g.parent_id, g.name, g.name_folded, g.parent_value_id, g.is_public,
        #{kind} AS kind, g.creator_id, ARRAY[g.id] AS path
      FROM groups g
      WHERE g.parent_id = $1 AND #{visible}

      UNION ALL

      SELECT g.id, $1::bigint, g.name, g.name_folded, g.parent_value_id, g.is_public, #{kind},
        g.creator_id, ARRAY[g.id]
      FROM groups g
      WHERE g.id = ANY($8::bigint[]) AND g.is_direct = FALSE#{record_filter_sql("g", records?)}

      UNION ALL

      SELECT g.id, g.parent_id, g.name, g.name_folded, g.parent_value_id, g.is_public, #{kind},
        g.creator_id, t.path || g.id
      FROM tree t
      JOIN groups g ON g.parent_id = t.id
      WHERE #{visible}
    ),
    walked AS (SELECT * FROM tree LIMIT $3::integer + 1),
    matches AS (
      SELECT w.path FROM walked w
      WHERE ($2::text IS NULL OR #{NameSearch.sql("w", "$2")})
        AND ($9::text IS NULL OR w.kind = $9)
        AND ($10::text IS NULL OR ($10 = 'creator' AND w.creator_id = $5)
          OR ($10 = 'member' AND w.id IN (SELECT group_id FROM mine))
          OR ($10 = 'follower' AND w.id IN (SELECT group_id FROM followed)))
      LIMIT $4::integer + 1
    ),
    shown AS (
      SELECT DISTINCT unnest(m.path) AS id FROM (SELECT path FROM matches LIMIT $4) m
    )
    SELECT cut.truncated, f.parent_id, f.id, f.name, f.is_thread, f.is_public, f.is_member,
      counts.child_count, counts.thread_child_count
    FROM (
      SELECT (SELECT COUNT(*) FROM walked) > $3 OR (SELECT COUNT(*) FROM matches) > $4
        AS truncated
    ) cut
    LEFT JOIN (
      SELECT w.id, w.parent_id, w.name, w.parent_value_id IS NOT NULL AS is_thread,
        w.is_public, w.id IN (SELECT group_id FROM mine) AS is_member
      FROM walked w
      JOIN shown s ON s.id = w.id
    ) f ON TRUE
    #{sub_group_counts_sql("f", records?)}
    ORDER BY lower(f.name), f.id
    """

    params = [
      group.id,
      filters.term,
      @sub_group_search_max_groups,
      @sub_group_search_max_matches,
      profile && profile.id,
      Keyword.get(opts, :threads?, true),
      Keyword.get(opts, :public?, true),
      detached_ids_below(profile, [group.id], records?),
      filters.preset,
      filters.relation
    ]

    # Postgres would compile the walk (seconds on a big tree: 2.3 s for a
    # profile in 102 groups on the dev database, 0.45 s without), and a walk
    # that still takes too long shows nothing found instead of holding the page.
    Repo.with_statement_timeout(
      @sub_group_search_timeout_ms,
      fn ->
        Repo.query!(sql, params, cache_statement: "social_search_sub_group_folders_#{records?}")
      end,
      jit: false
    )
    |> case do
      {:ok, %{rows: [[truncated? | _] | _] = rows}} ->
        folders =
          for [_truncated?, parent_id | folder] <- rows, parent_id != nil do
            folder |> sub_group_folder() |> Map.put(:parent_id, parent_id)
          end

        {folders, truncated?}

      {:error, :timeout} ->
        {[], true}
    end
  end

  # The folder queries take the profile as $5 (nil sees no memberships),
  # whether threads are shown as $6 and whether every public group is as $7.
  # `followed` are the groups the profile follows and may see, for the
  # follower filter: a follow outlives the right to see its group, so it is
  # checked again here. `member_paths` (`member_paths_sql/2`) are needed only
  # when $7 is false. The groups the root adds (`detached_ids_below/2`) are $8.
  # Without records (`records?: false`) the memberships leave out what apps
  # keep as groups, so no path leads to them either.
  defp sub_group_memberships_sql(profile_param, records? \\ true) do
    memberships =
      if records?,
        do: "SELECT gm.group_id FROM group_memberships gm WHERE gm.profile_id = #{profile_param}",
        else:
          "SELECT gm.group_id FROM group_memberships gm JOIN groups rg ON rg.id = gm.group_id" <>
            " WHERE gm.profile_id = #{profile_param} AND rg.external_key IS NULL"

    """
    mine AS MATERIALIZED (
      #{memberships}
    ),
    followed AS (
      SELECT f.group_id FROM group_follows f JOIN groups g ON g.id = f.group_id
      WHERE f.profile_id = #{profile_param}
        AND (g.is_public OR f.group_id IN (SELECT group_id FROM mine))
    ),
    #{member_paths_sql(profile_param, "SELECT group_id FROM mine")}
    """
  end

  # The public groups the root keeps while it hides the others: those the
  # profile follows, and those above its memberships (`memberships`, SQL
  # that gives their `group_id`) and its follows. A private group it follows
  # and may see is a membership. The follows are an arm of their own rather
  # than mixed into the memberships, which grew the planner's estimate past
  # Postgres' JIT threshold for a profile in thousands of groups.
  defp member_paths_sql(profile_param, memberships) do
    """
    member_paths(id) AS (
      SELECT g.parent_id FROM (#{memberships}) m JOIN groups g ON g.id = m.group_id
      WHERE g.parent_id IS NOT NULL

      UNION

      SELECT f.group_id FROM group_follows f JOIN groups g ON g.id = f.group_id
      WHERE f.profile_id = #{profile_param} AND g.is_public

      UNION

      SELECT g.parent_id FROM member_paths mp JOIN groups g ON g.id = mp.id
      WHERE g.parent_id IS NOT NULL
    )
    """
  end

  defp detached_ids_below(nil, _parent_ids, _records?), do: []

  defp detached_ids_below(%Profile{} = profile, parent_ids, records?) do
    if Repo.exists?(from(g in Group, where: g.id in ^parent_ids and g.is_root)),
      do: detached_group_ids(profile, records?),
      else: []
  end

  defp sub_group_filter_sql(alias, records?) do
    "#{alias}.is_direct = FALSE AND ($6::boolean OR #{alias}.parent_value_id IS NULL)" <>
      record_filter_sql(alias, records?)
  end

  # Leaves out the records apps keep as groups, for `records?: false`.
  defp record_filter_sql(_alias, true), do: ""
  defp record_filter_sql(alias, false), do: " AND #{alias}.external_key IS NULL"

  # The public groups the folder view shows, members or not: all of them, or
  # only the followed ones and those on the way to a membership or a follow.
  defp sub_group_public_sql(alias) do
    "#{alias}.is_public AND ($7::boolean OR #{alias}.id IN (SELECT id FROM member_paths))"
  end

  # The targets of the shortcuts in the group `parent` (SQL), as an array for
  # `= ANY(...)`: a generic plan of a join walked the whole key of `groups`
  # to find them, in hundreds of milliseconds with JIT for a profile in
  # thousands of groups, where this reads each by its key.
  defp shortcut_targets_sql(parent) do
    "ARRAY(SELECT st.target_id FROM group_shortcuts st WHERE st.parent_id = #{parent})"
  end

  # A shortcut target `alias` the folder view shows in the folder `folder`:
  # one the profile sees by the rule of the folder's own sub-groups, and not
  # one of them already. Shortcuts never lead to threads or direct
  # conversations.
  defp shortcut_folder_sql(alias, folder) do
    "#{alias}.parent_id <> #{folder} AND #{alias}.is_direct = FALSE" <>
      " AND #{alias}.parent_value_id IS NULL" <>
      " AND (#{alias}.id IN (SELECT group_id FROM mine) OR #{sub_group_public_sql(alias)})"
  end

  # Per folder: the visible sub-groups the folder view shows below it, its
  # shortcuts among them, and the threads among all of them for the threads
  # switch.
  defp sub_group_counts_sql(folder, records?) do
    """
    LEFT JOIN LATERAL (
      SELECT
        COUNT(*) FILTER (WHERE $6::boolean OR k.parent_value_id IS NULL) + (
          SELECT COUNT(*) FROM groups k
          WHERE k.id = ANY(#{shortcut_targets_sql("#{folder}.id")})
            AND #{shortcut_folder_sql("k", "#{folder}.id")}
        ) AS child_count,
        COUNT(*) FILTER (WHERE k.parent_value_id IS NOT NULL) AS thread_child_count
      FROM groups k
      WHERE k.parent_id = #{folder}.id
        AND k.is_direct = FALSE#{record_filter_sql("k", records?)}
        AND (k.id IN (SELECT group_id FROM mine) OR #{sub_group_public_sql("k")})
    ) counts ON TRUE
    """
  end

  # A folder of the folder queries; `shortcut_id` is set for a shortcut, which
  # the folder view shows as a leaf that opens its target.
  defp sub_group_folder([id, name, thread?, public?, member?, child_count, thread_child_count]),
    do:
      sub_group_folder([
        id,
        name,
        thread?,
        public?,
        member?,
        child_count,
        thread_child_count,
        nil
      ])

  defp sub_group_folder([
         id,
         name,
         thread?,
         public?,
         member?,
         child_count,
         thread_child_count,
         shortcut_id
       ]) do
    %{
      id: id,
      name: name,
      thread?: thread?,
      public?: public?,
      member?: member?,
      child_count: child_count,
      thread_child_count: thread_child_count,
      shortcut_id: shortcut_id
    }
  end

  @doc """
  The files of `group` and its sub-groups as a folder tree for the profile.
  It walks down through the sub-groups the profile can see, the same rule as
  the sub-groups tab (members, or public groups), skipping direct
  conversations. Files are listed only for groups the profile is a member of,
  and folders with no files anywhere below them are left out.

  Each node is `%{group: %{id, name, thread?, public?, member?}, files: [...],
  children: [...], file_count: n, byte_size: n}`. The walk stops at
  #{@group_tree_max_depth} levels and #{@group_tree_max_groups} groups,
  and only the newest #{@attachment_tree_max_files} files are placed;
  `{tree, truncated?}` tells whether anything was cut. `search` and `kind`
  narrow the files as in `list_group_attachments/2`, so only the folders that
  hold a match stay.
  """
  def attachment_tree(%Group{} = group, %Profile{} = profile, opts \\ []) do
    {folders, groups_truncated?} = visible_group_tree_rows(group, profile.id)

    member_group_ids = for folder <- folders, folder.member?, do: folder.id

    files =
      from(a in ValueAttachment,
        where: a.group_id in ^member_group_ids,
        order_by: [desc: a.id],
        limit: ^(@attachment_tree_max_files + 1),
        preload: [value: ^attachment_value_query()]
      )
      |> filter_attachments(opts)
      |> Repo.all()

    files_truncated? = length(files) > @attachment_tree_max_files

    files_by_group =
      files
      |> Enum.take(@attachment_tree_max_files)
      |> Enum.group_by(& &1.group_id)

    folders_by_parent = Enum.group_by(folders, & &1.parent_id)
    [root | _] = folders

    {build_attachment_folder(root, folders_by_parent, files_by_group, true),
     groups_truncated? or files_truncated?}
  end

  defp build_attachment_folder(folder, folders_by_parent, files_by_group, root?) do
    children =
      folders_by_parent
      |> Map.get(folder.id, [])
      |> Enum.map(&build_attachment_folder(&1, folders_by_parent, files_by_group, false))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(&{String.downcase(&1.group.name), &1.group.id})

    files =
      files_by_group
      |> Map.get(folder.id, [])
      |> Enum.sort_by(&{String.downcase(&1.filename), &1.id})

    file_count = length(files) + Enum.sum_by(children, & &1.file_count)

    if file_count == 0 and not root? do
      nil
    else
      %{
        group: Map.delete(folder, :parent_id),
        files: files,
        children: children,
        file_count: file_count,
        byte_size: Enum.sum_by(files, & &1.byte_size) + Enum.sum_by(children, & &1.byte_size)
      }
    end
  end

  def count_group_values(%Group{} = group) do
    import Ecto.Query, only: [from: 2]

    from(v in Value,
      where: v.group_id == ^group.id and v.is_data == false,
      select: count(v.id)
    )
    |> Repo.one()
  end

  def list_group_data_values(%Group{} = group, opts \\ []) do
    import Ecto.Query, only: [from: 2]

    from(v in Value,
      where: v.group_id == ^group.id and v.is_data == true,
      preload: [:creator, :parent]
    )
    |> maybe_filter_data_value_field(opts[:search_field], opts[:search_value])
    |> maybe_order_data_value_field(opts[:order_by], opts[:order_dir])
    |> maybe_paginate(opts)
    |> Repo.all()
  end

  @doc """
  Data values for the app API as plain maps. Joins only the creator's
  username instead of preloading full structs, caps the page size and
  supports `after_id` / `before_id` cursors for incremental reads.
  Returns `{rows, has_more?}`.

  `scope` picks the apps whose values are read: `{:app, nil}` (the default
  description's, also when omitted), `{:app, alt_description_id}` or
  `{:group, alt_description_ids}` (the default's and those alternatives').

  `collection` picks one collection (`PotokIde.Social.AppData`); without it
  only values outside collections are read, so apps that use none never see
  what the rules of a collection keep from them. `creator_id` keeps one
  author's values and `match` those whose data contains it (`@>`).

  Without `order_by`, a collection is ordered by id and other values by when
  they were written; `order_dir: "desc"` gives the newest first. A page always
  lies right next to its cursor: `before_id` alone gives the values just
  before it, `after_id` alone those just after it, in the asked order either
  way, and `offset` counts on from the cursor. `has_more?` tells whether more
  lie beyond the page, away from the cursor. With `order_by` (a key of the
  data) the cursors only narrow by id.

  The creators' names are read after the page, in a query of their own: joined
  in the same query, a filter that matches many rows can make Postgres loop
  over every profile for each of them.
  """
  def list_group_data_value_rows(%Group{} = group, opts \\ []) do
    limit = opts[:limit] |> Kernel.||(50) |> min(200) |> max(1)
    {scan, reverse?} = data_value_scan(opts)

    rows =
      group
      |> data_value_rows_query(opts)
      |> maybe_after_id(opts[:after_id])
      |> maybe_before_id(opts[:before_id])
      |> order_data_value_rows(opts, scan)
      |> maybe_offset(opts[:offset])
      |> limit(^(limit + 1))
      |> select([v], %{
        id: v.id,
        content: v.content,
        data: v.data,
        content_format: v.content_format,
        is_data: v.is_data,
        group_id: v.group_id,
        parent_id: v.parent_id,
        creator_id: v.creator_id,
        description_id: v.alt_description_id,
        collection: v.collection,
        anonymous: v.anonymous,
        revision: v.lock_version,
        managed: v.managed,
        inserted_at: v.inserted_at,
        updated_at: v.updated_at
      })
      |> Repo.all()

    page = Enum.take(rows, limit)
    page = if reverse?, do: Enum.reverse(page), else: page

    {put_creator_usernames(page), length(rows) > limit}
  end

  @data_count_timeout_ms 3_000

  @doc """
  How many values `list_group_data_value_rows/2` would page through with these
  filters. A total over a big collection with a search reads every row, so it
  gives up after #{@data_count_timeout_ms} ms and returns nil, as when no total
  is asked for, rather than hold the page and a connection.
  """
  def count_group_data_value_rows(%Group{} = group, opts \\ []) do
    query = group |> data_value_rows_query(opts) |> select([v], count(v.id))

    case Repo.with_statement_timeout(@data_count_timeout_ms, fn -> Repo.one(query) end,
           jit: false
         ) do
      {:ok, count} -> count
      {:error, :timeout} -> nil
    end
  end

  @doc """
  Sums over the numbers in the values `list_group_data_value_rows/2` would page
  through with the same filters (`PotokIde.Social.ValueAggregate`). `group_by`,
  `fields` and `under` are taken as the app sent them; `default_under` is where
  the numbers are read when `under` is not given.

  Returns `{:ok, result}` or `{:error, :invalid_aggregate | :timeout}`.
  """
  def aggregate_group_data_values(%Group{} = group, opts) do
    with {:ok, spec} <-
           ValueAggregate.spec(
             opts[:group_by],
             opts[:fields],
             opts[:under],
             opts[:default_under] || []
           ) do
      group
      |> data_value_rows_query(opts)
      |> ValueAggregate.run(spec)
    end
  end

  defp data_value_rows_query(%Group{id: group_id}, opts) do
    from(v in Value, where: v.group_id == ^group_id and v.is_data == true)
    |> filter_data_value_scope(opts[:scope])
    |> filter_data_value_collection(opts[:collection])
    |> maybe_filter_data_value_creator(opts[:creator_id])
    |> maybe_match_data_value(opts[:match])
    |> maybe_filter_data_value_field(opts[:search_field], opts[:search_value])
  end

  defp filter_data_value_collection(query, collection) when is_binary(collection),
    do: from(v in query, where: v.collection == ^collection)

  defp filter_data_value_collection(query, _none),
    do: from(v in query, where: is_nil(v.collection))

  defp maybe_filter_data_value_creator(query, creator_id) when is_integer(creator_id),
    do: from(v in query, where: v.creator_id == ^creator_id)

  defp maybe_filter_data_value_creator(query, _creator_id), do: query

  defp maybe_match_data_value(query, match) when is_map(match) and map_size(match) > 0,
    do: from(v in query, where: fragment("? @> ?", v.data, type(^match, :map)))

  defp maybe_match_data_value(query, _match), do: query

  # Which way the query walks, and whether its page is turned around after:
  # a lone cursor is walked away from, so the page lies right next to it in
  # either order. Ordered by a key of the data, the page keeps that order.
  defp data_value_scan(opts) do
    dir = normalize_data_value_order_dir(opts[:order_dir])
    before? = is_integer(opts[:before_id])
    after? = is_integer(opts[:after_id])

    cond do
      normalize_data_value_jsonb_field(opts[:order_by]) -> {dir, false}
      dir == :asc and before? and not after? -> {:desc, true}
      dir == :desc and after? and not before? -> {:asc, true}
      true -> {dir, false}
    end
  end

  # Values outside collections walk `values_group_data_order_index` either way.
  defp order_data_value_rows(query, opts, scan) do
    cond do
      normalize_data_value_jsonb_field(opts[:order_by]) ->
        maybe_order_data_value_field(query, opts[:order_by], opts[:order_dir])

      is_binary(opts[:collection]) ->
        from(v in query, order_by: [{^scan, v.id}])

      # By id, which grows with the time of writing, as the cursors page.
      true ->
        from(v in query, order_by: [{^scan, v.id}])
    end
  end

  defp put_creator_usernames([]), do: []

  defp put_creator_usernames(rows) do
    ids = rows |> Enum.map(& &1.creator_id) |> Enum.uniq()

    names =
      from(p in Profile, where: p.id in ^ids, select: {p.id, p.username})
      |> Repo.all()
      |> Map.new()

    Enum.map(rows, &Map.put(&1, :creator_username, Map.get(names, &1.creator_id)))
  end

  defp filter_data_value_scope(query, {:app, alt_description_id})
       when is_integer(alt_description_id),
       do: from(v in query, where: v.alt_description_id == ^alt_description_id)

  defp filter_data_value_scope(query, {:group, alt_description_ids})
       when is_list(alt_description_ids) do
    from(v in query,
      where: is_nil(v.alt_description_id) or v.alt_description_id in ^alt_description_ids
    )
  end

  defp filter_data_value_scope(query, _default_app),
    do: from(v in query, where: is_nil(v.alt_description_id))

  defp maybe_after_id(query, after_id) when is_integer(after_id),
    do: from(v in query, where: v.id > ^after_id)

  defp maybe_after_id(query, _after_id), do: query

  def get_latest_data_value_id_for_group(%Group{} = group) do
    import Ecto.Query, only: [from: 2]

    from(v in Value,
      where: v.group_id == ^group.id and v.is_data == true,
      order_by: [desc: v.id],
      limit: 1,
      select: v.id
    )
    |> Repo.one()
  end

  def get_latest_data_value_for_group(%Group{} = group) do
    import Ecto.Query, only: [from: 2]

    from(v in Value,
      where: v.group_id == ^group.id and v.is_data == true,
      order_by: [desc: v.id],
      limit: 1
    )
    |> Repo.one()
  end

  def count_group_data_values(%Group{} = group) do
    import Ecto.Query, only: [from: 2]

    from(v in Value,
      where: v.group_id == ^group.id and v.is_data == true,
      select: count(v.id)
    )
    |> Repo.one()
  end

  @doc """
  Moves the profile's read marker in `group` up to `up_to`: a value id, or
  `:latest` for the group's newest chat value. It never moves back. A chat
  read while still empty gets a marker at 0, so the first values posted after
  it find the place the profile left (`unread_start/2`).
  """
  def mark_group_values_read(profile, group, up_to \\ :latest)

  def mark_group_values_read(nil, _group, _up_to), do: :ok

  def mark_group_values_read(%Profile{} = profile, %Group{} = group, up_to) do
    latest_value_id = if up_to == :latest, do: latest_group_value_id(group) || 0, else: up_to

    case latest_value_id do
      nil ->
        :ok

      latest_value_id ->
        case upsert_group_value_read(Repo, profile.id, group.id, latest_value_id) do
          # A page marks what it shows and counts again itself, so only the
          # profile's other pages are told.
          {:ok, :updated} ->
            broadcast_from_profile_group_unread_counts_updated(profile, group.id)
            :ok

          # Nothing was unread; skip the broadcast so subscribers do not recount for no reason.
          {:ok, :unchanged} ->
            :ok

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  @doc """
  Where the profile stopped reading `group`: the first chat value after its
  read marker and how many chat values there are from it on, as
  `%{value_id: id, count: n}`. Nil when nothing is unread, and without a
  marker: a profile that never opened the group has no place to come back to.
  The chat's divider stands there.
  """
  def unread_start(nil, _group), do: nil

  def unread_start(%Profile{} = profile, %Group{} = group) do
    case read_position(profile, group) do
      {:unread, start, _last_value_id} -> start
      _read_or_no_marker -> nil
    end
  end

  @doc """
  Marks the chat of `group` read, as `mark_group_values_read/2` does, and
  returns where its unread values began (`unread_start/2`), which the marker
  then moves past. One query reads both, and a marker with nothing after it
  is left alone, so opening a read chat costs no more than that query.
  """
  def read_group_chat(%Profile{} = profile, %Group{} = group) do
    case read_position(profile, group) do
      :no_marker ->
        _ = mark_group_values_read(profile, group)
        nil

      :read ->
        nil

      {:unread, start, last_value_id} ->
        _ = mark_group_values_read(profile, group, last_value_id)
        start
    end
  end

  # The marker's row joined with the chat values after it: none at all
  # without a marker, which `COUNT(r.profile_id)` tells from a marker with
  # nothing after it, as an aggregate always gives one row.
  # The marker's row with where its unread values begin and end, and how many
  # there are up to `unread_cap/0`; no row without a marker.
  defp read_position(%Profile{id: profile_id}, %Group{id: group_id}) do
    unread =
      "v.group_id = r.group_id AND v.is_data = FALSE AND v.id > COALESCE(r.last_read_value_id, 0)"

    sql = """
    SELECT
      (SELECT MIN(v.id) FROM values v WHERE #{unread}),
      (SELECT MAX(v.id) FROM values v WHERE #{unread}),
      (SELECT COUNT(*) FROM (SELECT 1 FROM values v WHERE #{unread} LIMIT #{@unread_cap}) x)
    FROM group_value_reads r
    WHERE r.profile_id = $1 AND r.group_id = $2
    """

    case Repo.query!(sql, [profile_id, group_id], cache_statement: "social_read_position_v2") do
      %{rows: []} ->
        :no_marker

      %{rows: [[nil, _last, _count]]} ->
        :read

      %{rows: [[first, last, count]]} ->
        {:unread, %{value_id: first, count: count}, last}
    end
  end

  def list_group_unread_counts(nil, _groups), do: %{}

  def list_group_unread_counts(%Profile{} = profile, groups) when is_list(groups) do
    group_ids =
      groups
      |> Enum.map(&extract_group_id/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case group_ids do
      [] -> %{}
      _ -> profile |> unread_overview() |> unread_counts_for(group_ids)
    end
  end

  @doc """
  Unread count for the root group. Every non-root group is a descendant of the
  root, so this is simply the sum of unread values across the profile's
  memberships — no tree traversal needed.
  """
  def count_root_group_unread_values(profile), do: root_group_unread_snapshot(profile).count

  @doc """
  `count_root_group_unread_values/1` with what the count holds (`as_of`, a
  `PotokIde.CountMark`, as in `unread_overview/1`), so a page can add later
  values to it one by one. `as_of` is `nil` when the count failed.
  """
  def root_group_unread_snapshot(nil), do: %{count: 0, as_of: nil}

  def root_group_unread_snapshot(%Profile{id: profile_id}) do
    sql = """
    SELECT
      (
        SELECT COALESCE(SUM(u.unread), 0)::bigint
        FROM group_memberships gm
        LEFT JOIN group_value_reads gvr
          ON gvr.profile_id = gm.profile_id AND gvr.group_id = gm.group_id
        #{capped_unread_sql("gm", "gvr")}
        WHERE gm.profile_id = $1
          AND gm.group_id IS DISTINCT FROM (SELECT r.id FROM groups r WHERE r.is_root)
          AND NOT #{GroupMutes.muted_sql()}
      ),
      #{CountMark.ids_sql("values")}
    """

    case Repo.query(sql, [profile_id], cache_statement: "social_root_unread_count_v4") do
      {:ok, %{rows: [[count, ids]]}} -> %{count: count, as_of: CountMark.from_ids(ids)}
      {:error, _reason} -> %{count: 0, as_of: nil}
    end
  end

  @doc """
  Sums unread values of the visible child groups (and their subtrees) of `group`,
  split by whether the child is a direct group. Returns `%{direct: n, other: n}`.
  """
  def child_group_unread_summary(nil, _group), do: %{direct: 0, other: 0}

  def child_group_unread_summary(%Profile{} = profile, %Group{id: group_id}) do
    profile
    |> unread_overview()
    |> child_unread_summary(group_id)
  end

  @doc """
  A profile's unread values for every group that has some at or below it, in
  one query: `%{total: n, as_of: mark, groups: %{group_id => %{subtree: n,
  own: n, parent_id: id, direct?: bool, thread?: bool}}}`. `own` counts the
  group's own values, `subtree` adds those of its sub-groups, threads
  included, and `total` is the root group's count. `as_of` is what the count
  holds (`PotokIde.CountMark`): `add_unread_value/3` skips those values.

  The counts follow the sub-groups lists, so every value can be found from
  the root: groups the profile cannot see are left out, and `parent_id` of the
  ones below them is the root, which lists them (see
  `list_child_groups_for_profile/3`).

  Values only count in groups the profile is a member of, so the query starts
  from those memberships and walks up to the root, instead of walking down
  through every group below the one being looked at. Read the result with
  `unread_counts_for/2`, `thread_unread_counts/2` and `child_unread_summary/2`.
  """
  def unread_overview(nil), do: %{total: 0, as_of: CountMark.from_ids([]), groups: %{}}

  def unread_overview(%Profile{id: profile_id}) do
    {own, muted, as_of, read_marks} = own_unread_counts(profile_id)

    groups =
      case Map.keys(own) ++ Map.keys(muted) do
        [] -> %{}
        group_ids -> profile_id |> group_chain(group_ids) |> hang_from_root()
      end

    subtree =
      Enum.reduce(own, %{}, fn {group_id, count}, acc ->
        group_id
        |> self_and_ancestor_ids(groups)
        |> Enum.reduce(acc, &Map.update(&2, &1, count, fn sum -> sum + count end))
      end)

    # A silenced group keeps its own count, for its row, out of every sum.
    shown =
      Enum.uniq(Map.keys(subtree) ++ Enum.filter(Map.keys(muted), &Map.has_key?(groups, &1)))

    %{
      total: own |> Map.values() |> Enum.sum(),
      as_of: as_of,
      read_marks: read_marks,
      groups:
        Map.new(shown, fn group_id ->
          {group_id,
           Map.merge(groups[group_id], %{
             subtree: Map.get(subtree, group_id, 0),
             own: Map.get(own, group_id, 0),
             muted: Map.get(muted, group_id, 0)
           })}
        end)
    }
  end

  # Unread chat values per group the profile is a member of (the root's own
  # values never count), leaving out groups with none, the newest value ids
  # the same statement saw (`CountMark`) and where the profile's reading
  # stands in each of those groups (`remove_unread_value/3`): one statement,
  # so one snapshot for all. (Folding `group_chain/2` into it saves a round
  # trip but measured slower.)
  defp own_unread_counts(profile_id) do
    # Whether a group is silenced is asked once per group, past the count.
    sql = """
    SELECT hw.ids, c.group_id, c.unread, #{GroupMutes.muted_sql("c")}, c.read_mark
    FROM (SELECT #{CountMark.ids_sql("values")} AS ids) hw
    LEFT JOIN LATERAL (
      SELECT gm.group_id, gm.profile_id, gm.muted_until, u.unread,
             COALESCE(gvr.last_read_value_id, 0) AS read_mark
      FROM group_memberships gm
      LEFT JOIN group_value_reads gvr
        ON gvr.profile_id = gm.profile_id AND gvr.group_id = gm.group_id
      #{capped_unread_sql("gm", "gvr")}
      WHERE gm.profile_id = $1
        AND gm.group_id IS DISTINCT FROM (SELECT r.id FROM groups r WHERE r.is_root)
        AND u.unread > 0
    ) c ON TRUE
    """

    %{rows: [[ids | _] | _] = rows} =
      Repo.query!(sql, [profile_id], cache_statement: "social_own_unread_counts_v5")

    {own, muted, read_marks} =
      for [_ids, group_id, count, muted?, read_mark] <- rows,
          group_id != nil,
          reduce: {%{}, %{}, %{}} do
        {own, muted, marks} when muted? == true ->
          {own, Map.put(muted, group_id, count), Map.put(marks, group_id, read_mark)}

        {own, muted, marks} ->
          {Map.put(own, group_id, count), muted, Map.put(marks, group_id, read_mark)}
      end

    {own, muted, CountMark.from_ids(ids), read_marks}
  end

  # `group_ids` and all their ancestors with what the overview needs about
  # them.
  defp group_chain(profile_id, group_ids) do
    query_group_chain("g.id = ANY($2::bigint[])", [profile_id, group_ids], "social_group_chain")
  end

  # The same for all of the profile's memberships. As an array, like the ids
  # above: the planner reads `IN (SELECT ...)` as a walk over a quarter million
  # rows and JIT-compiles the statement, some 150 ms for any profile.
  defp member_group_chain(profile_id, true) do
    query_group_chain(
      "g.id = ANY(ARRAY(SELECT m.group_id FROM group_memberships m WHERE m.profile_id = $1))",
      [profile_id],
      "social_member_group_chain"
    )
  end

  defp member_group_chain(profile_id, false) do
    query_group_chain(
      "g.id = ANY(ARRAY(SELECT m.group_id FROM group_memberships m" <>
        " JOIN groups rg ON rg.id = m.group_id" <>
        " WHERE m.profile_id = $1 AND rg.external_key IS NULL))",
      [profile_id],
      "social_member_group_chain_without_records"
    )
  end

  defp query_group_chain(seed, params, statement) do
    sql = """
    WITH RECURSIVE #{group_chain_cte(seed)}
    SELECT c.id, c.parent_id, c.is_direct, c.is_public OR gm.profile_id IS NOT NULL, c.is_thread
    FROM chain c
    LEFT JOIN group_memberships gm
      ON gm.group_id = c.id AND gm.profile_id = $1
    """

    %{rows: rows} = Repo.query!(sql, params, cache_statement: statement)

    Map.new(rows, fn [group_id, parent_id, direct?, visible?, thread?] ->
      {group_id, %{parent_id: parent_id, direct?: direct?, visible?: visible?, thread?: thread?}}
    end)
  end

  # The chain as the sub-groups lists show it: groups the profile cannot see
  # drop out, and the ones below them hang from the root.
  defp hang_from_root(groups) do
    root_id = Enum.find_value(groups, fn {id, group} -> is_nil(group.parent_id) && id end)
    shown? = fn id -> id == root_id or groups[id].visible? end

    for {id, group} <- groups, shown?.(id), into: %{} do
      parent_id =
        if is_nil(group.parent_id) or shown?.(group.parent_id),
          do: group.parent_id,
          else: root_id

      {id, group |> Map.delete(:visible?) |> Map.put(:parent_id, parent_id)}
    end
  end

  # A group and its ancestors up to the root (in no particular order), with
  # what a page needs to count a value of the group without a query: see
  # `add_unread_value/3`. Groups never move, so this is the same for everyone.
  defp group_ancestry(group_id) do
    sql = """
    WITH RECURSIVE #{group_chain_cte("g.id = ANY($1::bigint[])")}
    SELECT c.id, c.parent_id, c.is_direct, c.is_public, c.is_thread
    FROM chain c
    """

    %{rows: rows} =
      Repo.query!(sql, [[group_id]], cache_statement: "social_group_ancestry")

    Enum.map(rows, fn [id, parent_id, direct?, public?, thread?] ->
      %{id: id, parent_id: parent_id, direct?: direct?, public?: public?, thread?: thread?}
    end)
  end

  # The groups `seed` picks and all their ancestors. Each step looks one parent
  # up by its primary key (the LATERAL ... LIMIT 1 keeps the planner from
  # scanning every group for a handful of rows).
  defp group_chain_cte(seed) do
    """
    chain(id, parent_id, is_direct, is_public, is_thread) AS (
      SELECT g.id, g.parent_id, g.is_direct, g.is_public, g.parent_value_id IS NOT NULL
      FROM groups g
      WHERE #{seed}

      UNION

      SELECT p.id, p.parent_id, p.is_direct, p.is_public, p.is_thread
      FROM chain c
      CROSS JOIN LATERAL (
        SELECT g.id, g.parent_id, g.is_direct, g.is_public,
               g.parent_value_id IS NOT NULL AS is_thread
        FROM groups g
        WHERE g.id = c.parent_id
        LIMIT 1
      ) p
    )
    """
  end

  @doc """
  Counts a value from a `{:group_value_unread, unread}` broadcast
  into an `unread_overview/1` result, without a query. Returns
  `{:ok, overview}`, or `:counted` when the overview already holds the value
  (`as_of`, see `PotokIde.CountMark`).

  `member_ids` are the profile's memberships (`ProfileAuth.unread_groups/1`),
  which with the value's chain tell what `unread_overview/1` asks the database:
  which of the groups above the value the profile can see.
  """
  def add_unread_value(
        %{as_of: as_of} = overview,
        %{value_id: value_id} = unread,
        member_ids,
        muted_ids \\ MapSet.new()
      ) do
    cond do
      CountMark.counted?(as_of, value_id) ->
        :counted

      MapSet.member?(muted_ids, unread.group_id) ->
        count_muted_value(overview, unread, member_ids)

      true ->
        count_unread_value(overview, unread, member_ids)
    end
  end

  @doc """
  Takes a deleted value (`{:group_value_removed, ...}`) out of an overview
  that counted it, with no query: it counted when it is newer than where the
  profile's reading stood when counting (`read_marks`). A value of the
  profile's own, one in a group with nothing counted, or one read already
  leaves the overview as it was (`:unchanged`). A read since the count comes
  with a recount, which brings the marks up to date.
  """
  def remove_unread_value(%{groups: groups} = overview, group_id, value_id)
      when is_integer(group_id) and is_integer(value_id) do
    read_mark = overview |> Map.get(:read_marks, %{}) |> Map.get(group_id)

    case groups do
      %{^group_id => entry} when is_integer(read_mark) and value_id > read_mark ->
        cond do
          # At the cap the group may hold more than it counts.
          entry.own >= @unread_cap or entry.muted >= @unread_cap ->
            :unchanged

          entry.muted > 0 ->
            {:ok,
             %{overview | groups: Map.put(groups, group_id, %{entry | muted: entry.muted - 1})}}

          entry.own > 0 ->
            groups =
              group_id
              |> self_and_ancestor_ids(groups)
              |> Enum.reduce(groups, fn id, groups ->
                Map.update!(groups, id, &%{&1 | subtree: max(&1.subtree - 1, 0)})
              end)
              |> Map.update!(group_id, &%{&1 | own: &1.own - 1})

            {:ok, %{overview | total: max(overview.total - 1, 0), groups: groups}}

          true ->
            :unchanged
        end

      _not_counted ->
        :unchanged
    end
  end

  # A group at the cap counts no more, as a count would not.
  defp count_muted_value(
         %{groups: groups} = overview,
         %{group_id: group_id},
         _member_ids
       )
       when is_map_key(groups, group_id) and
              :erlang.map_get(:muted, :erlang.map_get(group_id, groups)) >= @unread_cap,
       do: {:ok, overview}

  defp count_muted_value(overview, %{group_id: group_id} = unread, member_ids) do
    case shown_chain(unread, member_ids) do
      %{^group_id => node} ->
        entry =
          Map.get_lazy(overview.groups, group_id, fn ->
            Map.merge(node, %{subtree: 0, own: 0, muted: 0})
          end)

        groups = Map.put(overview.groups, group_id, Map.update(entry, :muted, 1, &(&1 + 1)))
        {:ok, %{overview | groups: groups}}

      _hidden ->
        {:ok, overview}
    end
  end

  defp shown_chain(%{group_id: group_id, chain: chain}, member_ids) do
    chain
    |> Map.new(fn node ->
      visible? = node.public? or node.id == group_id or node.id in member_ids

      {node.id,
       node |> Map.take([:parent_id, :direct?, :thread?]) |> Map.put(:visible?, visible?)}
    end)
    |> hang_from_root()
  end

  defp count_unread_value(
         %{groups: groups} = overview,
         %{group_id: group_id},
         _member_ids
       )
       when is_map_key(groups, group_id) and
              :erlang.map_get(:own, :erlang.map_get(group_id, groups)) >= @unread_cap,
       do: {:ok, overview}

  defp count_unread_value(overview, %{group_id: group_id} = unread, member_ids) do
    shown = shown_chain(unread, member_ids)

    groups =
      group_id
      |> self_and_ancestor_ids(shown)
      |> Enum.reduce(overview.groups, fn id, groups ->
        entry =
          Map.get_lazy(groups, id, fn -> Map.merge(shown[id], %{subtree: 0, own: 0, muted: 0}) end)

        own = if id == group_id, do: entry.own + 1, else: entry.own
        Map.put(groups, id, %{entry | subtree: entry.subtree + 1, own: own})
      end)

    {:ok, %{overview | total: overview.total + 1, groups: groups}}
  end

  defp self_and_ancestor_ids(group_id, groups) do
    case groups do
      %{^group_id => %{parent_id: parent_id}} ->
        [group_id | self_and_ancestor_ids(parent_id, groups)]

      _ ->
        []
    end
  end

  @doc """
  What waits for the profile in its groups' processes, at or below each
  group, as the sub-groups lists show it: `%{group_id => count}`, the groups
  the profile cannot see hanging from the root, as in `unread_overview/1`.
  Groups with nothing are left out.
  """
  def waiting_overview(nil), do: %{}

  def waiting_overview(%Profile{id: profile_id} = profile) do
    case PotokIde.Processes.waiting_by_group(profile) do
      own when map_size(own) == 0 ->
        %{}

      own ->
        groups = profile_id |> group_chain(Map.keys(own)) |> hang_from_root()

        Enum.reduce(own, %{}, fn {group_id, count}, acc ->
          group_id
          |> self_and_ancestor_ids(groups)
          |> Enum.reduce(acc, &Map.update(&2, &1, count, fn sum -> sum + count end))
        end)
    end
  end

  @doc "Unread values at or below each of `group_ids`, from `unread_overview/1`."
  def unread_counts_for(%{groups: groups}, group_ids) do
    Map.new(group_ids, fn group_id ->
      {group_id, get_in(groups, [group_id, :subtree]) || 0}
    end)
  end

  @doc """
  The unread values of the silenced groups among `group_ids`, which their
  rows show apart, as `%{group_id => n}` (only those with some), from
  `unread_overview/1`.
  """
  def muted_unread_counts(%{groups: groups}, group_ids) do
    for group_id <- group_ids,
        count = get_in(groups, [group_id, :muted]),
        is_integer(count) and count > 0,
        into: %{},
        do: {group_id, count}
  end

  @doc """
  The threads directly below `parent_ids` with something unread, as
  `%{thread_id => n}`, from `unread_overview/1`.
  """
  def thread_unread_counts(%{groups: groups}, parent_ids) do
    for {id, %{thread?: true, parent_id: parent_id, subtree: count} = entry} <- groups,
        parent_id in parent_ids,
        into: %{},
        do: {id, count + Map.get(entry, :muted, 0)}
  end

  @doc "`child_group_unread_summary/2` from an `unread_overview/1` result."
  def child_unread_summary(%{groups: groups}, group_id) do
    Enum.reduce(groups, %{direct: 0, other: 0}, fn
      {_id, %{parent_id: ^group_id, direct?: true, subtree: count}}, acc ->
        %{acc | direct: acc.direct + count}

      {_id, %{parent_id: ^group_id, subtree: count}}, acc ->
        %{acc | other: acc.other + count}

      _group, acc ->
        acc
    end)
  end

  def list_pending_invitations(%Profile{} = invitee, opts \\ []) do
    import Ecto.Query, only: [from: 2]

    limit = normalize_query_limit(opts[:limit])
    offset = normalize_query_offset(opts[:offset])
    search = normalize_invitation_search_query(opts[:search])

    from(i in GroupInvitation,
      join: g in assoc(i, :group),
      join: inviter in assoc(i, :inviter),
      where: i.invitee_id == ^invitee.id,
      where: not is_nil(i.accepted_at) or i.inserted_at > ^GroupInvitation.cutoff(),
      where: ^invitation_name_search_dynamic(search),
      order_by: [
        asc: fragment("CASE WHEN ? IS NULL THEN 0 ELSE 1 END", i.accepted_at),
        desc: i.inserted_at,
        desc: i.id
      ],
      offset: ^offset,
      preload: [:inviter, :group]
    )
    |> maybe_limit(limit)
    |> Repo.all()
    |> with_direct_members()
  end

  def list_group_invitations_for_inviter(%Profile{} = inviter, opts \\ []) do
    import Ecto.Query, only: [from: 2]

    limit = normalize_query_limit(opts[:limit])
    offset = normalize_query_offset(opts[:offset])
    search = normalize_invitation_search_query(opts[:search])

    from(i in GroupInvitation,
      join: g in assoc(i, :group),
      join: invitee in assoc(i, :invitee),
      where: i.inviter_id == ^inviter.id,
      where: not is_nil(i.accepted_at) or i.inserted_at > ^GroupInvitation.cutoff(),
      where: ^sent_invitation_name_search_dynamic(search),
      order_by: [
        asc: fragment("CASE WHEN ? IS NULL THEN 0 ELSE 1 END", i.accepted_at),
        desc: i.inserted_at,
        desc: i.id
      ],
      offset: ^offset,
      preload: [:invitee, :group]
    )
    |> maybe_limit(limit)
    |> Repo.all()
    |> with_direct_members()
  end

  def count_group_invitations_for_invitee(%Profile{} = invitee) do
    import Ecto.Query, only: [from: 2]

    from(i in GroupInvitation,
      where: i.invitee_id == ^invitee.id,
      where: not is_nil(i.accepted_at) or i.inserted_at > ^GroupInvitation.cutoff(),
      select: count(i.id)
    )
    |> Repo.one()
  end

  def count_group_invitations_for_inviter(%Profile{} = inviter) do
    import Ecto.Query, only: [from: 2]

    from(i in GroupInvitation,
      where: i.inviter_id == ^inviter.id,
      where: not is_nil(i.accepted_at) or i.inserted_at > ^GroupInvitation.cutoff(),
      select: count(i.id)
    )
    |> Repo.one()
  end

  def count_group_invitations_for_invitee(%Profile{} = invitee, opts) when is_list(opts) do
    import Ecto.Query, only: [from: 2]

    search = normalize_invitation_search_query(opts[:search])

    from(i in GroupInvitation,
      join: g in assoc(i, :group),
      join: inviter in assoc(i, :inviter),
      where: i.invitee_id == ^invitee.id,
      where: not is_nil(i.accepted_at) or i.inserted_at > ^GroupInvitation.cutoff(),
      where: ^invitation_name_search_dynamic(search),
      select: count(i.id)
    )
    |> Repo.one()
  end

  def count_group_invitations_for_inviter(%Profile{} = inviter, opts) when is_list(opts) do
    import Ecto.Query, only: [from: 2]

    search = normalize_invitation_search_query(opts[:search])

    from(i in GroupInvitation,
      join: g in assoc(i, :group),
      join: invitee in assoc(i, :invitee),
      where: i.inviter_id == ^inviter.id,
      where: not is_nil(i.accepted_at) or i.inserted_at > ^GroupInvitation.cutoff(),
      where: ^sent_invitation_name_search_dynamic(search),
      select: count(i.id)
    )
    |> Repo.one()
  end

  def count_pending_invitations(%Profile{id: invitee_id}) do
    sql = """
    SELECT
      (SELECT COUNT(*) FROM group_invitations WHERE invitee_id = $1 AND accepted_at IS NULL
         AND inserted_at > now() - make_interval(days => #{GroupInvitation.valid_days()})) +
      (SELECT COUNT(*) FROM profile_invitations WHERE invitee_id = $1 AND accepted_at IS NULL)
    """

    case Repo.query(sql, [invitee_id], cache_statement: "social_pending_invitations_count_v2") do
      {:ok, %{rows: [[count]]}} -> count
      {:error, _reason} -> 0
    end
  end

  def list_pending_profile_invitations(%Profile{} = invitee) do
    import Ecto.Query, only: [from: 2]

    from(i in ProfileInvitation,
      where: i.invitee_id == ^invitee.id and is_nil(i.accepted_at),
      order_by: [desc: i.inserted_at],
      preload: [:profile, :inviter]
    )
    |> Repo.all()
  end

  def get_pending_invitation_for_invitee(%Profile{} = invitee, invitation_id) do
    import Ecto.Query, only: [from: 2]

    from(i in GroupInvitation,
      where: i.id == ^invitation_id and i.invitee_id == ^invitee.id and is_nil(i.accepted_at),
      where: i.inserted_at > ^GroupInvitation.cutoff(),
      preload: [:inviter, :group]
    )
    |> Repo.one()
    |> with_direct_members()
  end

  def get_group_invitation_for_invitee(%Profile{} = invitee, invitation_id) do
    import Ecto.Query, only: [from: 2]

    from(i in GroupInvitation,
      where: i.id == ^invitation_id and i.invitee_id == ^invitee.id,
      preload: [:inviter, :group]
    )
    |> Repo.one()
    |> with_direct_members()
  end

  # Invitation and request rows show their group by `group_identity`, which
  # names a direct conversation after the other side: only those groups get
  # their members. Preloading members for every group loaded each big
  # group's whole member list.
  defp with_direct_members(nil), do: nil
  defp with_direct_members(%{group: _} = row), do: hd(with_direct_members([row]))

  defp with_direct_members(rows) when is_list(rows) do
    loaded =
      for(%{group: %Group{is_direct: true} = group} <- rows, uniq: true, do: group)
      |> Repo.preload(:members)
      |> Map.new(&{&1.id, &1})

    Enum.map(rows, fn %{group: %Group{id: id} = group} = row ->
      %{row | group: Map.get(loaded, id, group)}
    end)
  end

  defp invitation_name_search_dynamic(""), do: true

  defp invitation_name_search_dynamic(search_term) do
    dynamic(
      [_i, g, inviter],
      ^group_name_matches(search_term) or ilike(inviter.username, ^like_pattern(search_term))
    )
  end

  defp sent_invitation_name_search_dynamic(""), do: true

  defp sent_invitation_name_search_dynamic(search_term) do
    dynamic(
      [_i, g, invitee],
      ^group_name_matches(search_term) or ilike(invitee.username, ^like_pattern(search_term))
    )
  end

  defp normalize_invitation_search_query(query) when is_binary(query) do
    query
    |> String.trim()
    |> String.slice(0, 120)
  end

  defp normalize_invitation_search_query(_), do: ""

  defp maybe_preload_group_members(%Group{is_direct: true} = group) do
    Repo.preload(group, :members)
  end

  defp maybe_preload_group_members(%Group{} = group), do: group

  defp maybe_preload_group_members(groups) when is_list(groups) do
    direct_group_ids =
      groups
      |> Enum.filter(& &1.is_direct)
      |> Enum.map(& &1.id)

    case direct_group_ids do
      [] ->
        groups

      _ ->
        preloaded_groups =
          from(g in Group,
            where: g.id in ^direct_group_ids,
            preload: [:members]
          )
          |> Repo.all()
          |> Map.new(&{&1.id, &1})

        Enum.map(groups, fn group -> Map.get(preloaded_groups, group.id, group) end)
    end
  end

  def get_pending_profile_invitation_for_invitee(%Profile{} = invitee, invitation_id) do
    import Ecto.Query, only: [from: 2]

    from(i in ProfileInvitation,
      where: i.id == ^invitation_id and i.invitee_id == ^invitee.id and is_nil(i.accepted_at),
      preload: [:profile, :inviter]
    )
    |> Repo.one()
  end

  def get_profile_for_account(%Account{} = account, profile_id) do
    import Ecto.Query, only: [from: 2]

    from(p in Profile,
      join: ap in AccountProfile,
      on: ap.profile_id == p.id,
      where: p.id == ^profile_id and ap.account_id == ^account.id,
      select: p
    )
    |> Repo.one()
  end

  def member_of_group?(%Profile{} = profile, %Group{} = group),
    do: member_of_group_private?(profile, group)

  @doc """
  The groups at or below `group` that `profile` is a member of, for the views
  that gather a tree: the root's reaches all of its groups.
  """
  def member_group_ids_under(%Profile{} = profile, %Group{} = group) do
    # Up from each of the profile's groups until `group` is reached.
    %Postgrex.Result{rows: rows} =
      Repo.query!(
        """
        WITH RECURSIVE chain(member_group_id, id, parent_id) AS (
          SELECT g.id, g.id, g.parent_id
          FROM group_memberships gm
          JOIN groups g ON g.id = gm.group_id
          WHERE gm.profile_id = $1

          UNION ALL

          SELECT c.member_group_id, p.id, p.parent_id
          FROM chain c
          JOIN groups p ON p.id = c.parent_id
          WHERE c.id <> $2
        )
        SELECT DISTINCT member_group_id FROM chain WHERE id = $2
        """,
        [profile.id, group.id]
      )

    List.flatten(rows)
  end

  defp ensure_permission(%Profile{} = actor, %Group{} = group, permission) do
    if Access.can?(actor, group, permission), do: :ok, else: {:error, :not_permitted}
  end

  defp insert_admins(%Multi{} = multi, %Profile{} = creator, nil),
    do: insert_admin_role(multi, creator)

  # Direct members with the admin role, the creator among them or not.
  defp insert_admins(%Multi{} = multi, %Profile{}, admin_ids) do
    Multi.run(multi, :admins, fn repo, %{group: group} ->
      Enum.each(admin_ids, fn profile_id ->
        %GroupMembership{}
        |> GroupMembership.changeset(%{group_id: group.id, profile_id: profile_id})
        |> repo.insert!(on_conflict: :nothing, conflict_target: [:group_id, :profile_id])

        repo.insert!(admin_member_role(group.id, profile_id))
      end)

      {:ok, admin_ids}
    end)
  end

  # The creator of a group is its first admin. Runs after the `:group` step and
  # the creator's membership.
  defp insert_admin_role(%Multi{} = multi, %Profile{id: profile_id}) do
    Multi.insert(multi, :admin_role, fn %{group: group} ->
      admin_member_role(group.id, profile_id)
    end)
  end

  defp admin_member_role(group_id, profile_id) do
    %GroupMemberRole{group_id: group_id, profile_id: profile_id, role_key: GroupRole.admin_key()}
  end

  defp get_group_join_request(%Group{} = group, request_id) when is_integer(request_id) do
    from(r in GroupJoinRequest,
      where: r.group_id == ^group.id and r.id == ^request_id
    )
    |> Repo.one()
  end

  defp pending_group_invitation_for_profile?(%Group{} = group, %Profile{} = profile) do
    from(i in GroupInvitation,
      where: i.group_id == ^group.id and i.invitee_id == ^profile.id and is_nil(i.accepted_at),
      where: i.inserted_at > ^GroupInvitation.cutoff(),
      select: 1
    )
    |> Repo.exists?()
  end

  defp member_of_group_private?(%Profile{} = profile, %Group{} = group) do
    import Ecto.Query, only: [from: 2]

    from(gm in GroupMembership,
      where: gm.group_id == ^group.id and gm.profile_id == ^profile.id,
      select: 1
    )
    |> Repo.exists?()
  end

  defp maybe_paginate(query, opts) do
    query
    |> maybe_limit(opts[:limit])
    |> maybe_offset(opts[:offset])
  end

  defp find_direct_group(
         repo,
         %Group{} = root_group,
         %Profile{} = first_profile,
         %Profile{} = second_profile
       ) do
    requested_member_group_ids =
      from(membership in GroupMembership,
        where: membership.profile_id in ^[first_profile.id, second_profile.id],
        group_by: membership.group_id,
        having: count(membership.profile_id) == 2,
        select: membership.group_id
      )

    from(group in Group,
      join: membership in GroupMembership,
      on: membership.group_id == group.id,
      where: group.parent_id == ^root_group.id,
      where: group.is_direct,
      where: not group.is_public,
      where: not group.is_root,
      where: group.id in subquery(requested_member_group_ids),
      group_by: group.id,
      having: count(membership.profile_id) == 2,
      order_by: [asc: group.inserted_at],
      limit: 1
    )
    |> repo.one()
  end

  defp maybe_create_initial_direct_group(
         _repo,
         _root_group,
         %Account{invited_by_id: nil},
         _profile,
         _already_has_profiles
       ) do
    {:ok, nil}
  end

  defp maybe_create_initial_direct_group(
         _repo,
         _root_group,
         _account,
         _profile,
         true
       ) do
    {:ok, nil}
  end

  defp maybe_create_initial_direct_group(
         repo,
         %Group{} = root_group,
         %Account{} = account,
         %Profile{} = profile,
         false
       ) do
    case repo.get(Profile, account.invited_by_id) do
      %Profile{} = invited_by_profile ->
        create_direct_group(repo, root_group, profile, invited_by_profile)

      nil ->
        {:ok, nil}
    end
  end

  defp create_direct_group(
         repo,
         %Group{} = root_group,
         %Profile{} = current_profile,
         %Profile{} = other_profile
       ) do
    case find_direct_group(repo, root_group, current_profile, other_profile) do
      %Group{} = group ->
        {:ok, group}

      nil ->
        attrs = %{
          "name" => direct_group_name(current_profile, other_profile),
          "description" => "",
          "description_format" => :markdown,
          "home_page" => :chat,
          "has_public_chat" => true,
          "is_direct" => true,
          "is_public" => false,
          "creator_id" => current_profile.id,
          "parent_id" => root_group.id,
          "is_root" => false
        }

        Multi.new()
        |> Multi.insert(:group, Group.changeset(%Group{}, attrs))
        |> Multi.insert(:current_membership, fn %{group: group} ->
          GroupMembership.changeset(%GroupMembership{}, %{
            group_id: group.id,
            profile_id: current_profile.id
          })
        end)
        |> Multi.insert(:other_membership, fn %{group: group} ->
          GroupMembership.changeset(%GroupMembership{}, %{
            group_id: group.id,
            profile_id: other_profile.id
          })
        end)
        |> insert_admin_role(current_profile)
        |> repo.transaction()
        |> case do
          {:ok, %{group: group}} -> {:ok, group}
          {:error, _step, reason, _changes} -> {:error, reason}
        end
    end
  end

  defp pending_group_account_invitations_query(%Account{} = account) do
    from(invitation in GroupAccountInvitation,
      where: invitation.account_id == ^account.id,
      where: invitation.inserted_at > ^GroupInvitation.cutoff(),
      preload: [:group, :inviter],
      order_by: [asc: invitation.inserted_at, asc: invitation.id]
    )
  end

  defp direct_group_name(%Profile{} = first_profile, %Profile{} = second_profile) do
    [first_profile.username, second_profile.username]
    |> Enum.sort()
    |> Enum.join(" & ")
  end

  defp maybe_limit(query, limit) when is_integer(limit) and limit >= 0 do
    limit(query, ^limit)
  end

  defp maybe_limit(query, _limit), do: query

  defp maybe_filter_data_value_field(query, search_field, search_value) do
    field = normalize_data_value_jsonb_field(search_field)
    value = normalize_data_value_search_value(search_value)

    case {field, value} do
      {nil, _} ->
        query

      {_, nil} ->
        query

      {jsonb_field, jsonb_value} ->
        from(v in query,
          where:
            ilike(
              fragment("COALESCE(? ->> ?, '')", v.data, ^jsonb_field),
              ^like_pattern(jsonb_value)
            )
        )
    end
  end

  defp maybe_order_data_value_field(query, order_field, order_dir) do
    case normalize_data_value_jsonb_field(order_field) do
      nil ->
        from(v in query, order_by: [asc: v.id])

      "number" = jsonb_field ->
        case normalize_data_value_order_dir(order_dir) do
          :desc ->
            from(v in query,
              order_by: [
                desc:
                  fragment(
                    "CASE WHEN COALESCE(? ->> ?, '') ~ '^-{0,1}[0-9]+(\\.[0-9]+){0,1}$' THEN (? ->> ?)::numeric END",
                    v.data,
                    ^jsonb_field,
                    v.data,
                    ^jsonb_field
                  ),
                desc: fragment("LOWER(COALESCE(? ->> ?, ''))", v.data, ^jsonb_field),
                desc: v.id
              ]
            )

          :asc ->
            from(v in query,
              order_by: [
                asc:
                  fragment(
                    "CASE WHEN COALESCE(? ->> ?, '') ~ '^-{0,1}[0-9]+(\\.[0-9]+){0,1}$' THEN (? ->> ?)::numeric END",
                    v.data,
                    ^jsonb_field,
                    v.data,
                    ^jsonb_field
                  ),
                asc: fragment("LOWER(COALESCE(? ->> ?, ''))", v.data, ^jsonb_field),
                asc: v.id
              ]
            )
        end

      jsonb_field ->
        case normalize_data_value_order_dir(order_dir) do
          :desc ->
            from(v in query,
              order_by: [
                desc: fragment("LOWER(COALESCE(? ->> ?, ''))", v.data, ^jsonb_field),
                desc: v.id
              ]
            )

          :asc ->
            from(v in query,
              order_by: [
                asc: fragment("LOWER(COALESCE(? ->> ?, ''))", v.data, ^jsonb_field),
                asc: v.id
              ]
            )
        end
    end
  end

  defp normalize_data_value_jsonb_field(field) when is_binary(field) do
    field
    |> String.trim()
    |> String.slice(0, 120)
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_data_value_jsonb_field(_field), do: nil

  defp normalize_data_value_search_value(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.slice(0, 120)
    |> case do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp normalize_data_value_search_value(_value), do: nil

  defp normalize_data_value_order_dir("desc"), do: :desc
  defp normalize_data_value_order_dir(_value), do: :asc

  # Pending requests and approvals are merged in SQL so ordering, search and
  # pagination happen in the database instead of loading the whole history.
  defp request_history_union_query(%Profile{} = requester, search) do
    pending =
      from(r in GroupJoinRequest,
        join: g in assoc(r, :group),
        where: r.requester_id == ^requester.id,
        where: ^request_history_search_dynamic(search, :pending),
        select: %{
          kind: fragment("'request'::text"),
          id: r.id,
          sort_at: r.inserted_at,
          rank: fragment("0::integer")
        }
      )

    approved =
      from(a in GroupJoinRequestApproval,
        join: g in assoc(a, :group),
        join: approver in assoc(a, :approver),
        where: a.requester_id == ^requester.id,
        where: ^request_history_search_dynamic(search, :approved),
        select: %{
          kind: fragment("'approval'::text"),
          id: a.id,
          sort_at: a.approved_at,
          rank: fragment("1::integer")
        }
      )

    union_all(pending, ^approved)
  end

  defp request_history_search_dynamic("", _kind), do: true

  defp request_history_search_dynamic(search_term, :pending) do
    group_name_matches(search_term)
  end

  defp request_history_search_dynamic(search_term, :approved) do
    dynamic(
      [_a, g, approver],
      ^group_name_matches(search_term) or ilike(approver.username, ^like_pattern(search_term))
    )
  end

  defp load_request_history_entries([]), do: []

  defp load_request_history_entries(refs) do
    request_ids = for {"request", id} <- refs, do: id
    approval_ids = for {"approval", id} <- refs, do: id

    requests =
      from(r in GroupJoinRequest, where: r.id in ^request_ids, preload: [:group])
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    approvals =
      from(a in GroupJoinRequestApproval,
        where: a.id in ^approval_ids,
        preload: [:group, :approver]
      )
      |> Repo.all()
      |> Map.new(&{&1.id, &1})

    refs
    |> Enum.map(fn
      {"request", id} -> requests[id] && pending_request_history_entry(requests[id])
      {"approval", id} -> approvals[id] && approved_request_history_entry(approvals[id])
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp pending_request_history_entry(%GroupJoinRequest{} = request) do
    %{
      id: "request-#{request.id}",
      source_id: request.id,
      status: :pending,
      group: request.group,
      approver: nil,
      requested_at: request.inserted_at,
      approved_at: nil,
      sort_at: request.inserted_at
    }
  end

  defp approved_request_history_entry(%GroupJoinRequestApproval{} = approval) do
    %{
      id: "approval-#{approval.id}",
      source_id: approval.id,
      status: :approved,
      group: approval.group,
      approver: approval.approver,
      requested_at: nil,
      approved_at: approval.approved_at,
      sort_at: approval.approved_at
    }
  end

  defp approved_request_name_search_dynamic(""), do: true

  defp approved_request_name_search_dynamic(search_term) do
    dynamic(
      [_a, g, requester],
      ^group_name_matches(search_term) or ilike(requester.username, ^like_pattern(search_term))
    )
  end

  # The group (the second binding) whose name holds `search_term`, folded on
  # both sides as in every name search (`NameSearch`).
  defp group_name_matches(search_term) do
    term = NameSearch.term(search_term)
    dynamic([_x, g], fragment("? LIKE '%' || potok_fold(?) || '%'", g.name_folded, ^term))
  end

  defp like_pattern(search_term), do: "%" <> NameSearch.escape(search_term) <> "%"

  defp normalize_request_search_query(query) when is_binary(query) do
    query
    |> String.trim()
    |> String.slice(0, 120)
  end

  defp normalize_request_search_query(_), do: ""

  defp maybe_offset(query, offset) when is_integer(offset) and offset >= 0 do
    offset(query, ^offset)
  end

  defp maybe_offset(query, _offset), do: query

  defp notify_group_members_of_new_value(
         %Profile{} = _creator,
         %Group{} = _group,
         %Value{is_data: true},
         %Access{}
       ),
       do: :ok

  # Accounts of mentioned members get the mention payload instead of the
  # generic one, so nobody is notified twice about the same value. Someone
  # outside the group reaches only those it speaks to: anyone signed in could
  # otherwise push to every member, who has no way to mute a group. An author
  # outside the group hears of a reply here, as no other push reaches them.
  defp notify_group_members_of_new_value(
         %Profile{} = creator,
         %Group{} = group,
         %Value{} = value,
         %Access{member?: member?}
       ) do
    payload_for = Notifications.value_created(creator, group, value)
    mention_payload_for = Notifications.value_mention(creator, group, value)
    reply_payload_for = Notifications.value_reply(creator, group, value)

    run_notification(fn ->
      mentioned_account_ids =
        value
        |> mentioned_profile_ids_to_push(member?)
        |> recipient_account_ids_for_profiles()
        |> MapSet.new()

      replied_account_ids =
        value
        |> replied_profile_ids_to_push(group, creator, member?)
        |> recipient_account_ids_for_profiles()
        |> MapSet.new()

      group
      |> value_push_account_ids(
        creator,
        value,
        member?,
        mentioned_account_ids,
        replied_account_ids,
        own_profile_ids(value)
      )
      |> Dispatch.subscriptions_by_account()
      |> Dispatch.deliver_each(group.id, fn [%PushSubscription{account_id: account_id} | _] ->
        cond do
          MapSet.member?(mentioned_account_ids, account_id) ->
            {mention_payload_for, "group mention"}

          MapSet.member?(replied_account_ids, account_id) ->
            {reply_payload_for, "group reply"}

          true ->
            {payload_for, "group value"}
        end
      end)
    end)
  end

  defp mentioned_profile_ids_to_push(%Value{mentioned_profile_ids: ids}, true = _member?), do: ids

  defp mentioned_profile_ids_to_push(%Value{mentioned_profile_ids: ids}, false = _member?),
    do: Enum.take(ids, @outsider_mention_pushes)

  # The author of the value this one answers, when the push to the members would
  # pass them by: they are outside the group, or the new value's author is.
  defp replied_profile_ids_to_push(
         %Value{parent: %Value{creator_id: author_id}},
         %Group{} = group,
         %Profile{id: creator_id},
         member?
       )
       when is_integer(author_id) and author_id != creator_id do
    if member? and member_of_group?(%Profile{id: author_id}, group),
      do: [],
      else: [author_id]
  end

  defp replied_profile_ids_to_push(_value, _group, _creator, _member?), do: []

  defp value_push_account_ids(group, creator, value, true = _member?, _mentioned, replied, own) do
    members = coalesced_value_account_ids(group, creator, value, own)

    if MapSet.size(replied) == 0,
      do: members,
      else: union(members, ^accounts_query(replied))
  end

  defp value_push_account_ids(
         _group,
         _creator,
         _value,
         false = _member?,
         mentioned,
         replied,
         _own
       ) do
    accounts_query(MapSet.union(mentioned, replied))
  end

  # One push per group until it is read: a member who got a push for this
  # group's value hears of the next one only once they have read up to it, or
  # after `@push_quiet_seconds`. Picking them and marking them is one
  # statement, so two values posted at once still make one push. Those the
  # value speaks to (`own`: mentioned, the author it answers) always get it,
  # muted or not, and it leaves their mark alone.
  @push_quiet_seconds 300

  defp coalesced_value_account_ids(
         %Group{id: group_id},
         %Profile{id: creator_id},
         %Value{id: value_id},
         own
       ) do
    now = NaiveDateTime.utc_now(:second)

    %Postgrex.Result{rows: rows} =
      Repo.query!(
        """
        UPDATE group_memberships AS gm
        SET last_push_value_id = $3, last_pushed_at = $5
        WHERE gm.group_id = $1
          AND gm.profile_id <> $2
          AND gm.profile_id <> ALL($4)
          AND NOT #{GroupMutes.muted_sql("gm")}
          AND (
            gm.last_push_value_id IS NULL
            OR gm.last_pushed_at <= $6
            OR COALESCE((
              SELECT r.last_read_value_id
              FROM group_value_reads r
              WHERE r.profile_id = gm.profile_id AND r.group_id = gm.group_id
            ), 0) >= gm.last_push_value_id
          )
        RETURNING gm.profile_id
        """,
        [group_id, creator_id, value_id, own, now, NaiveDateTime.add(now, -@push_quiet_seconds)]
      )

    pushed = Enum.map(rows, &hd/1)

    own_members =
      from(gm in GroupMembership,
        where: gm.group_id == ^group_id and gm.profile_id != ^creator_id,
        where: gm.profile_id in ^own,
        select: gm.profile_id
      )

    from(ap in AccountProfile,
      where: ap.profile_id in ^pushed or ap.profile_id in subquery(own_members),
      select: ap.account_id
    )
  end

  # The members a value speaks to, whom a muted group still reaches: those
  # it mentions and the author of the value it answers.
  defp own_profile_ids(%Value{mentioned_profile_ids: mentioned} = value) do
    case value do
      %Value{parent: %Value{creator_id: author_id}} when is_integer(author_id) ->
        [author_id | mentioned || []]

      _value ->
        mentioned || []
    end
  end

  defp accounts_query(%MapSet{} = account_ids) do
    account_ids = MapSet.to_list(account_ids)
    from(ap in AccountProfile, where: ap.account_id in ^account_ids, select: ap.account_id)
  end

  # Only a reaction that was added notifies (a racing duplicate comes back
  # without an id), and only an author who is still a member and is not the
  # reactor. Accounts that also hold the reactor's profile are skipped.
  defp notify_value_creator_of_reaction(
         {:ok, %ValueReaction{id: reaction_id, emoji: emoji}},
         %Profile{} = reactor,
         %Group{} = group,
         %Value{creator: %Profile{} = creator} = value
       )
       when not is_nil(reaction_id) do
    if creator.id != reactor.id and member_of_group?(creator, group) do
      payload_for = Notifications.value_reaction(reactor, group, value, emoji)
      reactor_account_ids = recipient_account_ids_for_profiles([reactor.id])

      run_notification(fn ->
        creator
        |> recipient_accounts_for_profile_notification(reactor_account_ids)
        |> Enum.each(
          &deliver_account_push_notification(&1, payload_for, "value reaction", group.id)
        )
      end)
    end

    :ok
  end

  defp notify_value_creator_of_reaction(_result, _reactor, _group, _value), do: :ok

  defp recipient_account_ids_for_profiles([]), do: []

  defp recipient_account_ids_for_profiles(profile_ids) do
    from(ap in AccountProfile,
      where: ap.profile_id in ^profile_ids,
      distinct: true,
      select: ap.account_id
    )
    |> Repo.all()
  end

  defp run_notification(fun), do: Dispatch.run(fun)

  defp notify_profile_invitee_of_group_invitation(
         %Profile{} = inviter,
         %Group{} = group,
         %Profile{} = invitee
       ) do
    payload_for = Notifications.group_invitation(inviter, group)

    run_notification(fn ->
      invitee
      |> recipient_accounts_for_profile_notification()
      |> Enum.each(&deliver_profile_notification(&1, payload_for, "group invitation", inviter.id))
    end)
  end

  defp notify_profile_inviter_of_group_invitation_acceptance(
         %GroupInvitation{} = invitation,
         %Profile{} = invitee
       ) do
    payload_for = Notifications.group_invitation_accepted(invitation.group, invitee)

    run_notification(fn ->
      invitation.inviter
      |> recipient_accounts_for_profile_notification()
      |> Enum.each(
        &deliver_profile_notification(&1, payload_for, "group invitation acceptance", invitee.id)
      )
    end)
  end

  defp notify_profile_invitee_of_shared_profile_invitation(
         %Profile{} = inviter,
         %Profile{} = shared_profile,
         %Profile{} = invitee
       ) do
    payload_for = Notifications.shared_profile_invitation(inviter, shared_profile)

    run_notification(fn ->
      invitee
      |> recipient_accounts_for_profile_notification()
      |> Enum.each(
        &deliver_profile_notification(&1, payload_for, "shared profile invitation", inviter.id)
      )
    end)
  end

  defp notify_profile_inviter_of_shared_profile_acceptance(
         %ProfileInvitation{} = invitation,
         %Profile{} = invitee,
         %Account{} = invitee_account
       ) do
    payload_for = Notifications.shared_profile_invitation_accepted(invitation.profile, invitee)

    run_notification(fn ->
      invitation.inviter
      |> recipient_accounts_for_profile_notification([invitee_account.id])
      |> Enum.each(
        &deliver_profile_notification(
          &1,
          payload_for,
          "shared profile invitation acceptance",
          invitee.id
        )
      )
    end)
  end

  # The push subscriptions of the members' accounts, grouped per account in
  # one query. Members without a subscribed device cost nothing, where loading
  # every member's account and then its subscriptions took a query per member.
  defp push_subscriptions_for_group_value(%Group{} = group, %Profile{} = creator) do
    group
    |> group_value_account_ids(creator, [])
    |> Dispatch.subscriptions_by_account()
  end

  # Members who silenced the group are left out (`GroupMutes`), unless the
  # value speaks to them (`own`).
  defp group_value_account_ids(%Group{} = group, %Profile{} = creator, own) do
    from(ap in AccountProfile,
      join: gm in GroupMembership,
      on: gm.profile_id == ap.profile_id,
      where: gm.group_id == ^group.id and gm.profile_id != ^creator.id,
      where:
        gm.profile_id in ^own or
          gm.profile_id not in subquery(GroupMutes.muted_profile_ids(group)),
      select: ap.account_id
    )
  end

  defp recipient_accounts_for_profile_notification(
         %Profile{} = profile,
         excluded_account_ids \\ []
       ) do
    from(account in Account,
      join: ap in AccountProfile,
      on: ap.account_id == account.id,
      where: ap.profile_id == ^profile.id,
      where: account.id not in ^excluded_account_ids,
      distinct: account.id,
      order_by: [asc: account.id]
    )
    |> Repo.all()
  end

  defp deliver_profile_notification(%Account{} = account, payload_for, _context, _profile_id) do
    deliver_account_push_notification(account, payload_for, "profile notification", nil)
  end

  defp deliver_account_push_notification(%Account{} = account, payload_for, context, context_id) do
    account
    |> Accounts.list_push_subscriptions()
    |> Dispatch.deliver(account.id, payload_for, context, context_id)
  end

  defp extract_group_id(%Group{id: id}), do: id
  defp extract_group_id(id) when is_integer(id), do: id
  defp extract_group_id(_group), do: nil

  defp latest_group_value_id(%Group{} = group) do
    from(v in Value,
      where: v.group_id == ^group.id and v.is_data == false,
      select: max(v.id)
    )
    |> Repo.one()
  end

  # Who joins starts with the chat's history read, as a member taken in by
  # inheritance does (`MemberInheritance`): it is there to read, but it is
  # not news, and it is not counted on every page until it is opened.
  defp read_history_on_join(repo, profile_id, group_id) do
    from(v in Value, where: v.group_id == ^group_id and v.is_data == false, select: max(v.id))
    |> repo.one()
    |> case do
      nil -> {:ok, :empty}
      latest_value_id -> upsert_group_value_read(repo, profile_id, group_id, latest_value_id)
    end
  end

  defp upsert_group_value_read(repo, profile_id, group_id, last_read_value_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # The WHERE clause makes the upsert a no-op (num_rows = 0) when the read
    # marker would not advance, which lets callers skip redundant broadcasts.
    sql = """
    INSERT INTO group_value_reads (profile_id, group_id, last_read_value_id, inserted_at, updated_at)
    VALUES ($1, $2, $3, $4, $5)
    ON CONFLICT (profile_id, group_id)
    DO UPDATE SET
      last_read_value_id = EXCLUDED.last_read_value_id,
      updated_at = EXCLUDED.updated_at
    WHERE COALESCE(group_value_reads.last_read_value_id, 0) < EXCLUDED.last_read_value_id
    """

    case repo.query(sql, [profile_id, group_id, last_read_value_id, now, now],
           cache_statement: "social_upsert_group_value_read"
         ) do
      {:ok, %{num_rows: 0}} -> {:ok, :unchanged}
      {:ok, _result} -> {:ok, :updated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp account_topic(account_id), do: "accounts:#{account_id}"
  defp profile_topic(profile_id), do: "profiles:#{profile_id}"
  defp group_topic(group_id), do: "groups:#{group_id}"
  defp group_unread_topic(group_id), do: "groups:#{group_id}:unread"

  def group_presence_topic(%Group{id: group_id}), do: group_presence_topic(group_id)
  def group_presence_topic(group_id) when is_integer(group_id), do: "groups:#{group_id}:presence"

  defp broadcast_account_profiles_updated(%Account{id: account_id}) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      account_topic(account_id),
      {:account_profiles_updated, account_id}
    )
  end

  defp broadcast_profile_share_invitations_updated(%Profile{id: profile_id}) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      profile_topic(profile_id),
      {:profile_share_invitations_updated, profile_id}
    )
  end

  defp broadcast_profile_invitations_updated(%Profile{id: profile_id}) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      profile_topic(profile_id),
      {:profile_invitations_updated, profile_id}
    )
  end

  defp broadcast_pending_invitations_count_updated(%Profile{id: profile_id} = profile) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      profile_topic(profile_id),
      {:pending_invitations_count_updated, profile_id, count_pending_invitations(profile)}
    )
  end

  @doc """
  Silences `group` for the profile for one of `GroupMutes.durations/0`, or
  lets it speak again with `nil`, and tells the profile's pages, which count
  its unread values again (`{:group_mute_changed, profile_id, group_id}`).
  Returns `{:ok, until}` or `{:error, reason}`.
  """
  def set_group_mute(%Profile{id: profile_id} = profile, %Group{id: group_id} = group, duration) do
    with {:ok, until} <- GroupMutes.set(profile, group, duration) do
      Phoenix.PubSub.broadcast(
        PotokIde.PubSub,
        profile_topic(profile_id),
        {:group_mute_changed, profile_id, group_id}
      )

      {:ok, until}
    end
  end

  @doc """
  Pins the group `group_id` at the top of the profile's column of groups
  (`PinnedGroups`) when the profile sees it, and tells the profile's pages
  (`{:group_pins_changed, profile_id}`). Returns `:ok`, `{:error, :too_many}`,
  `{:error, :not_pinnable}` or `{:error, :not_found}`.
  """
  def pin_group(%Profile{id: profile_id} = profile, group_id) when is_integer(group_id) do
    with %Group{} = group <- get_visible_group(profile, group_id) || {:error, :not_found},
         :ok <- PinnedGroups.pin(profile, group) do
      broadcast_group_pins_changed(profile_id)
    end
  end

  @doc "Takes the profile's pin off the group and tells its pages."
  def unpin_group(%Profile{id: profile_id} = profile, group_id) when is_integer(group_id) do
    :ok = PinnedGroups.unpin(profile, group_id)
    broadcast_group_pins_changed(profile_id)
  end

  defdelegate list_pinned_groups(profile), to: PinnedGroups, as: :list
  defdelegate group_pinned?(profile, group_id), to: PinnedGroups, as: :pinned?
  defdelegate pinned_group_ids(profile), to: PinnedGroups, as: :ids

  @doc """
  What a group's avatar needs beyond its id, for each of `group_ids`: when
  it last changed (the picture's address carries it) and its preset and app
  for the kind mark. `%{group_id => %{updated_at, preset, uses_api}}`.
  """
  def group_avatar_facts([]), do: %{}

  def group_avatar_facts(group_ids) when is_list(group_ids) do
    from(g in Group,
      where: g.id in ^group_ids,
      select: {g.id, %{updated_at: g.updated_at, preset: g.preset, uses_api: g.uses_api}}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp broadcast_group_pins_changed(profile_id) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      profile_topic(profile_id),
      {:group_pins_changed, profile_id}
    )
  end

  @doc """
  Tells the pages of a profile that the messages it scheduled in a group
  changed (`PotokIde.Social.ScheduledValues`). `sent_value_id` is the message
  one of them became when its time came, nil for any other change; it goes out
  before that message does.
  """
  def broadcast_scheduled_values_changed(profile_id, group_id, sent_value_id)
      when is_integer(profile_id) and is_integer(group_id) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      profile_topic(profile_id),
      {:scheduled_values_changed, profile_id, group_id, sent_value_id}
    )
  end

  @doc """
  Tells each of the profiles that what waits for it in some group's
  processes changed (`PotokIde.Processes.Engine`), so its pages count again.
  """
  def broadcast_profile_waiting_updated(profile_ids) when is_list(profile_ids) do
    Enum.each(profile_ids, fn profile_id ->
      Phoenix.PubSub.broadcast(
        PotokIde.PubSub,
        profile_topic(profile_id),
        {:profile_waiting_updated, profile_id}
      )
    end)
  end

  defp broadcast_profile_group_join_requests_updated(%Profile{id: profile_id}) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      profile_topic(profile_id),
      {:profile_group_join_requests_updated, profile_id}
    )
  end

  defp broadcast_group_join_request_updates_for_group(%Group{} = group) do
    group
    |> Access.profile_ids_with_permission(:manage_join_requests)
    |> Enum.each(&broadcast_profile_group_join_requests_updated(%Profile{id: &1}))
  end

  defp broadcast_profile_group_unread_counts_updated(%Profile{id: profile_id}, group_id) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      profile_topic(profile_id),
      {:group_unread_counts_updated, profile_id, group_id}
    )
  end

  # A chat value went: its members' pages take it out of their counts if
  # they counted it (`remove_unread_value/3`), with no query. Its author never
  # counted it. Data values never count.
  defp broadcast_group_value_removed(%Value{is_data: true}), do: :ok

  defp broadcast_group_value_removed(%Value{id: id, group_id: group_id, creator_id: creator_id}) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      group_unread_topic(group_id),
      {:group_value_removed, group_id, id, creator_id}
    )
  end

  # The profile's open pages first change what they subscribe to (see
  # `subscribe_group_unread/1`), then count again, which covers a value posted
  # before they subscribed.
  defp broadcast_group_membership_changed(profile_id, group_id, change)
       when is_integer(profile_id) and is_integer(group_id) and change in [:added, :removed] do
    Access.forget([group_id])

    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      profile_topic(profile_id),
      {:group_membership_changed, profile_id, group_id, change}
    )

    broadcast_profile_group_unread_counts_updated(%Profile{id: profile_id}, group_id)
  end

  # The inviter may have pages open; the new profile has none yet.
  defp broadcast_initial_direct_group(nil, _root_group, _account), do: :ok

  # As for any new direct chat, the membership news brings it into the
  # inviter's list.
  defp broadcast_initial_direct_group(%Group{} = group, _root_group, %Account{} = account) do
    broadcast_group_membership_changed(account.invited_by_id, group.id, :added)
  end

  # Skips the calling process, which already knows (see `mark_group_values_read/3`).
  defp broadcast_from_profile_group_unread_counts_updated(%Profile{id: profile_id}, group_id) do
    Phoenix.PubSub.broadcast_from(
      PotokIde.PubSub,
      self(),
      profile_topic(profile_id),
      {:group_unread_counts_updated, profile_id, group_id}
    )
  end

  # A new chat value is one more unread value for every member but its
  # creator, whose pages skip it by `creator_id`. It goes out with the group's
  # chain up to the root, worked out once here, so each member's pages add it
  # to their counts without a query (`add_unread_value/3`) instead of all
  # counting again at once, and with its preview for the group's row in the
  # lists, which the creator's pages show too. The creator's read marker moved
  # past it, which may have read older values too, so the creator's other
  # pages count again. The root group's values never count.
  defp broadcast_group_value_unread(_creator, %Group{is_root: true}, _value), do: :ok

  defp broadcast_group_value_unread(%Profile{} = creator, %Group{id: group_id}, %Value{} = value) do
    unread = %{
      creator_id: creator.id,
      group_id: group_id,
      value_id: value.id,
      inserted_at: value.inserted_at,
      chain: group_ancestry(group_id),
      preview: ValuePreview.from_value(value)
    }

    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      group_unread_topic(group_id),
      {:group_value_unread, unread}
    )

    broadcast_from_profile_group_unread_counts_updated(creator, group_id)
  end

  defp broadcast_profile_updated(%Profile{id: profile_id}) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      profile_topic(profile_id),
      {:profile_updated, profile_id}
    )
  end

  # Every manifest or role change ends here, so the cached manifests go first:
  # the pages reload them on this message.
  defp broadcast_group_roles_updated(group_ids) when is_list(group_ids) do
    Access.forget_manifests(group_ids)
    Access.forget(group_ids)

    Enum.each(group_ids, fn group_id ->
      Phoenix.PubSub.broadcast(
        PotokIde.PubSub,
        group_topic(group_id),
        {:group_roles_updated, group_id}
      )
    end)
  end

  # The groups `MemberInheritance.sync/3` or `join/3` changed: their pages
  # read their members again, and the profiles who came or went recount
  # their unread values. One change can reach a whole chain of inheriting
  # groups, so the numbers are left to the pages that show them.
  defp broadcast_inheritance_changes(changes) do
    Enum.each(changes, fn %{group_id: group_id, added: added, removed: removed} ->
      broadcast_group_members_changed(group_id, [:members], numbers: false)
      Enum.each(added, &broadcast_group_membership_changed(&1, group_id, :added))
      Enum.each(removed, &broadcast_group_membership_changed(&1, group_id, :removed))
    end)

    case for(%{roles_changed?: true, group_id: group_id} <- changes, do: group_id) do
      [] -> :ok
      group_ids -> broadcast_group_roles_updated(group_ids)
    end
  end

  # A sub-group was created, changed or deleted. The parent's pages read their
  # list again only when it can concern them (GroupLive.Show): it shows the
  # sub-group, or the sub-group is public, inherits the parent's members, or
  # is the viewer's own. The parent used to get `group_updated`, which
  # reloaded every page on it: on the root, every user's (~3 ms of CPU each
  # in the load test, for every new direct chat or top-level group).
  defp broadcast_child_group_changed(parent_id, %Group{} = child, change)
       when is_integer(parent_id) and change in [:created, :updated, :deleted] do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      group_topic(parent_id),
      {:child_group_changed, parent_id,
       %{
         id: child.id,
         change: change,
         public?: child.is_public,
         inherits?: child.inherits_members,
         creator_id: child.creator_id
       }}
    )
  end

  @doc """
  The message a group's pages get when who belongs to it, asks to join or is
  blocked changed, instead of `{:group_updated, id}`, which made every open
  page read itself again at once:
  `{:group_members_changed, group_id, %{changed: [:members | :requests | :blocks], ...}}`.

  The numbers are read here once (`member_count`, `first3`,
  `join_request_count`), so a page needs no query for its header; a page that
  lists what changed reads that list again (`GroupLive.Show`). Options:

    * `:profile_id` - the profile the change is about (who asked, joined, left
      or was blocked): its own page reads itself again, as what it may do
      changed.
    * `numbers: false` - for the many groups one inheritance change can
      touch: each page that shows the numbers reads them itself.
  """
  def broadcast_group_members_changed(group, changed, opts \\ [])

  def broadcast_group_members_changed(group_id, changed, opts) when is_integer(group_id),
    do: broadcast_group_members_changed(%Group{id: group_id}, changed, opts)

  def broadcast_group_members_changed(%Group{id: group_id} = group, changed, opts)
      when is_list(changed) do
    numbers =
      if Keyword.get(opts, :numbers, true) do
        %{
          member_count: count_group_members(group),
          first3: list_first3_group_members(group),
          join_request_count: count_pending_group_join_requests(group)
        }
      else
        %{}
      end

    change =
      numbers
      |> Map.put(:changed, changed)
      |> Map.put(:profile_id, Keyword.get(opts, :profile_id))

    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      group_topic(group_id),
      {:group_members_changed, group_id, change}
    )
  end

  defp broadcast_group_updated(%Group{id: group_id}), do: broadcast_group_updated(group_id)

  defp broadcast_group_updated(group_id) when is_integer(group_id) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      group_topic(group_id),
      {:group_updated, group_id}
    )
  end

  @doc """
  Tells the group's pages that the public tags of an item shown there
  changed (`PotokIde.Tags`); each page reads the tags it sees again.
  """
  def broadcast_tags_changed(group_id, kind, item_id)
      when is_integer(group_id) and is_atom(kind) and is_integer(item_id) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      group_topic(group_id),
      {:tags_changed, kind, item_id}
    )
  end

  # Value broadcasts carry the preloaded value so subscribers do not each
  # query it again.
  defp broadcast_value_created(%Group{id: group_id}, %Value{} = value) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      group_topic(group_id),
      {:value_created, group_id, value}
    )
  end

  defp broadcast_data_value_created(%Group{id: group_id}, %Value{} = value) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      group_topic(group_id),
      {:data_value_created, group_id, value}
    )
  end

  # A reaction to the group: its pages take the pills from the message, the
  # same for everyone but `mine?`, which each page keeps (`change` says whose
  # reaction it was).
  defp broadcast_group_reactions_updated(%Group{id: group_id}, summaries, change) do
    reactions = Enum.map(summaries, &Map.put(&1, :mine?, false))

    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      group_topic(group_id),
      {:group_reactions_updated, group_id, %{reactions: reactions, change: change}}
    )
  end

  # A reaction to a value: its pages show the new pills. `change` says whose
  # reaction it was, so the reactor's pages know their own (`mine?` in the
  # value says nothing of a viewer).
  defp broadcast_value_reacted(%Value{group_id: group_id} = value, change) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      group_topic(group_id),
      {:value_reacted, group_id, value, change}
    )
  end

  defp broadcast_value_updated(%Value{group_id: group_id} = value) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      group_topic(group_id),
      {:value_updated, group_id, value}
    )
  end

  defp broadcast_alt_descriptions_updated(%Group{id: group_id}) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      group_topic(group_id),
      {:alt_descriptions_updated, group_id}
    )
  end

  defp broadcast_group_description_updated(%Group{id: group_id}) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      group_topic(group_id),
      {:group_description_updated, group_id}
    )
  end

  defp broadcast_value_deleted(%Value{group_id: group_id, id: value_id}) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      group_topic(group_id),
      {:value_deleted, group_id, value_id}
    )
  end

  defp broadcast_group_deleted(group_id, parent_id) when is_integer(group_id) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      group_topic(group_id),
      {:group_deleted, group_id, parent_id}
    )
  end

  # A process profile belongs to no account (`AppProcesses`): nobody logs in
  # as it or picks it.
  defp link_profile_to_account(_repo, %Profile{kind: :process}, %Account{}),
    do: {:error, :process_profile}

  defp link_profile_to_account(repo, %Profile{} = profile, %Account{} = account) do
    case profile.sharing do
      :shared ->
        if linked_to_account?(repo, profile, account) do
          {:ok, :already_linked}
        else
          repo.insert(
            AccountProfile.changeset(%AccountProfile{}, %{
              account_id: account.id,
              profile_id: profile.id
            })
          )
        end

      :unique ->
        existing_account_ids =
          from(ap in AccountProfile, where: ap.profile_id == ^profile.id, select: ap.account_id)
          |> repo.all()

        cond do
          existing_account_ids == [] ->
            repo.insert(
              AccountProfile.changeset(%AccountProfile{}, %{
                account_id: account.id,
                profile_id: profile.id
              })
            )

          account.id in existing_account_ids ->
            {:ok, :already_linked}

          true ->
            {:error, :profile_is_unique}
        end
    end
  end

  defp linked_to_account?(repo, %Profile{} = profile, %Account{} = account) do
    from(ap in AccountProfile,
      where: ap.profile_id == ^profile.id and ap.account_id == ^account.id,
      select: 1
    )
    |> repo.exists?()
  end
end
