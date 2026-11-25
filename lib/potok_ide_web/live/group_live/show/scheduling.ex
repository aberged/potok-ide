defmodule PotokIdeWeb.GroupLive.Show.Scheduling do
  @moduledoc """
  Messages that go out later (`PotokIde.Social.ScheduledValues`), on the page
  of a group: the dialog that asks for the time, the time the composer holds
  until its message is sent, and the list of what waits. The host LiveView
  calls `init/1` in mount, `maybe_load/3` with the chat, delegates every
  `"schedule_*"` event to `handle_event/3`, and posts what the composer holds
  at `@schedule_at` (`post/4`).

  The time is picked before the message goes out, not together with it: files
  upload only when the composer's own form is sent, so the dialog hands the
  time over and then has that form send itself. With nothing written yet the
  composer only holds the time. Like the message replied to, it lives on the
  server and never comes from the form.
  """

  use PotokIdeWeb, :html

  import Phoenix.LiveView, only: [connected?: 1, push_event: 3, put_flash: 3, put_private: 3]

  alias PotokIde.Events.{Format, Recurrence}
  alias PotokIde.Social.{Profile, ScheduledValue, ScheduledValues, Value}
  alias PotokIdeWeb.GroupLive.Show.Components

  # How many messages that went out by themselves the page remembers, to not
  # take them for ones written on it.
  @remembered 20

  def init(socket) do
    assign(socket,
      schedule_at: nil,
      schedule_form: nil,
      scheduled_values: [],
      scheduled_list: nil
    )
  end

  @doc "Loads what the viewer has waiting in the group, with its chat."
  def maybe_load(socket, group, active_tab) do
    if connected?(socket) and active_tab == "values" and shown?(socket, group),
      do: put_list(socket, ScheduledValues.list(socket.assigns.current_profile, group)),
      else: put_list(socket, [])
  end

  # A preview of what others see shows nothing of the one who looks.
  defp shown?(%{assigns: assigns}, group) do
    not is_nil(assigns.current_profile) and is_nil(assigns[:access_preview]) and
      not group.is_root and assigns.access.member?
  end

  # A message being edited may have gone out, or been deleted elsewhere.
  defp put_list(socket, scheduled) do
    list =
      case socket.assigns.scheduled_list do
        %{editing: id} = list when is_integer(id) ->
          if Enum.any?(scheduled, &(&1.id == id)), do: list, else: closed_edit(list)

        list ->
          list
      end

    list = if scheduled == [], do: nil, else: list

    assign(socket, scheduled_values: scheduled, scheduled_list: list)
  end

  @doc "What the viewer scheduled in the group changed, here or elsewhere."
  def changed(socket, sent_value_id) do
    %{group: group, active_tab: active_tab} = socket.assigns

    socket
    |> remember(sent_value_id)
    |> maybe_load(group, active_tab)
  end

  defp remember(socket, nil), do: socket

  defp remember(socket, value_id) do
    sent = Enum.take([value_id | sent_by_itself(socket)], @remembered)
    put_private(socket, :sent_by_itself, sent)
  end

  @doc "Whether `value` went out by itself, at the time the viewer picked for it."
  def sent_by_itself?(socket, %Value{id: id}), do: id in sent_by_itself(socket)

  defp sent_by_itself(socket), do: socket.private[:sent_by_itself] || []

  ## What the composer holds

  @doc """
  Whether the composer may go on: `:ok` unless it holds a time that has passed
  meanwhile. Asked before its files are taken from the upload.
  """
  def still_ahead(%{assigns: %{schedule_at: nil}}), do: :ok

  def still_ahead(%{assigns: %{schedule_at: send_at}}) do
    case ScheduledValue.check_time(send_at) do
      :ok -> :ok
      reason -> {:error, reason}
    end
  end

  @doc "Schedules a message for the time the composer holds."
  def post(%{assigns: %{schedule_at: %DateTime{} = send_at} = assigns}, attrs, files),
    do: ScheduledValues.schedule(assigns.current_profile, assigns.group, attrs, files, send_at)

  @doc "The page once its message was scheduled; the list comes with the broadcast."
  def posted(socket, %ScheduledValue{send_at: send_at}) do
    socket
    |> assign(schedule_at: nil)
    |> put_flash(
      :info,
      gettext("The message goes out %{when}.",
        when: when_text(send_at, socket.assigns.calendar_time_zone)
      )
    )
  end

  @doc "What a refused time or count says, or nil for any other reason."
  def error_text(:past), do: gettext("The time you picked has passed. Pick another one.")
  def error_text(:too_far), do: gettext("A message can be scheduled up to a year ahead.")

  def error_text(:too_many_scheduled) do
    gettext("You have %{count} scheduled messages, which is the most. Send or delete one first.",
      count: ScheduledValues.max_waiting()
    )
  end

  def error_text(_reason), do: nil

  ## Events

  def handle_event("schedule_open", _params, socket) do
    if can_schedule?(socket) and is_nil(socket.assigns.editing_value),
      do: {:noreply, put_time_form(socket, opening_params(socket), nil)},
      else: {:noreply, socket}
  end

  def handle_event("schedule_close", _params, socket),
    do: {:noreply, assign(socket, :schedule_form, nil)}

  # The composer lets go of the time it holds.
  def handle_event("schedule_cancel", _params, socket),
    do: {:noreply, assign(socket, :schedule_at, nil)}

  def handle_event("schedule_list_open", _params, socket) do
    if socket.assigns.scheduled_values == [],
      do: {:noreply, socket},
      else: {:noreply, assign(socket, :scheduled_list, closed_edit(%{}))}
  end

  def handle_event("schedule_list_close", _params, socket),
    do: {:noreply, assign(socket, :scheduled_list, nil)}

  def handle_event("schedule_" <> event, params, socket) do
    cond do
      socket.assigns.schedule_form -> handle_time(event, params, socket)
      socket.assigns.scheduled_list -> handle_list(event, params, socket)
      true -> {:noreply, socket}
    end
  end

  defp handle_time("preset", %{"at" => at}, socket) when is_binary(at),
    do: {:noreply, put_time_form(socket, %{"send_local" => at}, nil)}

  defp handle_time("validate", %{"schedule" => %{} = params}, socket),
    do: {:noreply, put_time_form(socket, params, :validate)}

  defp handle_time("save", %{"schedule" => %{} = params}, socket) do
    changeset = time_changeset(socket, params)

    if changeset.valid? do
      {:noreply,
       socket
       |> assign(:schedule_at, Ecto.Changeset.get_field(changeset, :send_at))
       |> assign(:schedule_form, nil)
       # What is already written goes on its way at once.
       |> push_event("value_composer_submit", %{})}
    else
      {:noreply, put_time_form(socket, params, :validate)}
    end
  end

  defp handle_time(_event, _params, socket), do: {:noreply, socket}

  defp handle_list("edit", %{"id" => id}, socket) do
    case find(socket, id) do
      %ScheduledValue{} = scheduled ->
        {:noreply, put_edit(socket, scheduled, %{}, nil)}

      nil ->
        {:noreply, socket}
    end
  end

  defp handle_list("edit_cancel", _params, socket),
    do: {:noreply, update(socket, :scheduled_list, &closed_edit/1)}

  defp handle_list("edit_validate", %{"scheduled" => %{} = params}, socket) do
    with_editing(socket, &put_edit(socket, &1, params, :validate))
  end

  defp handle_list("edit_save", %{"scheduled" => %{} = params}, socket) do
    %{current_profile: profile, group: group, calendar_time_zone: zone} = socket.assigns

    with_editing(socket, fn scheduled ->
      case ScheduledValues.update(profile, group, scheduled.id, params, zone) do
        {:ok, _scheduled} -> update(socket, :scheduled_list, &closed_edit/1)
        {:error, %Ecto.Changeset{}} -> put_edit(socket, scheduled, params, :validate)
        {:error, reason} -> put_list_error(socket, reason)
      end
    end)
  end

  # The message itself reaches this page as any other does.
  defp handle_list("send_now", %{"id" => id}, socket),
    do: with_found(socket, id, &ScheduledValues.send_now/3)

  defp handle_list("delete", %{"id" => id}, socket),
    do: with_found(socket, id, &ScheduledValues.cancel/3)

  defp handle_list(_event, _params, socket), do: {:noreply, socket}

  defp with_editing(socket, fun) do
    case find(socket, socket.assigns.scheduled_list.editing) do
      %ScheduledValue{} = scheduled -> {:noreply, fun.(scheduled)}
      nil -> {:noreply, socket}
    end
  end

  # The list itself is read again on the broadcast of what `action` did.
  defp with_found(socket, id, action) do
    %{current_profile: profile, group: group} = socket.assigns

    with %ScheduledValue{} = scheduled <- find(socket, id),
         {:error, reason} <- action.(profile, group, scheduled.id) do
      {:noreply, put_list_error(socket, reason)}
    else
      _done_or_gone -> {:noreply, socket}
    end
  end

  defp find(_socket, nil), do: nil

  defp find(socket, id),
    do: Enum.find(socket.assigns.scheduled_values, &(to_string(&1.id) == to_string(id)))

  defp closed_edit(list), do: Map.merge(list, %{editing: nil, form: nil, error: nil})

  defp put_list_error(socket, reason) do
    text =
      case reason do
        :not_found ->
          gettext("That message is no longer waiting.")

        :not_permitted ->
          failure_text(:not_permitted)

        _reason ->
          gettext("The message could not be sent.")
      end

    update(socket, :scheduled_list, &(&1 |> closed_edit() |> Map.put(:error, text)))
  end

  defp put_edit(socket, %ScheduledValue{} = scheduled, params, action) do
    zone = socket.assigns.calendar_time_zone

    changeset =
      scheduled
      |> ScheduledValue.with_form_fields(zone)
      |> ScheduledValue.changeset(params, zone)
      |> Map.put(:action, action)

    update(socket, :scheduled_list, fn list ->
      Map.merge(list, %{
        editing: scheduled.id,
        form: to_form(changeset, as: :scheduled),
        error: nil
      })
    end)
  end

  defp can_schedule?(%{assigns: assigns}),
    do: ScheduledValues.can_schedule?(assigns.current_profile, assigns.access, assigns.group)

  # The time the composer already holds, or one hour from now.
  defp opening_params(%{assigns: %{schedule_at: send_at, calendar_time_zone: zone}}) do
    at = send_at || DateTime.add(DateTime.utc_now(:second), 1, :hour)
    %{"send_local" => at |> DateTime.shift_zone!(zone) |> input_value()}
  end

  defp put_time_form(socket, params, action) do
    changeset = socket |> time_changeset(params) |> Map.put(:action, action)
    assign(socket, :schedule_form, to_form(changeset, as: :schedule))
  end

  defp time_changeset(socket, params) do
    ScheduledValue.time_changeset(
      %ScheduledValue{},
      params,
      socket.assigns.calendar_time_zone
    )
  end

  ## Times

  @doc """
  When a message goes out, in the viewer's zone: "today at 18:00", "tomorrow at
  09:00" or "Thu, Nov 26 at 09:00".
  """
  def when_text(%DateTime{} = send_at, zone, now \\ DateTime.utc_now()) do
    today = Recurrence.local_date(now, zone)
    date = Recurrence.local_date(send_at, zone)
    time = Format.time(send_at, zone)

    case Date.diff(date, today) do
      0 -> gettext("today at %{time}", time: time)
      1 -> gettext("tomorrow at %{time}", time: time)
      _days -> gettext("%{date} at %{time}", date: Format.date(date, today), time: time)
    end
  end

  @doc """
  The times the dialog offers, as `{name, label, value of the input}`, from
  `now` in the viewer's zone: an hour from now, this evening while it is not
  near, tomorrow morning, and Monday morning unless that is tomorrow.
  """
  def presets(zone, now \\ DateTime.utc_now(:second)) do
    local = DateTime.shift_zone!(now, zone)
    today = DateTime.to_date(local)
    monday = Date.add(today, 8 - Date.day_of_week(today))

    [
      {"hour", gettext("In an hour"), input_value(DateTime.add(local, 1, :hour))},
      local.hour < 19 && {"evening", gettext("This evening at 20:00"), input_value(today, 20)},
      {"tomorrow", gettext("Tomorrow at 9:00"), input_value(Date.add(today, 1), 9)},
      Date.diff(monday, today) > 1 &&
        {"monday", gettext("Monday at 9:00"), input_value(monday, 9)}
    ]
    |> Enum.filter(& &1)
  end

  defp input_value(%DateTime{} = local), do: Calendar.strftime(local, "%Y-%m-%dT%H:%M")

  defp input_value(%Date{} = date, hour),
    do: Calendar.strftime(NaiveDateTime.new!(date, Time.new!(hour, 0, 0)), "%Y-%m-%dT%H:%M")

  defp failure_text(:late),
    do: gettext("Potok was not running at that time, so it was not sent.")

  defp failure_text(:not_permitted),
    do: gettext("You may no longer send this in the group.")

  defp failure_text(:error), do: gettext("Something went wrong while it was being sent.")

  ## Markup

  attr :scheduled, :list, required: true, doc: "the `@scheduled_values` assign"
  attr :time_zone, :string, required: true

  @doc "The row above the composer that opens the list; nothing while nothing waits."
  def bar(assigns) do
    {failed, waiting} = Enum.split_with(assigns.scheduled, & &1.failure)
    assigns = assign(assigns, failed: length(failed), waiting: waiting)

    ~H"""
    <button
      :if={@scheduled != []}
      id="group-scheduled-bar"
      type="button"
      phx-click="schedule_list_open"
      aria-haspopup="dialog"
      class={[
        "mb-1.5 flex w-full cursor-pointer items-center gap-2 rounded-2xl px-3 py-1.5 text-left text-xs font-medium transition-colors duration-150 cramped:hidden sm:mb-2",
        if(@failed > 0,
          do: "bg-warning/15 text-base-content hover:bg-warning/25",
          else: "bg-base-200/70 text-base-content/75 hover:bg-base-200 hover:text-base-content"
        )
      ]}
    >
      <.icon
        name={if(@failed > 0, do: "hero-exclamation-triangle", else: "hero-clock")}
        class={["size-4 shrink-0", if(@failed > 0, do: "text-warning", else: "text-primary")]}
      />
      <span class="min-w-0 flex-1 truncate">{bar_text(@failed, @waiting, @time_zone)}</span>
      <.icon name="hero-chevron-right" class="size-4 shrink-0 opacity-50" />
    </button>
    """
  end

  defp bar_text(failed, waiting, zone) do
    [
      failed > 0 && gettext("Not sent: %{count}", count: failed),
      waiting != [] && gettext("Scheduled messages: %{count}", count: length(waiting)),
      waiting != [] &&
        gettext("next %{when}", when: when_text(hd(waiting).send_at, zone))
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  attr :form, :any, default: nil, doc: "the `@schedule_form` assign"
  attr :time_zone, :string, required: true

  @doc "The dialog that asks when the message goes out."
  def time_dialog(assigns) do
    ~H"""
    <dialog
      :if={@form}
      id="schedule-dialog"
      phx-hook=".ScheduleDialog"
      data-close-event="schedule_close"
      phx-mounted={JS.ignore_attributes(["open"])}
      aria-labelledby="schedule-title"
      class="fixed inset-0 m-0 size-full max-h-none max-w-none overflow-hidden bg-transparent p-0 backdrop:bg-transparent"
    >
      <div class="flex size-full items-end justify-center sm:items-center sm:p-4">
        <div
          id="schedule-backdrop"
          class="absolute inset-0 bg-black/30 backdrop-blur-[2px] dark:bg-black/60"
          phx-click="schedule_close"
          aria-hidden="true"
        >
        </div>
        <section
          tabindex="-1"
          autofocus
          class="relative flex max-h-[85dvh] w-full flex-col overflow-hidden rounded-t-3xl border border-b-0 border-base-300/70 bg-base-100 text-base-content shadow-2xl shadow-base-content/10 outline-none sm:max-w-md sm:rounded-3xl sm:border-b"
        >
          <header class="flex items-start gap-3 border-b border-base-300/60 px-5 pt-5 pb-4">
            <span class="inline-flex size-10 shrink-0 items-center justify-center rounded-2xl bg-primary/10 text-primary">
              <.icon name="hero-clock" class="size-5" />
            </span>
            <div class="min-w-0 flex-1">
              <h2 id="schedule-title" class="text-base font-semibold leading-tight">
                {gettext("Schedule the message")}
              </h2>
              <p class="mt-0.5 text-xs text-base-content/65">
                {gettext("It goes out by itself at the time you pick.")}
              </p>
            </div>
            <.icon_button
              id="schedule-close"
              type="button"
              phx-click="schedule_close"
              icon="hero-x-mark"
              label={gettext("Close")}
              class="-mr-1"
            />
          </header>

          <div class="min-h-0 flex-1 overflow-y-auto px-5 py-4">
            <div class="mb-3 grid grid-cols-2 gap-2">
              <button
                :for={{name, label, at} <- presets(@time_zone)}
                id={"schedule-preset-#{name}"}
                type="button"
                phx-click="schedule_preset"
                phx-value-at={at}
                aria-pressed={to_string(chosen?(@form, at))}
                class={[
                  "flex min-h-10 cursor-pointer items-center justify-center rounded-2xl border px-3 py-2 text-center text-sm font-medium transition duration-150 ease-out focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40 active:scale-[0.98]",
                  if(chosen?(@form, at),
                    do: "border-primary bg-primary/10 text-primary",
                    else: "border-base-300 bg-base-100 hover:border-primary/50 hover:text-primary"
                  )
                ]}
              >
                {label}
              </button>
            </div>
            <.form
              for={@form}
              id="schedule-form"
              phx-change="schedule_validate"
              phx-submit="schedule_save"
              novalidate
            >
              <.input
                field={@form[:send_local]}
                type="datetime-local"
                label={gettext("Date and time")}
                min={earliest(@time_zone)}
              />
              <p class="-mt-1 text-xs text-base-content/65">
                {gettext("Times are in %{zone}.", zone: @time_zone)}
              </p>
            </.form>
          </div>

          <footer class="flex items-center justify-end gap-2 border-t border-base-300/60 bg-base-200/40 px-5 pt-3 pb-[calc(0.75rem+var(--app-safe-area-bottom))] sm:pb-3">
            <.button type="button" phx-click="schedule_close" variant="ghost">
              {gettext("Cancel")}
            </.button>
            <.button id="schedule-submit" type="submit" form="schedule-form" variant="primary">
              {gettext("Schedule")}
            </.button>
          </footer>
        </section>
      </div>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ScheduleDialog">
      export default {
        mounted() {
          // Escape and Android's back button close it through the server, which
          // removes it.
          this.el.addEventListener("cancel", event => {
            event.preventDefault()
            this.pushEvent(this.el.dataset.closeEvent, {})
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

  defp earliest(zone), do: DateTime.utc_now() |> DateTime.shift_zone!(zone) |> input_value()

  defp chosen?(form, at) do
    case Ecto.Changeset.get_field(form.source, :send_local) do
      %NaiveDateTime{} = local -> Calendar.strftime(local, "%Y-%m-%dT%H:%M") == at
      nil -> false
    end
  end

  attr :list, :map, default: nil, doc: "the `@scheduled_list` assign"
  attr :scheduled, :list, required: true, doc: "the `@scheduled_values` assign"
  attr :time_zone, :string, required: true

  @doc "What the viewer scheduled in the group, to change, send now or delete."
  def list_dialog(assigns) do
    ~H"""
    <dialog
      :if={@list}
      id="scheduled-dialog"
      phx-hook=".ScheduleDialog"
      data-close-event="schedule_list_close"
      phx-mounted={JS.ignore_attributes(["open"])}
      aria-labelledby="scheduled-title"
      class="fixed inset-0 m-0 size-full max-h-none max-w-none overflow-hidden bg-transparent p-0 backdrop:bg-transparent"
    >
      <%!-- `--app-visual-height` keeps the form above a phone's keyboard. --%>
      <div class="flex h-[var(--app-visual-height,100dvh)] w-full items-end justify-center sm:items-center sm:p-4">
        <div
          id="scheduled-backdrop"
          class="absolute inset-0 bg-black/30 backdrop-blur-[2px] dark:bg-black/60"
          phx-click="schedule_list_close"
          aria-hidden="true"
        >
        </div>
        <section
          tabindex="-1"
          autofocus
          class="relative flex max-h-[85%] w-full flex-col overflow-hidden rounded-t-3xl border border-b-0 border-base-300/70 bg-base-100 text-base-content shadow-2xl shadow-base-content/10 outline-none cramped:max-h-full sm:max-w-lg sm:rounded-3xl sm:border-b"
        >
          <header class="flex items-start gap-3 border-b border-base-300/60 px-5 pt-5 pb-4">
            <span class="inline-flex size-10 shrink-0 items-center justify-center rounded-2xl bg-primary/10 text-primary">
              <.icon name="hero-clock" class="size-5" />
            </span>
            <div class="min-w-0 flex-1">
              <h2 id="scheduled-title" class="text-base font-semibold leading-tight">
                {gettext("Scheduled messages")}
              </h2>
              <p class="mt-0.5 text-xs text-base-content/65">
                {gettext("Nobody else sees them until they go out.")}
                {gettext("Times are in %{zone}.", zone: @time_zone)}
              </p>
            </div>
            <.icon_button
              id="scheduled-close"
              type="button"
              phx-click="schedule_list_close"
              icon="hero-x-mark"
              label={gettext("Close")}
              class="-mr-1"
            />
          </header>

          <div class="min-h-0 flex-1 overflow-y-auto px-4 pt-3 pb-[calc(1rem+var(--app-safe-area-bottom))]">
            <p
              :if={@list.error}
              id="scheduled-error"
              role="alert"
              class="mb-3 flex items-start gap-1.5 px-1 text-sm text-error"
            >
              <.icon name="hero-exclamation-circle" class="mt-0.5 size-4 shrink-0" />
              {@list.error}
            </p>
            <ul class="space-y-2">
              <li
                :for={scheduled <- @scheduled}
                id={"scheduled-#{scheduled.id}"}
                class={[
                  "rounded-2xl border px-3.5 py-3",
                  if(scheduled.failure,
                    do: "border-warning/50 bg-warning/5",
                    else: "border-base-300/70 bg-base-100"
                  )
                ]}
              >
                <p class="flex items-center gap-1.5 text-xs font-semibold text-base-content/75">
                  <.icon
                    name={if(scheduled.failure, do: "hero-exclamation-triangle", else: "hero-clock")}
                    class={[
                      "size-4 shrink-0",
                      if(scheduled.failure, do: "text-warning", else: "text-primary")
                    ]}
                  />
                  {when_text(scheduled.send_at, @time_zone)}
                </p>
                <p
                  :if={scheduled.failure}
                  id={"scheduled-failure-#{scheduled.id}"}
                  class="mt-1 text-xs text-base-content/75"
                >
                  {failure_text(scheduled.failure)}
                </p>
                <%= if @list.editing == scheduled.id do %>
                  <.edit_form form={@list.form} time_zone={@time_zone} />
                <% else %>
                  <.content scheduled={scheduled} />
                  <div class="mt-2 flex flex-wrap items-center justify-end gap-1">
                    <.button
                      id={"scheduled-delete-#{scheduled.id}"}
                      type="button"
                      variant="ghost"
                      size="sm"
                      phx-click="schedule_delete"
                      phx-value-id={scheduled.id}
                      data-confirm={gettext("Delete this scheduled message?")}
                    >
                      <.icon name="hero-trash" class="size-4" />
                      {gettext("Delete")}
                    </.button>
                    <.button
                      id={"scheduled-edit-#{scheduled.id}"}
                      type="button"
                      variant="ghost"
                      size="sm"
                      phx-click="schedule_edit"
                      phx-value-id={scheduled.id}
                    >
                      <.icon name="hero-pencil-square" class="size-4" />
                      {gettext("Edit")}
                    </.button>
                    <.button
                      id={"scheduled-send-#{scheduled.id}"}
                      type="button"
                      size="sm"
                      phx-click="schedule_send_now"
                      phx-value-id={scheduled.id}
                    >
                      <.icon name="hero-paper-airplane" class="size-4" />
                      {gettext("Send now")}
                    </.button>
                  </div>
                <% end %>
              </li>
            </ul>
          </div>
        </section>
      </div>
    </dialog>
    """
  end

  attr :scheduled, ScheduledValue, required: true

  # The text as it was written: the chat draws its markdown once it is sent.
  defp content(assigns) do
    ~H"""
    <p
      :if={@scheduled.parent}
      class="mt-1.5 truncate border-l-2 border-primary/50 pl-2 text-xs text-base-content/65"
    >
      {Profile.display_name(@scheduled.parent.creator)}: {Value.excerpt(@scheduled.parent, 120)}
    </p>
    <p
      :if={@scheduled.content != ""}
      class="mt-1.5 line-clamp-6 text-sm whitespace-pre-line wrap-break-word"
      phx-no-format
    >{@scheduled.content}</p>
    <ul :if={@scheduled.files != []} class="mt-1.5 space-y-1">
      <li
        :for={file <- ScheduledValue.attachments(@scheduled)}
        class="flex items-center gap-2 text-xs text-base-content/75"
      >
        <.icon name={Components.file_icon(file.content_type)} class="size-4 shrink-0 opacity-60" />
        <span class="min-w-0 truncate">{file.filename}</span>
        <span class="shrink-0 tabular-nums text-base-content/55">
          {Components.format_bytes(file.byte_size)}
        </span>
      </li>
    </ul>
    """
  end

  attr :form, :any, required: true
  attr :time_zone, :string, required: true

  # The files stay as they are, as in a sent message's edit.
  defp edit_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="scheduled-edit-form"
      phx-change="schedule_edit_validate"
      phx-submit="schedule_edit_save"
      class="mt-2"
      novalidate
    >
      <.input
        field={@form[:content]}
        type="textarea"
        rows="3"
        phx-debounce="300"
        aria-label={gettext("Message")}
      />
      <.input
        field={@form[:send_local]}
        type="datetime-local"
        aria-label={gettext("Date and time")}
        min={earliest(@time_zone)}
      />
      <div class="flex items-center justify-end gap-2">
        <.button
          id="scheduled-edit-cancel"
          type="button"
          variant="ghost"
          size="sm"
          phx-click="schedule_edit_cancel"
        >
          {gettext("Cancel")}
        </.button>
        <.button
          id="scheduled-edit-submit"
          type="submit"
          variant="primary"
          size="sm"
          phx-disable-with={gettext("Saving...")}
        >
          {gettext("Save")}
        </.button>
      </div>
    </.form>
    """
  end
end
