defmodule PotokIdeWeb.GroupLive.Show.CalendarTab do
  use PotokIdeWeb, :html

  alias PotokIde.Events
  alias PotokIde.Events.{Event, Format, Occurrence}
  alias PotokIdeWeb.GroupLive.Show.{CalendarState, Components}
  alias PotokIdeWeb.TagComponents

  # Chip colours of sub-groups' events; the group's own use the primary colour.
  @palette [
    {"bg-sky-500/15 text-sky-900 dark:text-sky-100", "bg-sky-500"},
    {"bg-emerald-500/15 text-emerald-900 dark:text-emerald-100", "bg-emerald-500"},
    {"bg-amber-500/20 text-amber-950 dark:text-amber-100", "bg-amber-500"},
    {"bg-rose-500/15 text-rose-900 dark:text-rose-100", "bg-rose-500"},
    {"bg-violet-500/15 text-violet-900 dark:text-violet-100", "bg-violet-500"},
    {"bg-teal-500/15 text-teal-900 dark:text-teal-100", "bg-teal-500"}
  ]

  attr :group, :map, required: true
  attr :current_profile, :map, required: true
  attr :access, :map, required: true
  attr :time_zone, :string, required: true
  attr :month, Date, required: true
  attr :mode, :string, required: true, doc: "\"month\" or \"list\""
  attr :weeks, :list, required: true, doc: "weeks of day maps, see `CalendarState`"
  attr :by_day, :map, required: true, doc: "occurrences per local date"
  attr :occurrences, :any, required: true, doc: "stream of the month's occurrences"
  attr :occurrences_empty, :boolean, default: true
  attr :selected_date, Date, required: true
  attr :include_subgroups, :boolean, default: false
  attr :show_groups, :boolean, default: true, doc: "root calendar: events of the viewer's groups"
  attr :show_public, :boolean, default: true, doc: "root calendar: public events"
  attr :event, :any, default: nil
  attr :occurrence, :any, default: nil
  attr :occurrence_cancelled, :boolean, default: false
  attr :summary, :any, default: nil
  attr :can_manage, :boolean, default: false
  attr :event_member, :boolean, default: false, doc: "the viewer is a member of the event's group"
  attr :my_reminders, :any, default: nil
  attr :form, :any, default: nil
  attr :form_values, :any, default: nil
  attr :announce, :boolean, default: true
  attr :notify, :boolean, default: true

  def panel(assigns) do
    assigns =
      assigns
      |> assign(:today, CalendarState.today(assigns.time_zone))
      |> assign(:side?, assigns.form != nil or assigns.event != nil)
      |> assign(:scope_text, scope_text(assigns))

    ~H"""
    <div id="group-panel-calendar" class="card flex min-h-0 flex-1 flex-col px-2">
      <div data-tab-scroll class="min-h-0 flex-1 overflow-y-auto overscroll-contain pt-4 pb-4">
        <.page_header id="group-calendar-header" icon="hero-calendar-days" class="px-1" compact>
          {if(@group.is_root, do: gettext("My calendar"), else: gettext("Calendar"))}
          <:subtitle>{@scope_text}</:subtitle>
        </.page_header>

        <div class={[
          @side? && "lg:grid lg:grid-cols-[minmax(0,1fr)_23rem] lg:items-start lg:gap-4"
        ]}>
          <section id="calendar-main" class={["min-w-0", @side? && "hidden lg:block"]}>
            <div class="mb-4 flex flex-wrap items-center justify-between gap-3 px-1">
              <h3 id="calendar-month-title" class="min-w-0 text-lg font-semibold">
                {upcase_first(Format.month_year(@month.year, @month.month))}
              </h3>
              <div class="flex flex-wrap items-center gap-2">
                <div class="inline-flex items-center rounded-full border border-base-300 bg-base-200/70 p-0.5">
                  <button
                    id="calendar-prev-month"
                    type="button"
                    phx-click="calendar_prev_month"
                    aria-label={gettext("Previous month")}
                    class={nav_button_class()}
                  >
                    <.icon name="hero-chevron-left" class="size-4" />
                  </button>
                  <button
                    id="calendar-today"
                    type="button"
                    phx-click="calendar_today"
                    class="rounded-full px-3 py-1 text-xs font-semibold text-base-content/70 transition hover:bg-base-100 hover:text-base-content"
                  >
                    {gettext("Today")}
                  </button>
                  <button
                    id="calendar-next-month"
                    type="button"
                    phx-click="calendar_next_month"
                    aria-label={gettext("Next month")}
                    class={nav_button_class()}
                  >
                    <.icon name="hero-chevron-right" class="size-4" />
                  </button>
                </div>
                <div
                  id="calendar-view"
                  role="group"
                  aria-label={gettext("Show calendar as")}
                  class="inline-flex rounded-full border border-base-300 bg-base-200/70 p-0.5"
                >
                  <Components.view_toggle_button
                    id="calendar-view-month"
                    event="calendar_set_mode"
                    view="month"
                    active={@mode == "month"}
                    icon="hero-calendar-days"
                    label={gettext("Month")}
                    label_class="hidden sm:inline"
                  />
                  <Components.view_toggle_button
                    id="calendar-view-list"
                    event="calendar_set_mode"
                    view="list"
                    active={@mode == "list"}
                    icon="hero-list-bullet"
                    label={gettext("List")}
                    label_class="hidden sm:inline"
                  />
                </div>
                <.button
                  :if={Events.can_create?(@access, @group)}
                  id="calendar-new-event"
                  type="button"
                  phx-click="calendar_new"
                  variant="primary"
                  size="sm"
                >
                  <.icon name="hero-plus" class="size-4" />
                  <span>{gettext("Event")}</span>
                </.button>
              </div>
            </div>

            <div
              :if={@group.is_root or @access.member?}
              class="mb-3 flex flex-wrap items-center gap-x-5 gap-y-2 px-1"
            >
              <%= if @group.is_root do %>
                <.switch
                  id="calendar-groups-toggle"
                  event="calendar_toggle_groups"
                  checked={@show_groups}
                  icon="hero-user-group"
                  label={gettext("My groups")}
                />
                <.switch
                  id="calendar-public-toggle"
                  event="calendar_toggle_public"
                  checked={@show_public}
                  icon="hero-globe-alt"
                  label={gettext("Public events")}
                />
              <% else %>
                <.switch
                  id="calendar-subgroups-toggle"
                  event="calendar_toggle_subgroups"
                  checked={@include_subgroups}
                  label={gettext("Include sub-groups")}
                />
              <% end %>
            </div>

            <%= if @mode == "month" do %>
              <div id="calendar-day-list" class="mb-4 flex flex-col gap-2 sm:hidden">
                <div class="flex flex-wrap items-baseline gap-x-2 px-1 text-sm">
                  <h4 class="font-semibold first-letter:uppercase">
                    {Format.date(@selected_date, @today)}
                  </h4>
                  <p
                    :if={Map.get(@by_day, @selected_date, []) == []}
                    id="calendar-day-empty"
                    class="text-base-content/65"
                  >
                    {gettext("No events on this day.")}
                  </p>
                </div>
                <.occurrence_row
                  :for={occurrence <- Map.get(@by_day, @selected_date, [])}
                  id={"calendar-day-occurrence-#{occurrence.event.id}-#{occurrence.date}"}
                  occurrence={occurrence}
                  group={@group}
                  time_zone={@time_zone}
                  today={@today}
                />
              </div>
              <.month_grid
                weeks={@weeks}
                selected_date={@selected_date}
                group={@group}
                time_zone={@time_zone}
                today={@today}
              />
            <% else %>
              <div id="calendar-list" phx-update="stream" class="flex flex-col gap-2">
                <.occurrence_row
                  :for={{dom_id, occurrence} <- @occurrences}
                  id={dom_id}
                  occurrence={occurrence}
                  group={@group}
                  time_zone={@time_zone}
                  today={@today}
                  show_date
                />
              </div>
              <div
                :if={@occurrences_empty}
                id="calendar-list-empty"
                class="flex min-h-48 flex-col items-center justify-center gap-2 rounded-3xl border border-dashed border-base-300 bg-base-100/70 px-6 text-center text-sm text-base-content/65"
              >
                <.icon name="hero-calendar" class="size-6 text-base-content/35" />
                {if @group.is_root and !@show_groups and !@show_public,
                  do: gettext("Turn on a filter above to see events."),
                  else: gettext("No events this month.")}
              </div>
            <% end %>
          </section>

          <aside :if={@side?} id="calendar-side" class="min-w-0 lg:sticky lg:top-0">
            <%= cond do %>
              <% @form -> %>
                <.event_form
                  form={@form}
                  values={@form_values}
                  time_zone={@time_zone}
                  announce={@announce}
                  notify={@notify}
                  can_announce={PotokIde.Social.Access.can?(@access, :post_values)}
                  can_publish={Events.can_publish?(@access, @group)}
                />
              <% @event -> %>
                <.event_detail
                  event={@event}
                  occurrence={@occurrence}
                  occurrence_cancelled={@occurrence_cancelled}
                  summary={@summary}
                  can_manage={@can_manage}
                  member={@event_member}
                  my_reminders={@my_reminders}
                  group={@group}
                  current_profile={@current_profile}
                  time_zone={@time_zone}
                  today={@today}
                />
            <% end %>
          </aside>
        </div>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :checked, :boolean, required: true
  attr :label, :string, required: true
  attr :icon, :string, default: nil

  def switch(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click={@event}
      role="switch"
      aria-checked={to_string(@checked)}
      class="inline-flex min-h-8 items-center gap-2 text-xs font-medium text-base-content/70 transition hover:text-base-content sm:min-h-0"
    >
      <span class={[
        "relative inline-flex h-4 w-7 items-center rounded-full transition-colors duration-200",
        if(@checked, do: "bg-primary", else: "bg-base-300")
      ]}>
        <span class={[
          "inline-block size-3 rounded-full bg-base-100 shadow transition-transform duration-200",
          if(@checked, do: "translate-x-3.5", else: "translate-x-0.5")
        ]} />
      </span>
      <.icon :if={@icon} name={@icon} class="size-4 text-base-content/65" />
      {@label}
    </button>
    """
  end

  attr :weeks, :list, required: true
  attr :selected_date, Date, required: true
  attr :group, :map, required: true
  attr :time_zone, :string, required: true
  attr :today, Date, required: true

  defp month_grid(assigns) do
    ~H"""
    <div
      id="calendar-grid"
      role="grid"
      phx-hook=".DayList"
      class="overflow-hidden rounded-3xl border border-base-300/70 bg-base-100/80 shadow-sm"
    >
      <div
        role="row"
        class="grid grid-cols-7 border-b border-base-300/70 bg-base-200/60 text-center text-[11px] font-semibold uppercase tracking-wide text-base-content/65"
      >
        <div :for={weekday <- 1..7} role="columnheader" class="py-2">
          {Format.weekday_short(weekday)}
        </div>
      </div>
      <div
        :for={week <- @weeks}
        role="row"
        class="grid grid-cols-7 divide-x divide-base-300/50 border-b border-base-300/50 last:border-b-0"
      >
        <div
          :for={day <- week}
          id={"calendar-day-#{day.date}"}
          role="gridcell"
          aria-selected={to_string(day.date == @selected_date)}
          phx-click="calendar_select_day"
          phx-value-date={day.date}
          class={[
            "relative min-h-16 min-w-0 cursor-pointer p-1 transition-colors duration-150 sm:min-h-26",
            "hover:bg-base-200/60",
            !day.in_month? && "bg-base-200/30 text-base-content/65",
            day.date == @selected_date && "bg-primary/5 ring-1 ring-inset ring-primary/30"
          ]}
        >
          <%!-- The whole day takes clicks; the keyboard and screen readers come here. --%>
          <button
            type="button"
            phx-click="calendar_select_day"
            phx-value-date={day.date}
            aria-label={Format.date(day.date, @today)}
            class={[
              "inline-flex size-6 cursor-pointer items-center justify-center rounded-full text-xs font-semibold tabular-nums focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40",
              day.today? && "bg-primary text-primary-content shadow-sm"
            ]}
          >
            {day.date.day}
          </button>
          <%!-- Dots on phones, where the day's events are listed above the grid. --%>
          <div class="mt-1 flex flex-wrap gap-0.5 px-0.5 sm:hidden">
            <span
              :for={occurrence <- Enum.take(day.occurrences, 4)}
              class={["size-1.5 rounded-full", dot_class(occurrence, @group)]}
            />
          </div>
          <div class="mt-1 hidden min-w-0 flex-col gap-0.5 sm:flex">
            <button
              :for={occurrence <- Enum.take(day.occurrences, 3)}
              id={"calendar-chip-#{occurrence.event.id}-#{day.date}"}
              type="button"
              phx-click="calendar_open"
              phx-value-id={occurrence.event.id}
              phx-value-date={occurrence.date}
              title={occurrence.event.title}
              class={[
                "truncate rounded-md px-1.5 py-0.5 text-left text-[11px] font-medium leading-snug transition duration-150 hover:brightness-95 hover:shadow-sm active:scale-[0.98]",
                chip_class(occurrence, @group)
              ]}
            >
              <.icon
                :if={occurrence.event.is_public}
                name="hero-globe-alt"
                class="-mt-px size-3 opacity-60"
              />
              <span :if={!occurrence.event.all_day} class="tabular-nums opacity-70">
                {Format.time(occurrence.starts_at, @time_zone)}
              </span>
              {occurrence.event.title}
            </button>
            <span
              :if={length(day.occurrences) > 3}
              class="px-1 text-[11px] font-medium text-base-content/65"
            >
              {gettext("+%{count} more", count: length(day.occurrences) - 3)}
            </span>
          </div>
        </div>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".DayList">
      // Picked further down the grid, a day would list its events out of view, above it.
      export default {
        mounted() {
          this.el.addEventListener("click", event => {
            if (!event.target.closest("[role='gridcell']")) return

            const list = document.getElementById("calendar-day-list")
            const scroller = this.el.closest("[data-tab-scroll]")
            // Hidden on wider screens, where the days show their events themselves.
            if (!list?.offsetParent || !scroller) return

            const above = list.getBoundingClientRect().top - scroller.getBoundingClientRect().top
            if (above < 0) scroller.scrollBy({top: above - 8, behavior: "smooth"})
          })
        },
      }
    </script>
    """
  end

  attr :id, :string, required: true
  attr :occurrence, Occurrence, required: true
  attr :group, :map, required: true
  attr :time_zone, :string, required: true
  attr :today, Date, required: true
  attr :show_date, :boolean, default: false

  defp occurrence_row(assigns) do
    assigns = assign(assigns, :event, assigns.occurrence.event)

    ~H"""
    <button
      id={@id}
      type="button"
      phx-click="calendar_open"
      phx-value-id={@event.id}
      phx-value-date={@occurrence.date}
      class="group flex w-full items-center gap-3 rounded-2xl border border-base-300/70 bg-base-100 px-3 py-2.5 text-left shadow-xs transition duration-150 hover:-translate-y-px hover:border-primary/40 hover:shadow-md active:translate-y-0"
    >
      <div
        :if={@show_date}
        class="flex w-11 shrink-0 flex-col items-center rounded-xl bg-base-200/70 py-1 leading-none"
      >
        <span class="text-[10px] font-semibold uppercase text-base-content/65">
          {Format.weekday_short(Date.day_of_week(@occurrence.date))}
        </span>
        <span class="text-lg font-bold tabular-nums">{@occurrence.date.day}</span>
      </div>
      <span class={["h-9 w-1 shrink-0 rounded-full", dot_class(@occurrence, @group)]} />
      <div class="min-w-0 flex-1">
        <p class="flex min-w-0 items-center gap-1.5 text-sm font-semibold">
          <span class="truncate">{@event.title}</span>
          <.icon
            :if={@event.is_public}
            name="hero-globe-alt"
            class="size-3.5 shrink-0 text-base-content/65"
          />
        </p>
        <p class="truncate text-xs text-base-content/65">
          <span class="tabular-nums">{time_range(@occurrence, @time_zone)}</span>
          <span :if={@event.location != ""}>{" · " <> @event.location}</span>
          <span :if={@event.group_id != @group.id}>{" · " <> @event.group.name}</span>
        </p>
      </div>
      <.icon
        :if={Event.recurring?(@event)}
        name="hero-arrow-path"
        class="size-4 shrink-0 text-base-content/40"
      />
      <.icon
        name="hero-chevron-right"
        class="size-4 shrink-0 text-base-content/30 transition-transform group-hover:translate-x-0.5"
      />
    </button>
    """
  end

  attr :event, Event, required: true
  attr :occurrence, :any, required: true
  attr :occurrence_cancelled, :boolean, default: false
  attr :summary, :any, default: nil
  attr :can_manage, :boolean, default: false
  attr :member, :boolean, default: false
  attr :my_reminders, :any, default: nil
  attr :group, :map, required: true
  attr :current_profile, :map, required: true
  attr :time_zone, :string, required: true
  attr :today, Date, required: true

  defp event_detail(assigns) do
    event = assigns.event
    occurrence = assigns.occurrence

    assigns =
      assigns
      |> assign(:cancelled?, Event.cancelled?(event) or assigns.occurrence_cancelled)
      |> assign(
        :can_respond?,
        not Event.cancelled?(event) and not assigns.occurrence_cancelled and occurrence != nil and
          DateTime.compare(occurrence.ends_at, DateTime.utc_now()) == :gt
      )

    ~H"""
    <div
      id="calendar-event-detail"
      class="rounded-3xl border border-base-300/70 bg-base-100 p-4 shadow-sm"
    >
      <div class="flex items-start gap-2">
        <.icon_button
          id="calendar-close"
          type="button"
          phx-click="calendar_close"
          icon="hero-arrow-left"
          label={gettext("Back to the calendar")}
          class="-ml-1"
        />
        <div class="min-w-0 flex-1 pt-0.5">
          <p
            :if={@event.group_id != @group.id}
            class="truncate text-xs font-semibold text-base-content/65"
          >
            {@event.group.name}
          </p>
          <h3
            id="calendar-event-title"
            class={[
              "text-lg font-semibold leading-snug wrap-break-word",
              @cancelled? && "line-through decoration-2 opacity-60"
            ]}
          >
            {@event.title}
          </h3>
        </div>
        <TagComponents.tag_button
          :if={!@cancelled?}
          id={"event-tags-#{@event.id}"}
          kind={:event}
          item_id={@event.id}
          class="shrink-0 p-1.5"
        />
      </div>

      <p
        :if={@event.is_public}
        id="calendar-event-public"
        class="mt-2 ml-9 inline-flex items-center gap-1.5 rounded-full bg-sky-500/10 px-2.5 py-1 text-xs font-semibold text-sky-800 dark:text-sky-200"
      >
        <.icon name="hero-globe-alt" class="size-3.5" />
        {gettext("Public event")}
      </p>

      <TagComponents.tag_chips
        id={"event-tag-list-#{@event.id}"}
        tags={@event.tags}
        class="mt-2 pl-9"
      />

      <p
        :if={@cancelled?}
        id="calendar-event-cancelled"
        class="mt-3 flex items-center gap-2 rounded-2xl bg-rose-500/10 px-3 py-2 text-sm font-medium text-rose-700 dark:text-rose-300"
      >
        <.icon name="hero-no-symbol" class="size-4 shrink-0" />
        {if Event.cancelled?(@event),
          do: gettext("This event was cancelled."),
          else: gettext("This occurrence was cancelled.")}
      </p>

      <dl class="mt-4 space-y-2.5 text-sm">
        <div class="flex gap-3">
          <dt class="pt-0.5 text-base-content/65">
            <.icon name="hero-clock" class="size-4" /><span class="sr-only">{gettext("When")}</span>
          </dt>
          <dd id="calendar-event-when" class="first-letter:uppercase">
            {Format.occurrence(@occurrence, @time_zone, @today)}
          </dd>
        </div>
        <div :if={Format.recurrence(@event)} class="flex gap-3">
          <dt class="pt-0.5 text-base-content/65">
            <.icon name="hero-arrow-path" class="size-4" />
            <span class="sr-only">
              {gettext("Repeats")}
            </span>
          </dt>
          <dd id="calendar-event-recurrence">{Format.recurrence(@event)}</dd>
        </div>
        <div :if={!@event.all_day and @event.time_zone != @time_zone} class="flex gap-3">
          <dt class="pt-0.5 text-base-content/65">
            <.icon name="hero-globe-europe-africa" class="size-4" />
            <span class="sr-only">{gettext("Time zone")}</span>
          </dt>
          <dd class="text-base-content/70">
            {gettext("Shown in your time zone; the event is in %{zone}.", zone: @event.time_zone)}
          </dd>
        </div>
        <div :if={@event.location != ""} class="flex gap-3">
          <dt class="pt-0.5 text-base-content/65">
            <.icon name="hero-map-pin" class="size-4" />
            <span class="sr-only">
              {gettext("Location")}
            </span>
          </dt>
          <dd id="calendar-event-location" class="wrap-break-word">{@event.location}</dd>
        </div>
        <div :if={@event.creator} class="flex items-center gap-3">
          <dt class="text-base-content/65">
            <.icon name="hero-user" class="size-4" />
            <span class="sr-only">
              {gettext("Organizer")}
            </span>
          </dt>
          <dd>
            <Components.profile_identity
              profile={@event.creator}
              avatar_size="size-6"
              text_class="text-sm"
              current_profile={@current_profile}
            />
          </dd>
        </div>
      </dl>

      <div
        :if={@event.description != ""}
        id="calendar-event-description"
        class="mt-4 rounded-2xl bg-base-200/50 px-3 py-2 text-sm"
      >
        <Components.formatted_content content={@event.description} content_format={:markdown} />
      </div>

      <div :if={@summary} class="mt-5">
        <h4 class="mb-2 text-xs font-semibold uppercase tracking-wide text-base-content/65">
          {gettext("Are you coming?")}
        </h4>
        <div id="calendar-rsvp" class="grid grid-cols-3 gap-2">
          <button
            :for={status <- [:going, :maybe, :declined]}
            id={"calendar-rsvp-#{status}"}
            type="button"
            phx-click="calendar_respond"
            phx-value-status={status}
            disabled={!@can_respond?}
            aria-pressed={to_string(@summary.mine == status)}
            class={[
              "flex flex-col items-center gap-0.5 rounded-2xl border px-2 py-2 text-xs font-semibold transition duration-150 active:scale-95 disabled:cursor-not-allowed disabled:opacity-50 phx-click-loading:opacity-70",
              rsvp_class(status, @summary.mine == status)
            ]}
          >
            <.icon name={rsvp_icon(status)} class="size-5" />
            <span>{rsvp_label(status)}</span>
            <span id={"calendar-rsvp-#{status}-count"} class="tabular-nums opacity-85">
              {@summary.counts[status]}
            </span>
          </button>
        </div>
        <div
          :for={status <- [:going, :maybe]}
          :if={@summary.profiles[status] != []}
          id={"calendar-rsvp-#{status}-profiles"}
          class="mt-3 flex items-center gap-2"
        >
          <span class="w-16 shrink-0 text-xs text-base-content/65">{rsvp_group_label(status)}</span>
          <div class="flex flex-wrap items-center gap-1">
            <span
              :for={profile <- @summary.profiles[status]}
              title={profile.username}
              class="inline-flex"
            >
              <Components.profile_identity
                profile={profile}
                avatar_size="size-6"
                text_class="hidden"
                sharing_badge_text_class="hidden"
              />
            </span>
            <span
              :if={@summary.counts[status] > length(@summary.profiles[status])}
              class="text-xs font-semibold text-base-content/65"
            >
              +{@summary.counts[status] - length(@summary.profiles[status])}
            </span>
          </div>
        </div>
      </div>

      <.my_reminders
        :if={!Event.cancelled?(@event)}
        event={@event}
        my_reminders={@my_reminders}
        member={@member}
      />

      <div class="mt-5 flex flex-wrap items-center gap-2 border-t border-base-300/60 pt-4">
        <.button
          :if={@event.is_public and !Event.cancelled?(@event)}
          id="calendar-share"
          type="button"
          data-share-link={url(~p"/groups/#{@event.group_id}/calendar?#{[event: @event.id]}")}
          size="sm"
        >
          <.icon name="hero-share" class="size-4" />
          {gettext("Share")}
        </.button>
        <.button
          :if={!Event.cancelled?(@event)}
          id="calendar-ics"
          href={~p"/events/#{@event.id}/event.ics"}
          download
          size="sm"
        >
          <.icon name="hero-arrow-down-tray" class="size-4" />
          {gettext("Add to my calendar")}
        </.button>
        <.button
          :if={@event.group_id != @group.id and (@member or @event.group.is_public)}
          id="calendar-open-group"
          navigate={
            ~p"/groups/#{@event.group_id}/calendar?#{[event: @event.id, on: Date.to_iso8601(@occurrence.date)]}"
          }
          size="sm"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-4" />
          {gettext("Open in %{group}", group: @event.group.name)}
        </.button>
        <%= if @can_manage and !Event.cancelled?(@event) do %>
          <.button
            id="calendar-edit-event"
            type="button"
            phx-click="calendar_edit"
            size="sm"
          >
            <.icon name="hero-pencil-square" class="size-4" />
            {gettext("Edit")}
          </.button>
          <.button
            :if={Event.recurring?(@event) and @can_respond?}
            id="calendar-cancel-occurrence"
            type="button"
            phx-click="calendar_cancel_occurrence"
            data-confirm={gettext("Cancel only this occurrence? Members will be told.")}
            variant="danger"
            size="sm"
          >
            <.icon name="hero-calendar" class="size-4" />
            {gettext("Cancel this occurrence")}
          </.button>
          <.button
            id="calendar-cancel-event"
            type="button"
            phx-click="calendar_cancel_event"
            data-confirm={
              if(Event.recurring?(@event),
                do: gettext("Cancel every occurrence of this event? Members will be told."),
                else: gettext("Cancel this event? Members will be told.")
              )
            }
            variant="danger"
            size="sm"
          >
            <.icon name="hero-no-symbol" class="size-4" />
            {if Event.recurring?(@event),
              do: gettext("Cancel all occurrences"),
              else: gettext("Cancel event")}
          </.button>
        <% end %>
      </div>
    </div>
    """
  end

  attr :event, Event, required: true
  attr :my_reminders, :any, default: nil
  attr :member, :boolean, default: true

  defp my_reminders(assigns) do
    assigns =
      assigns
      |> assign(:own?, assigns.my_reminders != nil)
      |> assign(:chosen, assigns.my_reminders || assigns.event.reminder_minutes)

    ~H"""
    <.form
      for={to_form(%{}, as: :reminders)}
      id="calendar-my-reminders-form"
      phx-submit="calendar_save_reminders"
      class="mt-5"
    >
      <h4 class="mb-1 text-xs font-semibold uppercase tracking-wide text-base-content/65">
        {gettext("My reminders")}
      </h4>
      <p id="calendar-my-reminders-source" class="mb-2 text-xs text-base-content/65">
        {if @own?,
          do: gettext("You chose your own reminders for this event."),
          else: gettext("You get the organizer's reminders.")}
        <span :if={!@member} id="calendar-my-reminders-public">
          {gettext("They come for the occurrences you answered Going or Maybe.")}
        </span>
      </p>
      <input type="hidden" name="reminders[reminder_minutes][]" value="" />
      <div class="flex flex-wrap gap-1.5">
        <label :for={minutes <- Event.reminder_choices(@event)} class="cursor-pointer">
          <input
            type="checkbox"
            name="reminders[reminder_minutes][]"
            value={minutes}
            checked={minutes in @chosen}
            class="peer sr-only"
          />
          <span class="inline-flex items-center rounded-full border border-base-300 px-2.5 py-1 text-xs font-medium text-base-content/70 transition peer-checked:border-primary/50 peer-checked:bg-primary/10 peer-checked:text-base-content peer-focus-visible:ring-2 peer-focus-visible:ring-primary/40 hover:border-base-content/30">
            {Format.reminder(minutes, @event.all_day)}
          </span>
        </label>
      </div>
      <div class="mt-2 flex flex-wrap items-center gap-2">
        <.button id="calendar-save-reminders" type="submit" variant="primary" size="sm">
          {gettext("Save reminders")}
        </.button>
        <.button
          :if={@own?}
          id="calendar-default-reminders"
          type="button"
          phx-click="calendar_default_reminders"
          variant="ghost"
          size="sm"
        >
          {gettext("Use the organizer's")}
        </.button>
      </div>
    </.form>
    """
  end

  attr :form, :any, required: true
  attr :values, :map, required: true
  attr :time_zone, :string, required: true
  attr :announce, :boolean, default: true
  attr :notify, :boolean, default: true
  attr :can_announce, :boolean, default: false
  attr :can_publish, :boolean, default: false

  defp event_form(assigns) do
    ~H"""
    <div
      id="calendar-event-form-card"
      class="rounded-3xl border border-base-300/70 bg-base-100 p-4 shadow-sm"
    >
      <div class="mb-3 flex items-center gap-2">
        <.icon_button
          id="calendar-close-form"
          type="button"
          phx-click="calendar_close_form"
          icon="hero-x-mark"
          label={gettext("Close")}
          class="-ml-1"
        />
        <h3 class="text-lg font-semibold">
          {if @values.new?, do: gettext("New event"), else: gettext("Edit event")}
        </h3>
      </div>

      <.form
        for={@form}
        id="calendar-event-form"
        phx-change="calendar_validate"
        phx-submit="calendar_save"
        class="space-y-1"
      >
        <.input
          field={@form[:title]}
          type="text"
          label={gettext("Title")}
          maxlength="200"
          phx-debounce="300"
          autocomplete="off"
        />
        <.input field={@form[:all_day]} type="checkbox" label={gettext("All day")} />

        <div class="grid grid-cols-2 gap-x-2">
          <.input field={@form[:start_date]} type="date" label={gettext("Starts")} />
          <.input
            :if={!@values.all_day?}
            field={@form[:start_time]}
            type="time"
            label={gettext("At")}
            value={time_value(@form[:start_time].value)}
          />
          <.input field={@form[:end_date]} type="date" label={gettext("Ends")} />
          <.input
            :if={!@values.all_day?}
            field={@form[:end_time]}
            type="time"
            label={gettext("At")}
            value={time_value(@form[:end_time].value)}
          />
        </div>
        <p
          :if={!@values.new? and !@values.all_day? and @values.time_zone != @time_zone}
          id="calendar-form-zone"
          class="mb-2 flex items-center gap-1.5 text-xs text-base-content/65"
        >
          <.icon name="hero-globe-europe-africa" class="size-4" />
          {gettext("Times are in %{zone}, the event's time zone.", zone: @values.time_zone)}
        </p>

        <.input
          field={@form[:recurrence]}
          type="select"
          label={gettext("Repeats")}
          options={recurrence_options()}
        />

        <div
          :if={@values.recurrence != :none}
          id="calendar-form-recurrence"
          class="mb-2 space-y-2 rounded-2xl border border-base-300/70 bg-base-200/40 p-3"
        >
          <.input
            field={@form[:recurrence_interval]}
            type="number"
            min="1"
            max="99"
            label={interval_label(@values.recurrence)}
          />

          <div :if={@values.recurrence == :weekly} id="calendar-form-weekdays">
            <p class="label mb-1 text-sm">{gettext("Repeats on")}</p>
            <input type="hidden" name={@form[:recurrence_weekdays].name <> "[]"} value="" />
            <div class="flex flex-wrap gap-1">
              <label :for={weekday <- 1..7} class="cursor-pointer">
                <input
                  type="checkbox"
                  id={"calendar-form-weekday-#{weekday}"}
                  name={@form[:recurrence_weekdays].name <> "[]"}
                  value={weekday}
                  checked={weekday in @values.weekdays or weekday == @values.start_weekday}
                  disabled={weekday == @values.start_weekday}
                  class="peer sr-only"
                />
                <span class="inline-flex size-9 items-center justify-center rounded-full border border-base-300 text-xs font-semibold text-base-content/70 transition peer-checked:border-primary peer-checked:bg-primary peer-checked:text-primary-content peer-disabled:cursor-default peer-focus-visible:ring-2 peer-focus-visible:ring-primary/40 hover:border-base-content/30">
                  {Format.weekday_short(weekday)}
                </span>
              </label>
            </div>
          </div>

          <fieldset :if={@values.recurrence == :monthly} id="calendar-form-monthly">
            <legend class="label mb-1 text-sm">{gettext("Repeats on")}</legend>
            <div class="flex flex-col gap-1.5">
              <label
                :for={mode <- @values.monthly_modes}
                class="inline-flex cursor-pointer items-center gap-2 text-sm"
              >
                <input
                  type="radio"
                  id={"calendar-form-monthly-#{mode}"}
                  name={@form[:recurrence_monthly].name}
                  value={mode}
                  checked={mode == @values.monthly}
                  class="radio radio-sm"
                />
                {Format.monthly_day(mode, @values.start_date)}
              </label>
            </div>
          </fieldset>

          <.input
            field={@form[:recurrence_until]}
            type="date"
            label={gettext("Until (optional)")}
          />
        </div>

        <.input
          field={@form[:location]}
          type="text"
          label={gettext("Location")}
          maxlength="300"
          phx-debounce="300"
        />
        <.input
          field={@form[:description]}
          type="textarea"
          label={gettext("Description")}
          rows="3"
          phx-debounce="300"
        />

        <div
          :if={@can_publish}
          id="calendar-form-public"
          class="mb-2 rounded-2xl border border-base-300/70 bg-base-200/40 px-3 pt-2 pb-1"
        >
          <.input field={@form[:is_public]} type="checkbox" label={gettext("Public event")} />
          <p class="-mt-1 mb-1 text-xs text-base-content/65">
            {gettext("Every user sees it in their calendar and can answer it.")}
            {gettext(
              "Its title, time, place and description also show outside Potok, to anyone with the link."
            )}
          </p>
        </div>

        <div id="calendar-form-reminders" class="pt-1">
          <p class="label mb-1 text-sm">{gettext("Reminders for members")}</p>
          <input type="hidden" name={@form[:reminder_minutes].name <> "[]"} value="" />
          <div class="flex flex-wrap gap-1.5">
            <label :for={minutes <- @values.reminder_choices} class="cursor-pointer">
              <input
                type="checkbox"
                id={"calendar-form-reminder-#{minutes}"}
                name={@form[:reminder_minutes].name <> "[]"}
                value={minutes}
                checked={minutes in @values.reminders}
                class="peer sr-only"
              />
              <span class="inline-flex items-center rounded-full border border-base-300 px-2.5 py-1 text-xs font-medium text-base-content/70 transition peer-checked:border-primary/50 peer-checked:bg-primary/10 peer-checked:text-base-content peer-focus-visible:ring-2 peer-focus-visible:ring-primary/40 hover:border-base-content/30">
                {Format.reminder(minutes, @values.all_day?)}
              </span>
            </label>
          </div>
          <p class="mt-1 text-xs text-base-content/65">
            {gettext("Members can choose their own reminders.")}
          </p>
        </div>

        <div class="pt-2">
          <label :if={@values.new? and @can_announce} class="inline-flex items-center gap-2 text-sm">
            <input type="hidden" name="announce" value="false" />
            <input
              type="checkbox"
              id="calendar-form-announce"
              name="announce"
              value="true"
              checked={@announce}
              class="checkbox checkbox-sm"
            />
            {gettext("Announce in the chat")}
          </label>
          <label :if={!@values.new?} class="inline-flex items-center gap-2 text-sm">
            <input type="hidden" name="notify" value="false" />
            <input
              type="checkbox"
              id="calendar-form-notify"
              name="notify"
              value="true"
              checked={@notify}
              class="checkbox checkbox-sm"
            />
            {gettext("Tell members if the time or place changes")}
          </label>
        </div>

        <div class="flex items-center justify-end gap-2 pt-3">
          <.button
            id="calendar-cancel-form"
            type="button"
            phx-click="calendar_close_form"
            variant="ghost"
          >
            {gettext("Cancel")}
          </.button>
          <.button
            id="calendar-save-event"
            type="submit"
            phx-disable-with={gettext("Saving…")}
            variant="primary"
          >
            {gettext("Save")}
          </.button>
        </div>
      </.form>
    </div>
    """
  end

  defp scope_text(%{group: %{is_root: true}, show_groups: true, show_public: true}),
    do: gettext("Events of your groups and public events.")

  defp scope_text(%{group: %{is_root: true}, show_groups: true}),
    do: gettext("Events of every group you are a member of.")

  defp scope_text(%{group: %{is_root: true}, show_public: true}),
    do: gettext("Public events of every group.")

  defp scope_text(%{group: %{is_root: true}}), do: gettext("No events are shown.")

  # Those who are no members of a public group see its public events.
  defp scope_text(%{access: %{member?: false}}), do: gettext("Public events of this group.")

  defp scope_text(%{include_subgroups: true}),
    do: gettext("Events of this group and of its sub-groups you are in.")

  defp scope_text(_assigns), do: gettext("Events of this group.")

  defp time_range(%Occurrence{event: %Event{all_day: true}}, _zone), do: gettext("All day")

  defp time_range(%Occurrence{starts_at: same, ends_at: same}, zone), do: Format.time(same, zone)

  defp time_range(%Occurrence{} = occurrence, zone),
    do: "#{Format.time(occurrence.starts_at, zone)}–#{Format.time(occurrence.ends_at, zone)}"

  # Month names are lowercase in some languages; a title starts with a capital.
  defp upcase_first(text) do
    {first, rest} = String.split_at(text, 1)
    String.upcase(first) <> rest
  end

  defp time_value(%Time{} = time), do: Calendar.strftime(time, "%H:%M")
  defp time_value(value), do: value

  defp recurrence_options do
    [
      {gettext("Does not repeat"), :none},
      {gettext("Daily"), :daily},
      {gettext("Weekly"), :weekly},
      {gettext("Monthly"), :monthly},
      {gettext("Yearly"), :yearly}
    ]
  end

  defp interval_label(:daily), do: gettext("Every how many days")
  defp interval_label(:weekly), do: gettext("Every how many weeks")
  defp interval_label(:monthly), do: gettext("Every how many months")
  defp interval_label(:yearly), do: gettext("Every how many years")

  defp rsvp_label(:going), do: gettext("Going")
  defp rsvp_label(:maybe), do: gettext("Maybe")
  defp rsvp_label(:declined), do: gettext("Not going")

  defp rsvp_group_label(:going), do: gettext("Going:")
  defp rsvp_group_label(:maybe), do: gettext("Maybe:")

  defp rsvp_icon(:going), do: "hero-check-circle"
  defp rsvp_icon(:maybe), do: "hero-question-mark-circle"
  defp rsvp_icon(:declined), do: "hero-x-circle"

  defp rsvp_class(:going, true),
    do: "border-emerald-500/60 bg-emerald-500/15 text-emerald-800 dark:text-emerald-200"

  defp rsvp_class(:maybe, true),
    do: "border-amber-500/60 bg-amber-500/15 text-amber-900 dark:text-amber-200"

  defp rsvp_class(:declined, true),
    do: "border-rose-500/60 bg-rose-500/15 text-rose-800 dark:text-rose-200"

  defp rsvp_class(_status, false),
    do: "border-base-300 text-base-content/70 hover:border-base-content/30 hover:bg-base-200/60"

  defp nav_button_class,
    do:
      "inline-flex size-7 items-center justify-center rounded-full text-base-content/70 transition hover:bg-base-100 hover:text-base-content"

  defp chip_class(%Occurrence{event: %Event{group_id: id}}, %{id: id}),
    do: "bg-primary/15 text-base-content"

  defp chip_class(%Occurrence{event: %Event{group_id: id}}, _group),
    do: @palette |> Enum.at(rem(id, length(@palette))) |> elem(0)

  defp dot_class(%Occurrence{event: %Event{group_id: id}}, %{id: id}), do: "bg-primary"

  defp dot_class(%Occurrence{event: %Event{group_id: id}}, _group),
    do: @palette |> Enum.at(rem(id, length(@palette))) |> elem(1)
end
