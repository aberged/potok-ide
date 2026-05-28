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
    ~H"""
    <div class="relative flex min-h-dvh max-h-dvh flex-col overflow-clip pt-(--app-safe-area-top) pb-(--app-safe-area-bottom)">
      <nav class="sticky z-100">
        <div class="mx-auto flex items-center justify-between gap-3 rounded-[2rem] border border-base-300/70 bg-base-100/85 px-4 py-3 shadow-lg shadow-primary/5 backdrop-blur sm:px-5">
          <% profile = @current_profile %>
          <.header_menu>
            <%= if @current_scope do %>
              <div class="mb-4 max-w-full z-50 truncate rounded-2xl border border-base-300 bg-base-200 px-4 py-3 text-sm font-medium text-base-content/70">
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
                    href={~p"/profiles"}
                    data-nav-link
                    data-nav-target="/profiles"
                    data-nav-match="prefix"
                    class="rounded-2xl border border-base-300 bg-base-200 px-4 py-3 text-sm font-medium text-base-content/70 transition-colors hover:bg-base-300 hover:text-base-content"
                  >
                    <.icon name="hero-users" class="size-6" /> {gettext("Profiles")}
                  </.link>
                  <.link
                    href={~p"/groups"}
                    data-nav-link
                    data-nav-target="/groups"
                    data-nav-match="prefix"
                    class="rounded-2xl border border-base-300 bg-base-200 px-4 py-3 text-sm font-medium text-base-content/70 transition-colors hover:bg-base-300 hover:text-base-content"
                  >
                    <.icon name="hero-user-group" class="size-6" /> {gettext("Groups")}
                  </.link>
                  <.link
                    href={~p"/invitations"}
                    data-nav-link
                    data-nav-target="/invitations"
                    data-nav-match="prefix"
                    class="rounded-2xl border border-base-300 bg-base-200 px-4 py-3 text-sm font-medium text-base-content/70 transition-colors hover:bg-base-300 hover:text-base-content"
                  >
                    <.icon name="hero-inbox-arrow-down" class="size-6" /> {gettext("Invitations")}
                  </.link>
                  <.link
                    href={~p"/requests"}
                    data-nav-link
                    data-nav-target="/requests"
                    data-nav-match="prefix"
                    class="rounded-2xl border border-base-300 bg-base-200 px-4 py-3 text-sm font-medium text-base-content/70 transition-colors hover:bg-base-300 hover:text-base-content"
                  >
                    <.icon name="hero-hand-raised" class="size-6" /> {gettext("Requests")}
                  </.link>
                <% else %>
                  <.link
                    href={~p"/accounts/log-in"}
                    data-nav-link
                    data-nav-target="/accounts/log-in"
                    data-nav-match="exact"
                    class="rounded-2xl border border-base-300 bg-base-200 px-4 py-3 text-sm font-medium text-base-content/70 transition-colors hover:bg-base-300 hover:text-base-content"
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
                    href={~p"/accounts/settings"}
                    data-nav-link
                    data-nav-target="/accounts/settings"
                    data-nav-match="prefix"
                    class="rounded-2xl border border-base-300 bg-base-200 px-4 py-3 text-sm font-medium text-base-content/70 transition-colors hover:bg-base-300 hover:text-base-content"
                  >
                    <.icon name="hero-cog-6-tooth" class="size-6" /> {gettext("Settings")}
                  </.link>
                  <.link
                    href={~p"/accounts/log-out"}
                    method="delete"
                    class="rounded-2xl border border-base-300 bg-base-200 px-4 py-3 text-sm font-medium text-base-content/70 transition-colors hover:bg-base-300 hover:text-base-content"
                  >
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
          </.header_menu>

          <.link
            id="nav-root-group-link"
            href={~p"/"}
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
              href={~p"/invitations"}
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
              href={~p"/requests"}
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
              href={~p"/profiles"}
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
                  <%= if profile do %>
                    {profile.username}
                  <% else %>
                    {gettext("Welcome!")}
                  <% end %>
                </span>
              </span>
              <span class="flex size-10 items-center justify-center rounded-2xl border border-base-300 bg-gradient-to-br from-primary/15 via-base-100 to-secondary/10 shadow-sm">
                <%= if profile do %>
                  <img
                    id="nav-brand-profile-avatar"
                    src={
                      if(@current_profile.profile_picture_url not in [nil, ""],
                        do: @current_profile.profile_picture_url,
                        else: "/avatar/profile/#{@current_profile.id}"
                      )
                    }
                    alt={if(@current_profile, do: @current_profile.username, else: "Potok")}
                    class={[
                      "size-10 rounded-2xl object-cover"
                    ]}
                  />
                <% else %>
                  <img
                    id="nav-brand-logo"
                    src={~p"/images/pwa/icon-512.png"}
                    width="34"
                    alt="Potok"
                    class={["rounded-2xl object-cover"]}
                  />
                <% end %>
              </span>
            </.link>
          </div>
        </div>
      </nav>

      <div class="relative z-0 flex max-w-screen flex-1 justify-center">
        <main class="flex flex-col flex-1 max-w-dvw lg:max-w-6xl justify-center">
          <div
            id="main-content"
            class="flex flex-col flex-1 max-w-dvw lg:max-w-6xl justify-center overflow-clip"
          >
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>

      <.flash_group flash={@flash} />
    </div>
    """
  end

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
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

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

  attr :id, :string, default: nil
  attr :icon, :string, default: "hero-bars-3"

  def header_menu(assigns) do
    assigns =
      assign(
        assigns,
        :id,
        assigns[:id] || "header-drawer-#{System.unique_integer([:positive, :monotonic])}"
      )

    ~H"""
    <div id={"#{@id}-container"} class="drawer w-auto flex-none" phx-hook="HeaderDrawer">
      <input id={@id} type="checkbox" class="drawer-toggle" />

      <div class="drawer-content">
        <label
          for={@id}
          class="btn btn-ghost btn-circle border border-base-300 bg-base-100/80 shadow-sm backdrop-blur"
        >
          <.icon name={@icon} class="size-5" />
        </label>
      </div>

      <div class="drawer-side z-4000">
        <label
          for={@id}
          aria-label={gettext("close")}
          class="drawer-overlay bg-base-content/25 backdrop-blur-[2px]"
        />

        <div class="min-h-full w-[min(18rem,calc(100vw-1.25rem))] sm:w-80 lg:w-96 border-r border-base-300/70 bg-base-100/95 p-4 shadow-2xl shadow-primary/10 backdrop-blur">
          <div class="mb-4 flex items-center justify-between gap-3 border-b border-base-300/70 pb-4">
            <div>
              <div class="text-xs font-semibold uppercase tracking-[0.18em] text-base-content/50">
                Potok
              </div>
            </div>

            <label for={@id} class="btn btn-ghost btn-circle border border-base-300 bg-base-100">
              <span class="sr-only">{gettext("close")}</span>
              <.icon name="hero-x-mark" class="size-5" />
            </label>
          </div>

          <div class="flex max-h-[calc(100vh-6rem)] flex-col overflow-y-auto pr-1">
            {render_slot(@inner_block)}
          </div>
        </div>
      </div>
    </div>
    """
  end

  slot :inner_block, required: true

  attr :id, :string, default: nil
  attr :icon, :string, default: "hero-ellipsis-horizontal"
  attr :label, :string, default: nil
  attr :menu_class, :string, default: nil

  def drop_down_menu(assigns) do
    assigns =
      assign(
        assigns,
        :id,
        assigns[:id] || "dropdown-menu-#{System.unique_integer([:positive, :monotonic])}"
      )

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
