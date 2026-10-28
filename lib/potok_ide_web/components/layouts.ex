defmodule PotokIdeWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use PotokIdeWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  # The active link is marked with `aria-current` by app.js (as a sticky JS
  # command, so LiveView patches keep it).
  @nav_link_class "rounded-2xl border border-base-300 bg-base-200 px-4 py-3 text-sm font-medium text-base-content/70 transition-colors hover:bg-base-300 hover:text-base-content aria-[current=page]:border-base-content aria-[current=page]:bg-base-content aria-[current=page]:text-base-100 aria-[current=page]:shadow-sm"

  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :current_profile, :map, default: nil, doc: "the current profile when available"
  attr :current_locale, :string, default: nil, doc: "the active locale"
  attr :available_locales, :list, default: PotokIdeWeb.Locale.supported_locales()
  attr :pending_invitations_count, :integer, default: 0
  attr :pending_group_join_requests_count, :integer, default: 0
  attr :root_group_unread_count, :integer, default: 0

  slot :inner_block, required: true

  def app(assigns) do
    assigns = assign(assigns, :nav_link_class, @nav_link_class)

    ~H"""
    <%!--
      App shell: one flex column per screen height. The top bar never scrolls,
      `#main-content` is the only flexible region and pages put their own
      `min-h-0 flex-1 overflow-y-auto` scroll area inside it. On lg+ the drawer
      is a permanent sidebar; below that it slides in from the menu button.
    --%>
    <div
      id="app-shell"
      class={["drawer h-dvh overflow-hidden", @current_scope && "lg:drawer-open"]}
      phx-hook="HeaderDrawer"
    >
      <%!-- Ignored by patches, otherwise every re-render would reset `checked` and close the drawer. --%>
      <input id="app-drawer-toggle" type="checkbox" class="drawer-toggle" phx-update="ignore" />
      <div class="drawer-content flex h-dvh min-w-0 flex-col overflow-hidden pt-(--app-safe-area-top) pb-(--app-safe-area-bottom)">
        <nav class="relative z-100 shrink-0">
          <div class="mx-auto flex items-center justify-between gap-3 rounded-[2rem] border border-base-300/70 bg-base-100/85 px-4 py-3 shadow-lg shadow-primary/5 backdrop-blur sm:px-5">
            <label
              for="app-drawer-toggle"
              aria-label={gettext("Open menu")}
              class={[
                "btn btn-ghost btn-circle border border-base-300 bg-base-100/80 shadow-sm backdrop-blur",
                @current_scope && "lg:hidden"
              ]}
            >
              <.icon name="hero-bars-3" class="size-5" />
            </label>
            <.link
              id="nav-root-group-link"
              navigate={home_path(@current_scope, @current_profile)}
              alt={gettext("Groups")}
              aria-label={gettext("Groups")}
              class="relative"
            >
              <.icon name="hero-home" class="size-6" />
              <span
                id="nav-root-group-unread-badge"
                class="absolute -right-1 -top-1 inline-flex min-w-5 items-center justify-center rounded-full bg-red-600 px-1 text-xs font-semibold text-white"
                hidden={@root_group_unread_count <= 0}
              >
                {if(@root_group_unread_count > 999, do: "999+", else: @root_group_unread_count)}
              </span>
            </.link>
            <div class="flex items-right gap-4 items-center ml-auto">
              <.link
                id="nav-invitations-link"
                navigate={~p"/invitations"}
                alt={gettext("Invitations")}
                class="relative"
                aria-label={gettext("Invitations")}
                hidden={is_nil(@current_profile)}
              >
                <.icon name="hero-inbox-arrow-down" class="size-6" />
                <span
                  id="nav-invitations-count-badge"
                  class="absolute -right-1 -top-1 inline-flex min-w-5 items-center justify-center rounded-full bg-red-600 px-1 text-xs font-semibold text-white"
                  hidden={@pending_invitations_count <= 0}
                >
                  {if(@pending_invitations_count > 999,
                    do: "999+",
                    else: @pending_invitations_count
                  )}
                </span>
              </.link>
              <.link
                id="nav-requests-link"
                navigate={~p"/requests"}
                alt={gettext("Requests")}
                class="relative"
                aria-label={gettext("Requests")}
                hidden={is_nil(@current_profile)}
              >
                <.icon name="hero-hand-raised" class="size-6" />
                <span
                  id="nav-requests-count-badge"
                  class="absolute -right-1 -top-1 inline-flex min-w-5 items-center justify-center rounded-full bg-red-600 px-1 text-xs font-semibold text-white"
                  hidden={@pending_group_join_requests_count <= 0}
                >
                  {if(@pending_group_join_requests_count > 999,
                    do: "999+",
                    else: @pending_group_join_requests_count
                  )}
                </span>
              </.link>
              <.link
                navigate={~p"/profiles"}
                class="flex min-w-0 items-center flex-row gap-3 self-start"
              >
                <span class="min-w-0 text-right">
                  <span class="block text-xs font-semibold uppercase tracking-[0.18em] text-base-content/55">
                    Potok
                  </span>
                  <span
                    id="nav-brand-title"
                    data-default-title=""
                    class="block truncate text-sm font-semibold text-base-content"
                  >
                    <%= if @current_profile do %>
                      {@current_profile.username}
                    <% else %>
                      {gettext("Welcome!")}
                    <% end %>
                  </span>
                </span>
                <span class="flex size-10 items-center justify-center rounded-2xl border border-base-300 bg-gradient-to-br from-primary/15 via-base-100 to-secondary/10 shadow-sm">
                  <%= if @current_profile do %>
                    <img
                      id="nav-brand-profile-avatar"
                      src={PotokIdeWeb.Avatars.profile_avatar_url(@current_profile)}
                      alt={@current_profile.username}
                      class="size-10 rounded-2xl object-cover"
                    />
                  <% else %>
                    <img
                      id="nav-brand-logo"
                      src={~p"/images/pwa/icon-512.png"}
                      width="34"
                      alt="Potok"
                      class="rounded-2xl object-cover"
                    />
                  <% end %>
                </span>
              </.link>
            </div>
          </div>
        </nav>

        <main
          id="main-content"
          class="relative z-0 mx-auto flex min-h-0 w-full max-w-6xl flex-1 flex-col overflow-y-auto overscroll-contain"
        >
          {render_slot(@inner_block)}
        </main>
      </div>

      <div class="drawer-side z-4000 lg:z-auto">
        <label
          for="app-drawer-toggle"
          aria-label={gettext("close")}
          class="drawer-overlay bg-base-content/25 backdrop-blur-[2px]"
        />
        <aside
          id="app-sidebar"
          class="flex h-full w-[min(18rem,calc(100vw-1.25rem))] flex-col border-r border-base-300/70 bg-base-100/95 p-4 pt-[calc(var(--app-safe-area-top)+1rem)] pb-[calc(var(--app-safe-area-bottom)+1rem)] shadow-2xl shadow-primary/10 backdrop-blur sm:w-80 lg:w-72 lg:shadow-none"
        >
          <div class="mb-4 flex items-center justify-between gap-3 border-b border-base-300/70 pb-4">
            <div class="text-xs font-semibold uppercase tracking-[0.18em] text-base-content/50">
              Potok
            </div>

            <label
              for="app-drawer-toggle"
              class="btn btn-ghost btn-circle border border-base-300 bg-base-100 lg:hidden"
            >
              <span class="sr-only">{gettext("close")}</span>
              <.icon name="hero-x-mark" class="size-5" />
            </label>
          </div>

          <div class="flex min-h-0 flex-1 flex-col overflow-y-auto overscroll-contain pr-1">
            <%= if @current_scope do %>
              <div class="mb-4 max-w-full truncate rounded-2xl border border-base-300 bg-base-200 px-4 py-3 text-sm font-medium text-base-content/70">
                {@current_scope.account.email}
              </div>
            <% end %>

            <div class="mb-4">
              <div class="mb-2 px-1 text-[11px] font-semibold uppercase tracking-[0.18em] text-base-content/45">
                {gettext("Navigation")}
              </div>

              <div class="flex flex-col gap-2" data-drawer-nav>
                <%= if @current_scope do %>
                  <.link
                    navigate={~p"/profiles"}
                    data-nav-link
                    data-nav-target="/profiles"
                    data-nav-match="prefix"
                    class={@nav_link_class}
                  >
                    <.icon name="hero-users" class="size-6" /> {gettext("Profiles")}
                  </.link>
                  <.link
                    navigate={~p"/groups"}
                    data-nav-link
                    data-nav-target="/groups"
                    data-nav-match="prefix"
                    class={@nav_link_class}
                  >
                    <.icon name="hero-user-group" class="size-6" /> {gettext("Groups")}
                  </.link>
                  <.link
                    navigate={~p"/invitations"}
                    data-nav-link
                    data-nav-target="/invitations"
                    data-nav-match="prefix"
                    class={@nav_link_class}
                  >
                    <.icon name="hero-inbox-arrow-down" class="size-6" /> {gettext("Invitations")}
                  </.link>
                  <.link
                    navigate={~p"/requests"}
                    data-nav-link
                    data-nav-target="/requests"
                    data-nav-match="prefix"
                    class={@nav_link_class}
                  >
                    <.icon name="hero-hand-raised" class="size-6" /> {gettext("Requests")}
                  </.link>
                <% else %>
                  <.link
                    navigate={~p"/accounts/log-in"}
                    data-nav-link
                    data-nav-target="/accounts/log-in"
                    data-nav-match="exact"
                    class={@nav_link_class}
                  >
                    <.icon name="hero-arrow-left-end-on-rectangle" class="size-6" /> {gettext(
                      "Log in"
                    )}
                  </.link>
                <% end %>
              </div>
            </div>

            <%= if @current_scope do %>
              <div class="mb-4 border-t border-base-300/70 pt-4">
                <div class="mb-2 px-1 text-[11px] font-semibold uppercase tracking-[0.18em] text-base-content/45">
                  {gettext("Account")}
                </div>

                <div class="flex flex-col gap-2" data-drawer-nav>
                  <.link
                    navigate={~p"/accounts/settings"}
                    data-nav-link
                    data-nav-target="/accounts/settings"
                    data-nav-match="prefix"
                    class={@nav_link_class}
                  >
                    <.icon name="hero-cog-6-tooth" class="size-6" /> {gettext("Settings")}
                  </.link>
                  <.link href={~p"/accounts/log-out"} method="delete" class={@nav_link_class}>
                    <.icon name="hero-arrow-left-start-on-rectangle" class="size-6" /> {gettext(
                      "Log out"
                    )}
                  </.link>
                </div>
              </div>
            <% end %>

            <div class="border-t border-base-300/70 pt-4">
              <div class="mb-2 px-1 text-[11px] font-semibold uppercase tracking-[0.18em] text-base-content/45">
                {gettext("Preferences")}
              </div>

              <div class="space-y-4">
                <.locale_switcher
                  current_locale={@current_locale}
                  available_locales={@available_locales}
                /> <.theme_toggle />
              </div>
            </div>
          </div>
        </aside>
      </div>
    </div>
    <.flash_group flash={@flash} />
    """
  end

  # The home button goes straight to the page `PageController.home/2` would
  # redirect to, saving a round trip and allowing live navigation.
  defp home_path(_current_scope, %{} = _current_profile), do: ~p"/groups"
  defp home_path(%{account: %{}}, nil), do: ~p"/profiles"
  defp home_path(_current_scope, _current_profile), do: ~p"/accounts/log-in"

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} /> <.flash kind={:error} flash={@flash} />
      <.flash
        id="client-error"
        kind={:info}
        title={gettext("Reconnecting")}
        auto_dismiss={false}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:info}
        title={gettext("Reconnecting")}
        auto_dismiss={false}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative inline-flex w-full max-w-[11rem] flex-row items-center rounded-full border-2 border-base-300 bg-base-300 sm:w-auto">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 transition-[left]" />
      <button
        class="flex w-1/3 cursor-pointer justify-center p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
      <button
        class="flex w-1/3 cursor-pointer justify-center p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
      <button
        class="flex w-1/3 cursor-pointer justify-center p-2"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end

  attr :current_locale, :string, default: nil
  attr :available_locales, :list, default: PotokIdeWeb.Locale.supported_locales()

  def locale_switcher(assigns) do
    assigns =
      assign(
        assigns,
        :current_locale,
        assigns.current_locale || PotokIdeWeb.Locale.default_locale()
      )

    ~H"""
    <nav
      aria-label={gettext("Language selector")}
      class="inline-flex w-full items-center justify-center gap-1 rounded-full border border-base-300 bg-base-200 p-1 shadow-sm sm:w-auto"
    >
      <%= for locale <- @available_locales do %>
        <.link
          href={~p"/locale/#{locale}"}
          class={[
            "min-w-[4.5rem] rounded-full px-3 py-1 text-center text-xs font-semibold tracking-[0.18em] uppercase transition-colors",
            if(locale == @current_locale,
              do: "bg-base-100 text-base-content shadow-sm",
              else: "text-base-content/60 hover:text-base-content"
            )
          ]}
          aria-current={locale == @current_locale && "true"}
        >
          {PotokIdeWeb.Locale.locale_name(locale)}
        </.link>
      <% end %>
    </nav>
    """
  end

  slot :inner_block, required: true

  # A stable id keeps the hook mounted (and the menu open) across re-renders.
  attr :id, :string, required: true
  attr :icon, :string, default: "hero-ellipsis-horizontal"
  attr :label, :string, default: nil
  attr :menu_class, :string, default: nil

  def drop_down_menu(assigns) do
    ~H"""
    <div
      id={"#{@id}-container"}
      class="dropdown dropdown-end w-auto flex-none"
      phx-hook="DropdownMenu"
    >
      <button
        id={@id}
        type="button"
        tabindex="0"
        aria-label={@label || gettext("Actions")}
        class="btn btn-ghost btn-circle border border-base-300 bg-base-100/80 shadow-sm backdrop-blur"
      >
        <span class="sr-only">{@label || gettext("Actions")}</span>
        <.icon name={@icon} class="size-5" />
      </button>
      <div
        tabindex="0"
        data-dropdown-content
        class={[
          "dropdown-content z-40 mt-3 w-[min(18rem,calc(100vw-1.25rem))] rounded-md border border-base-300/70 bg-base-100/95 p-3 shadow-2xl shadow-primary/10 backdrop-blur",
          @menu_class
        ]}
      >
        {render_slot(@inner_block)}
      </div>
    </div>
    """
  end
end
