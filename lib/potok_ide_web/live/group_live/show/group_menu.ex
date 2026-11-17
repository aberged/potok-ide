defmodule PotokIdeWeb.GroupLive.Show.GroupMenu do
  @moduledoc """
  What can be done with a group, in the two menus that offer it: the one of
  the open group, and the one on each row of the sub-groups tab. Both draw
  `items/1`, so an option added there reaches both.

  A row also leads to the sections of its group, which the open group has in
  its bar. `sections/3` is that list, for both of them.

  The rows do not carry their menus. What a viewer may do depends on the group,
  so a row only has a button, and the page loads that group and draws its menu
  once, when the button is pressed.
  """

  use PotokIdeWeb, :html

  alias PotokIde.Notices
  alias PotokIde.Social.{Access, Group}
  alias PotokIdeWeb.GroupLive.Show.Components
  alias PotokIdeWeb.TagComponents

  @row_prefix "group-row"

  # A bar of more does not fit every phone: past this, notices give way.
  @max_sections 6

  @doc """
  The sections of a group, in the order of its bar. The root has none: its
  header switches between conversations and groups. `flags` says whether it has
  a calendar (`:calendar?`), polls (`:polls?`) and notices (`:notices?`), as
  these take a query. Notices join only while the bar has room for them; the
  group's menu and its bell always lead there.
  """
  def sections(%Group{is_root: true}, _member?, _flags), do: []

  def sections(%Group{} = group, member?, %{calendar?: calendar?, polls?: polls?} = flags) do
    member_of_group? = member? and group.parent_id != nil

    [
      (member? or Group.open_chat?(group)) &&
        %{
          key: "values",
          tab: "values",
          icon: "hero-chat-bubble-oval-left-ellipsis",
          label: gettext("Messages")
        },
      member_of_group? &&
        %{key: "files", tab: "files", icon: "hero-paper-clip", label: gettext("Files")},
      calendar? &&
        %{
          key: "calendar",
          tab: "calendar",
          icon: "hero-calendar-days",
          label: gettext("Calendar")
        },
      polls? &&
        %{key: "polls", tab: "polls", icon: "hero-chart-bar", label: dgettext("polls", "Polls")},
      Map.get(flags, :notices?, false) &&
        %{key: "notices", tab: "notices", icon: "hero-bell-alert", label: gettext("Notices")},
      # Threads are sub-groups, which direct conversations do not have.
      ((member? or group.is_public) and not group.is_direct) &&
        %{
          key: "subgroups",
          tab: "sub_groups",
          icon: "hero-folder-open",
          label: gettext("Sub-groups")
        },
      member_of_group? &&
        %{
          key: "members",
          tab: "members",
          icon: "hero-user-group",
          label: gettext("Members")
        }
    ]
    |> Enum.filter(& &1)
    |> fit_bar()
  end

  defp fit_bar(sections) when length(sections) > @max_sections,
    do: Enum.reject(sections, &(&1.key == "notices"))

  defp fit_bar(sections), do: sections

  attr :group, :map, required: true
  attr :access, :any, required: true, doc: "the viewer's access to `group`"
  attr :id_prefix, :string, default: "group"

  attr :active_tab, :string,
    default: nil,
    doc: "the tab on screen when `group` is the open group; without it the items lead there"

  attr :mute, :map,
    default: nil,
    doc:
      "`%{until: nil | DateTime}` when the viewer may silence the group (`mute_state/3`), nil otherwise"

  attr :pin, :map,
    default: nil,
    doc:
      "`%{pinned?: boolean}` when the viewer may pin the group in its column (`pin_state/3`), nil otherwise"

  slot :inner_block, doc: "what only this menu offers, before the rest"

  def items(assigns) do
    assigns = assign(assigns, :row?, is_nil(assigns.active_tab))

    ~H"""
    <div class="flex min-w-56 flex-col gap-2 z-100">
      {render_slot(@inner_block)}
      <.mute_item :if={@mute} group={@group} mute={@mute} id_prefix={@id_prefix} row?={@row?} />
      <.pin_item :if={@pin} group={@group} pin={@pin} id_prefix={@id_prefix} row?={@row?} />
      <.tab_item
        :if={!@group.is_root}
        id={"#{@id_prefix}-tab-group-home"}
        group={@group}
        tab="group_home"
        active_tab={@active_tab}
        label={gettext("About the group")}
        icon="hero-information-circle"
      />
      <button
        :if={Group.guest_preview?(@group)}
        id={"#{@id_prefix}-share-button"}
        type="button"
        data-dropdown-close
        data-share-link={url(~p"/groups/#{@group.id}")}
        phx-click={@row? && "group_row_menu_close"}
        class={item_class()}
      >
        <.icon name="hero-share" class="size-4" />
        <span class="ml-2 truncate">{gettext("Share")}</span>
      </button>
      <button
        :if={!@group.is_root}
        id={"#{@id_prefix}-tags-button"}
        type="button"
        data-dropdown-close
        phx-click={open_dialog("tag_editor_open", %{kind: "group", id: @group.id}, @row?)}
        class={item_class()}
      >
        <.icon name="hero-hashtag" class="size-4" />
        <span class="ml-2 truncate">{gettext("Tags of this group")}</span>
      </button>
      <.link
        id={"#{@id_prefix}-tags-browse"}
        navigate={TagComponents.tags_path([], if(@group.is_root, do: nil, else: @group.id))}
        class={item_class()}
      >
        <.icon name="hero-squares-2x2" class="size-4" />
        <span class="ml-2 truncate">{gettext("Browse by tags")}</span>
      </.link>
      <.tab_item
        :if={Notices.followable?(@group)}
        id={"#{@id_prefix}-tab-notices"}
        group={@group}
        tab="notices"
        active_tab={@active_tab}
        label={gettext("Notices")}
        icon="hero-bell-alert"
      />
      <.tab_item
        :if={@access.member? and !@group.is_direct}
        id={"#{@id_prefix}-tab-roles"}
        group={@group}
        tab="roles"
        active_tab={@active_tab}
        label={gettext("Roles")}
        icon="hero-shield-check"
      />
      <button
        :if={Access.can?(@access, :create_subgroups)}
        id={"#{@id_prefix}-tab-create-sub-group"}
        type="button"
        data-dropdown-close
        phx-click={open_dialog("group_create_menu_open", %{id: @group.id}, @row?)}
        class={item_class()}
      >
        <.icon name="hero-folder-plus" class="size-4" />
        <span class="ml-2 truncate">{gettext("Create sub-group")}</span>
      </button>
      <.tab_item
        :if={
          @group.parent_id != nil && !@group.is_direct &&
            Access.can?(@access, :invite_members)
        }
        id={"#{@id_prefix}-tab-invite-profile"}
        group={@group}
        tab="invite_profile"
        active_tab={@active_tab}
        label={gettext("Invite profile")}
        icon="hero-user-plus"
      />
      <.tab_item
        :if={Access.can?(@access, :edit_group) and !@group.is_root}
        id={"#{@id_prefix}-tab-edit-group"}
        group={@group}
        tab="edit_group"
        active_tab={@active_tab}
        label={gettext("Edit group")}
        icon="hero-cog-6-tooth"
      />
    </div>
    """
  end

  @doc """
  What the menu of `group` offers to silence it: its members can, in any
  group but the root and a thread, which follows its conversation.
  `muted_until` is the viewer's (`Social.group_muted_until/2`).
  """
  def mute_state(%Group{is_root: true}, _member?, _muted_until), do: nil
  def mute_state(%Group{parent_value_id: id}, _member?, _muted_until) when not is_nil(id), do: nil
  def mute_state(%Group{}, true = _member?, muted_until), do: %{until: muted_until}
  def mute_state(%Group{}, _member?, _muted_until), do: nil

  attr :group, :map, required: true
  attr :mute, :map, required: true
  attr :id_prefix, :string, required: true
  attr :row?, :boolean, required: true

  # Silences the group for a while, or lets it speak again. The lengths open
  # below the item, inside the same menu.
  defp mute_item(%{mute: %{until: nil}} = assigns) do
    ~H"""
    <details id={"#{@id_prefix}-mute"} class="group/mute">
      <summary class={[item_class(), "cursor-pointer list-none [&::-webkit-details-marker]:hidden"]}>
        <.icon name="hero-speaker-x-mark" class="size-4" />
        <span class="ml-2 truncate">{gettext("Mute")}</span>
        <.icon
          name="hero-chevron-down"
          class="ml-auto size-4 transition-transform duration-150 group-open/mute:rotate-180"
        />
      </summary>
      <div class="mt-1 flex flex-col gap-1 pl-6">
        <button
          :for={{duration, label} <- mute_choices()}
          id={"#{@id_prefix}-mute-#{duration}"}
          type="button"
          data-dropdown-close
          phx-click={mute_click(@group, duration, @row?)}
          class={[item_class(), "py-1.5"]}
        >
          {label}
        </button>
      </div>
    </details>
    """
  end

  defp mute_item(assigns) do
    ~H"""
    <button
      id={"#{@id_prefix}-unmute"}
      type="button"
      data-dropdown-close
      phx-click={mute_click(@group, "off", @row?)}
      class={[item_class(), "flex-wrap"]}
    >
      <.icon name="hero-speaker-wave" class="size-4" />
      <span class="ml-2 truncate">{gettext("Turn notifications on")}</span>
      <span class="basis-full pl-6 text-xs font-normal text-base-content/60">
        <%= if PotokIde.Social.GroupMutes.forever?(@mute.until) do %>
          {gettext("Muted until you turn them on")}
        <% else %>
          {gettext("Muted until")}
          <Components.local_time id={"#{@id_prefix}-muted-until"} datetime={@mute.until} />
        <% end %>
      </span>
    </button>
    """
  end

  @doc """
  What the menu of `group` offers to pin it at the top of the viewer's column
  of groups: any group a signed-in viewer sees but the root and a direct
  conversation (`PinnedGroups.pinnable?/1`). `pinned?` is the viewer's.
  """
  def pin_state(_group, nil = _profile, _pinned?), do: nil

  def pin_state(%Group{} = group, _profile, pinned?) do
    if PotokIde.Social.PinnedGroups.pinnable?(group), do: %{pinned?: pinned? == true}
  end

  attr :group, :map, required: true
  attr :pin, :map, required: true
  attr :id_prefix, :string, required: true
  attr :row?, :boolean, required: true

  defp pin_item(assigns) do
    ~H"""
    <button
      id={"#{@id_prefix}-#{if(@pin.pinned?, do: "unpin", else: "pin")}"}
      type="button"
      data-dropdown-close
      phx-click={pin_click(@group, !@pin.pinned?, @row?)}
      class={item_class()}
    >
      <.icon
        name={if(@pin.pinned?, do: "hero-bookmark-slash", else: "hero-bookmark")}
        class="size-4"
      />
      <span class="ml-2 truncate">
        {if(@pin.pinned?,
          do: gettext("Unpin from your groups"),
          else: gettext("Pin to your groups")
        )}
      </span>
    </button>
    """
  end

  defp pin_click(group, pin?, row?) do
    js = if row?, do: JS.push("group_row_menu_close"), else: %JS{}
    JS.push(js, "group_pin", value: %{id: group.id, pin: pin?})
  end

  defp mute_choices do
    [
      {"hour", gettext("For an hour")},
      {"eight_hours", gettext("For 8 hours")},
      {"week", gettext("For a week")},
      {"forever", gettext("Until I turn them on")}
    ]
  end

  defp mute_click(group, duration, row?) do
    js = if row?, do: JS.push("group_row_menu_close"), else: %JS{}
    JS.push(js, "group_mute", value: %{id: group.id, for: duration})
  end

  attr :id, :string, required: true
  attr :group, :map, required: true
  attr :tab, :string, required: true
  attr :active_tab, :string, default: nil
  attr :label, :string, required: true
  attr :icon, :string, required: true

  # The open group switches tabs in place. Another group is a page of its own.
  defp tab_item(%{active_tab: nil} = assigns) do
    ~H"""
    <.link id={@id} navigate={~p"/groups/#{@group.id}/#{@tab}"} class={item_class()}>
      <.icon name={@icon} class="size-4" />
      <span class="ml-2 truncate">{@label}</span>
    </.link>
    """
  end

  defp tab_item(assigns) do
    ~H"""
    <Components.group_tab_button
      id={@id}
      tab={@tab}
      active_tab={@active_tab}
      label={@label}
      icon={@icon}
    />
    """
  end

  # A row's menu steps aside for what is a dialog of its own.
  defp open_dialog(event, value, row?) do
    js = if row?, do: JS.push("group_row_menu_close"), else: %JS{}

    JS.push(js, event, value: value)
  end

  defp item_class do
    "flex w-full flex-row items-center rounded-md bg-base-200 px-4 py-2 text-left text-sm font-medium text-base-content/70 transition-colors hover:bg-base-300 hover:text-base-content"
  end

  attr :group_id, :integer, required: true
  attr :shortcut_id, :integer, default: nil, doc: "the shortcut the row stands in the list by"
  attr :name, :string, required: true
  attr :class, :any, default: nil

  @doc """
  The button at the end of a row of the sub-groups tab. A shortcut's row
  names the shortcut too, whose menu can take it away.
  """
  def row_button(assigns) do
    ~H"""
    <button
      id={row_button_id(@group_id, @shortcut_id)}
      type="button"
      phx-click="group_row_menu_open"
      phx-value-id={@group_id}
      phx-value-shortcut={@shortcut_id}
      aria-haspopup="menu"
      aria-label={gettext("Options of the group %{name}", name: @name)}
      class={[
        "inline-flex items-center rounded-full p-2 text-base-content/65 transition duration-150 ease-out hover:bg-base-content/10 hover:text-base-content active:scale-95 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40 phx-click-loading:animate-pulse sm:p-1",
        @class
      ]}
    >
      <.icon name="hero-ellipsis-vertical" class="size-4" />
    </button>
    """
  end

  defp row_button_prefix, do: "#{@row_prefix}-menu-button-"

  # A shortcut's row has a button of its own: its target may have a row too.
  defp row_button_id(group_id, nil), do: "#{row_button_prefix()}#{group_id}"
  defp row_button_id(_group_id, shortcut_id), do: "#{row_button_prefix()}shortcut-#{shortcut_id}"

  defp menu_shortcut_id(%{shortcut: %{shortcut: %{id: id}}}), do: id
  defp menu_shortcut_id(_menu), do: nil

  attr :menu, :map,
    required: true,
    doc:
      "`%{group: group, access: access, sections: sections/3, shortcut: nil | %{shortcut, removable?}}`"

  @doc """
  The menu of a row. The list scrolls and `<main>` is its own stacking context,
  so a menu standing in a row would be cut off at the bottom of the list: this
  one is a modal `<dialog>`, in the top layer, which the hook puts by the button.
  """
  def row_menu(assigns) do
    assigns =
      assigns
      |> assign(:prefix, @row_prefix)
      |> assign(:shortcut, assigns.menu[:shortcut])
      |> assign(:anchor, row_button_id(assigns.menu.group.id, menu_shortcut_id(assigns.menu)))

    ~H"""
    <dialog
      id={"#{@prefix}-menu"}
      phx-hook=".GroupRowMenu"
      phx-mounted={JS.ignore_attributes(["open"])}
      data-anchor={@anchor}
      aria-label={@menu.group.name}
      class="fixed inset-0 m-0 size-full max-h-none max-w-none overflow-hidden bg-transparent p-0 backdrop:bg-transparent"
    >
      <div
        id={"#{@prefix}-menu-backdrop"}
        class="absolute inset-0"
        phx-click="group_row_menu_close"
        aria-hidden="true"
      >
      </div>
      <div
        id={"#{@prefix}-menu-card"}
        tabindex="-1"
        autofocus
        class="absolute right-2 top-2 max-h-[calc(100dvh-1rem)] w-[min(18rem,calc(100vw-1.25rem))] overflow-y-auto rounded-md border border-base-300/70 bg-base-100/95 p-3 shadow-2xl shadow-primary/10 outline-none backdrop-blur"
      >
        <.items
          group={@menu.group}
          access={@menu.access}
          id_prefix={@prefix}
          mute={@menu[:mute]}
          pin={@menu[:pin]}
        >
          <button
            :if={@shortcut && @shortcut.removable?}
            id={"#{@prefix}-menu-remove-shortcut"}
            type="button"
            phx-click="group_shortcut_remove"
            phx-value-id={@shortcut.shortcut.id}
            class={item_class()}
          >
            <.icon name="hero-link-slash" class="size-4" />
            <span class="ml-2 truncate">{gettext("Remove shortcut")}</span>
          </button>
          <div
            :if={@shortcut && @shortcut.removable?}
            class="border-t border-base-300/70"
            aria-hidden="true"
          >
          </div>
          <.tab_item
            :for={section <- @menu.sections}
            id={"#{@prefix}-tab-#{section.key}"}
            group={@menu.group}
            tab={section.tab}
            label={section.label}
            icon={section.icon}
          />
          <div :if={@menu.sections != []} class="border-t border-base-300/70" aria-hidden="true">
          </div>
        </.items>
      </div>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".GroupRowMenu">
      const GAP = 8
      const EDGE = 8

      // Under the button, its right edges in line, or over it where there is no
      // room below. A menu too tall for both stands beside the button, which
      // stays in sight with its row. A button gone from the list leaves the card
      // in its corner.
      const place = dialog => {
        const button = document.getElementById(dialog.dataset.anchor)
        const card = dialog.lastElementChild

        if (!button) return

        const anchor = button.getBoundingClientRect()
        const {width, height} = card.getBoundingClientRect()
        const lowest = window.innerHeight - EDGE - height
        const below = anchor.bottom + GAP
        const above = anchor.top - GAP - height
        const beside = below > lowest && above < EDGE
        const right = beside ? anchor.left - GAP : Math.min(anchor.right, window.innerWidth - EDGE)
        const top = beside
          ? Math.max(EDGE, Math.min(anchor.top, lowest))
          : below <= lowest ? below : above

        card.style.right = "auto"
        card.style.left = `${Math.max(EDGE, right - width)}px`
        card.style.top = `${top}px`
      }

      export default {
        mounted() {
          // Escape and Android's back button close it through the server, which
          // removes it.
          this.el.addEventListener("cancel", event => {
            event.preventDefault()
            this.pushEvent("group_row_menu_close", {})
          })

          this.handleResize = () => place(this.el)
          window.addEventListener("resize", this.handleResize)

          this.el.showModal()
          place(this.el)
        },

        updated() {
          if (!this.el.open) this.el.showModal()
          place(this.el)
        },

        destroyed() {
          window.removeEventListener("resize", this.handleResize)
        },
      }
    </script>
    """
  end
end
