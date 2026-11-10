defmodule PotokIdeWeb.GroupLive.Show.ChoiceMenus do
  @moduledoc """
  The menus of a bar of filters: a round button (`choice_toggle/1`) that opens
  its menu of choices (`choice_menu/1`) on the client, one pick at a time. The
  sub-groups tab narrows by membership and kind with them, and the root's map
  by the same and by time.
  """
  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.CreateMenu

  # "" is every group; the others are `Social.child_group_relations/0`.
  def relation_choices do
    [
      %{key: "", icon: "hero-user-circle", title: gettext("All groups")},
      %{
        key: "member",
        icon: "hero-user-group",
        title: gettext("Where I am a member"),
        short: gettext("Member")
      },
      %{
        key: "creator",
        icon: "hero-pencil-square",
        title: gettext("Created by me"),
        short: gettext("Creator")
      }
    ]
  end

  # "" is every kind, "none" the groups that show none (`GroupPresets.shown/1`).
  def kind_choices do
    [%{key: "", icon: "hero-squares-2x2", title: gettext("All kinds")}] ++
      CreateMenu.kinds() ++
      [%{key: "none", icon: "hero-minus-circle", title: gettext("No kind"), divider: true}]
  end

  defp chosen?(choice, selected), do: choice.key == (selected || "")

  attr :id, :string,
    required: true,
    doc: "the start of the ids of the button, its menu and options"

  attr :choices, :list,
    required: true,
    doc: "`%{key, icon, title}`, with a `short` title for the button"

  attr :selected, :string, default: nil, doc: "the key picked, nil for the first choice"
  attr :idle_label, :string, required: true, doc: "the button's text while nothing is picked"
  attr :title, :string, required: true
  attr :label, :string, required: true, doc: "what the menu narrows by, for screen readers"
  attr :text, :string, default: nil, doc: "the button's text in place of the choice's"
  attr :icon, :string, default: nil, doc: "the button's icon in place of the choice's"

  attr :active, :boolean,
    default: nil,
    doc: "whether the button shows a narrowing, by default while a key is picked"

  # Opens its `choice_menu/1` on the client: the menu holds nothing the server
  # would have to load.
  def choice_toggle(assigns) do
    choice = Enum.find(assigns.choices, &chosen?(&1, assigns.selected))

    assigns =
      assigns
      |> assign(:choice, choice)
      |> assign(
        :active,
        if(is_nil(assigns.active), do: assigns.selected != nil, else: assigns.active)
      )
      # What a screen reader hears after the label, as phones show no text:
      # the button's own text, or the choice picked.
      |> assign(:named, assigns.text || (assigns.selected && choice && choice.title))

    ~H"""
    <button
      id={"#{@id}-toggle"}
      type="button"
      phx-click={JS.dispatch("potok:choice-menu-open", to: "##{@id}-menu")}
      aria-haspopup="menu"
      aria-controls={"#{@id}-menu"}
      aria-label={if(@named, do: "#{@label}: #{@named}", else: @label)}
      title={@title}
      class={[
        "mt-1 inline-flex h-10 max-w-48 items-center gap-1.5 rounded-full border px-3 text-sm font-semibold shadow-xs max-sm:px-[11px] transition duration-150 ease-out hover:-translate-y-px active:scale-95 max-sm:group-has-[input:focus]/filters:hidden",
        if(@active,
          do: "border-primary/50 bg-base-100 text-primary hover:bg-base-200",
          else: "border-gray-500/50 bg-base-100 text-base-content/65 hover:text-base-content"
        )
      ]}
    >
      <.icon name={@icon || @choice.icon} class="size-4 shrink-0" />
      <span class="hidden truncate sm:inline">
        {@text || if(@selected, do: Map.get(@choice, :short, @choice.title), else: @idle_label)}
      </span>
      <.icon name="hero-chevron-down" class="hidden size-3.5 shrink-0 opacity-60 sm:block" />
    </button>
    """
  end

  attr :id, :string, required: true, doc: "as in its `choice_toggle/1`"
  attr :choices, :list, required: true, doc: "as in its `choice_toggle/1`, a `divider` above some"
  attr :selected, :string, default: nil
  attr :event, :string, required: true, doc: "sent with the key picked"
  attr :param, :string, required: true, doc: "the name the key goes under"
  attr :label, :string, required: true
  slot :top, doc: "what stands above the choices and leaves the menu open"
  slot :bottom, doc: "what stands below the choices, such as a small form"

  # A modal `<dialog>` in the top layer, as `<main>` would cut off a menu
  # standing in the panel; the hook puts it under its button. It stays on the
  # page, closed, and closes on the client, so a pick waits for no reply.
  def choice_menu(assigns) do
    ~H"""
    <dialog
      id={"#{@id}-menu"}
      phx-hook=".ChoiceMenu"
      phx-mounted={JS.ignore_attributes(["open"])}
      data-anchor={"#{@id}-toggle"}
      aria-label={@label}
      class="fixed inset-0 m-0 size-full max-h-none max-w-none overflow-hidden bg-transparent p-0 backdrop:bg-transparent"
    >
      <div
        id={"#{@id}-menu-backdrop"}
        class="absolute inset-0"
        phx-click={close_choice_menu(@id)}
        aria-hidden="true"
      >
      </div>
      <div
        data-card
        role="menu"
        aria-label={@label}
        class="absolute right-2 top-2 max-h-[calc(100dvh-1rem)] w-[min(15rem,calc(100vw-1.25rem))] overflow-y-auto rounded-2xl border border-base-300/70 bg-base-100/95 p-1.5 shadow-2xl shadow-primary/10 outline-none backdrop-blur"
      >
        {render_slot(@top)}
        <%= for choice <- @choices do %>
          <div
            :if={Map.get(choice, :divider)}
            class="mx-2 my-1 border-t border-base-300/70"
            aria-hidden="true"
          >
          </div>
          <button
            id={"#{@id}-option-#{if(choice.key == "", do: "all", else: choice.key)}"}
            type="button"
            role="menuitemradio"
            aria-checked={to_string(chosen?(choice, @selected))}
            autofocus={chosen?(choice, @selected)}
            phx-click={JS.push(@event, value: %{@param => choice.key}) |> close_choice_menu(@id)}
            class={[
              "group/choice flex w-full cursor-pointer items-center gap-2.5 rounded-xl px-2.5 py-2 text-left text-sm transition-colors duration-150 hover:bg-base-200 focus-visible:bg-base-200 focus-visible:outline-none",
              if(chosen?(choice, @selected),
                do: "font-semibold text-primary",
                else: "font-medium text-base-content/80 hover:text-base-content"
              )
            ]}
          >
            <span class={[
              "inline-flex size-7 shrink-0 items-center justify-center rounded-lg transition-colors",
              if(chosen?(choice, @selected),
                do: "bg-primary/15 text-primary",
                else: "bg-base-200 text-base-content/65 group-hover/choice:bg-base-300"
              )
            ]}>
              <.icon name={choice.icon} class="size-4" />
            </span>
            <span class="min-w-0 flex-1 truncate">{choice.title}</span>
            <.icon :if={chosen?(choice, @selected)} name="hero-check" class="size-4 shrink-0" />
          </button>
        <% end %>
        {render_slot(@bottom)}
      </div>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ChoiceMenu">
      const GAP = 6
      const EDGE = 8

      // Under the button, its right edges in line, or over it where there is
      // no room below.
      const place = dialog => {
        const button = document.getElementById(dialog.dataset.anchor)
        const card = dialog.querySelector("[data-card]")

        if (!button || !card) return

        const anchor = button.getBoundingClientRect()
        const {width, height} = card.getBoundingClientRect()
        const below = anchor.bottom + GAP
        const right = Math.min(anchor.right, window.innerWidth - EDGE)
        const top =
          below + height <= window.innerHeight - EDGE
            ? below
            : Math.max(EDGE, anchor.top - GAP - height)

        card.style.right = "auto"
        card.style.left = `${Math.max(EDGE, right - width)}px`
        card.style.top = `${top}px`
      }

      export default {
        mounted() {
          this.el.addEventListener("potok:choice-menu-open", () => {
            if (!this.el.open) this.el.showModal()
            place(this.el)
          })

          this.el.addEventListener("potok:choice-menu-close", () => this.el.close())

          // The arrows walk the choices, as in any menu.
          this.el.addEventListener("keydown", event => {
            const items = [
              ...this.el.querySelectorAll("[role=menuitemradio], [role=menuitemcheckbox]"),
            ]
            const index = items.indexOf(document.activeElement)
            const next = {
              ArrowDown: (index + 1) % items.length,
              ArrowUp: (index - 1 + items.length) % items.length,
              Home: 0,
              End: items.length - 1,
            }[event.key]

            if (next === undefined) return

            event.preventDefault()
            items[next].focus()
          })

          this.handleResize = () => this.el.open && place(this.el)
          window.addEventListener("resize", this.handleResize)
        },

        updated() {
          if (this.el.open) place(this.el)
        },

        destroyed() {
          window.removeEventListener("resize", this.handleResize)
        },
      }
    </script>
    """
  end

  @doc "Closes the menu `id` on the client."
  def close_choice_menu(js \\ %JS{}, id),
    do: JS.dispatch(js, "potok:choice-menu-close", to: "##{id}-menu")
end
