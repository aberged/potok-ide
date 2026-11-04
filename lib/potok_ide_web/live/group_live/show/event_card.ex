defmodule PotokIdeWeb.GroupLive.Show.EventCard do
  use PotokIdeWeb, :html

  alias PotokIde.Events.{Event, Format, Recurrence}
  alias PotokIdeWeb.GroupLive.Show.Components

  attr :value_id, :integer, required: true
  attr :event, Event, required: true
  attr :mine, :boolean, default: false

  @doc """
  The card a chat value that announced an event shows in place of its text:
  the event as it is now, with a link to it in the calendar.
  """
  def card(assigns) do
    start = Recurrence.start_date(assigns.event)

    assigns =
      assigns
      |> assign(:start, start)
      |> assign(:cancelled?, Event.cancelled?(assigns.event))
      |> assign(:recurrence, Format.recurrence(assigns.event))

    ~H"""
    <.link
      id={"value-event-card-#{@value_id}"}
      patch={~p"/groups/#{@event.group_id}/calendar?#{[event: @event.id]}"}
      class={[
        "group/event flex min-w-0 items-stretch gap-3 rounded-2xl p-1 pr-3 transition duration-150 hover:-translate-y-px",
        if(@mine,
          do: "bg-primary-content/10 hover:bg-primary-content/15",
          else: "bg-base-200/70 hover:bg-base-200"
        )
      ]}
    >
      <div class={[
        "flex w-13 shrink-0 flex-col items-center justify-center rounded-xl bg-base-100 py-1.5 leading-none text-base-content shadow-xs",
        @cancelled? && "opacity-50"
      ]}>
        <span class="text-[10px] font-bold uppercase tracking-wide text-rose-600 dark:text-rose-300">
          {Format.month_short(@start.month)}
        </span>
        <span class="text-xl font-bold tabular-nums">{@start.day}</span>
      </div>
      <div class="min-w-0 flex-1 py-1">
        <p class={[
          "flex items-center gap-1.5 text-[11px] font-semibold uppercase tracking-wide",
          if(@mine, do: "text-primary-content/90", else: "text-base-content/65")
        ]}>
          <.icon
            name={if(@event.is_public, do: "hero-globe-alt", else: "hero-calendar-days")}
            class="size-3.5"
          />
          {label(@cancelled?, @event.is_public)}
        </p>
        <p class={[
          "truncate font-semibold",
          @cancelled? && "line-through decoration-2 opacity-70"
        ]}>
          {@event.title}
        </p>
        <p class={[
          "truncate text-xs",
          if(@mine, do: "text-primary-content/90", else: "text-base-content/70")
        ]}>
          <%= if @event.all_day do %>
            {gettext("All day")}
          <% else %>
            <Components.local_time
              id={"value-event-card-time-#{@value_id}"}
              datetime={@event.starts_at}
            />
          <% end %>
          <span :if={@event.location != ""}>{" · " <> @event.location}</span>
        </p>
        <p
          :if={@recurrence}
          class={[
            "mt-0.5 flex items-center gap-1 truncate text-xs",
            if(@mine, do: "text-primary-content/90", else: "text-base-content/65")
          ]}
        >
          <.icon name="hero-arrow-path" class="size-3.5 shrink-0" />
          <span class="truncate">{@recurrence}</span>
        </p>
      </div>
      <.icon
        name="hero-chevron-right"
        class="size-4 shrink-0 self-center opacity-50 transition-transform group-hover/event:translate-x-0.5"
      />
    </.link>
    """
  end

  defp label(true, _public?), do: gettext("Event cancelled")
  defp label(false, true), do: gettext("Public event")
  defp label(false, false), do: gettext("Event")
end
