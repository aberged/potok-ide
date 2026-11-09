defmodule PotokIdeWeb.GroupLive.Show.CreateMenu do
  @moduledoc """
  What opens on "Create sub-group": first the presets of `GroupPresets`, each
  said in a line, then the name and what is left to pick. The full form stays a
  link away, for everything a preset does not ask.

  One dialog per page, as it opens from the menu of any row as well. The host
  LiveView calls `init/1` in mount and delegates every `"group_create_menu_*"`
  event to `handle_event/3`.
  """

  use PotokIdeWeb, :html

  import Phoenix.LiveView, only: [push_navigate: 2, put_flash: 3]

  alias PotokIde.Social
  alias PotokIde.Social.{Access, Group, GroupPresets, Profile}

  @preset_keys GroupPresets.keys()

  def init(socket), do: assign(socket, :group_create_menu, nil)

  # The id comes from the page, so the group has to be one the viewer sees, and
  # their rights are those in that group, which a row need not be the open one.
  def handle_event("group_create_menu_open", %{"id" => id}, socket) do
    profile = socket.assigns.current_profile

    with %Profile{} <- profile,
         {group_id, ""} <- Integer.parse(to_string(id)),
         %Group{} = parent <- Social.get_visible_group(profile, group_id),
         true <- Access.can?(Social.get_group_access(profile, parent), :create_subgroups) do
      menu = %{parent: parent, preset: nil, form: nil, error: nil}

      {:noreply, assign(socket, :group_create_menu, menu)}
    else
      _not_allowed -> {:noreply, socket}
    end
  end

  def handle_event("group_create_menu_close", _params, socket), do: {:noreply, init(socket)}

  def handle_event(_event, _params, %{assigns: %{group_create_menu: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("group_create_menu_pick", %{"preset" => preset}, socket)
      when preset in @preset_keys do
    menu = socket.assigns.group_create_menu

    {:noreply,
     assign(socket, :group_create_menu, %{
       menu
       | preset: preset,
         form: form(socket, preset, %{}),
         error: nil
     })}
  end

  def handle_event("group_create_menu_pick", _params, socket), do: {:noreply, socket}

  def handle_event("group_create_menu_back", _params, socket) do
    menu = socket.assigns.group_create_menu

    {:noreply, assign(socket, :group_create_menu, %{menu | preset: nil, form: nil, error: nil})}
  end

  def handle_event("group_create_menu_validate", %{"group_preset" => attrs}, socket) do
    menu = socket.assigns.group_create_menu

    {:noreply,
     assign(socket, :group_create_menu, %{
       menu
       | form: form(socket, menu.preset, attrs, :validate)
     })}
  end

  def handle_event("group_create_menu_save", %{"group_preset" => attrs}, socket) do
    profile = socket.assigns.current_profile
    menu = socket.assigns.group_create_menu

    case Social.create_group_from_preset(profile, menu.parent, menu.preset, attrs) do
      {:ok, created} ->
        {:noreply,
         socket
         |> put_flash(:info, created_message(menu.preset))
         |> push_navigate(to: next_path(menu.preset, created))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :group_create_menu, %{
           menu
           | form: to_form(changeset, as: :group_preset),
             error: nil
         })}

      {:error, _reason} ->
        # Here: the dialog covers the page's flash messages.
        {:noreply,
         assign(socket, :group_create_menu, %{menu | error: gettext("Could not create group.")})}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp form(socket, preset, attrs, action \\ nil) do
    parent = socket.assigns.group_create_menu.parent

    changeset =
      %Group{}
      |> Group.changeset(
        preset
        |> GroupPresets.defaults(parent)
        |> Map.merge(attrs)
        |> Map.merge(%{
          "creator_id" => socket.assigns.current_profile.id,
          "parent_id" => parent.id
        })
      )
      |> Map.put(:action, action)

    to_form(changeset, as: :group_preset)
  end

  defp created_message("feed"),
    do: gettext("The feed is ready. This is where you write its posts.")

  defp created_message("questionnaire"),
    do: gettext("The form is ready. Write its questions, then publish it.")

  defp created_message(_preset), do: gettext("Group created.")

  # Where the work goes on. An empty feed has nowhere to write from.
  defp next_path("feed", %{feed: feed}), do: ~p"/groups/#{feed.id}"

  defp next_path("page", %{group: group}),
    do: ~p"/groups/#{group.id}/edit_group?#{[section: "description"]}"

  defp next_path(_preset, %{group: group}), do: ~p"/groups/#{group.id}"

  defp presets do
    [
      %{
        key: "chat",
        icon: "hero-chat-bubble-left-right",
        mark: "hero-chat-bubble-left-right-micro",
        title: gettext("Chat"),
        hint: gettext("For talking. It opens on the messages."),
        summary: gettext("It opens on the messages, and every member can write.")
      },
      %{
        key: "folder",
        icon: "hero-folder",
        mark: "hero-folder-micro",
        title: gettext("Folder"),
        hint: gettext("Keeps sub-groups together."),
        summary: gettext("It opens on the list of its sub-groups, which you add next.")
      },
      %{
        key: "announcements",
        icon: "hero-megaphone",
        mark: "hero-megaphone-micro",
        title: gettext("Announcements"),
        hint: gettext("Only administrators write, the others read."),
        summary:
          gettext(
            "It opens on the messages. Only administrators can write, and the others read and react."
          )
      },
      %{
        key: "feed",
        icon: "hero-newspaper",
        mark: "hero-newspaper-micro",
        title: gettext("Feed"),
        hint: gettext("News to swipe through."),
        summary:
          gettext(
            "You get a group with the Feed app and a sub-group %{name} with the FeedCreator app, where you write the posts.",
            name: ".feed"
          )
      },
      %{
        key: "polls",
        icon: "hero-chart-bar",
        mark: "hero-chart-bar-micro",
        title: dgettext("polls", "Polls"),
        hint: dgettext("polls", "Votes and decisions, in one place."),
        summary:
          dgettext(
            "polls",
            "It opens on the Polls app, a board of the group's polls, where members vote and start new ones."
          )
      },
      %{
        key: "questionnaire",
        icon: "hero-clipboard-document-list",
        mark: "hero-clipboard-document-list-micro",
        title: gettext("Form"),
        hint: gettext("Questions, answers and a summary of them."),
        summary:
          gettext(
            "It opens on the Form app: you write the questions and choose who fills it in and who sees the answers."
          )
      },
      %{
        key: "page",
        icon: "hero-document-text",
        mark: "hero-document-text-micro",
        title: gettext("Page"),
        hint: gettext("Text that shows first, from a template."),
        summary: gettext("It opens on its text, which you write right after, from a template.")
      }
    ]
  end

  defp preset(key), do: Enum.find(presets(), &(&1.key == key))

  @doc """
  The icon and name of a preset (a `Group.preset` value) for the mark on the
  avatar of a group made from it: the same as in this menu, in the small size.
  Each `mark` is written out, as Tailwind makes the CSS only of icon names it
  finds in the source.
  """
  def mark(preset) when is_atom(preset) do
    %{mark: icon, title: title} = preset(Atom.to_string(preset))

    %{icon: icon, title: title}
  end

  attr :menu, :map, default: nil, doc: "the `@group_create_menu` assign"

  @doc """
  A modal `<dialog>`, for what `<main>` would cover: on a phone a sheet from
  the bottom edge, which keeps its footer above the home bar on its own.
  """
  def menu(assigns) do
    ~H"""
    <dialog
      :if={@menu}
      id="group-create-menu"
      phx-hook=".GroupCreateMenu"
      phx-mounted={JS.ignore_attributes(["open"])}
      aria-labelledby="group-create-menu-title"
      class="fixed inset-0 m-0 size-full max-h-none max-w-none overflow-hidden bg-transparent p-0 backdrop:bg-transparent"
    >
      <div class="flex size-full items-end justify-center sm:items-center sm:p-4">
        <div
          id="group-create-menu-backdrop"
          class="absolute inset-0 bg-black/30 backdrop-blur-[2px] dark:bg-black/60"
          phx-click="group_create_menu_close"
          aria-hidden="true"
        >
        </div>
        <section
          tabindex="-1"
          autofocus
          class="relative flex max-h-[85dvh] w-full flex-col overflow-hidden rounded-t-3xl border border-b-0 border-base-300/70 bg-base-100 text-base-content shadow-2xl shadow-base-content/10 outline-none sm:max-w-md sm:rounded-3xl sm:border-b"
        >
          <.choices :if={!@menu.preset} parent={@menu.parent} />
          <.details :if={@menu.preset} menu={@menu} preset={preset(@menu.preset)} />
        </section>
      </div>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".GroupCreateMenu">
      export default {
        mounted() {
          // Escape and Android's back button close it through the server, which
          // removes it.
          this.el.addEventListener("cancel", event => {
            event.preventDefault()
            this.pushEvent("group_create_menu_close", {})
          })

          this.el.showModal()
        },

        // The name is the only thing the second step needs, so the cursor waits
        // there, once: a check of the form must not take it back from a switch.
        updated() {
          if (!this.el.open) this.el.showModal()

          const name = this.el.querySelector("input[type=text]")

          if (name && !this.nameFocused) name.focus()

          this.nameFocused = Boolean(name)
        },
      }
    </script>
    """
  end

  attr :parent, :map, required: true

  defp choices(assigns) do
    ~H"""
    <.menu_header icon="hero-folder-plus">
      {gettext("What kind of group do you need?")}
      <:subtitle :if={!@parent.is_root}>
        {gettext("A new group in %{name}.", name: @parent.name)}
      </:subtitle>
    </.menu_header>

    <ul id="group-create-presets" class="min-h-0 flex-1 overflow-y-auto p-2">
      <li :for={preset <- presets()}>
        <button
          id={"group-create-preset-#{preset.key}"}
          type="button"
          phx-click="group_create_menu_pick"
          phx-value-preset={preset.key}
          class="group/preset flex w-full cursor-pointer items-center gap-3 rounded-2xl px-3 py-2.5 text-left transition duration-150 ease-out hover:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40 active:scale-[.99]"
        >
          <.preset_icon name={preset.icon} />
          <span class="min-w-0 flex-1">
            <span class="block text-sm font-semibold">{preset.title}</span>
            <span class="block text-sm text-base-content/65">{preset.hint}</span>
          </span>
          <.icon
            name="hero-chevron-right"
            class="size-4 shrink-0 text-base-content/40 transition-transform duration-150 ease-out group-hover/preset:translate-x-0.5"
          />
        </button>
      </li>
    </ul>

    <.menu_footer class="justify-center">
      <.link
        id="group-create-custom"
        navigate={~p"/groups/#{@parent.id}/create_group"}
        class="text-sm font-medium text-base-content/70 underline-offset-2 transition-colors hover:text-base-content hover:underline"
      >
        {gettext("Set everything up yourself")}
      </.link>
    </.menu_footer>
    """
  end

  attr :menu, :map, required: true
  attr :preset, :map, required: true

  defp details(assigns) do
    ~H"""
    <.menu_header icon={@preset.icon}>{@preset.title}</.menu_header>

    <div class="min-h-0 flex-1 overflow-y-auto px-5 py-4">
      <p id="group-create-summary" class="mb-4 text-sm text-base-content/75">
        {@preset.summary}
      </p>

      <.form
        for={@menu.form}
        id="group-create-preset-form"
        phx-change="group_create_menu_validate"
        phx-submit="group_create_menu_save"
        novalidate
      >
        <.input
          field={@menu.form[:name]}
          label={gettext("Name")}
          required
          autocomplete="off"
          phx-debounce="200"
        />

        <.input field={@menu.form[:is_public]} label={gettext("Public group")} type="checkbox" />
        <p class="-mt-1 mb-3 text-xs text-base-content/65">
          {gettext("Everyone can see the group and ask to join it.")}
          {gettext(
            "Its name, picture and description also show outside Potok, to anyone with the link."
          )}
        </p>

        <%!-- The root's children never inherit: they would hold every profile. --%>
        <div :if={!@menu.parent.is_root} id="group-create-preset-inherits">
          <.input
            field={@menu.form[:inherits_members]}
            label={gettext("Inherit members")}
            type="checkbox"
          />
          <p class="-mt-1 mb-1 text-xs text-base-content/65">
            {gettext(
              "Every member of this group is also a member of the sub-group, with the same roles."
            )}
          </p>
        </div>

        <p
          :if={@menu.error}
          id="group-create-menu-error"
          role="alert"
          class="mt-2 flex items-start gap-1.5 text-sm text-error"
        >
          <.icon name="hero-exclamation-circle" class="mt-0.5 size-4 shrink-0" />
          {@menu.error}
        </p>
      </.form>
    </div>

    <.menu_footer class="justify-end">
      <.button
        id="group-create-menu-back"
        type="button"
        phx-click="group_create_menu_back"
        variant="ghost"
      >
        {gettext("Back")}
      </.button>
      <.button
        id="group-create-preset-submit"
        type="submit"
        form="group-create-preset-form"
        phx-disable-with={gettext("Creating...")}
        variant="primary"
      >
        {gettext("Create")}
      </.button>
    </.menu_footer>
    """
  end

  attr :icon, :string, required: true
  slot :inner_block, required: true
  slot :subtitle

  defp menu_header(assigns) do
    ~H"""
    <header class="flex items-start gap-3 border-b border-base-300/60 px-5 pt-5 pb-4">
      <.preset_icon name={@icon} />
      <div class="min-w-0 flex-1">
        <h2 id="group-create-menu-title" class="text-base font-semibold leading-tight">
          {render_slot(@inner_block)}
        </h2>
        <p :if={@subtitle != []} class="mt-0.5 truncate text-sm text-base-content/65">
          {render_slot(@subtitle)}
        </p>
      </div>
      <.icon_button
        id="group-create-menu-close"
        type="button"
        phx-click="group_create_menu_close"
        icon="hero-x-mark"
        label={gettext("Close")}
        class="-mr-1"
      />
    </header>
    """
  end

  attr :class, :string, default: nil
  slot :inner_block, required: true

  defp menu_footer(assigns) do
    ~H"""
    <footer class={[
      "flex items-center gap-2 border-t border-base-300/60 bg-base-200/40 px-5 pt-3 pb-[calc(0.75rem+var(--app-safe-area-bottom))] sm:pb-3",
      @class
    ]}>
      {render_slot(@inner_block)}
    </footer>
    """
  end

  attr :name, :string, required: true

  defp preset_icon(assigns) do
    ~H"""
    <span class="inline-flex size-9 shrink-0 items-center justify-center rounded-2xl bg-primary/10 text-primary">
      <.icon name={@name} class="size-5" />
    </span>
    """
  end
end
