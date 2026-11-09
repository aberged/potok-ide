defmodule PotokIdeWeb.GroupLive.Show do
  use PotokIdeWeb, :live_view

  alias PotokIde.Accounts
  alias PotokIde.Accounts.Account
  alias PotokIde.Events
  alias PotokIde.Social

  alias PotokIde.Social.{
    Access,
    AppData,
    Group,
    GroupAccountInvitation,
    GroupAltDescription,
    GroupInvitation,
    GroupPresets,
    GroupRole,
    Profile,
    Value,
    ValueAttachment
  }

  alias PotokIde.Polls
  alias PotokIde.RateLimit
  alias PotokIde.Storage
  alias PotokIde.Tags

  alias PotokIdeWeb.GroupLive.Show.{
    CalendarState,
    CalendarTab,
    Components,
    CreateGroupTab,
    EditGroupTab,
    FilesTab,
    GroupDescriptionTab,
    GroupMenu,
    InviteProfileTab,
    MediaViewer,
    MembersTab,
    PollCard,
    PollForm,
    PollsState,
    PollsTab,
    RolesTab,
    RootMapState,
    RootMapTab,
    SubGroupsTab,
    SubGroupTree,
    ValuesTab
  }

  alias PotokIdeWeb.PostTemplates
  alias PotokIdeWeb.ProfileAuth
  alias PotokIdeWeb.PublicPreview
  alias PotokIdeWeb.RateLimited
  alias PotokIdeWeb.{TagComponents, TagEditor}

  alias PotokIdeWeb.GroupLive.Show.{
    AppApi,
    AppHost,
    AppValues,
    Components,
    CreateMenu,
    GroupSheet
  }

  @children_page_size 20
  @members_page_size 20
  @values_page_size 20
  @files_page_size 30
  # A jump to a value (a `?value=` link or a reply quote) loads this many
  # values before and after it, however far back it is.
  @values_window_older 10
  @values_window_newer 20
  # The feed holds at most this many values: a page loaded at one end drops
  # as many from the other, which load again when scrolled back to.
  @values_max_loaded 200
  # How long a page collects the values it shows before it writes the read
  # marker once (see `mark_value_read/2`); 0 (the test config) writes at once.
  @read_marker_delay_ms Application.compile_env(:potok_ide, :read_marker_delay_ms, 5_000)

  # What the browser sends is already shrunk (see `description_picture_picker`).
  @max_description_picture_size 5 * 1024 * 1024

  # The cards of the edit and create tabs (`sections/0` of each), and the
  # form fields of each card, so a save that fails opens the card with the
  # error.
  @edit_group_sections ~w(basics access home description alt_descriptions location danger)
  @create_group_sections ~w(basics access home description)
  @group_form_section_fields [
    {"basics", [:name, :group_picture_url]},
    {"access", [:is_public, :is_root_public, :inherits_members]},
    {"home", [:home_page, :home_alt_description_id]},
    {"description", [:description_name, :description, :description_format, :uses_api]},
    {"location", [:latitude, :longitude, :pin_icon]}
  ]

  # Bursts of `group_updated` / unread broadcasts are coalesced into one
  # reload. 0 (the test config) applies them inline.
  @refresh_debounce_ms Application.compile_env(:potok_ide, :live_refresh_debounce_ms, 100)
  # A value fans an unread refresh out to every member online. Each page waits
  # a random part of this on top of the debounce, so a big group's members do
  # not all recount or re-render in the same instant.
  @unread_refresh_spread_ms 1_000
  # Values posted by others only add to badges, so their pages wait longer:
  # a run of posts in a big group becomes one render per page, spread over a
  # few seconds, instead of one per post from every member online at once.
  # The chat on screen does not wait: its values come as `:value_created`.
  @unread_values_spread_ms 5_000
  # A sub-group that changed reloads the list on every page showing it: on
  # the root that can be every user's, so they spread over a second too.
  @children_refresh_spread_ms 1_000

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_profile={@current_profile}
      current_locale={@current_locale}
      available_locales={@available_locales}
      pending_invitations_count={@pending_invitations_count}
      pending_group_join_requests_count={@pending_group_join_requests_count}
      root_group_unread_count={@root_group_unread_count}
      collapse_nav
    >
      <%!-- Online indicators are toggled by this rule set instead of re-rendering streamed items. --%>
      <style id="group-presence-style">
        <%= Components.presence_css(@online_profile_ids) %>
      </style>
      <%!-- Unread counts on the chat's thread links work the same way. --%>
      <style id="group-thread-unread-style">
        <%= Components.thread_unread_css(@thread_unread_counts) %>
      </style>
      <%!-- So do the numbers of polls: a vote changes these rules and no message. --%>
      <style id="group-poll-tally-style">
        <%= Components.poll_tally_css(@poll_tallies) %>
      </style>

      <%!-- The back link, the name and the menu share a row; on narrower screens the sections
           take a row of their own. On phones the header is flat and the sections are
           equal columns, and neither they nor the path stay while typing. A flat header
           starts at the top of <main>, which cuts what stands above it, so the counts on
           the avatar stay inside the row. --%>
      <div
        id="group-header"
        class="relative z-50 shrink-0 border-b border-base-300/70 bg-base-100/85 backdrop-blur sm:mt-1 sm:rounded-4xl sm:border sm:px-3 sm:py-1.5 sm:shadow-lg sm:shadow-primary/5"
      >
        <div class="flex flex-wrap items-center gap-x-1 px-1 sm:gap-x-2 sm:px-0">
          <div :if={!@group.is_root and @group.parent_id} class="shrink-0">
            <%!-- Goes back like the browser does. With no page of this site
                 behind (opened from a notification, a link or a new tab) it
                 goes to the parent; a thread to the chat it was started from. --%>
            <.link
              id="group-back-link"
              phx-hook=".HistoryBack"
              navigate={back_path(@group, @group_path)}
              aria-label={gettext("Back")}
              class="inline-flex size-11 items-center justify-center rounded-full text-base-content/70 transition-colors duration-150 hover:bg-base-200 hover:text-base-content focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40 cramped:size-9"
            >
              <.icon name="hero-chevron-left" class="size-5" />
            </.link>
            <script :type={Phoenix.LiveView.ColocatedHook} name=".HistoryBack">
              const hasAppPageBehind = () => {
                // The Navigation API lists only this site's entries in this tab.
                if (window.navigation) return window.navigation.canGoBack
                if (window.history.length < 2) return false
                // LiveView numbers the entries of a tab from 0, the first page.
                if ((window.history.state?.position ?? 0) > 0) return true

                // A full page load that this site opened in the same tab.
                try {
                  return new URL(document.referrer).origin === window.location.origin
                } catch (_error) {
                  return false
                }
              }

              export default {
                mounted() {
                  this.el.addEventListener("click", event => {
                    const newTab =
                      event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey

                    if (newTab || !hasAppPageBehind()) return

                    event.preventDefault()
                    // LiveView's own link handler on window ignores defaultPrevented.
                    event.stopPropagation()
                    window.history.back()
                  })
                },
              }
            </script>
          </div>

          <div class="min-w-0 flex-1 py-1 cramped:py-0.5">
            <div :if={!@group.is_root} class="flex items-center gap-3">
              <Components.group_identity
                group={@group}
                current_profile={@current_profile}
                avatar_size="size-9 sm:size-10"
                badge_top="-top-1 sm:-top-2 cramped:-top-0.5"
                text_class="text-sm sm:text-base"
                pending_join_requests_count={@pending_join_requests_count}
                unread_count={Map.get(@group_unread_counts, @group.id, 0)}
              >
                <:subtitle>
                  <div class="flex min-w-0 items-center gap-2 cramped:hidden">
                    <Components.group_path
                      path={@group_path}
                      group={@group}
                      current_profile={@current_profile}
                    />
                    <TagComponents.tag_chips
                      id="group-tag-list"
                      tags={@group_tags}
                      size={:sm}
                      max={3}
                      class="max-sm:hidden"
                    />
                    <TagComponents.tag_count
                      id="group-tag-count"
                      tags={@group_tags}
                      kind={:group}
                      item_id={@group.id}
                      class="shrink-0 sm:hidden"
                    />
                  </div>
                </:subtitle>
              </Components.group_identity>
            </div>

            <div
              :if={@group.is_root}
              id="group-sub-groups-kind-tabs"
              class="inline-flex w-fit max-w-full items-center gap-0.5 rounded-full border border-base-300 bg-base-200/70 p-0.5"
            >
              <button
                id="group-sub-groups-kind-direct"
                type="button"
                phx-click="switch_sub_groups_kind"
                phx-value-kind="direct"
                aria-pressed={to_string(@sub_groups_kind == "direct")}
                class={root_kind_class(@sub_groups_kind == "direct")}
              >
                <.icon name="hero-users" class="size-4 shrink-0" />
                {gettext("Conversations")}
                <.count_badge
                  :if={@direct_sub_groups_unread_count > 0}
                  id="group-sub-groups-kind-direct-unread-badge"
                  count={@direct_sub_groups_unread_count}
                />
              </button>
              <button
                id="group-sub-groups-kind-other"
                type="button"
                phx-click="switch_sub_groups_kind"
                phx-value-kind="other"
                aria-pressed={to_string(@sub_groups_kind == "other")}
                class={root_kind_class(@sub_groups_kind == "other")}
              >
                <.icon name="hero-user-group" class="size-4 shrink-0" />
                {gettext("Groups")}
                <.count_badge
                  :if={@other_sub_groups_unread_count > 0}
                  id="group-sub-groups-kind-other-unread-badge"
                  count={@other_sub_groups_unread_count}
                />
              </button>
            </div>
          </div>

          <div
            :if={!@group.is_root and !@is_member and !@access.blocked?}
            id="group-join-request-callout"
            class="flex shrink-0 items-center"
          >
            <.button
              :if={is_nil(@pending_join_request)}
              id="group-request-access"
              type="button"
              phx-click="request_join"
              variant="soft"
            >
              {gettext("Request access")}
            </.button>
            <div
              :if={!is_nil(@pending_join_request)}
              id="group-request-access-pending"
              class="inline-flex items-center rounded-full bg-sky-900 px-3 py-2 text-sm font-medium text-sky-50"
            >
              {gettext("Access request pending")}
            </div>
          </div>

          <Components.group_tabs
            tabs={
              header_tabs(
                @group,
                @is_member,
                @active_tab,
                %{calendar?: @calendar_tab?, polls?: @polls_section?},
                {@current_group_unread_count, @sub_groups_unread_count, @pending_join_requests_count}
              )
            }
            class="max-[87.5rem]:order-last max-[87.5rem]:basis-full cramped:hidden"
          />

          <button
            :if={@calendar_tab? and @group.is_root}
            id="group-calendar-summary"
            type="button"
            phx-click="switch_tab"
            phx-value-tab="calendar"
            aria-label={gettext("Open calendar tab")}
            aria-current={@active_tab == "calendar" && "true"}
            class={header_shortcut_class(@active_tab == "calendar")}
          >
            <.icon name="hero-calendar-days" class="size-6 shrink-0" />
          </button>
          <button
            :if={@group.is_root}
            id="group-map-summary"
            type="button"
            phx-click="switch_tab"
            phx-value-tab="map"
            aria-label={gettext("Open the map of groups")}
            aria-current={@active_tab == "map" && "true"}
            class={header_shortcut_class(@active_tab == "map")}
          >
            <.icon name="hero-map" class="size-6 shrink-0" />
          </button>
          <button
            :if={@group.is_root and @group.is_public}
            id="group-subgroups-summary"
            type="button"
            phx-click="switch_tab"
            phx-value-tab="sub_groups"
            aria-label={gettext("Open sub-groups tab")}
            aria-current={needs_children?(@group, @active_tab) && "true"}
            class={header_shortcut_class(needs_children?(@group, @active_tab))}
          >
            <.icon name="hero-folder-open" class="size-6 shrink-0" />
            <.count_badge
              :if={@sub_groups_unread_count > 0}
              id="group-sub-groups-unread-badge"
              count={@sub_groups_unread_count}
              class="absolute right-0 top-0"
            />
          </button>
          <button
            :if={@group.parent_id == nil && @is_member}
            id="group-invite-account"
            type="button"
            phx-click="invite_account"
            aria-label={gettext("Open invite account tab")}
            class="cursor-pointer rounded-full transition-opacity hover:opacity-85 focus:outline-none focus:ring-2 focus:ring-primary/40"
          >
            <.icon
              name="hero-user-plus"
              class="size-6 shrink-0 rounded-full border p-1 shadow-sm"
            />
          </button>

          <%!-- Faces of the members where there is room for them; phones have the section. --%>
          <button
            :if={@group.parent_id != nil && @is_member}
            id="group-members-stack"
            type="button"
            phx-click="switch_tab"
            phx-value-tab="members"
            aria-label={gettext("Members")}
            class="avatar-group relative hidden -space-x-6 cursor-pointer rounded-full transition hover:opacity-85 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40 sm:inline-flex"
          >
            <div :for={m <- @first3_members} class="">
              <Components.profile_identity
                profile={m}
                avatar_size="size-6"
                text_class="hidden"
                sharing_badge_text_class="hidden"
              />
            </div>

            <div :if={@members_count > 3} class="avatar avatar-placeholder border-3">
              <div class="bg-neutral text-neutral-content size-5 text-xs">
                <span>+{@members_count - length(@first3_members)}</span>
              </div>
            </div>
          </button>

          <Layouts.drop_down_menu id="group-actions-menu" icon="hero-ellipsis-horizontal">
            <GroupMenu.items group={@group} access={@access} active_tab={@active_tab}>
              <%!-- The root has no bar of sections. --%>
              <Components.group_tab_button
                :if={@group.is_root and @calendar_tab?}
                id="group-tab-calendar"
                tab="calendar"
                active_tab={@active_tab}
                label={gettext("My calendar")}
                icon="hero-calendar-days"
              />
              <Components.group_tab_button
                :if={@group.is_root}
                id="group-tab-map"
                tab="map"
                active_tab={@active_tab}
                label={gettext("Map of groups")}
                icon="hero-map"
              />
              <%!-- Sections come with a group's first poll; this leads to starting one. --%>
              <Components.group_tab_button
                :if={@is_member and !@group.is_direct}
                id="group-tab-polls"
                tab="polls"
                active_tab={@active_tab}
                label={
                  if(@group.is_root,
                    do: dgettext("polls", "My polls"),
                    else: dgettext("polls", "Polls")
                  )
                }
                icon="hero-chart-bar"
              />
              <Components.group_tab_button
                :if={@group.is_root}
                id="group-tab-sub-groups"
                tab="sub_groups"
                active_tab={@active_tab}
                label={gettext("Sub-groups")}
                icon="hero-folder-open"
              />
            </GroupMenu.items>
          </Layouts.drop_down_menu>
        </div>
      </div>

      <%!-- The root's own pages lead back to its overview from here. --%>
      <Components.group_path
        :if={@group.is_root and !needs_children?(@group, @active_tab)}
        path={@group_path}
        group={@group}
        current_profile={@current_profile}
        class="shrink-0 px-4 py-2 text-sm"
      />

      <div class="flex min-h-0 flex-1 flex-col overflow-clip">
        <%!-- The first HTML only carries the header; the panel arrives once the socket connects. --%>
        <div
          :if={!@loaded?}
          id="group-panel-loading"
          aria-busy="true"
          class="flex min-h-0 flex-1 flex-col gap-3 p-2"
        >
          <span class="sr-only">{gettext("Loading…")}</span>
          <div :for={_row <- 1..4} class="h-14 animate-pulse rounded-3xl bg-base-200/70" />
        </div>

        <div :if={@loaded?} class="flex min-h-0 flex-1 flex-col gap-2">
          <SubGroupsTab.panel
            :if={@active_tab == "sub_groups" or (@group.parent_id == nil and @active_tab == "values")}
            group={@group}
            current_profile={@current_profile}
            children={@streams.children}
            pagination={@children_pagination}
            pending_join_request_counts={@child_pending_join_request_counts}
            unread_counts={@group_unread_counts}
            time_zone={@calendar_time_zone}
            is_member={@is_member}
            can_create_subgroups={Access.can?(@access, :create_subgroups)}
            sub_groups_kind={@sub_groups_kind}
            direct_sub_groups_unread_count={@direct_sub_groups_unread_count}
            other_sub_groups_unread_count={@other_sub_groups_unread_count}
            children_search_query={@children_search_query}
            children_preset={@children_preset}
            children_relation={@children_relation}
            show_thread_sub_groups={@show_thread_sub_groups}
            thread_sub_groups_count={@thread_sub_groups_count}
            thread_sub_groups_unread_count={@thread_sub_groups_unread_count}
            show_public_sub_groups={@show_public_sub_groups}
            sub_groups_view={@sub_groups_view}
            tree={@sub_group_tree}
            row_menu={@group_row_menu}
          />
          <MembersTab.panel
            :if={@active_tab == "members"}
            members={@streams.members}
            pagination={@members_pagination}
            current_profile={@current_profile}
            group={@group}
            access={@access}
            join_requests={@pending_join_requests}
            pending_join_requests_count={@pending_join_requests_count}
            blocks={@group_blocks}
          />
          <ValuesTab.panel
            :if={
              @active_tab == "values" and @group.parent_id != nil and
                Access.can_read_chat?(@access, @group)
            }
            values={@streams.values}
            has_more={@values_has_more?}
            has_newer={@values_has_newer?}
            group={@group}
            current_profile={@current_profile}
            editing_value_id={@editing_value && @editing_value.id}
            editing_value={@editing_value}
            edit_value_form={@edit_value_form}
            new_value_form={@new_value_form}
            replying_to_value={@replying_to_value}
            thread_origin={@thread_origin}
            focus_value_id={@focus_value_id}
            is_member={@is_member}
            access={@access}
            attachments={@uploads.attachments}
            can_attach={can_attach?(@access)}
            keyboard_media={
              if(can_send_keyboard_media?(@current_profile, @group, @access),
                do: @uploads.keyboard_media
              )
            }
            share_id={@share_id}
          />
          <FilesTab.panel
            :if={@active_tab == "files"}
            group={@group}
            files={@streams.files}
            files_view={@files_view}
            has_more={@files_has_more?}
            tree={@file_tree}
            tree_truncated={@file_tree_truncated?}
          />
          <RootMapTab.panel
            :if={@active_tab == "map"}
            filters={@root_map_filters}
            show_public={@show_public_sub_groups}
            extent={@root_map_extent}
            total={@root_map_total}
            spot={@root_map_spot}
            error={@root_map_error?}
            range_form={@root_map_range_form}
          />
          <CalendarTab.panel
            :if={@active_tab == "calendar"}
            group={@group}
            current_profile={@current_profile}
            access={@access}
            time_zone={@calendar_time_zone}
            month={@calendar_month}
            mode={@calendar_mode}
            weeks={@calendar_weeks}
            by_day={@calendar_by_day}
            occurrences={@streams.calendar_occurrences}
            occurrences_empty={@calendar_occurrences_empty?}
            selected_date={@calendar_selected_date}
            include_subgroups={@calendar_include_subgroups?}
            show_groups={@calendar_show_groups?}
            show_public={@calendar_show_public?}
            event={@calendar_event}
            occurrence={@calendar_occurrence}
            occurrence_cancelled={@calendar_occurrence_cancelled?}
            summary={@calendar_summary}
            can_manage={@calendar_can_manage?}
            event_member={@calendar_event_member?}
            my_reminders={@calendar_my_reminders}
            form={@calendar_form}
            form_values={@calendar_form_values}
            announce={@calendar_announce?}
            notify={@calendar_notify?}
          />
          <PollsTab.panel
            :if={@active_tab == "polls"}
            group={@group}
            access={@access}
            status={@polls_status}
            rows={@streams.polls}
            empty={@polls_empty?}
            more={@polls_more?}
            detail={@polls_detail}
            include_subgroups={@polls_include_subgroups?}
            show_groups={@polls_show_groups?}
            show_public={@polls_show_public?}
          />
          <GroupDescriptionTab.panel
            :if={
              @active_tab == "group_home" or
                (@active_tab == "values" and @group.parent_id != nil and
                   !Access.can_read_chat?(@access, @group))
            }
            group={@group}
            current_profile={@current_profile}
            is_member={@is_member}
            viewer_roles={Enum.join(@access.role_keys, ",")}
            pending_join_request={@pending_join_request}
            alt_descriptions={@visible_alt_descriptions}
            active_alt_description={@active_alt_description}
            can_edit={Access.can?(@access, :edit_group) and !@group.is_root}
            reactions={@group_reactions}
            can_react={@can_react_to_group}
            app_upload={if(@current_profile, do: @uploads.app_file)}
            host="page"
          />
          <CreateGroupTab.panel
            :if={Access.can?(@access, :create_subgroups) and @active_tab == "create_group"}
            section={@create_group_section}
            new_group_form={@new_group_form}
            format_options={@format_options}
            home_page_options={@home_page_options}
            value_parent_options={@value_parent_options}
            group={@group}
          />
          <EditGroupTab.panel
            :if={Access.can?(@access, :edit_group) and @active_tab == "edit_group"}
            edit_group_form={@edit_group_form}
            link_card={@link_card}
            dirty={edit_group_dirty?(@edit_group_form)}
            section={@edit_group_section}
            inherits_members_option={@inherits_members_option?}
            can_delete_group={@access.admin?}
            description_details_open={@description_details_open}
            format_options={@format_options}
            home_page_options={@home_page_options}
            group={@group}
            alt_descriptions={@alt_descriptions}
            alt_description_form={@alt_description_form}
            editing_alt_description={@editing_alt_description}
            roles={if(@access.manifest, do: @access.manifest.roles, else: [])}
            max_alt_descriptions={Social.max_alt_descriptions()}
            template_list={@template_list}
            picture_upload={
              if(can_post_description_picture?(@group, @access), do: @uploads.description_picture)
            }
            everyone_can_post={Access.everyone_can?(@access, :post_values)}
          />
          <InviteProfileTab.panel
            :if={Access.can?(@access, :invite_members) and @active_tab == "invite_profile"}
            invite_form={@invite_form}
            invite_form_version={@invite_form_version}
            invite_profile_suggestions={@invite_profile_suggestions}
            group={@group}
          />
          <RolesTab.panel
            :if={@is_member and !@group.is_direct and @active_tab == "roles"}
            group={@group}
            access={@access}
            manifest_owner={@manifest_owner}
            new_role_form={@new_role_form}
            role_member_counts={@role_member_counts}
            members_count={@members_count}
          />
        </div>
      </div>

      <MediaViewer.viewer />
      <TagComponents.tag_editor editor={@tag_editor} />
      <CreateMenu.menu menu={@group_create_menu} />
      <PollForm.dialog state={@poll_form} />
      <PollCard.dialog view={@poll_dialog} />
      <GroupSheet.dialog
        :if={@group_sheet}
        sheet={@group_sheet}
        socket={@socket}
        session={group_sheet_session(assigns)}
      />
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id} = params, _session, socket) do
    current_profile = socket.assigns.current_profile
    group = Social.get_group!(id)

    access = Social.get_group_access(current_profile, group)
    is_member = access.member?
    active_tab = normalize_active_tab(Map.get(params, "tab"), group, access)
    sub_groups_kind = normalize_sub_groups_kind(Map.get(params, "sub_groups_kind"), group)

    cond do
      path = public_event_path(params, access, active_tab, current_profile) ->
        {:ok, push_navigate(socket, to: path)}

      can_view_group?(group, is_member) ->
        if connected?(socket) do
          Social.subscribe_group(group)
          AppData.subscribe(group)
        end

        {:ok,
         socket
         |> stream_configure(:children, dom_id: &"child-group-#{&1.id}")
         |> stream_configure(:members, dom_id: &"member-#{&1.id}")
         |> stream_configure(:values, dom_id: &"value-#{&1.id}")
         |> stream_configure(:files, dom_id: &"file-#{&1.id}")
         |> assign(:children_pagination, default_pagination(@children_page_size))
         |> assign(:members_pagination, default_pagination(@members_page_size))
         |> assign(:values_has_more?, false)
         |> assign(:values_has_newer?, false)
         |> assign(:oldest_value_id, nil)
         |> assign(:newest_value_id, nil)
         |> assign(:loaded_value_ids, MapSet.new())
         |> assign(:focus_value_id, parse_focus_value_id(Map.get(params, "value")))
         |> assign(:files_view, "list")
         |> assign(:files_has_more?, false)
         |> assign(:files_loaded_count, 0)
         |> assign(:oldest_file_id, nil)
         |> assign(:file_tree, nil)
         |> assign(:file_tree_truncated?, false)
         |> allow_attachments_upload()
         |> allow_description_picture_upload()
         |> allow_keyboard_media_upload()
         |> AppHost.allow("page")
         |> assign(:template_list, nil)
         |> assign(:group_row_menu, nil)
         |> assign(:loaded_children, [])
         |> assign(:pending_refresh, MapSet.new())
         |> assign(:refresh_due_at, nil)
         |> assign(:unread_overview, nil)
         |> assign(:pending_unread_values, [])
         |> assign(:app_api_bucket, AppApi.new_bucket())
         |> assign(:child_pending_join_request_counts, %{})
         |> assign(:group_unread_counts, %{})
         |> assign(:current_group_unread_count, 0)
         |> assign(:sub_groups_unread_count, 0)
         |> assign(:direct_sub_groups_unread_count, 0)
         |> assign(:other_sub_groups_unread_count, 0)
         |> assign(:thread_unread_counts, %{})
         |> assign(:thread_sub_groups_unread_count, 0)
         |> assign(:children_search_query, "")
         |> assign(:children_preset, nil)
         |> assign(:children_relation, nil)
         |> assign(:show_thread_sub_groups, connect_show_threads?(socket))
         |> assign(:show_public_sub_groups, connect_show_public_groups?(socket))
         |> assign(:thread_sub_groups_count, 0)
         |> assign(:sub_groups_kind, sub_groups_kind)
         |> assign(
           :sub_groups_view,
           normalize_sub_groups_view(Map.get(params, "view"), sub_groups_kind)
         )
         |> assign(:sub_group_tree, nil)
         |> assign(:members_count, 0)
         |> assign(:first3_members, [])
         |> assign(:online_profile_ids, MapSet.new())
         |> assign(:presence_watched, MapSet.new())
         |> assign(:presence_profile_id, nil)
         |> assign(:description_param, Map.get(params, "d"))
         |> assign(:alt_descriptions, [])
         |> assign(:visible_alt_descriptions, [])
         |> assign(:active_alt_description, nil)
         |> assign(:alt_description_form, nil)
         |> assign(:editing_alt_description, nil)
         |> assign_access(access)
         |> assign(:group, group)
         |> assign(:active_tab, active_tab)
         |> assign(:manifest_owner, nil)
         |> assign(:new_role_form, nil)
         |> assign(:role_member_counts, %{})
         |> assign(:editing_value, nil)
         |> assign(:edit_value_form, nil)
         |> assign(:replying_to_value, nil)
         |> assign(:thread_origin, nil)
         |> assign(:format_options, [{gettext("Markdown"), :markdown}, {gettext("HTML"), :html}])
         |> assign(:home_page_options, home_page_options())
         |> assign(:value_parent_options, [])
         |> assign(:new_value_form, nil)
         |> assign(:new_group_form, nil)
         |> assign_tab_forms(active_tab)
         |> assign(:edit_group_form, edit_group_form(group, active_tab))
         |> assign(:link_card, link_card(group, active_tab))
         |> assign(:edit_group_section, opening_edit_section(params))
         |> assign(:create_group_section, "basics")
         |> assign(
           :inherits_members_option?,
           active_tab == "edit_group" and Social.inherits_members_option?(group)
         )
         |> assign(:description_details_open, true)
         |> assign(:invite_form, empty_invite_form())
         |> assign(:invite_form_version, 0)
         |> assign(:invite_profile_suggestions, [])
         |> assign(:pending_join_request, nil)
         |> assign(:pending_join_requests, [])
         |> assign(:pending_join_requests_count, 0)
         |> assign(:group_tags, [])
         |> assign(:group_reactions, [])
         |> assign(:can_react_to_group, false)
         |> TagEditor.init()
         |> CreateMenu.init()
         |> CalendarState.init(params)
         |> RootMapState.init()
         |> PollForm.init()
         |> PollsState.init(params)
         |> GroupSheet.init()
         |> load_group_data(group, active_tab)
         |> sync_group_presence()}

      true ->
        {:ok,
         socket
         |> put_flash(:error, gettext("You do not have access to that group."))
         |> push_navigate(to: ~p"/groups")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    active_tab =
      normalize_active_tab(Map.get(params, "tab"), socket.assigns.group, socket.assigns.access)

    sub_groups_kind =
      normalize_sub_groups_kind(Map.get(params, "sub_groups_kind"), socket.assigns.group)

    sub_groups_view = normalize_sub_groups_view(Map.get(params, "view"), sub_groups_kind)
    description_param = Map.get(params, "d")
    socket = assign(socket, :share_id, parse_share_id(Map.get(params, "share")))

    cond do
      active_tab != socket.assigns.active_tab or
          sub_groups_kind != socket.assigns.sub_groups_kind ->
        {:noreply,
         socket
         |> assign(:description_param, description_param)
         |> assign(:active_tab, active_tab)
         |> assign(:focus_value_id, nil)
         |> assign(:values_has_newer?, false)
         |> assign(:sub_groups_kind, sub_groups_kind)
         |> assign(:sub_groups_view, sub_groups_view)
         |> assign(:children_pagination, default_pagination(@children_page_size))
         |> maybe_reload_edit_group_form(active_tab)
         |> assign_tab_forms(active_tab)
         |> assign_new_tab_section(active_tab)
         |> CalendarState.assign_params(params)
         |> PollsState.assign_params(params)
         |> load_group_data(socket.assigns.group, active_tab)}

      active_tab == "calendar" and CalendarState.params_changed?(socket, params) ->
        {:noreply, CalendarState.handle_params(socket, params)}

      active_tab == "polls" and PollsState.params_changed?(socket, params) ->
        {:noreply, PollsState.handle_params(socket, params)}

      sub_groups_view != socket.assigns.sub_groups_view ->
        {:noreply,
         socket
         |> assign(:sub_groups_view, sub_groups_view)
         |> assign(:children_pagination, default_pagination(@children_page_size))
         |> reload_children()}

      description_param != socket.assigns.description_param ->
        {:noreply,
         socket
         |> assign(:description_param, description_param)
         |> put_active_alt_description()}

      true ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("calendar_" <> _ = event, params, socket),
    do: CalendarState.handle_event(event, params, socket)

  def handle_event("poll_form_" <> _ = event, params, socket),
    do: PollForm.handle_event(event, params, socket)

  def handle_event("root_map_" <> _ = event, params, socket),
    do: RootMapState.handle_event(event, params, socket)

  def handle_event("group_sheet_close", _params, socket),
    do: {:noreply, GroupSheet.close(socket)}

  def handle_event("poll" <> _ = event, params, socket),
    do: PollsState.handle_event(event, params, socket)

  def handle_event("tag_editor_" <> _ = event, params, socket),
    do: TagEditor.handle_event(event, params, socket)

  def handle_event("group_create_menu_" <> _ = event, params, socket),
    do: CreateMenu.handle_event(event, params, socket)

  def handle_event("validate_value", %{"value" => attrs}, socket) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    attrs =
      attrs
      |> Map.put_new("creator_id", current_profile.id)
      |> Map.put_new("group_id", group.id)

    changeset =
      %Value{}
      |> Value.changeset_for_update(attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :new_value_form, to_form(changeset))}
  end

  def handle_event("create_value", %{"value" => attrs}, socket) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    if not Access.can_read_chat?(socket.assigns.access, group) do
      {:noreply,
       put_flash(socket, :error, gettext("You must be a group member to post messages."))}
    else
      # The chat composer only posts chat values; app data goes through `app_api`.
      # The replied-to value comes from the server-side reply state, never the form.
      attrs =
        attrs
        |> Map.drop(["is_data", "data", "parent_id"])
        |> maybe_put_reply_parent(socket.assigns.replying_to_value)

      with {:ok, attachments} <- consume_attachments(socket),
           {:ok, value} <- create_value_or_drop_files(current_profile, group, attrs, attachments) do
        socket =
          socket
          |> assign(:active_tab, "values")
          |> assign(:replying_to_value, nil)
          |> assign(:new_value_form, empty_new_value_form())
          |> push_event("value_composer_reset", %{})
          |> apply_value_created(value)

        {:noreply, socket}
      else
        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, assign(socket, :new_value_form, to_form(changeset))}

        {:error, :not_permitted} ->
          {:noreply, put_flash(socket, :error, access_error_message(:not_permitted))}

        {:error, :too_many_attachments} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Attach at most %{count} files.", count: Storage.max_files())
           )}

        {:error, :too_many_values} ->
          {:noreply, put_flash(socket, :error, too_many_values_message())}

        {:error, message} when is_binary(message) ->
          {:noreply, put_flash(socket, :error, message)}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Could not create message."))}
      end
    end
  end

  # A picture for a template's field starts uploading as soon as it is picked.
  def handle_event("validate_description_picture", _params, socket), do: {:noreply, socket}

  # A file the app's frame sends goes up on its own (`AppHost`).
  def handle_event("validate_app_file", _params, socket),
    do: {:noreply, AppHost.validate_file(socket)}

  def handle_event("description_picture_invalid", _params, socket) do
    {:noreply, put_flash(socket, :error, gettext("Choose a valid image file."))}
  end

  # What the keyboard sends uploads by itself; all that is left here is a file
  # the upload would not take.
  def handle_event("validate_keyboard_media", _params, socket) do
    rejected = Enum.reject(socket.assigns.uploads.keyboard_media.entries, & &1.valid?)
    socket = Enum.reduce(rejected, socket, &cancel_upload(&2, :keyboard_media, &1.ref))

    {:noreply, if(rejected == [], do: socket, else: put_keyboard_media_error(socket))}
  end

  def handle_event("keyboard_media_failed", _params, socket),
    do: {:noreply, put_keyboard_media_error(socket)}

  def handle_event("keyboard_media_refused", _params, socket) do
    %{current_profile: profile, group: group, access: access} = socket.assigns

    message =
      if can_send_keyboard_media?(profile, group, access),
        do: gettext("Pictures from the keyboard go out from the message field."),
        else: gettext("You cannot send pictures in this group.")

    {:noreply, put_flash(socket, :error, message)}
  end

  def handle_event("cancel_attachment", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :attachments, ref)}
  end

  # Shared files the `ShareComposer` hook left out of the composer, by reason.
  def handle_event("share_files_skipped", params, socket) do
    too_large = skipped_share_names(params["too_large"])
    too_many = skipped_share_names(params["too_many"])
    not_allowed = skipped_share_names(params["not_allowed"])
    failed = skipped_share_names(params["failed"])

    message =
      [
        too_large != "" &&
          gettext("Larger than %{size}: %{names}.",
            size: Components.format_bytes(Storage.max_file_size()),
            names: too_large
          ),
        too_many != "" &&
          gettext("Only %{count} files fit in a message: %{names} left out.",
            count: Storage.max_files(),
            names: too_many
          ),
        not_allowed != "" &&
          gettext("You cannot attach files in this group: %{names} left out.",
            names: not_allowed
          ),
        failed != "" && gettext("Could not read %{names}.", names: failed)
      ]
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")

    {:noreply, if(message == "", do: socket, else: put_flash(socket, :error, message))}
  end

  # The shared content is posted (or no longer on the device): drop `?share`.
  def handle_event("share_done", _params, socket) do
    {:noreply,
     push_patch(socket, to: ~p"/groups/#{socket.assigns.group.id}/#{socket.assigns.active_tab}")}
  end

  def handle_event("set_files_view", %{"view" => view}, socket) when view in ["list", "tree"] do
    {:noreply,
     socket
     |> assign(:files_view, view)
     |> assign(:files_loaded_count, 0)
     |> maybe_load_files(socket.assigns.group, socket.assigns.active_tab)}
  end

  def handle_event("load_more_files", _params, socket) do
    {:noreply, load_more_files(socket)}
  end

  # Single entry point for the sandboxed app frame (see `AppApi`). The client
  # hook only forwards whitelisted methods; the server checks them again.
  def handle_event("app_api", %{"method" => method} = params, socket) when is_binary(method) do
    {reply, socket} =
      AppApi.call(method, Map.get(params, "params") || %{}, Map.get(params, "app_id"), socket)

    {:reply, reply, socket}
  end

  def handle_event("app_api", _params, socket) do
    {:reply, %{ok: false, error: "unknown_method"}, socket}
  end

  def handle_event("start_edit_value", %{"id" => id}, socket) do
    current_profile = socket.assigns.current_profile
    previous_editing_value = socket.assigns.editing_value

    case loaded_value(socket, id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Message not found."))}

      value when value.creator_id != current_profile.id ->
        {:noreply, put_flash(socket, :error, gettext("You can only edit your own messages."))}

      value ->
        # Re-insert both items so their edit buttons reflect the new editing state.
        {:noreply,
         socket
         |> assign(:replying_to_value, nil)
         |> assign(:editing_value, value)
         |> assign(:edit_value_form, to_form(Value.changeset(value, %{})))
         |> restream_value(previous_editing_value)
         |> restream_value(value)}
    end
  end

  def handle_event("validate_edit_value", %{"value" => attrs}, socket) do
    case socket.assigns.editing_value do
      nil ->
        {:noreply, socket}

      value ->
        changeset =
          value
          |> Value.changeset(attrs)
          |> Map.put(:action, :validate)

        {:noreply, assign(socket, :edit_value_form, to_form(changeset))}
    end
  end

  def handle_event("save_edit_value", %{"value" => attrs}, socket) do
    current_profile = socket.assigns.current_profile

    case socket.assigns.editing_value do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Message not found."))}

      value ->
        case Social.update_value(current_profile, value, attrs) do
          {:ok, updated_value} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Message updated."))
             |> assign(:editing_value, nil)
             |> assign(:edit_value_form, nil)
             |> apply_value_updated(updated_value)}

          {:error, :not_value_creator} ->
            {:noreply, put_flash(socket, :error, gettext("You can only edit your own messages."))}

          {:error, :too_many_values} ->
            {:noreply, put_flash(socket, :error, too_many_values_message())}

          {:error, %Ecto.Changeset{} = changeset} ->
            {:noreply,
             assign(socket, :edit_value_form, to_form(Map.put(changeset, :action, :validate)))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Could not update message."))}
        end
    end
  end

  def handle_event("cancel_edit_value", _params, socket) do
    {:noreply, clear_edit_value(socket)}
  end

  # Inline reply: the composer shows the value and the next post quotes it.
  def handle_event("start_reply_value", %{"id" => id}, socket) do
    %{access: access, group: group, current_profile: current_profile} = socket.assigns

    cond do
      not Access.can_read_chat?(access, group) ->
        {:noreply,
         put_flash(socket, :error, gettext("You must be a group member to post messages."))}

      not Access.can_post_in_chat?(current_profile, access, group) ->
        {:noreply, put_flash(socket, :error, access_error_message(:not_permitted))}

      value = replyable_value(socket, id) ->
        {:noreply,
         socket
         |> clear_edit_value()
         |> assign(:replying_to_value, value)
         |> push_event("value_composer_focus", %{})}

      true ->
        {:noreply, put_flash(socket, :error, gettext("Message not found."))}
    end
  end

  def handle_event("cancel_reply_value", _params, socket) do
    {:noreply, assign(socket, :replying_to_value, nil)}
  end

  # In-thread reply: opens (creating on first use) the value's thread group.
  def handle_event("open_value_thread", %{"id" => id}, socket) do
    with true <- socket.assigns.is_member,
         %Value{} = value <- loaded_value(socket, id),
         {:ok, thread} <-
           Social.get_or_create_value_thread(
             socket.assigns.current_profile,
             socket.assigns.group,
             value,
             %{"name" => Value.excerpt(value, 60) || gettext("Thread")}
           ) do
      {:noreply, push_navigate(socket, to: ~p"/groups/#{thread.id}/values")}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not open thread."))}
    end
  end

  def handle_event("delete_value", %{"id" => id}, socket) do
    current_profile = socket.assigns.current_profile

    case loaded_value(socket, id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Message not found."))}

      value ->
        case Social.delete_value(current_profile, value) do
          {:ok, _deleted_value} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Message deleted."))
             |> remove_value(value.id)}

          {:error, :not_value_creator} ->
            {:noreply,
             put_flash(socket, :error, gettext("You can only delete your own messages."))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Could not delete message."))}
        end
    end
  end

  # Sent by the reaction pills (`phx-click`) and by the emoji picker hook.
  def handle_event("toggle_reaction", %{"id" => id, "emoji" => emoji}, socket) do
    if not Access.can_read_chat?(socket.assigns.access, socket.assigns.group) do
      {:noreply, put_flash(socket, :error, gettext("You must be a group member to react."))}
    else
      case loaded_value(socket, id) do
        nil ->
          {:noreply, put_flash(socket, :error, gettext("Message not found."))}

        value ->
          case Social.toggle_value_reaction(
                 socket.assigns.current_profile,
                 socket.assigns.group,
                 value,
                 emoji
               ) do
            {:ok, updated_value} ->
              {:noreply, apply_value_updated(socket, updated_value)}

            {:error, _reason} ->
              {:noreply, put_flash(socket, :error, gettext("Could not update reaction."))}
          end
      end
    end
  end

  # Sent by the reaction pills under a description and by the emoji picker hook.
  def handle_event("toggle_group_reaction", %{"emoji" => emoji}, socket) do
    %{current_profile: profile, group: group} = socket.assigns

    case profile && Social.toggle_group_reaction(profile, group, emoji) do
      {:ok, reactions} ->
        {:noreply, assign(socket, :group_reactions, reactions)}

      _refused ->
        {:noreply, put_flash(socket, :error, gettext("Could not update reaction."))}
    end
  end

  def handle_event("dismiss_link_preview", %{"id" => id}, socket) do
    case loaded_value(socket, id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Message not found."))}

      value ->
        case Social.dismiss_value_link_preview(socket.assigns.current_profile, value) do
          {:ok, updated_value} ->
            {:noreply, apply_value_updated(socket, updated_value)}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Could not remove the preview."))}
        end
    end
  end

  def handle_event("switch_tab", %{"tab" => "group_home"}, socket) do
    {:noreply,
     redirect(
       socket,
       to:
         group_tab_path(
           socket.assigns.group,
           normalize_active_tab("group_home", socket.assigns.group, socket.assigns.access),
           sub_groups_kind: socket.assigns.sub_groups_kind,
           sub_groups_view: socket.assigns.sub_groups_view
         )
     )}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply,
     push_patch(
       socket,
       to:
         group_tab_path(
           socket.assigns.group,
           normalize_active_tab(tab, socket.assigns.group, socket.assigns.access),
           sub_groups_kind: socket.assigns.sub_groups_kind,
           sub_groups_view: socket.assigns.sub_groups_view
         )
     )}
  end

  def handle_event("set_sub_groups_view", %{"view" => view}, socket)
      when view in ["list", "tree"] do
    {:noreply,
     push_patch(socket,
       to:
         group_tab_path(socket.assigns.group, socket.assigns.active_tab,
           sub_groups_kind: socket.assigns.sub_groups_kind,
           sub_groups_view: view
         )
     )}
  end

  def handle_event("load_more_children", _params, socket) do
    {:noreply, load_more_children(socket)}
  end

  def handle_event("toggle_sub_group_folder", %{"id" => id}, socket) do
    case Integer.parse(id) do
      {group_id, ""} ->
        profile = socket.assigns.current_profile
        {:noreply, update_sub_group_tree(socket, &SubGroupTree.toggle(&1, group_id, profile))}

      _invalid ->
        {:noreply, socket}
    end
  end

  # Without an id, the next page of the top level.
  def handle_event("load_more_sub_group_folders", params, socket) do
    profile = socket.assigns.current_profile

    case Integer.parse(Map.get(params, "id", "")) do
      {group_id, ""} ->
        {:noreply, update_sub_group_tree(socket, &SubGroupTree.load_more(&1, group_id, profile))}

      _top_level ->
        {:noreply, update_sub_group_tree(socket, &SubGroupTree.load_more(&1, nil, profile))}
    end
  end

  def handle_event("search_children", %{"children_search" => %{"q" => query}}, socket) do
    next_query = normalize_children_search_query(query)

    if next_query == socket.assigns.children_search_query do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:children_search_query, next_query)
       |> assign(:children_pagination, default_pagination(@children_page_size))
       |> reload_children()}
    end
  end

  def handle_event("search_children", _params, socket), do: {:noreply, socket}

  def handle_event("clear_children_search", _params, socket) do
    {:noreply,
     socket
     |> assign(:children_search_query, "")
     |> assign(:children_pagination, default_pagination(@children_page_size))
     |> reload_children()}
  end

  # One kind at a time, or all of them (""). Like the search, it holds only
  # while the viewer stays on the group.
  def handle_event("filter_children_preset", %{"preset" => preset}, socket) do
    next_preset = if preset in GroupPresets.filter_keys(), do: preset

    if next_preset == socket.assigns.children_preset do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:children_preset, next_preset)
       |> assign(:children_pagination, default_pagination(@children_page_size))
       |> reload_children()}
    end
  end

  def handle_event("filter_children_preset", _params, socket), do: {:noreply, socket}

  # The viewer's memberships ("member"), its own groups ("creator"), or all
  # (""). It holds as long as the kind does.
  def handle_event("filter_children_relation", %{"relation" => relation}, socket) do
    next_relation = if relation in Social.child_group_relations(), do: relation

    if next_relation == socket.assigns.children_relation do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:children_relation, next_relation)
       |> assign(:children_pagination, default_pagination(@children_page_size))
       |> reload_children()}
    end
  end

  def handle_event("filter_children_relation", _params, socket), do: {:noreply, socket}

  # Takes off the kind and the membership filters; the search keeps its own reset.
  def handle_event("clear_children_filters", _params, socket) do
    {:noreply,
     socket
     |> assign(:children_preset, nil)
     |> assign(:children_relation, nil)
     |> assign(:children_pagination, default_pagination(@children_page_size))
     |> reload_children()}
  end

  # The browser keeps the choice for the next pages (`show_threads` in app.js).
  def handle_event("toggle_thread_sub_groups", _params, socket) do
    show? = not socket.assigns.show_thread_sub_groups

    {:noreply,
     socket
     |> assign(:show_thread_sub_groups, show?)
     |> assign(:children_pagination, default_pagination(@children_page_size))
     |> reload_children()
     |> push_event("sub_groups_threads", %{shown: show?})}
  end

  # Only the root has this switch; the browser keeps the choice for the next
  # pages (`show_public_groups` in app.js).
  def handle_event(
        "toggle_public_sub_groups",
        _params,
        %{assigns: %{group: %Group{is_root: true}}} = socket
      ) do
    show? = not socket.assigns.show_public_sub_groups

    {:noreply,
     socket
     |> assign(:show_public_sub_groups, show?)
     |> assign(:children_pagination, default_pagination(@children_page_size))
     |> reload_children()
     |> push_event("sub_groups_public", %{shown: show?})}
  end

  def handle_event("toggle_public_sub_groups", _params, socket), do: {:noreply, socket}

  def handle_event("switch_sub_groups_kind", %{"kind" => kind}, socket) do
    next_kind = normalize_sub_groups_kind(kind, socket.assigns.group)

    if next_kind == socket.assigns.sub_groups_kind do
      {:noreply, socket}
    else
      {:noreply,
       push_patch(socket,
         to:
           group_tab_path(socket.assigns.group, socket.assigns.active_tab,
             sub_groups_kind: next_kind,
             sub_groups_view: socket.assigns.sub_groups_view
           )
       )}
    end
  end

  def handle_event("load_more_members", _params, socket) do
    {:noreply, load_more_members(socket)}
  end

  def handle_event("request_join", _params, socket) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    case Social.request_group_access(current_profile, group) do
      {:ok, _request} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Access request sent."))
         |> refresh_group_data()}

      {:error, :group_not_public} ->
        {:noreply,
         put_flash(socket, :error, gettext("Only public groups accept access requests."))}

      {:error, :already_a_member} ->
        {:noreply, put_flash(socket, :error, gettext("You are already a group member."))}

      {:error, :already_invited} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("You already have a pending invitation to this group.")
         )}

      {:error, :blocked} ->
        {:noreply, put_flash(socket, :error, gettext("You are blocked in this group."))}

      {:error, %Ecto.Changeset{}} ->
        {:noreply, put_flash(socket, :error, gettext("Access request already pending."))}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not send access request."))}
    end
  end

  # The author of a value in an open chat: a member goes with the block.
  def handle_event("block_value_author", %{"id" => id}, socket) do
    %{current_profile: current_profile, group: group} = socket.assigns

    case loaded_value(socket, id) do
      nil ->
        {:noreply, put_flash(socket, :error, gettext("Message not found."))}

      value ->
        case Social.block_from_group(current_profile, group, value.creator) do
          {:ok, _block} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Blocked in this group."))
             |> refresh_group_data()}

          {:error, reason} when reason in [:not_permitted, :last_admin, :inherited_member] ->
            {:noreply, put_flash(socket, :error, access_error_message(reason))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Could not block."))}
        end
    end
  end

  def handle_event("unblock_profile", %{"id" => id}, socket) do
    %{current_profile: current_profile, group: group} = socket.assigns

    with {profile_id, ""} <- Integer.parse(id),
         :ok <- Social.unblock_from_group(current_profile, group, profile_id) do
      {:noreply,
       socket
       |> put_flash(:info, gettext("Block removed."))
       |> refresh_group_data()}
    else
      _ -> {:noreply, put_flash(socket, :error, gettext("Could not remove the block."))}
    end
  end

  def handle_event("remove_member", %{"id" => id}, socket) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    case Integer.parse(id) do
      {member_id, ""} ->
        case Social.remove_group_member(current_profile, group, member_id) do
          {:ok, _member} ->
            {:noreply,
             socket
             |> put_flash(:info, gettext("Member removed."))
             |> refresh_group_data()}

          {:error, reason}
          when reason in [:not_permitted, :last_admin, :direct_group, :inherited_member] ->
            {:noreply, put_flash(socket, :error, access_error_message(reason))}

          {:error, :not_a_group_member} ->
            {:noreply, put_flash(socket, :error, gettext("That profile is not a group member."))}

          {:error, :member_not_found} ->
            {:noreply, put_flash(socket, :error, gettext("Profile not found."))}

          {:error, :cannot_remove_root_group_members} ->
            {:noreply,
             put_flash(socket, :error, gettext("Root group members cannot be removed."))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Could not remove member."))}
        end

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Profile not found."))}
    end
  end

  def handle_event("accept_join_request", %{"id" => id}, socket) do
    handle_join_request_action(
      socket,
      id,
      &Social.accept_group_join_request/3,
      gettext("Access request accepted.")
    )
  end

  def handle_event("reject_join_request", %{"id" => id}, socket) do
    handle_join_request_action(
      socket,
      id,
      &Social.reject_group_join_request/3,
      gettext("Access request rejected.")
    )
  end

  def handle_event("load_more_values", _params, socket) do
    {:noreply, load_more_values(socket)}
  end

  def handle_event("load_newer_values", _params, socket) do
    {:noreply, load_newer_values(socket)}
  end

  # A reply quote whose value is not in the feed: the chat reloads around it.
  def handle_event("show_value", %{"id" => id}, socket) do
    with true <- needs_values?(socket.assigns.group, socket.assigns.active_tab),
         {value_id, ""} <- Integer.parse(to_string(id)) do
      if MapSet.member?(socket.assigns.loaded_value_ids, value_id) do
        {:noreply, push_event(socket, "show_value", %{id: value_id})}
      else
        case load_values_around(socket, value_id) do
          {:ok, socket} ->
            {:noreply,
             socket
             |> assign(:focus_value_id, nil)
             |> push_event("show_value", %{id: value_id})}

          :error ->
            {:noreply,
             put_flash(socket, :error, gettext("The original message is no longer available."))}
        end
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_event("jump_to_latest_values", _params, socket) do
    if needs_values?(socket.assigns.group, socket.assigns.active_tab) do
      {:noreply,
       socket
       |> assign(:focus_value_id, nil)
       |> load_latest_values(socket.assigns.group)
       |> push_event("scroll_values_to_latest", %{force: true})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("validate_group", %{"group" => attrs}, socket) do
    current_profile = socket.assigns.current_profile
    parent = socket.assigns.group

    attrs =
      attrs
      |> Map.put_new("creator_id", current_profile.id)
      |> Map.put_new("parent_id", parent.id)
      |> Map.put_new("is_root", false)

    changeset =
      %Group{}
      |> Group.changeset(attrs)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, :new_group_form, to_form(changeset))}
  end

  def handle_event("create_group", %{"group" => attrs}, socket) do
    current_profile = socket.assigns.current_profile
    parent = socket.assigns.group

    if not Access.can?(socket.assigns.access, :create_subgroups) do
      {:noreply,
       put_flash(socket, :error, gettext("You must be a group member to create sub-groups."))}
    else
      attrs =
        attrs
        |> normalize_select_nil("parent_value_id")
        |> Map.put("is_root", false)

      case Social.create_group(current_profile, parent, attrs) do
        {:ok, child} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Group created."))
           |> push_navigate(to: ~p"/groups/#{child.id}")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply,
           socket
           |> assign(:new_group_form, to_form(changeset))
           |> assign(
             :create_group_section,
             group_form_error_section(changeset) || socket.assigns.create_group_section
           )}

        {:error, :not_permitted} ->
          {:noreply, put_flash(socket, :error, access_error_message(:not_permitted))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Could not create group."))}
      end
    end
  end

  # Changes are taken against the group the form was built from, which has
  # its picture loaded, so an untouched picture is no change and the save
  # bar only shows for real edits.
  def handle_event("validate_edit_group", %{"group" => attrs} = params, socket) do
    if Access.can?(socket.assigns.access, :edit_group) do
      group = edit_group_data(socket)
      template = params["description_template"]
      {attrs, _missing} = PostTemplates.Form.prepare(attrs, template, group.description)

      changeset =
        group
        |> Group.update_changeset(attrs)
        |> Map.put(:action, :validate)

      {:noreply,
       socket
       |> assign(:edit_group_form, to_form(changeset))
       |> close_template_list(template)}
    else
      {:noreply, put_flash(socket, :error, access_error_message(:not_permitted))}
    end
  end

  def handle_event("set_edit_group_section", %{"section" => section}, socket)
      when section in @edit_group_sections,
      do: {:noreply, assign(socket, :edit_group_section, section)}

  def handle_event("set_edit_group_section", _params, socket), do: {:noreply, socket}

  def handle_event("set_create_group_section", %{"section" => section}, socket)
      when section in @create_group_sections,
      do: {:noreply, assign(socket, :create_group_section, section)}

  def handle_event("set_create_group_section", _params, socket), do: {:noreply, socket}

  def handle_event("discard_edit_group", _params, socket) do
    with_edit_group(socket, fn socket ->
      assign(socket, :edit_group_form, edit_group_form(socket.assigns.group, "edit_group"))
    end)
  end

  # Rights differ from group to group, so a row's menu is worked out when it
  # is opened. The id comes from the page, so the group has to be one the
  # viewer can see.
  def handle_event("group_row_menu_open", %{"id" => id}, socket) do
    profile = socket.assigns.current_profile

    with %Profile{} <- profile,
         {group_id, ""} <- Integer.parse(to_string(id)),
         %Group{} = group <- Social.get_visible_group(profile, group_id) do
      access = Social.get_group_access(profile, group)

      sections =
        GroupMenu.sections(group, access.member?, %{
          calendar?: calendar_tab?(group, access),
          polls?: polls_section?(group, access)
        })

      menu = %{group: group, access: access, sections: sections}

      {:noreply, assign(socket, :group_row_menu, menu)}
    else
      _invisible -> {:noreply, socket}
    end
  end

  def handle_event("group_row_menu_close", _params, socket),
    do: {:noreply, assign(socket, :group_row_menu, nil)}

  def handle_event("toggle_template_list", %{"workspace" => workspace}, socket) do
    open = if socket.assigns.template_list != workspace, do: workspace
    {:noreply, assign(socket, :template_list, open)}
  end

  def handle_event("save_edit_group", %{"group" => attrs} = params, socket) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    {attrs, missing} =
      PostTemplates.Form.prepare(
        attrs,
        params["description_template"],
        edit_group_data(socket).description
      )

    cond do
      not Access.can?(socket.assigns.access, :edit_group) ->
        {:noreply, put_flash(socket, :error, access_error_message(:not_permitted))}

      missing != [] ->
        {:noreply, refuse_edit_group(socket, attrs, missing)}

      true ->
        save_edit_group(socket, current_profile, group, attrs)
    end
  end

  def handle_event("delete_group_data_values", _params, socket) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    if not Access.can?(socket.assigns.access, :edit_group) do
      {:noreply, put_flash(socket, :error, access_error_message(:not_permitted))}
    else
      case Social.delete_group_data_values(current_profile, group) do
        {:ok, 0} ->
          {:noreply, put_flash(socket, :info, gettext("No data values to delete."))}

        {:ok, deleted_count} ->
          {:noreply,
           socket
           |> refresh_group_data()
           |> put_flash(
             :info,
             ngettext(
               "Deleted 1 data value.",
               "Deleted %{count} data values.",
               deleted_count,
               count: deleted_count
             )
           )}

        {:error, :not_permitted} ->
          {:noreply, put_flash(socket, :error, access_error_message(:not_permitted))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Could not delete data values."))}
      end
    end
  end

  def handle_event("delete_group", _params, socket) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    if not socket.assigns.is_member do
      {:noreply,
       put_flash(socket, :error, gettext("You must be a group member to delete this group."))}
    else
      case Social.delete_group(current_profile, group) do
        {:ok, _deleted_group} ->
          {:noreply,
           socket
           |> put_flash(:info, gettext("Group deleted."))
           |> push_navigate(to: delete_group_redirect_path(group.parent_id))}

        {:error, :cannot_delete_root_group} ->
          {:noreply, put_flash(socket, :error, gettext("The root group cannot be deleted."))}

        {:error, :not_a_group_member} ->
          {:noreply,
           put_flash(socket, :error, gettext("You must be a group member to delete this group."))}

        {:error, :not_permitted} ->
          {:noreply, put_flash(socket, :error, access_error_message(:not_permitted))}

        {:error, :group_has_children} ->
          {:noreply,
           put_flash(
             socket,
             :error,
             gettext("Delete this group's sub-groups before deleting the group.")
           )}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Could not delete group."))}
      end
    end
  end

  def handle_event("new_alt_description", _params, socket) do
    with_edit_group(socket, fn socket ->
      open_alt_description_form(socket, %GroupAltDescription{})
    end)
  end

  def handle_event("edit_alt_description", %{"id" => id}, socket) do
    with_alt_description(socket, id, &open_alt_description_form/2)
  end

  def handle_event("cancel_alt_description", _params, socket) do
    {:noreply, close_alt_description_form(socket)}
  end

  def handle_event(
        "validate_alt_description",
        %{"group_alt_description" => attrs} = params,
        socket
      ) do
    case socket.assigns.editing_alt_description do
      %GroupAltDescription{} = editing ->
        template = params["description_template"]
        {attrs, _missing} = PostTemplates.Form.prepare(attrs, template, editing.description)

        changeset =
          editing
          |> Social.change_alt_description(attrs)
          |> Map.put(:action, :validate)

        {:noreply,
         socket
         |> assign(:alt_description_form, to_form(changeset))
         |> close_template_list(template)}

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("save_alt_description", %{"group_alt_description" => attrs} = params, socket) do
    editing = socket.assigns.editing_alt_description
    saved = editing && editing.description

    case PostTemplates.Form.prepare(attrs, params["description_template"], saved) do
      {attrs, missing} when missing == [] or is_nil(editing) ->
        save_alt_description(socket, editing, attrs)

      {attrs, missing} ->
        changeset =
          editing
          |> Social.change_alt_description(attrs)
          |> add_template_error(missing)
          |> Map.put(:action, :validate)

        {:noreply, assign(socket, :alt_description_form, to_form(changeset))}
    end
  end

  def handle_event("delete_alt_description", %{"id" => id}, socket) do
    with_alt_description(socket, id, fn socket, alt_description ->
      case Social.delete_alt_description(
             socket.assigns.current_profile,
             socket.assigns.group,
             alt_description
           ) do
        {:ok, _deleted} ->
          socket
          |> maybe_close_alt_description_form(alt_description)
          |> reload_alt_descriptions()
          |> put_flash(:info, gettext("Description deleted."))

        {:error, reason} ->
          put_flash(socket, :error, alt_description_error_message(reason))
      end
    end)
  end

  def handle_event("move_alt_description", %{"id" => id, "direction" => direction}, socket)
      when direction in ["up", "down"] do
    with_alt_description(socket, id, fn socket, alt_description ->
      case Social.move_alt_description(
             socket.assigns.current_profile,
             socket.assigns.group,
             alt_description,
             if(direction == "up", do: :up, else: :down)
           ) do
        {:ok, _moved} -> reload_alt_descriptions(socket)
        {:error, reason} -> put_flash(socket, :error, alt_description_error_message(reason))
      end
    end)
  end

  def handle_event("promote_alt_description", %{"id" => id}, socket) do
    with_alt_description(socket, id, fn socket, alt_description ->
      case Social.promote_alt_description(
             socket.assigns.current_profile,
             socket.assigns.group,
             alt_description,
             gettext("Description")
           ) do
        {:ok, group, _demoted} ->
          socket
          |> close_alt_description_form()
          |> assign(:group, group)
          |> assign(:edit_group_form, edit_group_form(group, "edit_group"))
          |> reload_alt_descriptions()
          |> put_flash(:info, gettext("The description is now the default."))

        {:error, reason} ->
          put_flash(socket, :error, alt_description_error_message(reason))
      end
    end)
  end

  def handle_event("delete_alt_description_data_values", %{"id" => id}, socket) do
    with_alt_description(socket, id, fn socket, alt_description ->
      case Social.delete_group_data_values(
             socket.assigns.current_profile,
             socket.assigns.group,
             alt_description
           ) do
        {:ok, 0} ->
          put_flash(socket, :info, gettext("No data values to delete."))

        {:ok, deleted_count} ->
          put_flash(
            socket,
            :info,
            ngettext(
              "Deleted 1 data value.",
              "Deleted %{count} data values.",
              deleted_count,
              count: deleted_count
            )
          )

        {:error, reason} ->
          put_flash(socket, :error, alt_description_error_message(reason))
      end
    end)
  end

  def handle_event("set_edit_group_description_open", %{"open" => open}, socket) do
    {:noreply, assign(socket, :description_details_open, open == "true")}
  end

  def handle_event(
        "suggest_invite_profiles",
        %{"invite" => %{"identifier" => identifier}},
        socket
      ) do
    identifier = String.trim(identifier || "")

    {:noreply,
     socket
     |> assign(:invite_form, invite_form(identifier))
     |> assign(
       :invite_profile_suggestions,
       invite_profile_suggestions(
         socket.assigns.current_profile,
         socket.assigns.group,
         identifier
       )
     )}
  end

  def handle_event("select_invite_profile", %{"username" => username}, socket) do
    username = String.trim(username || "")

    {:noreply,
     socket
     |> assign(:invite_form, invite_form(username))
     |> assign(:invite_profile_suggestions, [])}
  end

  def handle_event("clear_invite_profile_suggestions", _params, socket) do
    {:noreply, assign(socket, :invite_profile_suggestions, [])}
  end

  def handle_event("invite", %{"invite" => %{"identifier" => identifier}}, socket) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    if not socket.assigns.is_member do
      {:noreply, put_flash(socket, :error, gettext("You must be a member to invite."))}
    else
      identifier = String.trim(identifier || "")

      socket =
        socket
        |> assign(:invite_form, invite_form(identifier))
        |> assign(
          :invite_profile_suggestions,
          invite_profile_suggestions(current_profile, group, identifier)
        )

      account_id = socket.assigns.current_scope.account.id

      case invite_group_identifier(current_profile, account_id, group, identifier) do
        {:ok, message} ->
          {:noreply,
           socket
           |> assign(:invite_form, empty_invite_form())
           |> assign(:invite_profile_suggestions, [])
           |> update(:invite_form_version, &(&1 + 1))
           |> put_flash(:info, message)}

        {:error, :blank_identifier} ->
          {:noreply, put_flash(socket, :error, gettext("Username or email is required."))}

        {:error, :invalid_email} ->
          {:noreply, put_flash(socket, :error, gettext("Enter a valid email address."))}

        {:error, :profile_not_found} ->
          {:noreply, put_flash(socket, :error, gettext("No profile found with that username."))}

        {:error, :inviter_not_a_member} ->
          {:noreply, put_flash(socket, :error, gettext("You must be a member to invite."))}

        {:error, :cannot_invite_self} ->
          {:noreply, put_flash(socket, :error, gettext("You cannot invite yourself."))}

        {:error, :blocked} ->
          {:noreply, put_flash(socket, :error, gettext("That profile is blocked in this group."))}

        {:error, reason} when reason in [:not_permitted, :direct_group] ->
          {:noreply, put_flash(socket, :error, access_error_message(reason))}

        {:error, :rate_limited, retry_after} ->
          {:noreply, put_flash(socket, :error, RateLimited.message(retry_after))}

        {:error, %Ecto.Changeset{}} ->
          {:noreply, put_flash(socket, :error, gettext("An invitation is already pending."))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Could not send invitation."))}
      end
    end
  end

  def handle_event("invite_account", _params, socket) do
    {:noreply, push_navigate(socket, to: ~p"/accounts/register")}
  end

  # Replies to the composer's `.MentionComposer` hook.
  def handle_event("suggest_mentions", %{"query" => query}, socket) when is_binary(query) do
    items =
      socket.assigns.current_profile
      |> Social.list_mention_candidates(socket.assigns.group, query)
      |> Enum.map(&mention_candidate_payload/1)

    {:reply, %{items: items}, socket}
  end

  def handle_event("suggest_mentions", _params, socket), do: {:reply, %{items: []}, socket}

  def handle_event("validate_role", %{"group_role" => attrs}, socket) do
    form =
      %GroupRole{}
      |> Social.change_group_role(attrs)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :new_role_form, form)}
  end

  def handle_event("create_role", %{"group_role" => attrs}, socket) do
    case Social.create_group_role(socket.assigns.current_profile, socket.assigns.group, attrs) do
      {:ok, role} ->
        {:noreply,
         socket
         |> assign(:new_role_form, empty_new_role_form())
         |> put_flash(:info, gettext("Role %{name} added.", name: role.name))
         |> reload_access()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :new_role_form, to_form(Map.put(changeset, :action, :insert)))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, access_error_message(reason))}
    end
  end

  def handle_event("rename_role", %{"role" => %{"key" => key} = attrs}, socket) do
    case Social.rename_group_role(
           socket.assigns.current_profile,
           socket.assigns.group,
           key,
           attrs
         ) do
      {:ok, _role} ->
        {:noreply, socket |> put_flash(:info, gettext("Role renamed.")) |> reload_access()}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, changeset_error_message(changeset))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, access_error_message(reason))}
    end
  end

  def handle_event("delete_role", %{"key" => key}, socket) do
    case Social.delete_group_role(socket.assigns.current_profile, socket.assigns.group, key) do
      {:ok, role} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("Role %{name} deleted.", name: role.name))
         |> reload_access()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, access_error_message(reason))}
    end
  end

  def handle_event(
        "set_role_permission",
        %{"key" => key, "permission" => permission, "state" => state},
        socket
      ) do
    with permission when not is_nil(permission) <- parse_permission(permission),
         state when not is_nil(state) <- parse_permission_state(state),
         {:ok, _role} <-
           Social.set_group_role_permission(
             socket.assigns.current_profile,
             socket.assigns.group,
             key,
             permission,
             state
           ) do
      {:noreply, reload_access(socket)}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, access_error_message(reason))}
      _ -> {:noreply, put_flash(socket, :error, access_error_message(:invalid_permission))}
    end
  end

  def handle_event("create_own_manifest", _params, socket) do
    case Social.create_own_group_manifest(socket.assigns.current_profile, socket.assigns.group) do
      {:ok, _manifest} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("This group now has its own manifest."))
         |> reload_access()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, access_error_message(reason))}
    end
  end

  def handle_event("revert_manifest", _params, socket) do
    case Social.revert_to_inherited_group_manifest(
           socket.assigns.current_profile,
           socket.assigns.group
         ) do
      {:ok, _manifest} ->
        {:noreply,
         socket
         |> put_flash(:info, gettext("This group uses its parent's roles again."))
         |> reload_access()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, access_error_message(reason))}
    end
  end

  def handle_event("toggle_member_role", %{"profile-id" => profile_id, "key" => key}, socket) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    with {profile_id, ""} <- Integer.parse(profile_id),
         :ok <- toggle_member_role(current_profile, group, profile_id, key) do
      {:noreply, socket |> reload_access() |> restream_member(profile_id)}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, access_error_message(reason))}
      _ -> {:noreply, put_flash(socket, :error, gettext("Profile not found."))}
    end
  end

  defp toggle_member_role(current_profile, group, profile_id, key) do
    role_keys = Map.get(Access.role_keys_by_profile(group, [profile_id]), profile_id, [])

    result =
      if key in role_keys,
        do: Social.unassign_group_member_role(current_profile, group, profile_id, key),
        else: Social.assign_group_member_role(current_profile, group, profile_id, key)

    case result do
      {:ok, _member_role} -> :ok
      other -> other
    end
  end

  @impl true
  def handle_info({:group_updated, _group_id}, %{assigns: %{current_profile: nil}} = socket) do
    {:noreply, socket}
  end

  def handle_info({:group_updated, group_id}, socket) when socket.assigns.group.id == group_id do
    {:noreply, schedule_refresh(socket, :group)}
  end

  def handle_info({:group_updated, _group_id}, socket), do: {:noreply, socket}

  # A sub-group of this group was created, changed or deleted
  # (`Social.broadcast_child_group_changed/3`): only a list that shows it, or
  # could now, is read again.
  def handle_info({:child_group_changed, group_id, child}, socket)
      when socket.assigns.group.id == group_id and not is_nil(socket.assigns.current_profile) do
    socket = tell_app_children_changed(socket)

    if child_on_list?(socket, child),
      do: {:noreply, schedule_refresh(socket, :children)},
      else: {:noreply, socket}
  end

  def handle_info({:child_group_changed, _group_id, _child}, socket), do: {:noreply, socket}

  # The sheet over the app lost its group: deleted, or no longer the viewer's to see.
  def handle_info({:group_sheet_gone, group_id}, socket),
    do: {:noreply, GroupSheet.gone(socket, group_id)}

  def handle_info({:group_reactions_updated, group_id}, socket)
      when socket.assigns.group.id == group_id do
    {:noreply, schedule_refresh(socket, :group_reactions)}
  end

  def handle_info({:group_reactions_updated, _group_id}, socket), do: {:noreply, socket}

  # A manifest or role assignment changed: permissions are recomputed with the
  # group reload, which also re-renders streamed values and members.
  def handle_info(
        {:group_roles_updated, _group_id},
        %{assigns: %{current_profile: nil}} = socket
      ),
      do: {:noreply, socket}

  def handle_info({:group_roles_updated, group_id}, socket)
      when socket.assigns.group.id == group_id do
    {:noreply, schedule_refresh(socket, :group)}
  end

  def handle_info({:group_roles_updated, _group_id}, socket), do: {:noreply, socket}

  def handle_info({:group_description_updated, group_id}, socket)
      when socket.assigns.group.id == group_id do
    {:noreply, assign(socket, :group, Social.get_group!(group_id))}
  end

  def handle_info({:group_description_updated, _group_id}, socket), do: {:noreply, socket}

  # The group too: a promotion swaps its description and deleting the home
  # description clears its pointer.
  def handle_info({:alt_descriptions_updated, group_id}, socket)
      when socket.assigns.group.id == group_id do
    {:noreply,
     socket
     |> assign(:group, Social.get_group!(group_id))
     |> reload_alt_descriptions()}
  end

  def handle_info({:alt_descriptions_updated, _group_id}, socket), do: {:noreply, socket}

  def handle_info(:flush_refresh, socket) do
    {:noreply, flush_refresh(socket)}
  end

  def handle_info(:flush_read_marker, socket) do
    {:noreply, socket |> put_private(:read_marker_scheduled?, false) |> flush_read_marker()}
  end

  def handle_info({:calendar, message}, socket), do: CalendarState.handle_info(message, socket)

  def handle_info({:polls, message}, socket) do
    {:noreply, socket} = PollsState.handle_info(message, socket)
    {:noreply, refresh_polls_section(socket, message)}
  end

  # From the tag editor, or a public tag changed by another member.
  def handle_info({:tags_changed, kind, item_id}, socket) do
    {:noreply,
     socket
     |> apply_tags_changed(kind, item_id)
     |> TagEditor.refresh(kind, item_id)}
  end

  def handle_info({:value_created, group_id, %Value{} = value}, socket)
      when socket.assigns.group.id == group_id do
    {:noreply, apply_value_created(socket, value)}
  end

  def handle_info({:value_created, _group_id, _value}, socket), do: {:noreply, socket}

  def handle_info({:data_value_created, group_id, %Value{} = value}, socket)
      when socket.assigns.group.id == group_id do
    {:noreply, AppHost.announce_new_data_value(socket, value)}
  end

  def handle_info({:data_value_created, _group_id, _value}, socket), do: {:noreply, socket}

  def handle_info({:app_value, group_id, event, payload}, socket)
      when socket.assigns.group.id == group_id do
    {:noreply, AppValues.announce(socket, event, payload)}
  end

  def handle_info({:app_value, _group_id, _event, _payload}, socket), do: {:noreply, socket}

  def handle_info({:value_updated, group_id, %Value{} = value}, socket)
      when socket.assigns.group.id == group_id do
    {:noreply, apply_value_updated(socket, value)}
  end

  def handle_info({:value_updated, _group_id, _value}, socket), do: {:noreply, socket}

  def handle_info({:value_deleted, group_id, value_id}, socket)
      when socket.assigns.group.id == group_id do
    {:noreply, apply_value_deleted(socket, value_id)}
  end

  def handle_info({:value_deleted, _group_id, _value_id}, socket), do: {:noreply, socket}

  def handle_info({:group_deleted, group_id, parent_id}, socket)
      when socket.assigns.group.id == group_id do
    {:noreply,
     socket
     |> put_flash(:info, gettext("Group deleted."))
     |> push_navigate(to: delete_group_redirect_path(parent_id))}
  end

  def handle_info({:group_deleted, _group_id, _parent_id}, socket), do: {:noreply, socket}

  def handle_info({:presence_changed, topic, key, online?}, socket) do
    with true <- topic == Social.group_presence_topic(socket.assigns.group),
         {profile_id, ""} <- Integer.parse(key) do
      {:noreply, apply_presence_change(socket, profile_id, online?)}
    else
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:profile_invitations_updated, _profile_id}, socket), do: {:noreply, socket}

  def handle_info({:profile_share_invitations_updated, _profile_id}, socket),
    do: {:noreply, socket}

  def handle_info({:pending_invitations_count_updated, _profile_id, _count}, socket),
    do: {:noreply, socket}

  def handle_info({:profile_group_join_requests_updated, _profile_id}, socket),
    do: {:noreply, socket}

  def handle_info({:pending_group_join_requests_count_updated, _profile_id, _count}, socket),
    do: {:noreply, socket}

  def handle_info({:email, _email}, socket), do: {:noreply, socket}

  def handle_info(
        {:group_unread_counts_updated, profile_id, _group_id},
        %{assigns: %{current_profile: %{id: current_profile_id}}} = socket
      )
      when profile_id == current_profile_id do
    {:noreply, schedule_refresh(socket, :unread)}
  end

  def handle_info({:group_unread_counts_updated, _profile_id, _group_id}, socket),
    do: {:noreply, socket}

  def handle_info({:group_members_unread_changed, _group_id}, socket),
    do: {:noreply, schedule_refresh(socket, :unread)}

  def handle_info({:group_value_unread, unread}, socket) do
    {:noreply,
     socket
     |> update(:pending_unread_values, &[unread | &1])
     |> schedule_refresh(:unread_values)}
  end

  def handle_info({:account_profiles_updated, account_id}, socket)
      when socket.assigns.current_scope.account.id == account_id do
    ProfileAuth.handle_current_profile_change(
      socket,
      fn socket, current_profile ->
        group = Social.get_group!(socket.assigns.group.id)
        access = Social.get_group_access(current_profile, group)

        if can_view_group?(group, access.member?) do
          {:noreply,
           socket
           |> assign_access(access)
           |> load_group_data(group)
           |> sync_group_presence()}
        else
          {:noreply,
           socket
           |> put_flash(:error, gettext("You do not have access to that group."))
           |> push_navigate(to: ~p"/groups")}
        end
      end,
      fn socket ->
        {:noreply, push_navigate(socket, to: ~p"/profiles")}
      end
    )
  end

  def handle_info({:account_profiles_updated, _account_id}, socket), do: {:noreply, socket}

  # Leaving the page (navigation or a closed tab) writes the read marker the
  # page still holds.
  @impl true
  def terminate(_reason, socket) do
    flush_read_marker(socket)
    :ok
  end

  defp load_group_data(socket, group, active_tab \\ nil) do
    active_tab =
      active_tab ||
        normalize_active_tab(Map.get(socket.assigns, :active_tab), group, socket.assigns.access)

    sub_groups_kind =
      socket.assigns
      |> Map.get(:sub_groups_kind, normalize_sub_groups_kind(nil, group))
      |> normalize_sub_groups_kind(group)

    socket =
      socket
      |> assign_group_path(group)
      |> assign(:group, group)
      |> assign(:active_tab, active_tab)
      |> assign(:calendar_tab?, calendar_tab?(group, socket.assigns.access))
      |> assign(:polls_section?, polls_section?(group, socket.assigns.access))
      |> assign(:sub_groups_kind, sub_groups_kind)

    # The first, disconnected render shows only the header. The panel and
    # the counts load once the socket connects, so a page view queries them
    # once instead of twice.
    if connected?(socket) do
      load_group_panel(socket, group, active_tab)
    else
      assign(socket, :loaded?, false)
    end
  end

  defp load_group_panel(socket, group, active_tab) do
    socket = maybe_mark_group_values_read(socket, group, active_tab)
    # One unread overview orders the sub-groups and feeds every count.
    overview = Social.unread_overview(socket.assigns.current_profile)

    socket
    |> assign(:loaded?, true)
    |> put_unread_overview(overview)
    |> load_member_summary(group)
    |> load_join_request_data(group, active_tab)
    |> maybe_load_children(group, active_tab, overview)
    |> assign_child_pending_join_request_counts()
    |> maybe_load_members(group, active_tab)
    |> maybe_load_values(group, active_tab)
    |> maybe_load_files(group, active_tab)
    |> CalendarState.maybe_load(group, active_tab)
    |> RootMapState.maybe_load(group, active_tab)
    |> PollsState.maybe_load(group, active_tab)
    |> maybe_load_roles(group, active_tab)
    |> maybe_load_thread_origin(group, active_tab)
    |> maybe_load_alt_descriptions(group, active_tab)
    |> assign_group_tags(group)
    |> assign_group_reactions()
    |> assign(:root_group_unread_count, overview.total)
    |> assign_group_unread_counts(overview)
    |> maybe_push_root_group_unread_count()
    |> maybe_load_value_parent_options(group, active_tab)
  end

  defp refresh_group_data(socket) do
    load_group_data(socket, socket.assigns.group, socket.assigns.active_tab)
  end

  # The path only changes with the group or the viewing profile, so tab switches
  # and refreshes reuse it instead of querying the ancestors again.
  defp assign_group_path(
         %{assigns: %{group_path_for: {group, profile}, current_profile: profile}} = socket,
         group
       ),
       do: socket

  defp assign_group_path(socket, group) do
    profile = socket.assigns.current_profile
    path = Social.list_visible_group_path_for_profile(group, profile)

    socket
    |> assign(:group_path, path)
    |> assign(:group_path_for, {group, profile})
  end

  # A value posted in a big group fans out `group_updated` / unread broadcasts
  # to every member; collecting them for a moment turns a burst into one reload.
  defp schedule_refresh(socket, kind) do
    socket = update(socket, :pending_refresh, &MapSet.put(&1, kind))

    case refresh_debounce_ms() do
      0 -> flush_refresh(socket)
      delay -> schedule_flush(socket, delay + refresh_spread_ms(kind))
    end
  end

  # One flush covers every pending kind. A kind that should not wait as long
  # as the flush already planned sets an earlier one; the later timer then
  # finds nothing to do, or flushes what came since a little early.
  defp schedule_flush(socket, delay) do
    due_at = System.monotonic_time(:millisecond) + delay

    case socket.assigns.refresh_due_at do
      planned when is_integer(planned) and planned <= due_at ->
        socket

      _planned ->
        Process.send_after(self(), :flush_refresh, delay)
        assign(socket, :refresh_due_at, due_at)
    end
  end

  defp refresh_debounce_ms, do: @refresh_debounce_ms

  defp refresh_spread_ms(:unread), do: :rand.uniform(@unread_refresh_spread_ms)
  defp refresh_spread_ms(:unread_values), do: :rand.uniform(@unread_values_spread_ms)
  defp refresh_spread_ms(:children), do: :rand.uniform(@children_refresh_spread_ms)
  defp refresh_spread_ms(_kind), do: 0

  # `:unread_values` are values posted since the last count, added without a
  # query; a reload or a recount counts them anyway.
  defp flush_refresh(socket) do
    pending = socket.assigns.pending_refresh

    socket =
      socket
      |> assign(:pending_refresh, MapSet.new())
      |> assign(:refresh_due_at, nil)

    # On their own, as `cond` takes one branch and any kind can come with these.
    socket =
      if MapSet.member?(pending, :group_reactions) and not MapSet.member?(pending, :group),
        do: refresh_group_reactions_or_retry(socket),
        else: socket

    socket =
      if MapSet.member?(pending, :children) and not MapSet.member?(pending, :group),
        do: reload_children_or_retry(socket),
        else: socket

    cond do
      MapSet.member?(pending, :group) -> reload_current_group(socket)
      MapSet.member?(pending, :unread) -> refresh_unread_counts_or_retry(socket)
      MapSet.member?(pending, :unread_values) -> add_unread_values(socket)
      true -> socket
    end
  end

  # The counts refresh in the background, so one that finds no free database
  # connection is tried again a little later instead of crashing the page,
  # whose remount would cost the database far more.
  defp refresh_unread_counts_or_retry(socket) do
    refresh_unread_counts(socket)
  rescue
    DBConnection.ConnectionError -> schedule_refresh(socket, :unread)
  end

  defp refresh_group_reactions_or_retry(socket) do
    assign_group_reactions(socket)
  rescue
    DBConnection.ConnectionError -> schedule_refresh(socket, :group_reactions)
  end

  defp reload_children_or_retry(socket) do
    reload_children(socket)
  rescue
    DBConnection.ConnectionError -> schedule_refresh(socket, :children)
  end

  defp reload_current_group(socket) do
    current_profile = socket.assigns.current_profile
    group = Social.get_group!(socket.assigns.group.id)
    access = Social.get_group_access(current_profile, group)
    previous_newest_value_id = socket.assigns.newest_value_id

    if can_view_group?(group, access.member?) do
      socket
      |> assign_access(access)
      |> load_group_data(group)
      |> maybe_scroll_values_to_latest(previous_newest_value_id)
    else
      socket
      |> put_flash(:error, gettext("You do not have access to that group."))
      |> push_navigate(to: ~p"/groups")
    end
  end

  defp refresh_unread_counts(socket) do
    overview = Social.unread_overview(socket.assigns.current_profile)

    socket
    |> put_unread_overview(overview)
    |> refresh_children_order(overview)
    |> assign(:root_group_unread_count, overview.total)
    |> assign_group_unread_counts(overview)
    |> maybe_push_root_group_unread_count()
  end

  # A fresh count holds every value broadcast before it, so the ones still
  # waiting are dropped.
  defp put_unread_overview(socket, overview) do
    socket
    |> assign(:unread_overview, overview)
    |> assign(:pending_unread_values, [])
  end

  # Values others posted since the last count, one more unread each. They are
  # added in memory; the sub-groups list is only read again when a value moves
  # a sub-group that is not loaded. A value in the chat on screen is already
  # read (`insert_created_value/2` marked it).
  defp add_unread_values(%{assigns: %{unread_overview: nil}} = socket),
    do: refresh_unread_counts_or_retry(socket)

  defp add_unread_values(socket) do
    %{unread_overview: overview, pending_unread_values: pending} = socket.assigns
    member_ids = ProfileAuth.unread_groups(socket)
    socket = assign(socket, :pending_unread_values, [])

    pending
    |> Enum.reverse()
    |> Enum.reject(&shown_chat_value?(socket, &1))
    |> Enum.reduce({overview, []}, fn unread, {overview, added} ->
      case Social.add_unread_value(overview, unread, member_ids) do
        :counted -> {overview, added}
        {:ok, overview} -> {overview, [unread | added]}
      end
    end)
    |> case do
      {_overview, []} ->
        socket

      {overview, added} ->
        socket
        |> assign(:unread_overview, overview)
        |> move_children_up(overview, Enum.reverse(added))
        |> assign(:root_group_unread_count, overview.total)
        |> assign_group_unread_counts(overview)
        |> maybe_push_root_group_unread_count()
    end
  end

  defp shown_chat_value?(%{assigns: %{group: group, active_tab: active_tab}}, unread),
    do: unread.group_id == group.id and needs_values?(group, active_tab)

  # The sub-group of the page's group that a value counts in, if any: the
  # overview knows where the lists show it.
  defp page_child(%{chain: chain}, overview, %Group{id: group_id}),
    do: Enum.find(chain, &(get_in(overview.groups, [&1.id, :parent_id]) == group_id))

  # A value only adds to a count, so it can only move a sub-group up the list
  # (unread first, then the newest). The list holds the first sub-groups in
  # that order, so a loaded one is moved in memory. One that is not loaded may
  # now belong in it, which only the database can tell, unless the list's
  # filters leave it out anyway.
  defp move_children_up(socket, overview, unread_values) do
    %{group: group, active_tab: active_tab, loaded_children: loaded_children} = socket.assigns

    if needs_children?(group, active_tab) and socket.assigns.sub_groups_view != "tree" do
      loaded = Map.new(loaded_children, &{&1.id, &1})

      {loaded, moved, unloaded?} =
        Enum.reduce(
          unread_values,
          {loaded, MapSet.new(), false},
          &track_child(socket, overview, &1, &2)
        )

      # The loaded sub-groups keep their newest value either way, as the
      # in-memory order needs it.
      socket = assign(socket, :loaded_children, Enum.map(loaded_children, &loaded[&1.id]))

      if unloaded? do
        refresh_children_order(socket, overview)
      else
        children = Social.sort_child_groups(Map.values(loaded), overview)
        stream_moved_children(socket, children, moved)
      end
    else
      socket
    end
  end

  # Notes the page's sub-group a value counts in: a loaded one gets the
  # value's time when the value is its own, and one that is not loaded asks
  # for the database if the list could show it.
  defp track_child(socket, overview, unread, {loaded, moved, unloaded?}) do
    case page_child(unread, overview, socket.assigns.group) do
      nil ->
        {loaded, moved, unloaded?}

      %{id: id} = child ->
        case loaded do
          %{^id => loaded_child} when id == unread.group_id ->
            loaded_child = %{loaded_child | last_value_at: unread.inserted_at}
            {Map.put(loaded, id, loaded_child), MapSet.put(moved, id), unloaded?}

          %{^id => _loaded_child} ->
            {loaded, MapSet.put(moved, id), unloaded?}

          _ ->
            {loaded, moved, unloaded? or may_list_child?(socket, child)}
        end
    end
  end

  defp may_list_child?(socket, child) do
    filters = children_filters(socket)

    filters[:search] != "" or
      (child.direct? == filters[:is_direct] and
         not (child.thread? and filters[:is_thread] == false))
  end

  # Moved sub-groups are taken out and put back at their new place, in list
  # order, so each lands after everything that precedes it; the others stay.
  defp stream_moved_children(socket, children, moved) do
    socket =
      if Enum.map(children, & &1.id) == Enum.map(socket.assigns.loaded_children, & &1.id) do
        children
        |> Enum.filter(&MapSet.member?(moved, &1.id))
        |> Enum.reduce(socket, &stream_insert(&2, :children, &1))
      else
        moved_children = Enum.filter(children, &MapSet.member?(moved, &1.id))
        socket = Enum.reduce(moved_children, socket, &stream_delete(&2, :children, &1))

        children
        |> Enum.with_index()
        |> Enum.filter(fn {child, _index} -> MapSet.member?(moved, child.id) end)
        |> Enum.reduce(socket, fn {child, index}, socket ->
          stream_insert(socket, :children, child, at: index)
        end)
      end

    assign(socket, :loaded_children, children)
  end

  # A new value can move a sub-group up the list (unread first, then the
  # newest), so the order is read again. The groups are only fetched again when
  # it changed; otherwise just the rows whose count changed are re-sent.
  defp refresh_children_order(socket, overview) do
    %{group: group, active_tab: active_tab, loaded_children: loaded_children} = socket.assigns

    if needs_children?(group, active_tab) and socket.assigns.sub_groups_view != "tree" do
      ids =
        list_children_ids(socket,
          limit: reload_limit(socket.assigns.children_pagination),
          unread_overview: overview
        )

      if ids == Enum.map(loaded_children, & &1.id) do
        previous_counts = socket.assigns.group_unread_counts
        counts = Social.unread_counts_for(overview, ids)

        loaded_children
        |> Enum.filter(&(Map.get(previous_counts, &1.id, 0) != counts[&1.id]))
        |> Enum.reduce(socket, &stream_insert(&2, :children, &1))
      else
        maybe_load_children(socket, group, active_tab, overview)
      end
    else
      socket
    end
  end

  # Online dots are driven by the `#group-presence-style` rule set, so a
  # presence change only re-renders that one element instead of streamed
  # items. The rule set covers just the profiles whose dot is on the page
  # (see `watch_presence/2`). The root page shows no dots at all, so it
  # neither tracks the viewer nor watches anyone: everybody passes through it.
  defp sync_group_presence(socket) do
    current_profile = socket.assigns.current_profile
    previous_profile_id = socket.assigns.presence_profile_id
    group = socket.assigns.group

    tracked_profile_id =
      if connected?(socket) and not group.is_root and current_profile,
        do: current_profile.id

    if previous_profile_id != tracked_profile_id do
      if previous_profile_id,
        do: Social.untrack_group_presence(self(), group, previous_profile_id)

      if tracked_profile_id do
        case Social.track_group_presence(self(), group, current_profile) do
          {:ok, _meta} -> :ok
          {:error, _reason} -> :ok
        end
      end
    end

    # The viewer is online as soon as it is tracked; the presence broadcast
    # for its own join arrives a moment later.
    online = MapSet.delete(socket.assigns.online_profile_ids, previous_profile_id)
    online = if tracked_profile_id, do: MapSet.put(online, tracked_profile_id), else: online

    socket
    |> assign(:presence_profile_id, tracked_profile_id)
    |> assign(:online_profile_ids, online)
  end

  # Subscribes to the presence of the profiles whose dot was just rendered
  # (members and value authors), so a join or leave elsewhere reaches only
  # the pages that show that profile.
  defp watch_presence(socket, profile_ids) do
    watched = socket.assigns.presence_watched

    new_ids =
      profile_ids
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(watched, &1))

    if new_ids != [] and connected?(socket) and not socket.assigns.group.is_root do
      group = socket.assigns.group
      online_ids = Enum.filter(new_ids, &Social.watch_group_presence(group, &1))

      socket
      |> assign(:presence_watched, Enum.into(new_ids, watched))
      |> then(fn socket ->
        if online_ids == [],
          do: socket,
          else: update(socket, :online_profile_ids, &Enum.into(online_ids, &1))
      end)
    else
      socket
    end
  end

  defp apply_presence_change(socket, profile_id, online?) do
    online = socket.assigns.online_profile_ids

    cond do
      online? and not MapSet.member?(online, profile_id) ->
        assign(socket, :online_profile_ids, MapSet.put(online, profile_id))

      # This page's own presence keeps the viewer online whatever its other
      # tabs do.
      online? or profile_id == socket.assigns.presence_profile_id ->
        socket

      MapSet.member?(online, profile_id) ->
        assign(socket, :online_profile_ids, MapSet.delete(online, profile_id))

      true ->
        socket
    end
  end

  defp maybe_scroll_values_to_latest(socket, previous_newest_value_id) do
    newest_value_id = socket.assigns.newest_value_id

    if needs_values?(socket.assigns.group, socket.assigns.active_tab) and
         is_integer(newest_value_id) and
         (is_nil(previous_newest_value_id) or newest_value_id > previous_newest_value_id) do
      push_event(socket, "scroll_values_to_latest", %{force: false})
    else
      socket
    end
  end

  # Incremental value updates. These are idempotent so the acting LiveView and
  # the PubSub broadcast it also receives can both apply them safely.
  defp apply_value_created(socket, %Value{is_data: true}), do: socket

  defp apply_value_created(socket, %Value{} = value) do
    {socket, value} = PollsState.with_views(socket, value)

    socket
    |> insert_created_value(value)
    |> maybe_reload_files(value)
  end

  defp insert_created_value(socket, %Value{} = value) do
    group = socket.assigns.group
    active_tab = socket.assigns.active_tab

    mine? = value.creator_id == socket.assigns.current_profile.id

    # Unread badges are updated by the `group_value_unread` broadcast that
    # Social sends to every member right after the value broadcast. The value
    # is marked read here, so this page skips that one (`shown_chat_value?/2`).
    cond do
      not needs_values?(group, active_tab) or
          MapSet.member?(socket.assigns.loaded_value_ids, value.id) ->
        socket

      # The feed shows earlier values, so the new one would not join on: the
      # viewer's own value brings the feed back to the newest, others' only
      # light the dot on the jump button.
      socket.assigns.values_has_newer? and mine? ->
        socket
        |> load_latest_values(group)
        |> mark_value_read(value)
        |> push_event("scroll_values_to_latest", %{force: true})

      socket.assigns.values_has_newer? ->
        socket
        |> mark_value_read(value)
        |> push_event("scroll_values_to_latest", %{force: false})

      true ->
        socket
        |> update(:loaded_value_ids, &MapSet.put(&1, value.id))
        |> assign(:newest_value_id, max(socket.assigns.newest_value_id || 0, value.id))
        |> assign(:oldest_value_id, socket.assigns.oldest_value_id || value.id)
        |> stream_insert(:values, value)
        |> prune_values(:oldest)
        |> watch_presence([value.creator_id])
        |> mark_value_read(value)
        # The feed follows its own values; others' wait while it is scrolled up.
        |> push_event("scroll_values_to_latest", %{force: mine?})
    end
  end

  defp apply_value_updated(socket, %Value{} = value) do
    socket =
      case socket.assigns.replying_to_value do
        %Value{id: id} when id == value.id -> assign(socket, :replying_to_value, value)
        _ -> socket
      end

    # Broadcasts carry the value without tags or a poll's view, which depend on
    # the viewer.
    if MapSet.member?(socket.assigns.loaded_value_ids, value.id) do
      {socket, value} = PollsState.with_views(socket, value)

      stream_insert(socket, :values, Tags.put_tags(value, socket.assigns.current_profile, :value))
    else
      socket
    end
  end

  # Reads the item again with the tags this profile sees, when it is on the page.
  defp apply_tags_changed(socket, :value, value_id),
    do: restream_value(socket, %Value{id: value_id})

  defp apply_tags_changed(
         %{assigns: %{active_tab: "files", files_view: "list"}} = socket,
         :attachment,
         attachment_id
       ) do
    # The list holds the newest files down to `oldest_file_id`.
    with oldest_id when is_integer(oldest_id) and attachment_id >= oldest_id <-
           socket.assigns.oldest_file_id,
         %ValueAttachment{} = file <-
           Social.get_group_attachment(socket.assigns.group, attachment_id) do
      stream_insert(
        socket,
        :files,
        Tags.put_tags(file, socket.assigns.current_profile, :attachment)
      )
    else
      _ -> socket
    end
  end

  defp apply_tags_changed(socket, :attachment, _attachment_id), do: socket

  defp apply_tags_changed(socket, :group, group_id) do
    socket =
      if socket.assigns.group.id == group_id,
        do: assign_group_tags(socket, socket.assigns.group),
        else: socket

    case Enum.find(socket.assigns.loaded_children, &(&1.id == group_id)) do
      nil ->
        socket

      child ->
        child = Tags.put_tags(child, socket.assigns.current_profile, :group)

        socket
        |> update(:loaded_children, fn children ->
          Enum.map(children, &if(&1.id == group_id, do: child, else: &1))
        end)
        |> stream_insert(:children, child)
    end
  end

  defp apply_tags_changed(socket, :profile, profile_id), do: restream_member(socket, profile_id)

  defp apply_tags_changed(socket, :event, event_id),
    do: CalendarState.refresh_event_tags(socket, event_id)

  # Read only for the panel that shows them: a reaction reaches every page open
  # on the group, whatever its tab.
  defp assign_group_reactions(socket) do
    %{group: group, current_profile: profile, access: access} = socket.assigns

    if description_visible?(socket.assigns) do
      reactions = Social.group_reaction_summaries([group.id], profile)

      socket
      |> assign(:group_reactions, Map.get(reactions, group.id, []))
      |> assign(:can_react_to_group, Access.can_react_to_group?(profile, access, group))
    else
      socket
    end
  end

  defp assign_group_tags(socket, %Group{is_root: true}), do: assign(socket, :group_tags, [])

  defp assign_group_tags(socket, %Group{id: group_id}) do
    tags = Tags.tags_for(socket.assigns.current_profile, :group, [group_id])
    assign(socket, :group_tags, Map.get(tags, group_id, []))
  end

  defp apply_value_deleted(socket, value_id) do
    socket =
      case socket.assigns.editing_value do
        %Value{id: ^value_id} ->
          socket
          |> assign(:editing_value, nil)
          |> assign(:edit_value_form, nil)

        _ ->
          socket
      end

    socket =
      case socket.assigns.replying_to_value do
        %Value{id: ^value_id} -> assign(socket, :replying_to_value, nil)
        _ -> socket
      end

    socket =
      if MapSet.member?(socket.assigns.loaded_value_ids, value_id) do
        remove_value(socket, value_id)
      else
        socket
      end

    # The files of the deleted value are gone with it.
    maybe_reload_files(socket, nil)
  end

  # `nil` is a deleted value, whose files may have been on screen.
  defp maybe_reload_files(%{assigns: %{active_tab: "files"}} = socket, value) do
    case value do
      %Value{attachments: []} -> socket
      _value -> maybe_load_files(socket, socket.assigns.group, "files")
    end
  end

  defp maybe_reload_files(socket, _value), do: socket

  # An app that shows sub-groups (a map's pins) reads them again. It hears
  # only that something changed: which group would tell it of one it may not see.
  defp tell_app_children_changed(socket) do
    source = socket.assigns.active_alt_description || socket.assigns.group

    if source.uses_api and description_visible?(socket.assigns),
      do: AppHost.push(socket, "app_children_changed", %{}),
      else: socket
  end

  # Who looks at the sheet over the app, signed into its LiveView's session:
  # opened after the page, it gets nothing from the page's assigns.
  defp group_sheet_session(assigns) do
    %{
      "account_id" => assigns.current_scope.account.id,
      "profile_id" => assigns.current_profile.id,
      "parent_id" => assigns.group.id,
      "locale" => assigns[:current_locale],
      "time_zone" => assigns[:calendar_time_zone]
    }
  end

  @doc false
  def description_visible?(%{active_tab: active_tab, group: group, access: access}) do
    active_tab == "group_home" or
      (active_tab == "values" and group.parent_id != nil and
         not Access.can_read_chat?(access, group))
  end

  @doc false
  def value_payload(%Value{} = value) do
    %{
      id: value.id,
      content: value.content,
      data: value.data,
      content_format: to_string(value.content_format),
      is_data: value.is_data,
      group_id: value.group_id,
      parent_id: value.parent_id,
      creator_id: value.creator_id,
      creator_username: value_creator_username(value),
      description_id: value.alt_description_id,
      collection: value.collection,
      anonymous: value.anonymous,
      revision: value.lock_version,
      managed: value.managed,
      inserted_at: value.inserted_at,
      updated_at: value.updated_at
    }
  end

  defp value_creator_username(%Value{creator: %{username: username}}), do: username
  defp value_creator_username(_), do: nil

  # Values are only held in the stream; events re-read the row and check it
  # belongs to a value this LiveView has rendered.
  defp loaded_value(socket, id) do
    with {value_id, ""} <- Integer.parse(to_string(id)),
         true <- MapSet.member?(socket.assigns.loaded_value_ids, value_id),
         %Value{} = value <- Social.get_value_for_display(value_id),
         true <- value.group_id == socket.assigns.group.id do
      value
    else
      _ -> nil
    end
  end

  # A reply shows what it answers in the composer, and an event for members is
  # not on the page of someone outside the group.
  defp replyable_value(socket, id) do
    value = loaded_value(socket, id)
    if value && !Components.event_hidden?(value, !socket.assigns.is_member), do: value
  end

  defp can_attach?(%Access{} = access),
    do: Storage.enabled?() and access.member? and Access.can?(access, :attach_files)

  # A picture from the device is a message with a file, in the group's chat, so
  # it takes what such a message takes. It also takes editing the group, as the
  # address it gives opens with no session. The root has no chat, though its
  # settings can be reached by address.
  defp can_post_description_picture?(%Group{} = group, %Access{} = access) do
    not group.is_root and Access.can?(access, :edit_group) and can_attach?(access) and
      Access.can?(access, :post_values)
  end

  # What the keyboard sends is a file in a message of its own, so it takes what
  # both of those take.
  defp can_send_keyboard_media?(profile, %Group{} = group, %Access{} = access),
    do: can_attach?(access) and Access.can_post_in_chat?(profile, access, group)

  # Browsers upload through the LiveView channel, or straight to the bucket
  # when the storage hands out presigned URLs.
  defp allow_attachments_upload(socket) do
    opts = [
      accept: :any,
      max_entries: Storage.max_files(),
      max_file_size: Storage.max_file_size()
    ]

    opts =
      if Storage.direct_upload?(),
        do: Keyword.put(opts, :external, &presign_attachment/2),
        else: opts

    allow_upload(socket, :attachments, opts)
  end

  defp allow_description_picture_upload(socket) do
    opts = [
      accept: ~w(image/jpeg),
      max_entries: 1,
      max_file_size: @max_description_picture_size,
      auto_upload: true,
      progress: &description_picture_progress/3
    ]

    opts =
      if Storage.direct_upload?(),
        do: Keyword.put(opts, :external, &presign_description_picture/2),
        else: opts

    allow_upload(socket, :description_picture, opts)
  end

  defp presign_description_picture(entry, socket) do
    if can_post_description_picture?(socket.assigns.group, socket.assigns.access),
      do: presign_attachment(entry, socket),
      else: {:error, %{reason: "not_permitted"}, socket}
  end

  # Also called when an upload to the bucket fails, with the entry not done.
  defp description_picture_progress(:description_picture, %{done?: true} = entry, socket) do
    if can_post_description_picture?(socket.assigns.group, socket.assigns.access),
      do: {:noreply, post_description_picture(socket, entry)},
      else: {:noreply, cancel_upload(socket, :description_picture, entry.ref)}
  end

  defp description_picture_progress(:description_picture, entry, socket) do
    if upload_errors(socket.assigns.uploads.description_picture, entry) == [] do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> cancel_upload(:description_picture, entry.ref)
       |> put_flash(:error, gettext("The picture could not be sent."))}
    end
  end

  # The file goes where every file of the group goes, as a message with it, and
  # the field gets its address. The author's own message moves their read
  # marker, which the broadcast of the unread count skips on their own page.
  defp post_description_picture(socket, entry) do
    %{current_profile: profile, group: group} = socket.assigns
    content = gettext("Picture for the group's description")

    stored =
      consume_uploaded_entry(socket, entry, &{:ok, store_attachment(group, &1, entry)})

    with {:ok, attachment} <- stored,
         {:ok, value} <-
           create_value_or_drop_files(profile, group, %{"content" => content}, [attachment]) do
      socket
      |> schedule_refresh(:unread)
      |> push_event("description_picture_ready", %{
        url: PostTemplates.Picture.address(hd(value.attachments))
      })
    else
      _error -> put_flash(socket, :error, gettext("The picture could not be sent."))
    end
  end

  # Two quick taps on the keyboard are two uploads at once.
  defp allow_keyboard_media_upload(socket) do
    opts = [
      accept: ~w(image/gif image/png image/jpeg image/webp image/avif),
      max_entries: 5,
      max_file_size: Storage.max_file_size(),
      auto_upload: true,
      progress: &keyboard_media_progress/3
    ]

    opts =
      if Storage.direct_upload?(),
        do: Keyword.put(opts, :external, &presign_keyboard_media/2),
        else: opts

    allow_upload(socket, :keyboard_media, opts)
  end

  defp presign_keyboard_media(entry, socket) do
    %{current_profile: profile, group: group, access: access} = socket.assigns

    if can_send_keyboard_media?(profile, group, access),
      do: presign_attachment(entry, socket),
      else: {:error, %{reason: "not_permitted"}, socket}
  end

  # Also called when an upload to the bucket fails, with the entry not done.
  defp keyboard_media_progress(:keyboard_media, %{done?: true} = entry, socket) do
    %{current_profile: profile, group: group, access: access} = socket.assigns

    if can_send_keyboard_media?(profile, group, access),
      do: {:noreply, post_keyboard_media(socket, entry)},
      else: {:noreply, cancel_upload(socket, :keyboard_media, entry.ref)}
  end

  defp keyboard_media_progress(:keyboard_media, entry, socket) do
    if upload_errors(socket.assigns.uploads.keyboard_media, entry) == [] do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> cancel_upload(:keyboard_media, entry.ref)
       |> put_keyboard_media_error()}
    end
  end

  # The message holds only the file, so what is typed stays in the composer. A
  # reply being written goes out with the file.
  defp post_keyboard_media(socket, entry) do
    %{current_profile: profile, group: group, replying_to_value: replying_to} = socket.assigns
    attrs = maybe_put_reply_parent(%{"content" => ""}, replying_to)

    stored =
      consume_uploaded_entry(socket, entry, &{:ok, store_attachment(group, &1, entry)})

    with {:ok, attachment} <- stored,
         {:ok, value} <- create_value_or_drop_files(profile, group, attrs, [attachment]) do
      socket
      |> assign(:replying_to_value, nil)
      |> apply_value_created(value)
    else
      {:error, :too_many_values} -> put_flash(socket, :error, too_many_values_message())
      _error -> put_keyboard_media_error(socket)
    end
  end

  defp put_keyboard_media_error(socket),
    do: put_flash(socket, :error, gettext("The picture could not be sent."))

  defp presign_attachment(entry, socket) do
    key = Storage.new_key(socket.assigns.group.id)
    content_type = ValueAttachment.clean_content_type(entry.client_type)

    with true <- can_attach?(socket.assigns.access),
         {:ok, url} <- Storage.presign_put(key, content_type, entry.client_size) do
      {:ok, %{uploader: "S3", key: key, url: url, content_type: content_type}, socket}
    else
      _ -> {:error, %{reason: "not_permitted"}, socket}
    end
  end

  # The composer's files, stored and checked, as attrs for
  # `Social.create_value/4`. Nothing is consumed until every file is ready.
  defp consume_attachments(socket) do
    upload = socket.assigns.uploads.attachments
    {_completed, in_progress} = uploaded_entries(socket, :attachments)

    cond do
      upload.entries == [] ->
        {:ok, []}

      not can_attach?(socket.assigns.access) ->
        {:error, :not_permitted}

      upload_errors(upload) != [] or Enum.any?(upload.entries, &(not &1.valid?)) ->
        {:error, gettext("Remove the files that cannot be attached.")}

      in_progress != [] ->
        {:error, gettext("Wait until the files finish uploading.")}

      true ->
        group = socket.assigns.group

        # Consumed entries come back in reverse; the value keeps the files in
        # the order they were picked, which is the order of `upload.entries`.
        position = Map.new(Enum.with_index(upload.entries, &{&1.ref, &2}))

        socket
        |> consume_uploaded_entries(
          :attachments,
          &{:ok, {&2.ref, store_attachment(group, &1, &2)}}
        )
        |> Enum.sort_by(fn {ref, _result} -> Map.fetch!(position, ref) end)
        |> Enum.map(fn {_ref, result} -> result end)
        |> Enum.split_with(&match?({:ok, _attrs}, &1))
        |> case do
          {stored, []} ->
            {:ok, Enum.map(stored, fn {:ok, attrs} -> attrs end)}

          {stored, _failed} ->
            Storage.delete_later(Enum.map(stored, fn {:ok, attrs} -> attrs.storage_key end))
            {:error, gettext("Some files could not be uploaded. Please try again.")}
        end
    end
  end

  # A channel upload is a temporary file that moves into storage. A direct
  # upload is already in the bucket, but its size came from the browser, so
  # the stored object is checked against it.
  @doc false
  def store_attachment(group, %{path: path}, entry) do
    key = Storage.new_key(group.id)

    with :ok <- Storage.put_file(key, path),
         {:ok, byte_size} <- Storage.stat(key) do
      {:ok, attachment_attrs(key, entry, byte_size)}
    else
      _error ->
        Storage.delete_later([key])
        :error
    end
  end

  def store_attachment(_group, %{key: key}, entry) do
    case Storage.stat(key) do
      {:ok, byte_size} when byte_size == entry.client_size ->
        {:ok, attachment_attrs(key, entry, byte_size)}

      _error ->
        Storage.delete_later([key])
        :error
    end
  end

  defp attachment_attrs(key, entry, byte_size) do
    %{
      storage_key: key,
      filename: entry.client_name,
      content_type: entry.client_type,
      byte_size: byte_size
    }
  end

  # Files already in storage are removed again when the value is refused.
  defp create_value_or_drop_files(profile, group, attrs, attachments) do
    case Social.create_value(profile, group, attrs, attachments) do
      {:ok, value} ->
        {:ok, value}

      error ->
        Storage.delete_later(Enum.map(attachments, & &1.storage_key))
        error
    end
  end

  defp maybe_put_reply_parent(attrs, %Value{id: parent_id}),
    do: Map.put(attrs, "parent_id", parent_id)

  defp maybe_put_reply_parent(attrs, nil), do: attrs

  defp clear_edit_value(socket) do
    editing_value = socket.assigns.editing_value

    socket
    |> assign(:editing_value, nil)
    |> assign(:edit_value_form, nil)
    |> restream_value(editing_value)
  end

  defp remove_value(socket, value_id) do
    socket
    |> update(:loaded_value_ids, &MapSet.delete(&1, value_id))
    |> stream_delete_by_dom_id(:values, "value-#{value_id}")
  end

  @doc false
  # Re-reads the row so a stale struct never overwrites newer content.
  def restream_value(socket, nil), do: socket

  def restream_value(socket, %Value{id: value_id}) do
    with true <- MapSet.member?(socket.assigns.loaded_value_ids, value_id),
         %Value{} = value <- Social.get_value_for_display(value_id) do
      {socket, value} = PollsState.with_views(socket, value)

      stream_insert(socket, :values, Tags.put_tags(value, socket.assigns.current_profile, :value))
    else
      _ -> socket
    end
  end

  defp default_pagination(per_page) do
    %{per_page: per_page, loaded_count: 0, total_count: 0, has_more?: false}
  end

  # Each form is made when its tab opens, and dropped when the viewer leaves
  # the tab without having typed anything into it. Every page used to keep
  # all of them from its mount: a blank value, a blank group and a role, and
  # a changeset of the group itself, on whatever tab it showed.
  defp assign_tab_forms(socket, active_tab) do
    socket
    |> tab_form(:new_value_form, active_tab == "values", &empty_new_value_form/0)
    |> tab_form(:new_group_form, active_tab == "create_group", &empty_new_group_form/0)
    |> tab_form(:new_role_form, active_tab == "roles", &empty_new_role_form/0)
  end

  defp tab_form(socket, key, true = _shown, build) do
    if socket.assigns[key], do: socket, else: assign(socket, key, build.())
  end

  defp tab_form(socket, key, false = _shown, _build) do
    case socket.assigns[key] do
      %Phoenix.HTML.Form{source: %Ecto.Changeset{changes: changes}} when changes != %{} -> socket
      _untouched -> assign(socket, key, nil)
    end
  end

  defp empty_new_value_form do
    to_form(Value.changeset(%Value{}, %{}))
  end

  defp empty_new_group_form do
    to_form(
      Group.changeset(%Group{}, %{
        is_public: false,
        description_format: :markdown,
        home_page: :description
      })
    )
  end

  # The picture column is not loaded by regular queries; the edit form is the
  # only place that needs the raw value, so it is fetched just for that tab.
  # Other tabs keep no form (`assign_tab_forms/2`).
  defp edit_group_form(group, "edit_group"),
    do: to_form(Group.update_changeset(Social.load_picture(group), %{}))

  defp edit_group_form(_group, _active_tab), do: nil

  # The group as the edit form holds it (with its picture), also for an
  # event that arrives after the form was dropped.
  defp edit_group_data(socket) do
    case socket.assigns.edit_group_form do
      %Phoenix.HTML.Form{source: %Ecto.Changeset{data: group}} -> group
      nil -> Social.load_picture(socket.assigns.group)
    end
  end

  # What a link to the group shows outside Potok, for its settings: as it is
  # saved, so it costs nothing while the form is being typed in.
  defp link_card(%Group{} = group, "edit_group") do
    with true <- Group.guest_preview?(group),
         {:ok, preview} <- PublicPreview.link_preview(url(~p"/groups/#{group.id}")) do
      %{
        preview: preview,
        app: group.uses_api,
        describes_itself: PublicPreview.describes_itself?(group)
      }
    else
      _ -> nil
    end
  end

  defp link_card(_group, _active_tab), do: nil

  # Whether the edit form holds something not saved yet (its save bar shows).
  # A field that fails validation, like a cleared name, is dropped from the
  # changes, so errors count too: the bar's save then shows what is wrong.
  defp edit_group_dirty?(%Phoenix.HTML.Form{
         source: %Ecto.Changeset{changes: changes, errors: errors}
       }),
       do: changes != %{} or errors != []

  defp edit_group_dirty?(_form), do: false

  # By the form, not the tab: `handle_params` sets the new tab first, so a
  # check of the tab here never made the form (the edit tab then showed the
  # one from mount, without the group's picture or its link card).
  defp maybe_reload_edit_group_form(socket, "edit_group") do
    if socket.assigns.edit_group_form do
      socket
    else
      group = socket.assigns.group

      socket
      |> assign(:edit_group_form, edit_group_form(group, "edit_group"))
      |> assign(:link_card, link_card(group, "edit_group"))
      |> assign(:inherits_members_option?, Social.inherits_members_option?(group))
    end
  end

  # Coming back to the edit tab makes a fresh form anyway (above).
  defp maybe_reload_edit_group_form(socket, _active_tab) do
    socket
    |> assign(:edit_group_form, nil)
    |> assign(:link_card, nil)
  end

  # A link can open the edit tab on one of its cards.
  defp opening_edit_section(%{"section" => section}) when section in @edit_group_sections,
    do: section

  defp opening_edit_section(_params), do: "basics"

  # Opening the create tab starts on its first card.
  defp assign_new_tab_section(socket, "create_group"),
    do: assign(socket, :create_group_section, "basics")

  defp assign_new_tab_section(socket, _active_tab), do: socket

  # The first card, in bar order, holding a field with an error.
  defp group_form_error_section(%Ecto.Changeset{errors: errors}) do
    fields = Keyword.keys(errors)

    Enum.find_value(@group_form_section_fields, fn {section, section_fields} ->
      if Enum.any?(fields, &(&1 in section_fields)), do: section
    end)
  end

  # Alternative descriptions are only needed where the description shows and
  # in the edit tab: apps can be large, so the other tabs skip them.
  defp maybe_load_alt_descriptions(socket, group, active_tab) do
    alt_descriptions =
      if active_tab == "edit_group" or
           description_visible?(%{
             active_tab: active_tab,
             group: group,
             access: socket.assigns.access
           }),
         do: Social.list_alt_descriptions(group),
         else: []

    socket
    |> assign(:alt_descriptions, alt_descriptions)
    |> put_active_alt_description()
  end

  defp reload_alt_descriptions(socket) do
    socket
    |> maybe_load_alt_descriptions(socket.assigns.group, socket.assigns.active_tab)
    |> maybe_close_deleted_alt_description_form()
  end

  # `d` in the URL: "default", an alternative description's id, or nothing
  # for the group's home description. One the viewer cannot see shows the
  # default instead.
  defp put_active_alt_description(socket) do
    %{alt_descriptions: alt_descriptions, access: access, group: group} = socket.assigns
    visible = Enum.filter(alt_descriptions, &Access.sees_alt_description?(access, &1))

    socket
    |> assign(:visible_alt_descriptions, visible)
    |> assign(
      :active_alt_description,
      resolve_alt_description(visible, group, socket.assigns.description_param)
    )
  end

  defp resolve_alt_description(_visible, _group, "default"), do: nil

  defp resolve_alt_description(visible, group, nil),
    do: find_alt_description(visible, group.home_alt_description_id)

  defp resolve_alt_description(visible, _group, param) when is_binary(param) do
    case Integer.parse(param) do
      {id, ""} -> find_alt_description(visible, id)
      _ -> nil
    end
  end

  defp resolve_alt_description(_visible, _group, _param), do: nil

  defp find_alt_description(_visible, nil), do: nil
  defp find_alt_description(visible, id), do: Enum.find(visible, &(&1.id == id))

  defp with_edit_group(socket, fun) do
    if Access.can?(socket.assigns.access, :edit_group) do
      {:noreply, fun.(socket)}
    else
      {:noreply, put_flash(socket, :error, access_error_message(:not_permitted))}
    end
  end

  # The description comes from the loaded list, so it is one of this group's.
  defp with_alt_description(socket, id, fun) do
    with_edit_group(socket, fn socket ->
      case Enum.find(socket.assigns.alt_descriptions, &(to_string(&1.id) == to_string(id))) do
        nil ->
          socket
          |> reload_alt_descriptions()
          |> put_flash(:error, alt_description_error_message(:not_found))

        alt_description ->
          fun.(socket, alt_description)
      end
    end)
  end

  defp open_alt_description_form(socket, %GroupAltDescription{} = alt_description) do
    socket
    |> assign(:editing_alt_description, alt_description)
    |> assign(:alt_description_form, to_form(Social.change_alt_description(alt_description)))
  end

  defp close_alt_description_form(socket) do
    socket
    |> assign(:editing_alt_description, nil)
    |> assign(:alt_description_form, nil)
    |> assign(:template_list, nil)
  end

  defp save_edit_group(socket, current_profile, group, attrs) do
    case Social.update_group(current_profile, group, attrs) do
      {:ok, updated_group} ->
        {:noreply,
         socket
         |> assign(:group, updated_group)
         |> assign(:edit_group_form, edit_group_form(updated_group, "edit_group"))
         |> assign(:link_card, link_card(updated_group, "edit_group"))
         |> put_flash(:info, gettext("Group updated."))
         |> refresh_group_data()}

      {:error, :not_permitted} ->
        {:noreply, put_flash(socket, :error, access_error_message(:not_permitted))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         socket
         |> assign(:edit_group_form, to_form(Map.put(changeset, :action, :validate)))
         |> assign(
           :edit_group_section,
           group_form_error_section(changeset) || socket.assigns.edit_group_section
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, gettext("Could not update group."))}
    end
  end

  defp save_alt_description(socket, editing, attrs) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    result =
      case editing do
        %GroupAltDescription{id: nil} ->
          Social.create_alt_description(current_profile, group, attrs)

        %GroupAltDescription{} = editing ->
          Social.update_alt_description(current_profile, group, editing, attrs)

        nil ->
          {:error, :not_found}
      end

    case result do
      {:ok, _alt_description} ->
        {:noreply,
         socket
         |> close_alt_description_form()
         |> reload_alt_descriptions()
         |> put_flash(:info, gettext("Description saved."))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :alt_description_form, to_form(Map.put(changeset, :action, :validate)))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, alt_description_error_message(reason))}
    end
  end

  # The list closes with the choice made in it.
  defp close_template_list(socket, %{"pick" => _id}), do: assign(socket, :template_list, nil)
  defp close_template_list(socket, _template), do: socket

  defp add_template_error(changeset, missing) do
    Ecto.Changeset.add_error(
      changeset,
      :description,
      gettext("Still needed: %{fields}", fields: Enum.join(missing, ", "))
    )
  end

  # A template's form with empty required fields. The form says which ones,
  # so the save only has to bring it into view.
  defp refuse_edit_group(socket, attrs, missing) do
    changeset =
      edit_group_data(socket)
      |> Group.update_changeset(attrs)
      |> add_template_error(missing)
      |> Map.put(:action, :validate)

    socket
    |> assign(:edit_group_form, to_form(changeset))
    |> assign(:edit_group_section, "description")
    |> assign(:description_details_open, true)
  end

  defp maybe_close_alt_description_form(socket, %GroupAltDescription{id: id}) do
    case socket.assigns.editing_alt_description do
      %GroupAltDescription{id: ^id} -> close_alt_description_form(socket)
      _editing -> socket
    end
  end

  # Someone else deleted the description being edited.
  defp maybe_close_deleted_alt_description_form(socket) do
    case socket.assigns.editing_alt_description do
      %GroupAltDescription{id: id} when not is_nil(id) ->
        if Enum.any?(socket.assigns.alt_descriptions, &(&1.id == id)),
          do: socket,
          else: close_alt_description_form(socket)

      _editing ->
        socket
    end
  end

  defp alt_description_error_message(:not_permitted), do: access_error_message(:not_permitted)

  defp alt_description_error_message(:too_many_alt_descriptions),
    do:
      gettext("A group can have at most %{count} alternative descriptions.",
        count: Social.max_alt_descriptions()
      )

  defp alt_description_error_message(:alt_description_restricted),
    do: gettext("Remove the role limit to make it the default.")

  defp alt_description_error_message(:not_found),
    do: gettext("That description no longer exists.")

  defp alt_description_error_message(%Ecto.Changeset{} = changeset) do
    if Keyword.has_key?(changeset.errors, :name),
      do: gettext("Another description already uses the name of the current default."),
      else: gettext("Could not save the description.")
  end

  defp alt_description_error_message(_reason), do: gettext("Could not save the description.")

  defp empty_invite_form do
    invite_form()
  end

  defp invite_form(identifier \\ "") do
    to_form(%{"identifier" => identifier}, as: "invite")
  end

  defp invite_profile_suggestions(nil, _group, _identifier), do: []

  defp invite_profile_suggestions(_current_profile, _group, identifier)
       when identifier in [nil, ""] do
    []
  end

  defp invite_profile_suggestions(current_profile, group, identifier) do
    normalized_identifier = String.trim(identifier)

    cond do
      normalized_identifier == "" ->
        []

      String.contains?(normalized_identifier, "@") ->
        []

      true ->
        Social.list_invitable_profiles_for_group(current_profile, group, normalized_identifier,
          limit: 6
        )
    end
  end

  defp invite_group_identifier(_current_profile, _account_id, _group, "") do
    {:error, :blank_identifier}
  end

  defp invite_group_identifier(current_profile, account_id, group, identifier) do
    cond do
      valid_email_identifier?(identifier) ->
        invite_group_by_email(current_profile, account_id, group, identifier)

      String.contains?(identifier, "@") ->
        {:error, :invalid_email}

      true ->
        invite_group_by_username(current_profile, group, identifier)
    end
  end

  defp invite_group_by_username(current_profile, group, username) do
    case Social.get_profile_by_username(username) do
      %{} = invitee_profile ->
        case Social.invite_profile_to_group(current_profile, group, invitee_profile) do
          {:ok, _invitation} -> {:ok, gettext("Invitation sent.")}
          error -> error
        end

      nil ->
        {:error, :profile_not_found}
    end
  end

  # An address with no account gets a new one and an email, so the permission
  # and the inviting account's limit are checked before either.
  defp invite_group_by_email(current_profile, account_id, group, email) do
    case Accounts.get_account_by_email(email) do
      %Account{} = account ->
        invite_group_for_account(current_profile, group, account)

      nil ->
        with nil <- Social.invitation_refusal(current_profile, group),
             :ok <- RateLimit.check(:invitation_email, account_id),
             {:ok, account} <- Accounts.register_account(%{email: email}),
             :ok <- RateLimit.hit(:invitation_email, account_id),
             {:ok, _email} <-
               Accounts.deliver_login_instructions(account, &url(~p"/accounts/log-in/#{&1}"),
                 invited_by: current_profile,
                 group: group
               ),
             {:ok, %GroupAccountInvitation{}} <-
               Social.invite_account_to_group(current_profile, group, account) do
          {:ok, gettext("Account invitation email sent.")}
        else
          {:ok, %GroupInvitation{}} ->
            {:ok, gettext("Invitation sent.")}

          reason when is_atom(reason) ->
            {:error, reason}

          error ->
            error
        end
    end
  end

  defp invite_group_for_account(current_profile, group, account) do
    case Social.invite_account_to_group(current_profile, group, account) do
      {:ok, %GroupInvitation{}} ->
        {:ok, gettext("Invitation sent.")}

      {:ok, %GroupAccountInvitation{}} ->
        {:ok, gettext("Invitation will be sent when they create their first profile.")}

      error ->
        error
    end
  end

  defp valid_email_identifier?(identifier) do
    Accounts.change_account_email(%Account{}, %{"email" => identifier}, validate_unique: false).valid?
  end

  defp list_children(socket, opts) do
    Social.list_child_groups_for_profile(
      socket.assigns.group,
      socket.assigns.current_profile,
      Keyword.merge(opts, children_filters(socket))
    )
  end

  # The loaded window with the count of all sub-groups, in one query.
  defp list_children_page(socket, opts) do
    Social.list_child_groups_page_for_profile(
      socket.assigns.group,
      socket.assigns.current_profile,
      Keyword.merge(opts, children_filters(socket))
    )
  end

  defp list_children_ids(socket, opts) do
    Social.list_child_group_ids_for_profile(
      socket.assigns.group,
      socket.assigns.current_profile,
      Keyword.merge(opts, children_filters(socket))
    )
  end

  # Threads start hidden; the browser sends the viewer's last choice (app.js).
  defp connect_show_threads?(socket),
    do: connected?(socket) and (get_connect_params(socket) || %{})["show_threads"] == true

  # So do the root's public groups the viewer is not in.
  defp connect_show_public_groups?(socket),
    do: connected?(socket) and (get_connect_params(socket) || %{})["show_public_groups"] == true

  # Hidden threads are filtered out; shown ones mix with the other sub-groups.
  # The root leaves out the public groups the viewer is not in until shown,
  # but those on the way to one of its groups. Direct conversations have no
  # kind and are all the viewer's own, so the kind and membership filters
  # leave them alone.
  defp children_filters(socket) do
    [
      is_direct: child_group_direct_filter(socket.assigns.sub_groups_kind),
      is_thread: if(socket.assigns.show_thread_sub_groups, do: nil, else: false),
      public: socket.assigns.show_public_sub_groups or not socket.assigns.group.is_root,
      search: normalize_children_search_query(socket.assigns.children_search_query),
      preset: children_narrowing(socket.assigns, :children_preset),
      relation: children_narrowing(socket.assigns, :children_relation)
    ]
  end

  defp children_narrowing(%{sub_groups_kind: "direct"}, _key), do: nil
  defp children_narrowing(assigns, key), do: Map.fetch!(assigns, key)

  # The threads filter is only offered when the group has thread sub-groups;
  # the count ignores the search so the filter stays put while searching.
  defp count_thread_children(%{assigns: %{group: %Group{is_root: true}}}), do: 0

  defp count_thread_children(socket) do
    Social.count_child_groups_for_profile(
      socket.assigns.group,
      socket.assigns.current_profile,
      is_direct: child_group_direct_filter(socket.assigns.sub_groups_kind),
      is_thread: true
    )
  end

  # Reloads keep the window the viewer already scrolled to; "load more" only
  # fetches the next page and appends it to the stream.
  defp reload_limit(%{loaded_count: loaded_count, per_page: per_page}),
    do: max(loaded_count, per_page)

  defp loaded_pagination(pagination, loaded_count, total_count) do
    %{
      pagination
      | loaded_count: loaded_count,
        total_count: total_count,
        has_more?: loaded_count < total_count
    }
  end

  defp reload_children(socket) do
    socket
    |> maybe_load_children(
      socket.assigns.group,
      socket.assigns.active_tab,
      socket.assigns.unread_overview
    )
    |> assign_child_pending_join_request_counts()
    |> assign_group_unread_counts()
  end

  defp load_more_children(socket) do
    pagination = socket.assigns.children_pagination

    if pagination.has_more? and needs_children?(socket.assigns.group, socket.assigns.active_tab) do
      loaded_ids = MapSet.new(socket.assigns.loaded_children, & &1.id)

      entries =
        socket
        |> list_children(limit: pagination.per_page, offset: pagination.loaded_count)
        |> Enum.reject(&MapSet.member?(loaded_ids, &1.id))
        |> Tags.put_tags(socket.assigns.current_profile, :group)

      loaded_children = socket.assigns.loaded_children ++ entries

      socket
      |> assign(:loaded_children, loaded_children)
      |> assign(
        :children_pagination,
        loaded_pagination(pagination, length(loaded_children), pagination.total_count)
      )
      |> merge_child_counts(entries)
      |> stream(:children, entries)
    else
      socket
    end
  end

  defp merge_child_counts(socket, children) do
    current_profile = socket.assigns.current_profile

    socket
    |> update(
      :group_unread_counts,
      &Map.merge(&1, unread_counts_for(socket, children))
    )
    |> update(
      :child_pending_join_request_counts,
      &Map.merge(&1, manageable_pending_join_request_counts(current_profile, children))
    )
  end

  # Only groups with pending requests need a permission check.
  defp manageable_pending_join_request_counts(current_profile, groups) do
    groups_by_id = Map.new(groups, &{&1.id, &1})

    groups
    |> Social.list_pending_group_join_request_counts()
    |> Map.filter(fn {group_id, _count} ->
      Access.can?(current_profile, Map.fetch!(groups_by_id, group_id), :manage_join_requests)
    end)
  end

  defp load_more_members(socket) do
    pagination = socket.assigns.members_pagination

    if pagination.has_more? and needs_members?(socket.assigns.group, socket.assigns.active_tab) do
      entries =
        socket.assigns.group
        |> Social.list_group_members(limit: pagination.per_page, offset: pagination.loaded_count)
        |> member_entries(socket.assigns.group, socket.assigns.current_profile)

      socket
      |> assign(
        :members_pagination,
        loaded_pagination(
          pagination,
          pagination.loaded_count + length(entries),
          pagination.total_count
        )
      )
      |> stream(:members, entries)
      |> watch_presence(Enum.map(entries, & &1.id))
    else
      socket
    end
  end

  defp load_more_values(socket) do
    if socket.assigns.values_has_more? and
         needs_values?(socket.assigns.group, socket.assigns.active_tab) do
      {older_values, has_more?} =
        Social.list_group_values_page(socket.assigns.group,
          before_id: socket.assigns.oldest_value_id,
          limit: @values_page_size
        )

      older_values = Tags.put_tags(older_values, socket.assigns.current_profile, :value)
      {socket, older_values} = PollsState.with_views(socket, older_values)

      socket
      |> update(:loaded_value_ids, fn ids -> Enum.into(older_values, ids, & &1.id) end)
      |> assign(:values_has_more?, has_more?)
      |> assign(:oldest_value_id, first_value_id(older_values) || socket.assigns.oldest_value_id)
      |> stream(:values, Enum.reverse(older_values), at: 0)
      |> prune_values(:newest)
      |> watch_presence(Enum.map(older_values, & &1.creator_id))
    else
      socket
    end
  end

  defp load_newer_values(socket) do
    if socket.assigns.values_has_newer? and
         needs_values?(socket.assigns.group, socket.assigns.active_tab) do
      {newer_values, has_newer?} =
        Social.list_group_values_page(socket.assigns.group,
          after_id: socket.assigns.newest_value_id,
          limit: @values_page_size
        )

      newer_values = Tags.put_tags(newer_values, socket.assigns.current_profile, :value)
      {socket, newer_values} = PollsState.with_views(socket, newer_values)

      socket
      |> update(:loaded_value_ids, fn ids -> Enum.into(newer_values, ids, & &1.id) end)
      |> assign(:values_has_newer?, has_newer?)
      |> assign(:newest_value_id, last_value_id(newer_values) || socket.assigns.newest_value_id)
      |> stream(:values, newer_values)
      |> prune_values(:oldest)
      |> watch_presence(Enum.map(newer_values, & &1.creator_id))
    else
      socket
    end
  end

  # Keeps the feed at `@values_max_loaded` values by dropping the excess from
  # one end; the values are contiguous by id, so the cursors move to the new
  # ends. Explicit deletes rather than the stream's `:limit`, which would count
  # the empty-state element among the values.
  defp prune_values(socket, drop) do
    loaded = socket.assigns.loaded_value_ids
    excess = MapSet.size(loaded) - @values_max_loaded

    if excess > 0 do
      sorted = Enum.sort(loaded)

      {dropped, kept, socket} =
        case drop do
          :oldest ->
            {dropped, kept} = Enum.split(sorted, excess)

            {dropped, kept,
             socket
             |> assign(:oldest_value_id, hd(kept))
             |> assign(:values_has_more?, true)}

          :newest ->
            {kept, dropped} = Enum.split(sorted, -excess)

            {dropped, kept,
             socket
             |> assign(:newest_value_id, List.last(kept))
             |> assign(:values_has_newer?, true)}
        end

      dropped
      |> Enum.reduce(socket, &stream_delete_by_dom_id(&2, :values, "value-#{&1}"))
      |> assign(:loaded_value_ids, MapSet.new(kept))
    else
      socket
    end
  end

  defp first_value_id([%{id: id} | _]), do: id
  defp first_value_id([]), do: nil

  defp last_value_id(values), do: values |> Enum.reverse() |> first_value_id()

  defp load_member_summary(socket, group) do
    if group.parent_id != nil do
      socket
      |> assign(:members_count, Social.count_group_members(group))
      |> assign(:first3_members, Social.list_first3_group_members(group))
    else
      socket
      |> assign(:members_count, 0)
      |> assign(:first3_members, [])
    end
  end

  defp load_join_request_data(socket, group, active_tab) do
    current_profile = socket.assigns.current_profile
    can_manage_join_requests = Access.can?(socket.assigns.access, :manage_join_requests)

    pending_join_request =
      if group.is_public and not socket.assigns.is_member do
        Social.get_pending_group_join_request(current_profile, group)
      else
        nil
      end

    pending_join_requests =
      if needs_members?(group, active_tab) and can_manage_join_requests do
        Social.list_pending_group_join_requests(group)
      else
        []
      end

    pending_join_requests_count =
      if can_manage_join_requests do
        Social.count_pending_group_join_requests(group)
      else
        0
      end

    group_blocks =
      if needs_members?(group, active_tab) and
           Access.can?(socket.assigns.access, :remove_members) do
        Social.list_group_blocks(group)
      else
        []
      end

    socket
    |> assign(:pending_join_request, pending_join_request)
    |> assign(:pending_join_requests, pending_join_requests)
    |> assign(:pending_join_requests_count, pending_join_requests_count)
    |> assign(:group_blocks, group_blocks)
  end

  defp maybe_load_children(socket, group, active_tab, unread_overview) do
    cond do
      not needs_children?(group, active_tab) ->
        socket
        |> assign(:loaded_children, [])
        |> assign(:sub_group_tree, nil)

      socket.assigns.sub_groups_view == "tree" ->
        load_sub_group_tree(socket, group)

      true ->
        pagination = socket.assigns.children_pagination

        {entries, total_count} =
          list_children_page(socket,
            limit: reload_limit(pagination),
            unread_overview: unread_overview
          )

        entries = Tags.put_tags(entries, socket.assigns.current_profile, :group)

        socket
        |> assign(:loaded_children, entries)
        |> assign(:sub_group_tree, nil)
        |> assign(
          :children_pagination,
          loaded_pagination(pagination, length(entries), total_count)
        )
        |> assign(:thread_sub_groups_count, count_thread_children(socket))
        |> stream(:children, entries, reset: true)
    end
  end

  # The folder view loads a level at a time (see `SubGroupTree`); a reload
  # keeps the folders that were open.
  defp load_sub_group_tree(socket, group) do
    filters = children_filters(socket)

    tree =
      SubGroupTree.load(group, socket.assigns.current_profile, socket.assigns.sub_group_tree,
        threads?: filters[:is_thread] != false,
        public?: filters[:public],
        search: filters[:search],
        preset: filters[:preset],
        relation: filters[:relation],
        thread_count: count_thread_children(socket)
      )

    socket
    |> assign(:loaded_children, [])
    |> assign_sub_group_tree(tree)
    # The panel always takes `@streams.children`, so it must exist.
    |> stream(:children, [], reset: true)
  end

  # The pagination only carries the top-level count, so the list's empty
  # states work for the tree too.
  defp assign_sub_group_tree(socket, tree) do
    top_level_count = length(tree.nodes)

    socket
    |> assign(:sub_group_tree, tree)
    |> assign(
      :children_pagination,
      loaded_pagination(socket.assigns.children_pagination, top_level_count, top_level_count)
    )
    |> assign(:thread_sub_groups_count, tree.thread_count)
  end

  # Opening a folder or loading another page adds folders, which then need
  # their unread counts.
  defp update_sub_group_tree(%{assigns: %{sub_group_tree: %{} = tree}} = socket, fun) do
    socket
    |> assign_sub_group_tree(fun.(tree))
    |> assign_group_unread_counts()
  end

  defp update_sub_group_tree(socket, _fun), do: socket

  defp maybe_load_members(socket, group, active_tab) do
    if needs_members?(group, active_tab) do
      pagination = socket.assigns.members_pagination

      entries =
        group
        |> Social.list_group_members(limit: reload_limit(pagination))
        |> member_entries(group, socket.assigns.current_profile)

      socket
      |> assign(
        :members_pagination,
        loaded_pagination(pagination, length(entries), Social.count_group_members(group))
      )
      |> stream(:members, entries, reset: true)
      |> watch_presence(Enum.map(entries, & &1.id))
    else
      socket
    end
  end

  # The first load after a `?value=` link opens the chat around that value,
  # which the `.ValuesFeed` hook then scrolls to; a value not in this chat is
  # dropped. A feed showing earlier values reloads the same span, and one at
  # the newest reloads as many of the newest as it had.
  defp maybe_load_values(socket, group, active_tab) do
    if needs_values?(group, active_tab) do
      %{focus_value_id: focus_value_id, loaded_value_ids: loaded} = socket.assigns
      limit = max(MapSet.size(loaded), @values_page_size)

      cond do
        is_integer(focus_value_id) and MapSet.size(loaded) == 0 ->
          case load_values_around(socket, focus_value_id) do
            {:ok, socket} ->
              socket

            :error ->
              socket
              |> assign(:focus_value_id, nil)
              |> load_latest_values(group)
          end

        socket.assigns.values_has_newer? and is_integer(socket.assigns.oldest_value_id) ->
          {values, has_newer?} =
            Social.list_group_values_page(group,
              after_id: socket.assigns.oldest_value_id - 1,
              limit: limit
            )

          put_values(socket, values, socket.assigns.values_has_more?, has_newer?)

        true ->
          load_latest_values(socket, group, limit)
      end
    else
      socket
    end
  end

  defp load_latest_values(socket, group, limit \\ @values_page_size) do
    {values, has_more?} = Social.list_group_values_page(group, limit: limit)
    put_values(socket, values, has_more?, false)
  end

  defp load_values_around(socket, value_id) do
    case Social.list_group_values_around(socket.assigns.group, value_id,
           older: @values_window_older,
           newer: @values_window_newer
         ) do
      {values, has_more?, has_newer?} -> {:ok, put_values(socket, values, has_more?, has_newer?)}
      nil -> :error
    end
  end

  # Replaces the feed with `values`, a contiguous run oldest first.
  defp put_values(socket, values, has_more?, has_newer?) do
    values = Tags.put_tags(values, socket.assigns.current_profile, :value)
    {socket, values} = PollsState.with_views(socket, values)

    socket
    |> assign(:loaded_value_ids, MapSet.new(values, & &1.id))
    |> assign(:values_has_more?, has_more?)
    |> assign(:values_has_newer?, has_newer?)
    |> assign(:oldest_value_id, first_value_id(values))
    |> assign(:newest_value_id, last_value_id(values))
    |> stream(:values, values, reset: true)
    |> watch_presence(Enum.map(values, & &1.creator_id))
  end

  defp parse_focus_value_id(param) when is_binary(param) do
    case Integer.parse(param) do
      {id, ""} when id > 0 -> id
      _ -> nil
    end
  end

  defp parse_focus_value_id(_param), do: nil

  # `?share=` names content shared from another app that waits on the device
  # (see `ShareLive`); the composer's `ShareComposer` hook takes it from there.
  defp parse_share_id(param) when is_binary(param) do
    if Regex.match?(~r/\A[A-Za-z0-9_-]{1,64}\z/, param), do: param
  end

  defp parse_share_id(_param), do: nil

  # The names of skipped shared files for a flash, a few at most.
  defp skipped_share_names(names) when is_list(names) do
    names = Enum.filter(names, &(is_binary(&1) and &1 != ""))
    shown = names |> Enum.take(5) |> Enum.map_join(", ", &String.slice(&1, 0, 80))

    case length(names) - 5 do
      more when more > 0 -> gettext("%{names} and %{count} more", names: shown, count: more)
      _none -> shown
    end
  end

  defp skipped_share_names(_names), do: ""

  defp maybe_load_files(socket, group, "files") do
    case socket.assigns.files_view do
      "tree" ->
        {tree, truncated?} = Social.attachment_tree(group, socket.assigns.current_profile)

        socket
        |> assign(:file_tree, tree)
        |> assign(:file_tree_truncated?, truncated?)

      _list ->
        limit = max(socket.assigns.files_loaded_count, @files_page_size)
        {files, has_more?} = Social.list_group_attachments(group, limit: limit)
        files = Tags.put_tags(files, socket.assigns.current_profile, :attachment)

        socket
        |> assign(:files_has_more?, has_more?)
        |> assign(:files_loaded_count, length(files))
        |> assign(:oldest_file_id, last_value_id(files))
        |> stream(:files, files, reset: true)
    end
  end

  defp maybe_load_files(socket, _group, _active_tab), do: socket

  defp load_more_files(%{assigns: %{files_has_more?: true, oldest_file_id: before_id}} = socket)
       when is_integer(before_id) do
    {files, has_more?} =
      Social.list_group_attachments(socket.assigns.group,
        limit: @files_page_size,
        before_id: before_id
      )

    files = Tags.put_tags(files, socket.assigns.current_profile, :attachment)

    socket
    |> assign(:files_has_more?, has_more?)
    |> update(:files_loaded_count, &(&1 + length(files)))
    |> assign(:oldest_file_id, last_value_id(files) || before_id)
    |> stream(:files, files)
  end

  defp load_more_files(socket), do: socket

  # Members are streamed with their role keys in the group, what they hold
  # through the parent, which the group itself cannot take away, and the
  # tags the viewer sees on them.
  defp member_entries(profiles, group, viewer) do
    profile_ids = Enum.map(profiles, & &1.id)
    keys_by_profile = Access.role_keys_by_profile(group, profile_ids)
    inherited = Access.inherited_by_profile(group, profile_ids)

    profiles
    |> Tags.put_tags(viewer, :profile)
    |> Enum.map(fn profile ->
      %{
        id: profile.id,
        profile: profile,
        role_keys: Map.get(keys_by_profile, profile.id, []),
        inherited?: Map.has_key?(inherited, profile.id),
        inherited_role_keys: Map.get(inherited, profile.id, [])
      }
    end)
  end

  defp restream_member(socket, profile_id) do
    group = socket.assigns.group

    if needs_members?(group, socket.assigns.active_tab) do
      case Social.get_profile(profile_id) do
        nil ->
          socket

        profile ->
          [entry] = member_entries([profile], group, socket.assigns.current_profile)
          stream_insert(socket, :members, entry)
      end
    else
      socket
    end
  end

  defp maybe_load_roles(socket, group, "roles") do
    manifest = socket.assigns.access.manifest

    manifest_owner =
      if manifest && manifest.group_id != group.id, do: Social.get_group!(manifest.group_id)

    socket
    |> assign(:manifest_owner, manifest_owner)
    |> assign(:role_member_counts, Access.role_member_counts(group))
  end

  defp maybe_load_roles(socket, _group, _active_tab), do: socket

  defp assign_access(socket, %Access{} = access) do
    socket
    |> assign(:access, access)
    |> assign(:is_member, access.member?)
  end

  # After the viewer changed roles: their own access and the roles tab. Other
  # viewers catch up through the `group_roles_updated` broadcast.
  defp reload_access(socket) do
    group = socket.assigns.group

    socket
    |> assign_access(Social.get_group_access(socket.assigns.current_profile, group))
    |> put_active_alt_description()
    |> maybe_load_roles(group, socket.assigns.active_tab)
  end

  defp empty_new_role_form, do: to_form(Social.change_group_role(%GroupRole{}))

  defp mention_candidate_payload(%{kind: :role} = role) do
    %{
      kind: "role",
      name: role.name,
      everyone: role.key == GroupRole.everyone_key(),
      hint:
        ngettext("Role · %{count} member", "Role · %{count} members", role.member_count,
          count: role.member_count
        )
    }
  end

  defp mention_candidate_payload(%{kind: :profile} = profile) do
    %{
      kind: "profile",
      name: profile.name,
      avatar_url: PotokIdeWeb.Avatars.profile_avatar_url(profile)
    }
  end

  defp parse_permission(permission) do
    Enum.find(GroupRole.permissions(), &(Atom.to_string(&1) == permission))
  end

  defp parse_permission_state("allow"), do: :allow
  defp parse_permission_state("deny"), do: :deny
  defp parse_permission_state("neutral"), do: :neutral
  defp parse_permission_state(_state), do: nil

  defp too_many_values_message, do: gettext("Too many messages at once. Try again in a moment.")

  defp access_error_message(:not_permitted),
    do: gettext("Your roles in this group do not allow that.")

  defp access_error_message(:last_admin), do: gettext("A group must keep at least one admin.")

  defp access_error_message(:direct_group),
    do: gettext("Direct conversations do not have roles or invitations.")

  defp access_error_message(:manifest_is_inherited),
    do: gettext("This group inherits its roles. Create its own manifest to change them.")

  defp access_error_message(:root_manifest_is_fixed),
    do: gettext("The default manifest cannot be changed.")

  defp access_error_message(:own_manifest),
    do: gettext("This group already has its own manifest.")

  defp access_error_message(:builtin_role),
    do: gettext("The admin and everyone roles cannot be renamed or deleted.")

  defp access_error_message(:role_not_found), do: gettext("Role not found.")

  defp access_error_message(:inherited_member),
    do: gettext("This member comes from the parent group. Remove them there.")

  defp access_error_message(:inherited_role),
    do: gettext("This role comes from the parent group. Change it there.")

  defp access_error_message(:not_a_group_member),
    do: gettext("That profile is not a group member.")

  defp access_error_message(_reason), do: gettext("Could not update roles.")

  defp changeset_error_message(%Ecto.Changeset{errors: [{field, error} | _]}) do
    "#{Phoenix.Naming.humanize(field)} #{translate_error(error)}"
  end

  defp changeset_error_message(_changeset), do: gettext("Could not update roles.")

  # The value a thread group was started from, shown above its chat.
  defp maybe_load_thread_origin(socket, group, active_tab) do
    thread_origin =
      if group.parent_value_id && needs_values?(group, active_tab) do
        Social.get_thread_origin(socket.assigns.current_profile, group)
      end

    assign(socket, :thread_origin, thread_origin)
  end

  defp maybe_load_value_parent_options(socket, _group, active_tab) do
    if needs_value_parent_options?(socket, active_tab) do
      socket
      # skip loading parent options
      # |> assign(:value_parent_options, value_parent_options(Social.list_group_values(group)))
    else
      socket
    end
  end

  # A value that just arrived is the newest one the viewer has seen, so its id
  # is the read marker; no need to look up the group's latest value. Only members
  # have unread counts, and in an open chat everyone on the page would write it.
  #
  # Writing it for every value cost one database write per viewer per value
  # (a group of ~140 viewers wrote 120 per post in the load test). The page
  # writes it at most once every few seconds, with the newest id it has
  # shown, and when it leaves (`terminate/2`). The profile's other pages learn
  # of it that much later.
  defp mark_value_read(%{assigns: %{is_member: false}} = socket, %Value{}), do: socket

  defp mark_value_read(socket, %Value{id: value_id}) do
    pending = max(socket.private[:read_marker_value_id] || 0, value_id)
    socket = put_private(socket, :read_marker_value_id, pending)

    cond do
      @read_marker_delay_ms == 0 ->
        flush_read_marker(socket)

      socket.private[:read_marker_scheduled?] ->
        socket

      true ->
        Process.send_after(self(), :flush_read_marker, @read_marker_delay_ms)
        put_private(socket, :read_marker_scheduled?, true)
    end
  end

  defp flush_read_marker(socket) do
    case socket.private[:read_marker_value_id] do
      nil ->
        socket

      value_id ->
        _ =
          Social.mark_group_values_read(
            socket.assigns.current_profile,
            socket.assigns.group,
            value_id
          )

        put_private(socket, :read_marker_value_id, nil)
    end
  end

  defp maybe_mark_group_values_read(socket, group, active_tab) do
    if needs_values?(group, active_tab) and socket.assigns.current_profile do
      _ = Social.mark_group_values_read(socket.assigns.current_profile, group)
      socket
    else
      socket
    end
  end

  defp assign_group_unread_counts(socket) do
    assign_group_unread_counts(socket, current_unread_overview(socket))
  end

  defp unread_counts_for(socket, groups) do
    socket
    |> current_unread_overview()
    |> Social.unread_counts_for(Enum.map(groups, & &1.id))
  end

  # The overview the page keeps up to date; only a page that has not loaded
  # its panel yet counts.
  defp current_unread_overview(socket) do
    socket.assigns.unread_overview || Social.unread_overview(socket.assigns.current_profile)
  end

  # Every count holds the threads, hidden or not, so a value in one can be
  # followed from the header's badge down to it: the rows lead to the group,
  # and there the threads switch and the chat's thread links show it.
  defp assign_group_unread_counts(%{assigns: %{group: group}} = socket, overview) do
    tree_ids =
      case Map.get(socket.assigns, :sub_group_tree) do
        %{ids: ids} -> ids
        nil -> []
      end

    group_ids =
      [group.id | Enum.map(Map.get(socket.assigns, :loaded_children, []), & &1.id)] ++ tree_ids

    group_unread_counts = Social.unread_counts_for(overview, group_ids)
    current_group_unread_count = get_in(overview.groups, [group.id, :own]) || 0

    sub_groups_unread_count =
      max(Map.get(group_unread_counts, group.id, 0) - current_group_unread_count, 0)

    %{direct: direct_sub_groups_unread_count, other: other_sub_groups_unread_count} =
      Social.child_unread_summary(overview, group.id)

    thread_unread_counts = Social.thread_unread_counts(overview, [group.id | tree_ids])

    socket
    |> assign(:thread_unread_counts, thread_unread_counts)
    |> assign(:thread_sub_groups_unread_count, thread_unread_counts |> Map.values() |> Enum.sum())
    |> assign(:group_unread_counts, group_unread_counts)
    |> assign(:current_group_unread_count, current_group_unread_count)
    |> assign(:sub_groups_unread_count, sub_groups_unread_count)
    |> assign(:direct_sub_groups_unread_count, direct_sub_groups_unread_count)
    |> assign(:other_sub_groups_unread_count, other_sub_groups_unread_count)
    |> put_sub_group_tree_unread_counts()
  end

  # Each folder carries its own unread count instead of the folder view
  # taking the whole map: LiveView re-sends a `:for` entry only when its
  # node changed, so a new value re-sends just the folders on its path.
  defp put_sub_group_tree_unread_counts(%{assigns: %{sub_group_tree: %{} = tree}} = socket) do
    counts = socket.assigns.group_unread_counts
    assign(socket, :sub_group_tree, %{tree | nodes: put_node_unread_counts(tree.nodes, counts)})
  end

  defp put_sub_group_tree_unread_counts(socket), do: socket

  defp put_node_unread_counts(nil, _counts), do: nil

  defp put_node_unread_counts(nodes, counts) do
    Enum.map(nodes, fn node ->
      %{
        node
        | children: put_node_unread_counts(node.children, counts),
          unread_count: Map.get(counts, node.group.id, 0)
      }
    end)
  end

  defp assign_child_pending_join_request_counts(%{assigns: %{current_profile: nil}} = socket) do
    assign(socket, :child_pending_join_request_counts, %{})
  end

  defp assign_child_pending_join_request_counts(socket) do
    assign(
      socket,
      :child_pending_join_request_counts,
      manageable_pending_join_request_counts(
        socket.assigns.current_profile,
        Map.get(socket.assigns, :loaded_children, [])
      )
    )
  end

  defp maybe_push_root_group_unread_count(socket) do
    if connected?(socket) do
      push_event(socket, "root_group_unread_count_updated", %{
        count: socket.assigns.root_group_unread_count
      })
    else
      socket
    end
  end

  # A sub-group concerns this page's list when the list is on screen and
  # holds it, or when it may be on it or counted by it (hidden threads have a
  # count): a public one where the list shows public groups (the root only
  # with its switch on), one that inherits this group's members when the
  # viewer is one, or the viewer's own. The folder view is always read again,
  # as its open folders are not tracked here.
  defp child_on_list?(socket, child) do
    %{group: group, active_tab: active_tab, current_profile: profile} = socket.assigns

    cond do
      not needs_children?(group, active_tab) ->
        false

      socket.assigns[:sub_groups_view] == "tree" ->
        true

      Enum.any?(socket.assigns.loaded_children, &(&1.id == child.id)) ->
        true

      child.public? and (socket.assigns[:show_public_sub_groups] == true or not group.is_root) ->
        true

      child.inherits? and socket.assigns[:is_member] == true ->
        true

      true ->
        child.creator_id == profile.id
    end
  end

  defp needs_children?(group, active_tab) do
    active_tab == "sub_groups" or (group.parent_id == nil and active_tab == "values")
  end

  defp needs_members?(group, active_tab) do
    group.parent_id != nil and active_tab == "members"
  end

  defp needs_values?(group, active_tab) do
    group.parent_id != nil and active_tab == "values"
  end

  defp needs_value_parent_options?(socket, active_tab) do
    socket.assigns.is_member and active_tab == "create_group"
  end

  defp home_page_options do
    [
      {gettext("Description"), :description},
      {gettext("Messages"), :chat},
      {gettext("Sub-groups"), :subgroups}
    ]
  end

  # Direct conversations are flat, so they have no folder view.
  defp normalize_sub_groups_view("tree", sub_groups_kind) when sub_groups_kind != "direct",
    do: "tree"

  defp normalize_sub_groups_view(_view, _sub_groups_kind), do: "list"

  defp normalize_sub_groups_kind(_kind, %Group{is_root: false}), do: "other"
  defp normalize_sub_groups_kind("direct", %Group{is_root: true}), do: "direct"
  defp normalize_sub_groups_kind("other", %Group{is_root: true}), do: "other"
  defp normalize_sub_groups_kind(_, %Group{is_root: true}), do: "other"

  defp normalize_children_search_query(query) when is_binary(query) do
    query
    |> String.trim()
    |> String.slice(0, 120)
  end

  defp normalize_children_search_query(_), do: ""

  defp child_group_direct_filter("direct"), do: true
  defp child_group_direct_filter("other"), do: false
  defp child_group_direct_filter(_), do: false

  defp default_active_tab(%Group{is_root: true}), do: "sub_groups"
  defp default_active_tab(%Group{is_direct: true}), do: "values"
  defp default_active_tab(%Group{home_page: :chat}), do: "values"
  defp default_active_tab(%Group{home_page: :subgroups}), do: "sub_groups"
  defp default_active_tab(%Group{}), do: "group_home"

  # The count is only loaded for profiles that manage access requests.
  defp group_tab_path(%Group{} = group, tab, opts) do
    base_path = ~p"/groups/#{group.id}/#{tab}"

    query_params =
      %{}
      |> maybe_put_sub_groups_kind_query(group, tab, opts[:sub_groups_kind])
      |> maybe_put_sub_groups_view_query(group, tab, opts)

    append_query_params(base_path, query_params)
  end

  defp maybe_put_sub_groups_kind_query(query_params, group, tab, sub_groups_kind) do
    if group.is_root and needs_children?(group, tab) do
      Map.put(query_params, "sub_groups_kind", normalize_sub_groups_kind(sub_groups_kind, group))
    else
      query_params
    end
  end

  # The list is the default, so only the folder view shows up in the URL.
  defp maybe_put_sub_groups_view_query(query_params, group, tab, opts) do
    sub_groups_kind = normalize_sub_groups_kind(opts[:sub_groups_kind], group)

    if needs_children?(group, tab) and
         normalize_sub_groups_view(opts[:sub_groups_view], sub_groups_kind) == "tree" do
      Map.put(query_params, "view", "tree")
    else
      query_params
    end
  end

  defp append_query_params(path, query_params) when map_size(query_params) == 0, do: path

  defp append_query_params(path, query_params) do
    path <> "?" <> URI.encode_query(query_params)
  end

  # A parent the profile cannot see would only turn it away: the root lists
  # such a group instead (`Social.list_child_groups_for_profile/3`).
  defp back_path(%Group{parent_id: parent_id, parent_value_id: value_id}, path) do
    cond do
      not Enum.any?(path, &(&1.id == parent_id)) -> ~p"/groups"
      value_id -> ~p"/groups/#{parent_id}/values"
      true -> ~p"/groups/#{parent_id}/sub_groups"
    end
  end

  defp delete_group_redirect_path(nil), do: ~p"/groups"
  defp delete_group_redirect_path(parent_id), do: ~p"/groups/#{parent_id}"

  defp normalize_active_tab(tab, _group, _access)
       when tab in ["values", "sub_groups", "members", "group_home"],
       do: tab

  defp normalize_active_tab("roles", %Group{is_direct: false}, %Access{member?: true}),
    do: "roles"

  # In the root group, the events of every group the profile is in.
  defp normalize_active_tab("calendar", group, %Access{} = access) do
    if calendar_tab?(group, access), do: "calendar", else: default_active_tab(group)
  end

  # In the root group, every group with a place the profile sees.
  defp normalize_active_tab("map", %Group{is_root: true}, _access), do: "map"

  defp normalize_active_tab("polls", group, %Access{} = access) do
    if polls_tab?(group, access), do: "polls", else: default_active_tab(group)
  end

  defp normalize_active_tab("files", %Group{parent_id: parent_id}, %Access{member?: true})
       when not is_nil(parent_id),
       do: "files"

  defp normalize_active_tab(tab, group, %Access{} = access)
       when tab in ["create_group", "invite_profile", "edit_group"] do
    if Access.can?(access, tab_permission(tab)), do: tab, else: default_active_tab(group)
  end

  defp normalize_active_tab(_, group, _access), do: default_active_tab(group)

  # Members have the calendar; those who are not see the public events of a
  # public group in it, when it has some.
  defp calendar_tab?(_group, %Access{member?: true}), do: true

  defp calendar_tab?(%Group{is_public: true, is_root: false} = group, _access),
    do: Events.public_events?(group)

  defp calendar_tab?(_group, _access), do: false

  # Members have the overview, in the root of all their groups; those who are not
  # see the public polls of a public group in it, when it has some. Direct
  # conversations have no roles to give a poll its rules.
  defp polls_tab?(%Group{is_direct: true}, _access), do: false
  defp polls_tab?(_group, %Access{member?: true}), do: true
  defp polls_tab?(%Group{} = group, _access), do: Polls.public_polls?(group)

  # A sixth section does not fit every phone, so a group has it once it has a
  # poll. Until then the group's menu leads there. The root has no bar.
  defp polls_section?(%Group{is_root: true}, _access), do: false
  defp polls_section?(%Group{is_direct: true}, _access), do: false
  defp polls_section?(group, %Access{member?: true}), do: Polls.any?(group)
  defp polls_section?(group, _access), do: Polls.public_polls?(group)

  defp refresh_polls_section(socket, {kind, _poll_id}) when kind in [:changed, :deleted] do
    assign(socket, :polls_section?, polls_section?(socket.assigns.group, socket.assigns.access))
  end

  defp refresh_polls_section(socket, _message), do: socket

  defp tab_permission("create_group"), do: :create_subgroups
  defp tab_permission("invite_profile"), do: :invite_members
  defp tab_permission("edit_group"), do: :edit_group

  defp root_kind_class(active?) do
    [
      "inline-flex h-9 min-w-0 cursor-pointer items-center gap-1.5 rounded-full px-3 text-sm font-semibold transition duration-150 ease-out active:scale-95 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40",
      if(active?,
        do: "bg-base-100 text-base-content shadow-sm",
        else: "text-base-content/65 hover:text-base-content"
      )
    ]
  end

  defp header_tabs(group, member?, active_tab, flags, {unread, sub_groups_unread, requests}) do
    badges = %{
      "values" => %{badge: unread, badge_id: "group-values-unread-badge"},
      "sub_groups" => %{badge: sub_groups_unread, badge_id: "group-sub-groups-unread-badge"},
      "members" => %{
        badge: requests,
        badge_id: "group-join-requests-badge",
        badge_tone: :attention
      }
    }

    group
    |> GroupMenu.sections(member?, flags)
    |> Enum.map(fn section ->
      section
      |> Map.merge(%{
        id: "group-#{section.key}-summary",
        active?: section_active?(section, group, active_tab)
      })
      |> Map.merge(Map.get(badges, section.tab, %{}))
    end)
  end

  defp section_active?(%{tab: "sub_groups"}, group, active_tab),
    do: needs_children?(group, active_tab)

  defp section_active?(section, _group, active_tab), do: section.tab == active_tab

  # Header shortcuts of the root: the active one gets a thin ring. `-m-1 p-1`
  # makes room for it around the icon without taking more room in the header.
  defp header_shortcut_class(active?) do
    [
      "relative -m-1 inline-flex cursor-pointer items-center justify-center rounded-full p-1 transition duration-150 hover:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40",
      active? && "ring-1 ring-base-content/30"
    ]
  end

  defp normalize_select_nil(attrs, key) when is_binary(key) do
    case Map.get(attrs, key) do
      "" -> Map.put(attrs, key, nil)
      _ -> attrs
    end
  end

  defp handle_join_request_action(socket, id, action, success_message) do
    current_profile = socket.assigns.current_profile
    group = socket.assigns.group

    case Integer.parse(id) do
      {request_id, ""} ->
        case action.(current_profile, group, request_id) do
          {:ok, _result} ->
            {:noreply,
             socket
             |> put_flash(:info, success_message)
             |> refresh_group_data()}

          {:error, :not_permitted} ->
            {:noreply, put_flash(socket, :error, access_error_message(:not_permitted))}

          {:error, :request_not_found} ->
            {:noreply, put_flash(socket, :error, gettext("Access request not found."))}

          {:error, %Ecto.Changeset{}} ->
            {:noreply, put_flash(socket, :error, gettext("Could not update access request."))}

          {:error, _reason} ->
            {:noreply, put_flash(socket, :error, gettext("Could not update access request."))}
        end

      _ ->
        {:noreply, put_flash(socket, :error, gettext("Access request not found."))}
    end
  end

  defp can_view_group?(group, is_member) do
    group.is_public or is_member
  end

  # Links to a public event in its group's calendar (push notifications,
  # calendar files) open it in the root calendar for those who are no
  # members of the group and cannot open its calendar (a private group).
  defp public_event_path(
         %{"tab" => "calendar", "event" => event_id} = params,
         %Access{member?: false},
         active_tab,
         %Profile{} = profile
       )
       when active_tab != "calendar" do
    with {id, ""} <- Integer.parse(event_id),
         {:ok, event} <- Events.get_event(profile, id) do
      query = params |> Map.take(["month", "on"]) |> Map.put("event", event.id)
      ~p"/groups/#{Social.get_root_group!().id}/calendar?#{query}"
    else
      _ -> nil
    end
  end

  defp public_event_path(_params, _access, _active_tab, _profile), do: nil
end
