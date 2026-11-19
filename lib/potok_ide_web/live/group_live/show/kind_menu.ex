defmodule PotokIdeWeb.GroupLive.Show.KindMenu do
  @moduledoc """
  "Change kind" on Uredi grupu: the kinds of the Create sub-group menu
  (`CreateMenu.presets_for/1`) and "No kind", then what the chosen one would
  do, read from `GroupPresets.change_plan/4` as `Social.change_group_preset/4`
  will do it. When an app (or a text) would be overwritten the dialog says
  so, and where it goes.

  The host LiveView keeps the state in `@group_kind_menu` and handles the
  `"group_kind_*"` events, as saving reaches the edit form and the list of
  alternative descriptions.
  """

  use PotokIdeWeb, :html

  alias PotokIde.Social.{Group, GroupPresets}
  alias PotokIdeWeb.GroupLive.Show.{ChoiceMenus, CreateMenu}

  @doc """
  The state of a dialog just opened for `group` under `parent`: its tiles, or
  why there are none (`dirty`: the edit form has unsaved changes; `not_here`:
  the group belongs to an app).
  """
  def open(%Group{} = group, parent, opts) do
    %{
      group: group,
      tiles: if(parent, do: tiles(parent), else: []),
      current: current(group),
      dirty: Keyword.get(opts, :dirty, false),
      not_here: Keyword.get(opts, :not_here, false),
      picked: nil,
      plan: nil,
      error: nil
    }
  end

  @doc "The kind a group shows, as on its avatar: a preset key, `\"app\"` or `\"none\"`."
  def current(%Group{} = group) do
    case GroupPresets.shown(group) do
      nil -> if group.uses_api, do: "app", else: "none"
      preset -> Atom.to_string(preset)
    end
  end

  @doc "The icon and name of `kind` (`current/1`), as the kind filter shows them."
  def look(kind), do: Enum.find(ChoiceMenus.kind_choices(), &(&1.key == kind))

  @doc """
  What the old default is called once parked, when it had no name of its own:
  by its kind, in the editor's language.
  """
  def park_name(%Group{} = group) do
    case current(group) do
      "none" -> gettext("Previous description")
      "app" -> gettext("Previous app")
      kind -> gettext("%{kind} (previous)", kind: look(kind).title)
    end
  end

  @doc "Why a change cannot be made, in words."
  def error_message(:kind_not_here),
    do:
      gettext(
        "This group belongs to an app (it keeps its files, or holds a feed's posts), so its kind stays."
      )

  def error_message(:same_kind), do: gettext("The group is already of this kind.")
  def error_message(:kind_not_allowed), do: gettext("This kind is not offered here.")

  def error_message(:too_many_alt_descriptions),
    do:
      gettext(
        "The group has as many alternative descriptions as it may. Delete one first, so its current description has somewhere to go."
      )

  def error_message(:feed_not_permitted),
    do:
      gettext(
        "A feed needs a sub-group %{name} for its posts, and you may not create sub-groups here.",
        name: GroupPresets.feed_group_name()
      )

  def error_message(_reason), do: gettext("Could not change the kind.")

  # "No kind" last, as in the kind filter.
  defp tiles(parent) do
    CreateMenu.presets_for(parent) ++
      [
        %{
          key: "none",
          icon: "hero-minus-circle",
          title: gettext("No kind"),
          hint: gettext("Only the kind's name goes; the rest stays.")
        }
      ]
  end

  attr :menu, :map, default: nil, doc: "the `@group_kind_menu` assign"

  @doc "A modal `<dialog>` like the Create sub-group menu: a sheet on a phone."
  def dialog(assigns) do
    ~H"""
    <dialog
      :if={@menu}
      id="group-kind-menu"
      phx-hook=".GroupKindMenu"
      phx-mounted={JS.ignore_attributes(["open"])}
      aria-labelledby="group-kind-menu-title"
      class="fixed inset-0 m-0 size-full max-h-none max-w-none overflow-hidden bg-transparent p-0 backdrop:bg-transparent"
    >
      <div class="flex size-full items-end justify-center sm:items-center sm:p-4">
        <div
          id="group-kind-menu-backdrop"
          class="absolute inset-0 bg-black/30 backdrop-blur-[2px] dark:bg-black/60"
          phx-click="group_kind_close"
          aria-hidden="true"
        >
        </div>
        <section
          tabindex="-1"
          autofocus
          class="relative flex max-h-[85dvh] w-full flex-col overflow-hidden rounded-t-3xl border border-b-0 border-base-300/70 bg-base-100 text-base-content shadow-2xl shadow-base-content/10 outline-none sm:max-w-md sm:rounded-3xl sm:border-b"
        >
          <%= cond do %>
            <% @menu.dirty or @menu.not_here -> %>
              <.blocked menu={@menu} />
            <% @menu.picked -> %>
              <.summary menu={@menu} />
            <% true -> %>
              <.choices menu={@menu} />
          <% end %>
        </section>
      </div>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".GroupKindMenu">
      export default {
        mounted() {
          // Escape and Android's back button close it through the server.
          this.el.addEventListener("cancel", event => {
            event.preventDefault()
            this.pushEvent("group_kind_close", {})
          })

          this.el.showModal()
        },

        updated() {
          if (!this.el.open) this.el.showModal()
        },
      }
    </script>
    """
  end

  attr :menu, :map, required: true

  defp blocked(assigns) do
    ~H"""
    <CreateMenu.menu_header icon="hero-tag" id="group-kind-menu" close="group_kind_close">
      {gettext("Change kind")}
    </CreateMenu.menu_header>

    <div class="px-5 py-5">
      <p id="group-kind-blocked" class="text-sm text-base-content/75">
        {if(@menu.dirty,
          do: gettext("Save or discard your changes first: changing the kind sets the form anew."),
          else: error_message(:kind_not_here)
        )}
      </p>
    </div>

    <CreateMenu.menu_footer class="justify-end">
      <.button id="group-kind-menu-ok" type="button" phx-click="group_kind_close" variant="ghost">
        {gettext("Close")}
      </.button>
    </CreateMenu.menu_footer>
    """
  end

  attr :menu, :map, required: true

  defp choices(assigns) do
    ~H"""
    <CreateMenu.menu_header icon="hero-tag" id="group-kind-menu" close="group_kind_close">
      {gettext("Change kind")}
      <:subtitle>{gettext("What should %{name} be?", name: @menu.group.name)}</:subtitle>
    </CreateMenu.menu_header>

    <ul id="group-kind-tiles" class="min-h-0 flex-1 overflow-y-auto p-2">
      <li :for={tile <- @menu.tiles}>
        <button
          id={"group-kind-tile-#{tile.key}"}
          type="button"
          phx-click="group_kind_pick"
          phx-value-kind={tile.key}
          disabled={tile.key == @menu.current or (tile.key == "none" and is_nil(@menu.group.preset))}
          aria-current={if(tile.key == @menu.current, do: "true")}
          class="group/preset flex w-full cursor-pointer items-center gap-3 rounded-2xl px-3 py-2.5 text-left transition duration-150 ease-out hover:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40 active:scale-[.99] disabled:cursor-default disabled:hover:bg-transparent disabled:active:scale-100"
        >
          <CreateMenu.preset_icon name={tile.icon} />
          <span class="min-w-0 flex-1">
            <span class="block text-sm font-semibold">{tile.title}</span>
            <span class="block text-sm text-base-content/65">{tile.hint}</span>
          </span>
          <span
            :if={tile.key == @menu.current}
            class="shrink-0 rounded-full bg-primary/10 px-2 py-0.5 text-xs font-medium text-primary"
          >
            {gettext("Now")}
          </span>
          <.icon
            :if={tile.key != @menu.current}
            name="hero-chevron-right"
            class="size-4 shrink-0 text-base-content/40 transition-transform duration-150 ease-out group-hover/preset:translate-x-0.5 group-disabled/preset:opacity-0"
          />
        </button>
      </li>
    </ul>
    """
  end

  attr :menu, :map, required: true

  defp summary(assigns) do
    tile = Enum.find(assigns.menu.tiles, &(&1.key == assigns.menu.picked))
    plan = assigns.menu.plan
    overwrites = plan && plan.park && plan.park.kind == :app

    assigns =
      assign(assigns,
        tile: tile,
        plan: plan,
        overwrites: overwrites,
        lines: if(plan, do: lines(assigns.menu.group, tile, plan), else: [])
      )

    ~H"""
    <CreateMenu.menu_header icon={@tile.icon} id="group-kind-menu" close="group_kind_close">
      {@tile.title}
      <:subtitle>{gettext("New kind of %{name}", name: @menu.group.name)}</:subtitle>
    </CreateMenu.menu_header>

    <div class="min-h-0 flex-1 overflow-y-auto px-5 py-4">
      <div
        :if={@overwrites}
        id="group-kind-overwrite"
        role="alert"
        class="mb-4 rounded-2xl border border-warning/40 bg-warning/10 px-4 py-3 text-sm"
      >
        <p class="flex items-center gap-2 font-semibold">
          <.icon name="hero-exclamation-triangle" class="size-5 shrink-0 text-warning" />
          {overwrite_title(@menu.group)}
        </p>
        <p class="mt-1 text-base-content/80">
          {gettext(
            "It goes, with all its data, to the alternative description “%{name}”, which only those who edit the group see. From there you can make it the default again.",
            name: @plan.park.name
          )}
        </p>
      </div>

      <ul :if={@plan} id="group-kind-summary" class="space-y-2.5">
        <li :for={{icon, text} <- @lines} class="flex items-start gap-2.5 text-sm">
          <.icon name={icon} class="mt-0.5 size-4 shrink-0 text-base-content/50" />
          <span class="text-base-content/80">{text}</span>
        </li>
      </ul>

      <p
        :if={@menu.error}
        id="group-kind-error"
        role="alert"
        class="mt-3 flex items-start gap-1.5 text-sm text-error"
      >
        <.icon name="hero-exclamation-circle" class="mt-0.5 size-4 shrink-0" />
        {@menu.error}
      </p>
    </div>

    <CreateMenu.menu_footer class="justify-end">
      <.button id="group-kind-back" type="button" phx-click="group_kind_back" variant="ghost">
        {gettext("Back")}
      </.button>
      <.button
        :if={@plan}
        id="group-kind-apply"
        type="button"
        phx-click="group_kind_apply"
        phx-disable-with={gettext("Changing...")}
        variant={if(@overwrites, do: "danger", else: "primary")}
      >
        {if(@overwrites, do: gettext("Overwrite and change"), else: gettext("Change kind"))}
      </.button>
    </CreateMenu.menu_footer>
    """
  end

  defp overwrite_title(group) do
    case current(group) do
      "app" -> gettext("The current app will be overwritten.")
      kind -> gettext("The %{app} app will be overwritten.", app: look(kind).title)
    end
  end

  # What changes, then what stays, each a line with an icon.
  defp lines(%Group{} = group, tile, plan) do
    [
      plan.key && plan.feed != :reuse && {"hero-sparkles", Map.get(tile, :summary)},
      plan.key == nil &&
        {"hero-tag",
         gettext("The group no longer carries a kind. Its description, app and home page stay.")},
      plan.feed == :reuse &&
        {"hero-newspaper",
         gettext(
           "It opens on the Feed app again and takes back the sub-group %{name} it holds, with its posts.",
           name: GroupPresets.feed_group_name()
         )},
      plan.park && plan.park.kind == :text &&
        {"hero-document-duplicate",
         gettext(
           "The text of its description goes to the alternative description “%{name}”, which only those who edit the group see.",
           name: plan.park.name
         )},
      plan.key && plan.description == :keep && String.trim(group.description || "") != "" &&
        {"hero-document-text", gettext("The text of its description stays.")},
      plan.leaves_feed &&
        {"hero-newspaper",
         gettext(
           "The sub-group %{name} and its posts stay. Delete them yourself if you no longer need them.",
           name: GroupPresets.feed_group_name()
         )},
      plan.picture == :replace && {"hero-photo", gettext("It gets the picture of its new kind.")},
      plan.park && plan.park.kind == :app && group.description_for_guests &&
        {"hero-globe-alt",
         gettext("Guests who have its page open see the old app until they reload it.")},
      {"hero-check-circle",
       gettext("Its name, access, members, messages and sub-groups stay as they are.")}
    ]
    |> Enum.filter(&match?({_icon, text} when is_binary(text), &1))
  end
end
