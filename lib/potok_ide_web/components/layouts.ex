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

  attr :full_width, :boolean,
    default: false,
    doc:
      "lets the page's scroll area span the whole width, so its scrollbar sits at the window's edge"

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
              class={[icon_button_class("secondary", "md"), @current_scope && "lg:hidden"]}
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
                id="nav-tags-link"
                navigate={~p"/tags"}
                alt={gettext("Tags")}
                aria-label={gettext("Tags")}
                hidden={is_nil(@current_profile)}
              >
                <.icon name="hero-hashtag" class="size-6" />
              </.link>
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
                  <span class="block font-brand text-xs font-bold uppercase tracking-[0.18em] text-base-content/55">
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
          class={[
            "relative z-0 mx-auto flex min-h-0 w-full flex-1 flex-col overflow-y-auto overscroll-contain",
            !@full_width && "max-w-6xl"
          ]}
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
            <div class="font-brand text-xs font-bold uppercase tracking-[0.18em] text-base-content/50">
              Potok
            </div>

            <label
              for="app-drawer-toggle"
              class={[icon_button_class("secondary", "md"), "lg:hidden"]}
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
                  <.link
                    navigate={~p"/tags"}
                    data-nav-link
                    data-nav-target="/tags"
                    data-nav-match="prefix"
                    class={@nav_link_class}
                  >
                    <.icon name="hero-hashtag" class="size-6" /> {gettext("Tags")}
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

  @doc """
  Renders the layout of the pages for guests: the landing page and the log-in
  pages. Instead of the app's menu it has the landing page's own header and
  footer, and since the body never scrolls, the page is its own scroll area.

  ## Examples

      <Layouts.guest flash={@flash} current_locale={@current_locale} centered>
        <Layouts.guest_card id="login" title={gettext("Log in")}>...</Layouts.guest_card>
      </Layouts.guest>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :current_locale, :string, default: nil, doc: "the active locale"
  attr :available_locales, :list, default: PotokIdeWeb.Locale.supported_locales()

  attr :centered, :boolean,
    default: false,
    doc: "centers the content (a single card) between the header and the footer"

  attr :about_link, :boolean,
    default: false,
    doc: "links the header back to the landing page, for pages without a `header_action`"

  slot :inner_block, required: true
  slot :header_action, doc: "a link at the right end of the header"

  def guest(assigns) do
    ~H"""
    <div
      id="guest"
      class="landing h-dvh overflow-y-auto overscroll-contain bg-base-100 text-base-content"
    >
      <div class="relative isolate flex min-h-full flex-col overflow-x-clip pt-(--app-safe-area-top) pb-(--app-safe-area-bottom)">
        <div class="lp-glow absolute inset-x-0 top-0 -z-10 h-[42rem]" aria-hidden="true"></div>

        <header
          id="guest-header"
          class="mx-auto flex w-full max-w-5xl items-center justify-between gap-4 px-5 py-5 sm:px-8"
        >
          <a href={~p"/"} class="group flex items-center gap-2.5" aria-label="Potok">
            <.mark
              id="guest-header-mark"
              class="size-9 transition-transform duration-500 group-hover:-rotate-6"
            />
            <span class="font-brand text-xl font-bold">potok</span>
          </a>
          {render_slot(@header_action)}
          <.link
            :if={@about_link && @header_action == []}
            id="guest-about-link"
            href={~p"/"}
            class="rounded-full border border-base-content/15 px-4 py-2 text-sm font-medium transition duration-200 hover:border-base-content/30 hover:bg-base-content/5 active:scale-[0.98]"
          >
            {gettext("What is Potok?")}
          </.link>
        </header>

        <main class={[
          "flex-1",
          @centered && "flex flex-col items-center justify-center px-5 py-10 sm:py-16"
        ]}>
          {render_slot(@inner_block)}
        </main>

        <footer id="guest-footer" class="border-t border-base-content/8">
          <div class="mx-auto flex max-w-5xl flex-col gap-6 px-5 py-10 sm:px-8 md:flex-row md:items-center md:justify-between">
            <div>
              <div class="flex items-center gap-2">
                <.mark id="guest-footer-mark" class="size-6" />
                <span class="font-brand font-bold">potok</span>
              </div>
              <p class="mt-2 text-sm text-base-content/55">
                {gettext("A shared platform for assemblies")}
              </p>
              <p class="mt-1 text-xs text-base-content/45 hidden">
                {gettext(
                  "No ads, no tracking. The only cookie here is the one that keeps you logged in."
                )}
              </p>
            </div>
            <div class="flex flex-col gap-4 md:items-end">
              <div class="flex flex-wrap items-center gap-3 md:justify-end">
                <.locale_switcher
                  current_locale={@current_locale}
                  available_locales={@available_locales}
                />
                <.theme_toggle />
              </div>
              <.link
                id="guest-privacy-link"
                href={~p"/privacy-policy"}
                class="text-sm text-base-content/60 underline-offset-4 transition hover:text-base-content hover:underline"
              >
                {gettext("Privacy policy")}
              </.link>
            </div>
          </div>
        </footer>
      </div>
      <%!-- Inside `.landing`, so its flashes take the mark's blue. --%>
      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  The card of a log-in page inside a centered `guest/1` layout: the mark, a
  title and a line under it, then the page's form.
  """
  attr :id, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil

  attr :invitation_note, :boolean,
    default: false,
    doc: "tells visitors without an account, under the card, how to get one"

  slot :inner_block, required: true

  def guest_card(assigns) do
    ~H"""
    <div id={@id} class="w-full max-w-md">
      <section class="lp-panel lp-rise px-6 py-8 sm:px-10 sm:py-10">
        <div class="text-center">
          <.mark id={"#{@id}-mark"} class="mx-auto size-12" />
          <h1 class="lp-serif mt-5 text-3xl tracking-tight text-balance sm:text-4xl">
            {@title}
          </h1>
          <p :if={@subtitle} class="mt-3 leading-7 text-pretty wrap-break-word text-base-content/70">
            {@subtitle}
          </p>
        </div>
        <div class="mt-8">{render_slot(@inner_block)}</div>
      </section>
      <p
        :if={@invitation_note}
        id={"#{@id}-invitation-note"}
        class="lp-rise mt-6 text-center text-sm leading-6 text-pretty text-base-content/60"
      >
        {gettext("No account yet?")}
        <.link href={~p"/" <> "#landing-join"} class="lp-link">
          {gettext("Potok is invitation only for now.")}
        </.link>
      </p>
    </div>
    """
  end

  @doc """
  The Potok mark: a drop that turns into a stream.
  """
  attr :id, :string, required: true, doc: "unique on the page, it names the mark's gradient"
  attr :class, :string, default: nil

  def mark(assigns) do
    ~H"""
    <svg id={@id} viewBox="247 142 540 540" class={@class} aria-hidden="true">
      <defs>
        <linearGradient id={"#{@id}-gradient"} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#69cbf5" />
          <stop offset="0.45" stop-color="#2e8fde" />
          <stop offset="1" stop-color="#0056c4" />
        </linearGradient>
      </defs>
      <path
        fill={"url(##{@id}-gradient)"}
        d="m 674.01932,396.85242 c 13.95963,29.86298 23.09625,60.54444 22.17121,93.28308 -1.24783,44.16177 -15.95191,83.43815 -45.36201,116.82792 -1.21933,1.38428 -2.23986,3.12007 -4.78685,3.41667 -2.0492,-1.99134 -1.66361,-4.97542 -2.00289,-7.47084 -1.41324,-10.39427 -4.47739,-20.24088 -9.70759,-29.27488 -2.05803,-3.55475 -1.54977,-6.02275 0.54542,-9.17186 19.18496,-28.83385 26.17573,-60.81065 22.42971,-94.87463 -2.4893,-22.63609 -10.53228,-43.83776 -21.20171,-63.9588 -2.3458,-4.42388 -4.15004,-9.18676 -7.64911,-13.42671 -3.30019,2.45154 -3.77863,6.22913 -5.34575,9.25239 -11.04301,21.3042 -29.26389,34.54261 -50.01774,45.02568 -16.6135,8.39178 -34.56829,13.73489 -51.01257,22.50524 -4.8732,2.59904 -9.45738,5.56441 -13.22676,9.6937 -9.5859,10.50103 -9.02495,22.13097 1.67155,31.56648 8.68296,7.65937 19.21129,12.24696 29.42853,17.29587 20.09622,9.93052 40.43073,19.44799 57.47596,34.44163 16.18059,14.23308 25.849,31.6426 25.44793,53.70051 -0.0801,4.40204 -0.90468,8.81345 -1.65648,13.17382 -0.71596,4.15229 -3.03101,7.17749 -6.74916,9.4477 -41.15822,25.13035 -85.51688,33.60119 -132.69468,23.90328 -61.91989,-12.72831 -105.34418,-49.04609 -129.91485,-107.03789 -18.07285,-42.6556 -17.60944,-86.26095 -3.07414,-130.03547 12.5374,-37.75766 33.5891,-70.9529 55.08947,-103.89645 35.01388,-53.6492 71.47927,-106.31244 108.56256,-158.54868 1.20508,-1.69745 2.19316,-3.60479 4.9947,-5.09971 5.55477,7.86459 11.17435,15.68595 16.65532,23.60328 32.60938,47.10486 65.83963,93.78652 97.12073,141.79867 15.4634,23.73422 30.66938,47.63637 42.8092,73.86 m -133.42186,33.60901 c 6.75783,-3.47983 13.68239,-6.67257 20.24607,-10.48655 39.43661,-22.91565 46.47756,-64.65151 23.51088,-98.70125 -17.59515,-26.08609 -35.24327,-52.13652 -52.90348,-78.17867 -4.55568,-6.71794 -9.24542,-13.34497 -14.16462,-20.43313 -1.68893,2.04684 -2.71047,3.11139 -3.53631,4.31058 -35.22802,51.15255 -70.79685,102.08616 -102.80711,155.36008 -13.20043,21.9692 -24.47739,44.91002 -30.37123,70.04082 -8.60746,36.70135 -4.48491,71.86335 14.83519,104.52985 22.45994,37.97527 56.01862,60.16661 99.44062,67.16133 14.15785,2.28059 26.7241,-6.15285 29.70012,-18.77018 2.51617,-10.66787 -2.49874,-18.85497 -9.42911,-26.10255 -9.71128,-10.15575 -21.68723,-17.48247 -32.95021,-25.68165 -9.75708,-7.10298 -19.60315,-14.13372 -26.8736,-23.93971 -7.15828,-9.65485 -11.0719,-20.29478 -8.56022,-32.6205 3.40424,-16.70615 14.87124,-27.02159 28.23744,-35.76031 20.13807,-13.16616 42.95835,-20.66646 65.62557,-30.72816 z"
      />
    </svg>
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
        phx-disconnected={
          JS.show(to: ".phx-client-error #client-error") |> JS.remove_attribute("hidden")
        }
        phx-connected={hide_flash("#client-error") |> JS.set_attribute({"hidden", ""})}
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
        phx-disconnected={
          JS.show(to: ".phx-server-error #server-error") |> JS.remove_attribute("hidden")
        }
        phx-connected={hide_flash("#server-error") |> JS.set_attribute({"hidden", ""})}
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
        class={icon_button_class("secondary", "md")}
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
