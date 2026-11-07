defmodule PotokIdeWeb.GroupLive.Show.PollForm do
  @moduledoc """
  The form of a poll, one dialog per page: it opens from the chat's composer,
  from the overview, and from an app on the group's page. The host LiveView
  calls `init/1` in mount and delegates every `"poll_form_*"` event to
  `handle_event/3`.

  What everyone needs is on top. The rest waits under "More settings", as most
  polls are a question and some answers.

  Once a poll has votes only its schedule can change (`PotokIde.Polls.Poll`), so
  the form holds no more than that.
  """

  use PotokIdeWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3]

  alias PotokIde.Polls
  alias PotokIde.Polls.{Poll, Rules}
  alias PotokIde.Social.{Access, Group}
  alias PotokIdeWeb.GroupLive.Show.RolesTab

  @deadlines [1, 24, 72, 168]
  @deadline_params Enum.map(@deadlines, &Integer.to_string/1)

  def init(socket), do: assign(socket, :poll_form, nil)

  @doc "Opens the form on a new poll of the page's group, when the viewer may start one."
  def open_new(socket) do
    %{access: access, group: group} = socket.assigns

    if Rules.can_create?(access, group) do
      form_state =
        put_changeset(
          %{
            poll: %Poll{},
            params: Polls.blank_attrs(),
            announce?: Access.can?(access, :post_values),
            error: nil,
            action: nil
          },
          socket
        )

      assign(socket, :poll_form, form_state)
    else
      socket
    end
  end

  def handle_event("poll_form_open", %{"id" => id}, socket) do
    with {poll_id, ""} <- Integer.parse(to_string(id)),
         %Poll{} = poll <- Polls.get_poll(poll_id),
         true <- poll.group_id == socket.assigns.group.id,
         true <- Rules.manage?(poll, socket.assigns.access, socket.assigns.current_profile) do
      form_state =
        put_changeset(
          %{poll: poll, params: %{}, announce?: false, error: nil, action: nil},
          socket
        )

      {:noreply, assign(socket, :poll_form, form_state)}
    else
      _not_allowed -> {:noreply, socket}
    end
  end

  def handle_event("poll_form_open", _params, socket), do: {:noreply, open_new(socket)}

  def handle_event("poll_form_close", _params, socket), do: {:noreply, init(socket)}

  def handle_event(_event, _params, %{assigns: %{poll_form: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("poll_form_validate", %{"poll" => attrs} = params, socket) do
    state =
      socket.assigns.poll_form
      |> Map.merge(%{params: attrs, action: :validate, error: nil})
      |> Map.put(:announce?, announce?(params, socket.assigns.poll_form))

    {:noreply, assign(socket, :poll_form, put_changeset(state, socket))}
  end

  def handle_event("poll_form_deadline", %{"hours" => hours}, socket)
      when hours == "none" or hours in @deadline_params do
    local = deadline_in(hours, socket.assigns.calendar_time_zone)
    state = socket.assigns.poll_form
    state = %{state | params: Map.put(state.params, "closes_local", local)}

    {:noreply, assign(socket, :poll_form, put_changeset(state, socket))}
  end

  def handle_event("poll_form_answers", %{"set" => set}, socket)
      when set in ["yes_no", "for_against"] do
    state = socket.assigns.poll_form
    state = %{state | params: Map.put(state.params, "options", answers(set))}

    {:noreply, assign(socket, :poll_form, put_changeset(state, socket))}
  end

  def handle_event("poll_form_save", %{"poll" => attrs} = params, socket) do
    %{current_profile: profile, group: group, calendar_time_zone: time_zone} = socket.assigns
    state = socket.assigns.poll_form

    result =
      case state.poll do
        %Poll{id: nil} ->
          Polls.create_poll(profile, group, attrs, time_zone, announce: announce?(params, state))

        %Poll{} = poll ->
          Polls.update_poll(profile, poll, attrs, time_zone)
      end

    case result do
      {:ok, _poll} ->
        {:noreply,
         socket
         |> init()
         |> put_flash(:info, saved_message(state.poll))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket, :poll_form, %{
           state
           | params: attrs,
             form: to_form(changeset, as: :poll),
             values: values(changeset)
         })}

      {:error, reason} ->
        # Here: the dialog covers the page's flash messages.
        {:noreply, assign(socket, :poll_form, %{state | error: error_message(reason)})}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp announce?(params, state),
    do: Map.get(params, "announce", to_string(state.announce?)) == "true"

  defp saved_message(%Poll{id: nil}), do: dgettext("polls", "The poll has started.")
  defp saved_message(%Poll{}), do: dgettext("polls", "The poll is changed.")

  defp error_message(:closed), do: dgettext("polls", "This poll has ended.")
  defp error_message(:not_permitted), do: dgettext("polls", "You may not do that.")
  defp error_message(_reason), do: dgettext("polls", "Could not save the poll.")

  defp put_changeset(state, socket) do
    changeset =
      state.poll
      |> Polls.change_poll(state.params, socket.assigns.calendar_time_zone)
      |> Map.put(:action, state[:action])

    state
    |> Map.put(:form, to_form(changeset, as: :poll))
    |> Map.put(:values, values(changeset))
    |> Map.put(:can_publish?, Rules.can_publish?(socket.assigns.access, socket.assigns.group))
    |> Map.put(:can_announce?, can_announce?(socket))
    |> Map.put(:roles, roles(socket.assigns.access))
    |> Map.put(:time_zone, socket.assigns.calendar_time_zone)
    |> Map.put(:group, socket.assigns.group)
  end

  defp can_announce?(socket), do: Access.can?(socket.assigns.access, :post_values)

  defp roles(%Access{manifest: nil}), do: []
  defp roles(%Access{manifest: manifest}), do: manifest.roles

  defp values(changeset) do
    get = &Ecto.Changeset.get_field(changeset, &1)

    %{
      schedule_only?: changeset.data.voters_count > 0,
      new?: is_nil(changeset.data.id),
      kind: get.(:kind),
      secret?: get.(:secret),
      public?: get.(:is_public),
      majority: get.(:majority),
      deadline?: not is_nil(get.(:closes_local))
    }
  end

  defp deadline_in("none", _time_zone), do: ""

  defp deadline_in(hours, time_zone) do
    hours = String.to_integer(hours)

    DateTime.utc_now()
    |> DateTime.add(hours, :hour)
    |> DateTime.shift_zone!(time_zone)
    |> Calendar.strftime("%Y-%m-%dT%H:%M")
  end

  defp answers(set) do
    set
    |> answer_set()
    |> Enum.with_index()
    |> Map.new(fn {text, index} -> {Integer.to_string(index), %{"text" => text}} end)
  end

  defp answer_set("yes_no"), do: [dgettext("polls", "Yes"), dgettext("polls", "No")]

  defp answer_set("for_against") do
    [dgettext("polls", "For"), dgettext("polls", "Against"), dgettext("polls", "Abstain")]
  end

  attr :state, :map, default: nil, doc: "the `@poll_form` assign"

  @doc """
  A modal `<dialog>`, for what `<main>` would cover: on a phone a sheet from the
  bottom edge, as `CreateMenu`.
  """
  def dialog(assigns) do
    ~H"""
    <dialog
      :if={@state}
      id="poll-form-dialog"
      phx-hook=".PollFormDialog"
      phx-mounted={JS.ignore_attributes(["open"])}
      aria-labelledby="poll-form-title"
      class="fixed inset-0 m-0 size-full max-h-none max-w-none overflow-hidden bg-transparent p-0 backdrop:bg-transparent"
    >
      <div class="flex size-full items-end justify-center sm:items-center sm:p-4">
        <div
          id="poll-form-backdrop"
          class="absolute inset-0 bg-black/30 backdrop-blur-[2px] dark:bg-black/60"
          phx-click="poll_form_close"
          aria-hidden="true"
        >
        </div>
        <section
          tabindex="-1"
          autofocus
          class="relative flex max-h-[85dvh] w-full flex-col overflow-hidden rounded-t-3xl border border-b-0 border-base-300/70 bg-base-100 text-base-content shadow-2xl shadow-base-content/10 outline-none sm:max-w-lg sm:rounded-3xl sm:border-b"
        >
          <header class="flex items-start gap-3 border-b border-base-300/60 px-5 pt-5 pb-4">
            <span class="inline-flex size-10 shrink-0 items-center justify-center rounded-2xl bg-primary/10 text-primary">
              <.icon name="hero-chart-bar" class="size-5" />
            </span>
            <div class="min-w-0 flex-1 self-center">
              <h2 id="poll-form-title" class="text-base font-semibold leading-tight">
                {if(@state.values.new?,
                  do: dgettext("polls", "New poll"),
                  else: dgettext("polls", "Change poll")
                )}
              </h2>
            </div>
            <.icon_button
              id="poll-form-close"
              type="button"
              phx-click="poll_form_close"
              icon="hero-x-mark"
              label={dgettext("polls", "Close")}
              class="-mr-1"
            />
          </header>

          <div class="min-h-0 flex-1 overflow-y-auto px-5 py-4">
            <.form
              for={@state.form}
              id="poll-form"
              phx-change="poll_form_validate"
              phx-submit="poll_form_save"
              novalidate
            >
              <.question_fields :if={!@state.values.schedule_only?} form={@state.form} />
              <p :if={@state.values.schedule_only?} id="poll-form-frozen" class="mb-3 text-sm">
                {dgettext(
                  "polls",
                  "Votes are in, so only the deadline can change. Voters saw the rest."
                )}
              </p>
              <.deadline_fields form={@state.form} time_zone={@state.time_zone} />
              <.more_settings :if={!@state.values.schedule_only?} state={@state} />

              <label
                :if={@state.values.new? and @state.can_announce?}
                id="poll-form-announce"
                class="mt-3 flex items-center gap-2 text-sm"
              >
                <input type="hidden" name="announce" value="false" />
                <input
                  type="checkbox"
                  name="announce"
                  value="true"
                  checked={@state.announce?}
                  class="checkbox checkbox-sm"
                />
                {dgettext("polls", "Post it in the chat")}
              </label>

              <p
                :if={@state.error}
                id="poll-form-error"
                role="alert"
                class="mt-3 flex items-start gap-1.5 text-sm text-error"
              >
                <.icon name="hero-exclamation-circle" class="mt-0.5 size-4 shrink-0" />
                {@state.error}
              </p>
            </.form>
          </div>

          <footer class="flex items-center justify-end gap-2 border-t border-base-300/60 bg-base-200/40 px-5 pt-3 pb-[calc(0.75rem+var(--app-safe-area-bottom))] sm:pb-3">
            <.button type="button" phx-click="poll_form_close" variant="ghost">
              {dgettext("polls", "Cancel")}
            </.button>
            <.button
              id="poll-form-submit"
              type="submit"
              form="poll-form"
              phx-disable-with={dgettext("polls", "Saving...")}
              variant="primary"
            >
              {if(@state.values.new?,
                do: dgettext("polls", "Start the poll"),
                else: dgettext("polls", "Save")
              )}
            </.button>
          </footer>
        </section>
      </div>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PollFormDialog">
      export default {
        mounted() {
          // Escape and Android's back button close it through the server, which
          // removes it.
          this.el.addEventListener("cancel", event => {
            event.preventDefault()
            this.pushEvent("poll_form_close", {})
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

  attr :form, :any, required: true

  defp question_fields(assigns) do
    ~H"""
    <.input
      field={@form[:question]}
      label={dgettext("polls", "Question")}
      maxlength={Poll.max_question()}
      autocomplete="off"
      phx-debounce="200"
      required
    />
    <.input
      field={@form[:description]}
      type="textarea"
      rows="2"
      label={dgettext("polls", "More about it (optional)")}
      maxlength={Poll.max_description()}
      phx-debounce="200"
    />

    <fieldset id="poll-form-options" class="fieldset mt-1">
      <legend class="fieldset-legend">{dgettext("polls", "Answers")}</legend>
      <.inputs_for :let={option} field={@form[:options]}>
        <input type="hidden" name="poll[options_sort][]" value={option.index} />
        <div class="flex items-start gap-1">
          <div class="min-w-0 flex-1">
            <.input
              field={option[:text]}
              placeholder={dgettext("polls", "Answer %{number}", number: option.index + 1)}
              aria-label={dgettext("polls", "Answer %{number}", number: option.index + 1)}
              maxlength={PotokIde.Polls.PollOption.max_text()}
              autocomplete="off"
              phx-debounce="200"
            />
          </div>
          <button
            type="button"
            id={"poll-form-drop-#{option.index}"}
            name="poll[options_drop][]"
            value={option.index}
            phx-click={JS.dispatch("change")}
            aria-label={dgettext("polls", "Remove answer")}
            title={dgettext("polls", "Remove answer")}
            class={[icon_button_class("ghost", "sm"), "mt-1"]}
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>
      </.inputs_for>
      <input type="hidden" name="poll[options_drop][]" />
      <.field_errors field={@form[:options]} />

      <div class="mt-1 flex flex-wrap items-center gap-2">
        <button
          id="poll-form-add-option"
          type="button"
          name="poll[options_sort][]"
          value="new"
          phx-click={JS.dispatch("change")}
          class={chip_class()}
        >
          <.icon name="hero-plus" class="size-3.5" />
          {dgettext("polls", "Add answer")}
        </button>
        <button
          id="poll-form-yes-no"
          type="button"
          phx-click="poll_form_answers"
          phx-value-set="yes_no"
          class={chip_class()}
        >
          {dgettext("polls", "Yes / No")}
        </button>
        <button
          id="poll-form-for-against"
          type="button"
          phx-click="poll_form_answers"
          phx-value-set="for_against"
          class={chip_class()}
        >
          {dgettext("polls", "For / Against / Abstain")}
        </button>
      </div>
    </fieldset>
    """
  end

  attr :form, :any, required: true
  attr :time_zone, :string, required: true

  defp deadline_fields(assigns) do
    assigns = assign(assigns, :deadlines, @deadlines)

    ~H"""
    <fieldset id="poll-form-deadline" class="fieldset mt-3">
      <legend class="fieldset-legend">{dgettext("polls", "Deadline")}</legend>
      <div class="mb-1 flex flex-wrap items-center gap-2">
        <button
          :for={hours <- @deadlines}
          id={"poll-form-deadline-#{hours}"}
          type="button"
          phx-click="poll_form_deadline"
          phx-value-hours={hours}
          class={chip_class()}
        >
          {deadline_label(hours)}
        </button>
        <button
          id="poll-form-deadline-none"
          type="button"
          phx-click="poll_form_deadline"
          phx-value-hours="none"
          class={chip_class()}
        >
          {dgettext("polls", "No deadline")}
        </button>
      </div>
      <.input
        field={@form[:closes_local]}
        type="datetime-local"
        aria-label={dgettext("polls", "Deadline")}
      />
      <p class="-mt-1 text-xs text-base-content/65">
        {dgettext("polls", "Times are in %{zone}.", zone: @time_zone)}
      </p>
      <.input
        field={@form[:reminder_minutes]}
        type="select"
        label={dgettext("polls", "Remind those who have not voted")}
        options={reminder_options()}
      />
    </fieldset>
    """
  end

  defp deadline_label(1), do: dgettext("polls", "1 hour")
  defp deadline_label(24), do: dgettext("polls", "1 day")
  defp deadline_label(72), do: dgettext("polls", "3 days")
  defp deadline_label(168), do: dgettext("polls", "7 days")

  defp reminder_options do
    [
      {dgettext("polls", "No reminder"), ""},
      {dgettext("polls", "An hour before the end"), 60},
      {dgettext("polls", "A day before the end"), 1440}
    ]
  end

  attr :state, :map, required: true

  defp more_settings(assigns) do
    assigns = assign(assigns, :form, assigns.state.form)
    assigns = assign(assigns, :values, assigns.state.values)

    ~H"""
    <details
      id="poll-form-more"
      phx-mounted={JS.ignore_attributes(["open"])}
      class="group/more mt-3 rounded-2xl border border-base-300/70 px-3"
    >
      <summary class="flex cursor-pointer list-none items-center justify-between gap-2 py-2.5 text-sm font-semibold">
        {dgettext("polls", "More settings")}
        <.icon
          name="hero-chevron-down"
          class="size-4 transition-transform duration-150 group-open/more:rotate-180"
        />
      </summary>

      <div class="pb-3">
        <.input
          field={@form[:kind]}
          type="select"
          label={dgettext("polls", "How many answers can one vote hold")}
          options={[
            {dgettext("polls", "One"), :single},
            {dgettext("polls", "Several"), :multiple}
          ]}
        />
        <.input
          :if={@values.kind == :multiple}
          field={@form[:max_choices]}
          type="number"
          min="1"
          max="30"
          label={dgettext("polls", "At most (optional)")}
        />

        <.input
          field={@form[:secret]}
          type="checkbox"
          label={dgettext("polls", "Secret poll")}
        />
        <p class="-mt-1 mb-2 text-xs text-base-content/65">
          {dgettext(
            "polls",
            "Nothing keeps who voted for what, so not even the group's admins can see it. A vote cannot be changed, the counts show only at the end, and a finished poll cannot be opened again."
          )}
        </p>

        <.input
          :if={!@values.secret?}
          field={@form[:allow_change]}
          type="checkbox"
          label={dgettext("polls", "Voters can change their vote")}
        />
        <.input
          :if={!@values.secret? and !@values.public?}
          field={@form[:allow_member_options]}
          type="checkbox"
          label={dgettext("polls", "Members can add answers")}
        />

        <div :if={@state.can_publish?} id="poll-form-public">
          <.input
            field={@form[:is_public]}
            type="checkbox"
            label={dgettext("polls", "Public: non-members can vote too")}
          />
          <p class="-mt-1 mb-2 text-xs text-base-content/65">
            {dgettext(
              "polls",
              "Anyone signed in can vote and the poll shows among public polls, so its result is a mood, not a count of people."
            )}
          </p>
        </div>

        <.role_picker
          :if={!@values.public?}
          id="poll-form-voters"
          field={@form[:voter_role_keys]}
          roles={@state.roles}
          legend={dgettext("polls", "Who votes")}
        />

        <.role_picker
          id="poll-form-results"
          field={@form[:results_role_keys]}
          roles={@state.roles}
          legend={dgettext("polls", "Who sees the results")}
          hint={dgettext("polls", "Counts without names. The organizer always sees them.")}
        />
        <.input
          :if={!@values.secret?}
          field={@form[:results_when]}
          type="select"
          label={dgettext("polls", "From when")}
          options={[
            {dgettext("polls", "After voting, and everyone at the end"), :voted},
            {dgettext("polls", "From the start"), :always},
            {dgettext("polls", "Only at the end"), :closed}
          ]}
        />

        <.role_picker
          id="poll-form-details"
          field={@form[:details_role_keys]}
          roles={@state.roles}
          legend={dgettext("polls", "Who sees the details")}
          hint={details_hint(@values)}
        />
        <.input
          field={@form[:details_when]}
          type="select"
          label={dgettext("polls", "From when")}
          options={[
            {dgettext("polls", "From the start"), :always},
            {dgettext("polls", "Only at the end"), :closed}
          ]}
        />

        <div :if={@values.kind == :single and !@values.public?} id="poll-form-decision">
          <.input
            field={@form[:majority]}
            type="select"
            label={dgettext("polls", "Decision")}
            options={[
              {dgettext("polls", "None, just the results"), :none},
              {dgettext("polls", "The most votes"), :plurality},
              {dgettext("polls", "More than half of the votes"), :simple},
              {dgettext("polls", "Two thirds of the votes"), :two_thirds},
              {dgettext("polls", "More than half of those who may vote"), :absolute}
            ]}
          />
          <.input
            :if={@values.majority != :none}
            field={@form[:quorum_percent]}
            type="number"
            min="1"
            max="100"
            label={dgettext("polls", "Quorum: percent of those who may vote (optional)")}
          />
        </div>
      </div>
    </details>
    """
  end

  defp details_hint(%{secret?: true}) do
    dgettext("polls", "Turnout and who took part. The organizer always sees them.")
  end

  defp details_hint(_values) do
    dgettext("polls", "Who voted for what, with statistics. The organizer always sees them.")
  end

  attr :id, :string, required: true
  attr :field, Phoenix.HTML.FormField, required: true
  attr :roles, :list, required: true
  attr :legend, :string, required: true
  attr :hint, :string, default: nil

  defp role_picker(assigns) do
    ~H"""
    <fieldset id={@id} class="fieldset mt-1">
      <legend class="fieldset-legend">{@legend}</legend>
      <p :if={@hint} class="text-xs text-base-content/65">{@hint}</p>
      <input type="hidden" name={@field.name <> "[]"} value="" />
      <div class="mt-1 flex flex-wrap gap-x-3 gap-y-1.5">
        <label :for={role <- @roles} class="inline-flex items-center gap-2 text-sm">
          <input
            type="checkbox"
            name={@field.name <> "[]"}
            value={role.key}
            checked={role.key in List.wrap(@field.value)}
            class="checkbox checkbox-sm"
          />
          <span>{RolesTab.role_label(role)}</span>
        </label>
      </div>
      <.field_errors field={@field} />
    </fieldset>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true

  # For what has no `<.input>` of its own to show it.
  defp field_errors(assigns) do
    ~H"""
    <p
      :for={error <- @field.errors}
      class="mt-1 flex items-center gap-1.5 text-sm text-error"
      role="alert"
    >
      <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />
      {translate_error(error)}
    </p>
    """
  end

  defp chip_class do
    "inline-flex h-8 cursor-pointer items-center gap-1 rounded-full border border-base-300 bg-base-100 px-3 text-xs font-semibold transition duration-150 ease-out hover:border-primary/50 hover:text-primary focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40 active:scale-95"
  end

  @doc "Whether `group` takes polls from its chat."
  def chat_entry?(%Group{} = group, %Access{} = access) do
    Rules.can_create?(access, group) and Access.can?(access, :post_values)
  end
end
