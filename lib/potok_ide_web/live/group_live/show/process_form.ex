defmodule PotokIdeWeb.GroupLive.Show.ProcessForm do
  @moduledoc """
  The form a process drawn in Potok asks a person to fill in (a `formTask`,
  `PotokIde.Processes.Engine`), one dialog per page. The host LiveView calls
  `init/1` in mount, delegates every `"process_form_*"` event to
  `handle_event/3`, and hands `moved/2` what it hears of the group's runs.

  The dialog opens by itself only as an answer to what its viewer just did:
  the run asks them, as the one who started it, and it was their step that
  led to the form (a message they wrote, a Start they pressed, a form before
  this one). A form reached any other way, after a wait or someone else's
  decision, and a form of a role, wait on the Processes tab, where "Fill in"
  opens the same dialog.

  It also holds the one input of an attribute (`field/1`), which the Start
  form of a process started by hand shares.
  """

  use PotokIdeWeb, :html

  import Phoenix.LiveView, only: [put_flash: 3]

  alias PotokIde.Processes

  def init(socket), do: assign(socket, :process_form, nil)

  @doc """
  What a run of the group that moved means for the dialog: `payload` is what
  the engine told (`id`, and `asks`, whom the run asks or just stopped
  asking). An open form that no longer waits closes, and a form that came to
  wait for the viewer on their own step opens, unless one is open already.
  """
  def moved(%{assigns: %{current_profile: %{id: viewer}}} = socket, %{id: id, asks: %{} = asks}) do
    case socket.assigns.process_form do
      %{task: %{id: ^id}} -> again(socket, id)
      nil when asks.profile_id == viewer -> arrived(socket, id)
      _another_or_not_theirs -> socket
    end
  end

  def moved(socket, _payload), do: socket

  # The form on screen, read again: gone when it no longer waits.
  defp again(socket, id) do
    shown = socket.assigns.process_form.task.element

    case task(socket, id) do
      %{element: ^shown} -> socket
      nil -> socket |> init() |> put_flash(:info, gettext("That form no longer waits."))
      task -> open(socket, task)
    end
  end

  defp arrived(socket, id) do
    case task(socket, id) do
      %{by_viewer?: true} = task -> open(socket, task)
      _later_or_gone -> socket
    end
  end

  defp task(socket, id) do
    %{current_profile: profile, group: group, access: access} = socket.assigns
    Processes.form_task(profile, group, access, id)
  end

  defp open(socket, task) do
    fields = Map.new(task.attributes, &{&1["name"], ""})
    assign(socket, :process_form, %{task: task, form: to_form(fields, as: :answers), error: nil})
  end

  def handle_event("process_form_open", %{"id" => id}, socket) do
    with %{} <- socket.assigns.current_profile,
         {id, ""} <- Integer.parse(to_string(id)),
         %{} = task <- task(socket, id) do
      {:noreply, open(socket, task)}
    else
      _gone -> {:noreply, put_flash(socket, :error, gettext("That form no longer waits."))}
    end
  end

  def handle_event("process_form_close", _params, socket), do: {:noreply, init(socket)}

  def handle_event(_event, _params, %{assigns: %{process_form: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("process_form_validate", %{"answers" => answers}, socket) do
    state = socket.assigns.process_form
    {:noreply, assign(socket, :process_form, %{state | form: to_form(answers, as: :answers)})}
  end

  def handle_event("process_form_save", %{"answers" => answers}, socket) do
    %{current_profile: profile, group: group, access: access, process_form: state} =
      socket.assigns

    # A time typed into the form is the viewer's own.
    zone = socket.assigns[:calendar_time_zone]

    case Processes.complete_form(
           profile,
           group,
           access,
           state.task.id,
           state.task.element,
           answers,
           zone
         ) do
      {:ok, _instance} ->
        {:noreply, socket |> init() |> put_flash(:info, gettext("Sent. The process goes on."))}

      {:error, reason} when reason in [:not_waiting, :not_found] ->
        {:noreply, socket |> init() |> put_flash(:error, gettext("That form no longer waits."))}

      {:error, reason} ->
        {:noreply,
         assign(socket, :process_form, %{
           state
           | form: to_form(answers, as: :answers),
             error: error_text(reason)
         })}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp error_text({:invalid_field, name, reason}),
    do: gettext("%{name}: %{problem}.", name: name, problem: field_problem(reason))

  defp error_text(:not_permitted), do: gettext("This form is not yours to fill in.")
  defp error_text(:process_inactive), do: gettext("The process is off.")
  defp error_text(:too_much_data), do: gettext("That is more than the process can keep.")
  defp error_text(_reason), do: gettext("That did not work.")

  @doc "What is wrong with what was typed for an attribute, in words."
  def field_problem(:required), do: gettext("must be filled in")
  def field_problem(:not_a_number), do: gettext("takes a number")
  def field_problem(:not_a_date), do: gettext("takes a date")
  def field_problem(:not_a_datetime), do: gettext("takes a date and a time")
  def field_problem(:not_an_option), do: gettext("takes one of its choices")
  def field_problem(_reason), do: gettext("is not right")

  attr :state, :map, default: nil, doc: "the `@process_form` assign"

  @doc """
  A modal `<dialog>`, for what `<main>` would cover: on a phone a sheet from
  the bottom edge, as `PollForm`.
  """
  def dialog(assigns) do
    ~H"""
    <dialog
      :if={@state}
      id="process-form-dialog"
      phx-hook=".ProcessFormDialog"
      phx-mounted={JS.ignore_attributes(["open"])}
      aria-labelledby="process-form-title"
      class="fixed inset-0 m-0 size-full max-h-none max-w-none overflow-hidden bg-transparent p-0 backdrop:bg-transparent"
    >
      <div class="flex size-full items-end justify-center sm:items-center sm:p-4">
        <div
          id="process-form-backdrop"
          class="absolute inset-0 bg-black/30 backdrop-blur-[2px] dark:bg-black/60"
          phx-click="process_form_close"
          aria-hidden="true"
        >
        </div>
        <section
          tabindex="-1"
          autofocus
          class="relative flex max-h-[85dvh] w-full flex-col overflow-hidden rounded-t-3xl border border-b-0 border-base-300/70 bg-base-100 text-base-content shadow-2xl shadow-base-content/10 outline-none sm:max-w-lg sm:rounded-3xl sm:border-b"
        >
          <header class="flex items-start gap-3 border-b border-base-300/60 px-5 pt-5 pb-4">
            <span class="inline-flex size-10 shrink-0 items-center justify-center rounded-2xl bg-emerald-500/10 text-emerald-700 dark:text-emerald-300">
              <.icon name="hero-clipboard-document-list" class="size-5" />
            </span>
            <div class="min-w-0 flex-1 self-center">
              <h2 id="process-form-title" class="text-base font-semibold leading-tight">
                {@state.task.label}
              </h2>
              <p class="truncate text-xs text-base-content/60">{@state.task.process.name}</p>
            </div>
            <.icon_button
              id="process-form-close"
              type="button"
              phx-click="process_form_close"
              icon="hero-x-mark"
              label={gettext("Close")}
              class="-mr-1"
            />
          </header>

          <div class="min-h-0 flex-1 overflow-y-auto px-5 py-4">
            <%!-- On one line: the text keeps its own line breaks, and gets none of the template's. --%>
            <p
              :if={@state.task.text not in [nil, ""]}
              id="process-form-subject"
              class="mb-3 line-clamp-3 whitespace-pre-line break-words rounded-2xl bg-base-200/60 px-3 py-2 text-sm text-base-content/75"
              phx-no-format
            >{@state.task.text}</p>
            <.form
              for={@state.form}
              id="process-form"
              phx-change="process_form_validate"
              phx-submit="process_form_save"
              class="space-y-3"
            >
              <.field
                :for={attribute <- @state.task.attributes}
                attribute={attribute}
                field={@state.form[attribute["name"]]}
              />
              <p
                :if={@state.error}
                id="process-form-error"
                role="alert"
                class="flex items-start gap-1.5 rounded-xl bg-error/10 px-3 py-2 text-sm text-error"
              >
                <.icon name="hero-exclamation-circle" class="mt-0.5 size-4 shrink-0" />
                {@state.error}
              </p>
            </.form>
            <p id="process-form-later-note" class="mt-3 text-xs text-base-content/55">
              {gettext("Not now? It waits for you on the Processes tab, under Waiting for you.")}
            </p>
          </div>

          <footer class="flex items-center justify-end gap-2 border-t border-base-300/60 bg-base-200/40 px-5 pt-3 pb-[calc(0.75rem+var(--app-safe-area-bottom))] sm:pb-3">
            <.button
              id="process-form-later"
              type="button"
              phx-click="process_form_close"
              variant="ghost"
            >
              {gettext("Later")}
            </.button>
            <.button
              id="process-form-submit"
              type="submit"
              form="process-form"
              phx-disable-with={gettext("Sending...")}
              variant="primary"
            >
              <.icon name="hero-paper-airplane" class="size-4" />
              {gettext("Send")}
            </.button>
          </footer>
        </section>
      </div>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ProcessFormDialog">
      export default {
        mounted() {
          // Escape and Android's back button close it through the server, which
          // removes it.
          this.el.addEventListener("cancel", event => {
            event.preventDefault()
            this.pushEvent("process_form_close", {})
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

  attr :attribute, :map, required: true, doc: "an attribute of the entity a form asks for"
  attr :field, :any, required: true

  @doc "One attribute in a form, asked for as its type."
  def field(assigns) do
    assigns =
      assign(
        assigns,
        :label,
        assigns.attribute["name"] <> if(assigns.attribute["required"] == true, do: " *", else: "")
      )

    ~H"""
    <%= case @attribute["type"] do %>
      <% "boolean" -> %>
        <.input field={@field} type="checkbox" label={@label} />
      <% "date" -> %>
        <.input field={@field} type="date" label={@label} required={@attribute["required"] == true} />
      <% "datetime" -> %>
        <.input
          field={@field}
          type="datetime-local"
          label={@label}
          required={@attribute["required"] == true}
        />
      <% "choice" -> %>
        <.input
          field={@field}
          type="select"
          label={@label}
          prompt={gettext("Pick one")}
          options={@attribute["options"] || []}
          required={@attribute["required"] == true}
        />
      <% "number" -> %>
        <.input
          field={@field}
          type="text"
          label={@label}
          placeholder="0"
          maxlength="40"
          required={@attribute["required"] == true}
        />
      <% _text -> %>
        <.input
          field={@field}
          type="text"
          label={@label}
          maxlength="1000"
          required={@attribute["required"] == true}
        />
    <% end %>
    """
  end
end
