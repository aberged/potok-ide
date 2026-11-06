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

  alias PotokIde.Social.{Access, Group}
  alias PotokIdeWeb.GroupLive.Show.Components
  alias PotokIdeWeb.TagComponents

  @row_prefix "group-row"

  @doc """
  The sections of a group, in the order of its bar. The root has none: its
  header switches between conversations and groups. `calendar?` is passed in,
  as for someone outside a public group it takes a query.
  """
  def sections(%Group{is_root: true}, _member?, _calendar?), do: []

  def sections(%Group{} = group, member?, calendar?) do
    member_of_group? = member? and group.parent_id != nil

    [
      member? &&
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
  end

  attr :group, :map, required: true
  attr :access, :any, required: true, doc: "the viewer's access to `group`"
  attr :id_prefix, :string, default: "group"

  attr :active_tab, :string,
    default: nil,
    doc: "the tab on screen when `group` is the open group; without it the items lead there"

  slot :inner_block, doc: "what only this menu offers, before the rest"

  def items(assigns) do
    assigns = assign(assigns, :row?, is_nil(assigns.active_tab))

    ~H"""
    <div class="flex min-w-56 flex-col gap-2 z-100">
      {render_slot(@inner_block)}
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
        phx-click={open_tags(@group, @row?)}
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
        :if={@access.member? and !@group.is_direct}
        id={"#{@id_prefix}-tab-roles"}
        group={@group}
        tab="roles"
        active_tab={@active_tab}
        label={gettext("Roles")}
        icon="hero-shield-check"
      />
      <.tab_item
        :if={Access.can?(@access, :create_subgroups)}
        id={"#{@id_prefix}-tab-create-sub-group"}
        group={@group}
        tab="create_group"
        active_tab={@active_tab}
        label={gettext("Create sub-group")}
        icon="hero-folder-plus"
      />
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

  # A row's menu steps aside, as the tag editor is a dialog of its own.
  defp open_tags(group, row?) do
    js = if row?, do: JS.push("group_row_menu_close"), else: %JS{}

    JS.push(js, "tag_editor_open", value: %{kind: "group", id: group.id})
  end

  defp item_class do
    "flex w-full flex-row items-center rounded-md bg-base-200 px-4 py-2 text-left text-sm font-medium text-base-content/70 transition-colors hover:bg-base-300 hover:text-base-content"
  end

  attr :group_id, :integer, required: true
  attr :name, :string, required: true
  attr :class, :any, default: nil

  @doc "The button at the end of a row of the sub-groups tab."
  def row_button(assigns) do
    ~H"""
    <button
      id={"#{row_button_prefix()}#{@group_id}"}
      type="button"
      phx-click="group_row_menu_open"
      phx-value-id={@group_id}
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

  attr :menu, :map, required: true, doc: "`%{group: group, access: access, sections: sections/3}`"

  @doc """
  The menu of a row. The list scrolls and `<main>` is its own stacking context,
  so a menu standing in a row would be cut off at the bottom of the list: this
  one is a modal `<dialog>`, in the top layer, which the hook puts by the button.
  """
  def row_menu(assigns) do
    assigns =
      assigns
      |> assign(:prefix, @row_prefix)
      |> assign(:anchor, "#{row_button_prefix()}#{assigns.menu.group.id}")

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
        <.items group={@menu.group} access={@menu.access} id_prefix={@prefix}>
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
