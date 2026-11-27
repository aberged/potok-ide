defmodule PotokIdeWeb.GroupLive.Show.ReportDialog do
  @moduledoc """
  The dialog of the group page that reports a message to the group's admins
  (`PotokIde.Social.ValueReports`): why, and a note. The page handles
  `report_value_open`, `report_value_close` and `report_value_submit`.
  """

  use PotokIdeWeb, :html

  alias PotokIde.Social.{Profile, Value, ValueReport, ValueReports}

  attr :report, :map, default: nil, doc: "`%{value: value, form: form}` while open, else nil"

  def dialog(assigns) do
    ~H"""
    <dialog
      :if={@report}
      id="report-value-dialog"
      phx-hook=".ReportValueDialog"
      phx-mounted={JS.ignore_attributes(["open"])}
      aria-labelledby="report-value-title"
      class="fixed inset-0 m-0 size-full max-h-none max-w-none overflow-hidden bg-transparent p-0 backdrop:bg-transparent"
    >
      <div class="flex size-full items-end justify-center sm:items-center sm:p-4">
        <div
          id="report-value-backdrop"
          class="absolute inset-0 bg-black/30 backdrop-blur-[2px] dark:bg-black/60"
          phx-click="report_value_close"
          aria-hidden="true"
        >
        </div>
        <section class="relative flex max-h-[92dvh] w-full flex-col overflow-hidden rounded-t-3xl border border-b-0 border-base-300/70 bg-base-100 text-base-content shadow-2xl shadow-base-content/10 sm:max-w-md sm:rounded-3xl sm:border-b">
          <header class="flex items-start gap-3 px-5 pt-5">
            <span class="inline-flex size-10 shrink-0 items-center justify-center rounded-2xl bg-error/10 text-error">
              <.icon name="hero-flag" class="size-5" />
            </span>
            <div class="min-w-0 flex-1">
              <h2 id="report-value-title" class="text-base font-semibold">
                {gettext("Report message")}
              </h2>
              <p class="mt-0.5 text-sm text-base-content/65">
                {gettext(
                  "The report goes to the admins of the group. The author does not learn who reported it."
                )}
              </p>
            </div>
            <.icon_button
              id="report-value-close"
              type="button"
              phx-click="report_value_close"
              icon="hero-x-mark"
              label={gettext("Close")}
            />
          </header>

          <.form
            for={@report.form}
            id="report-value-form"
            phx-submit="report_value_submit"
            class="min-h-0 flex-1 space-y-4 overflow-y-auto px-5 pt-4 pb-[calc(1.25rem+var(--app-safe-area-bottom))] sm:pb-5"
          >
            <blockquote
              id="report-value-quote"
              class="rounded-2xl border-l-4 border-base-300 bg-base-200/60 px-3 py-2 text-sm"
            >
              <span class="block text-xs font-semibold text-base-content/70">
                {Profile.display_name(@report.value.creator)}
              </span>
              <span class="line-clamp-3 wrap-break-word text-base-content/80">
                {Value.excerpt(@report.value, 200) || gettext("A message")}
              </span>
            </blockquote>

            <fieldset id="report-value-reasons">
              <legend class="mb-2 text-sm font-medium">{gettext("Why are you reporting it?")}</legend>
              <div class="space-y-1.5">
                <label
                  :for={reason <- ValueReports.reasons()}
                  id={"report-value-reason-#{reason}"}
                  class="flex cursor-pointer items-center gap-3 rounded-2xl border border-base-300/80 px-3 py-2.5 text-sm transition hover:border-base-content/30 has-[:checked]:border-error/50 has-[:checked]:bg-error/5"
                >
                  <input
                    type="radio"
                    id={"report-value-reason-#{reason}-input"}
                    name={@report.form[:reason].name}
                    value={reason}
                    checked={to_string(@report.form[:reason].value) == to_string(reason)}
                    class="radio radio-sm"
                    required
                  />
                  <span>{ValueReports.reason_label(reason)}</span>
                </label>
              </div>
              <p
                :for={message <- translate_errors(@report.form.errors, :reason)}
                class="mt-1.5 text-sm text-error"
              >
                {message}
              </p>
            </fieldset>

            <.input
              field={@report.form[:note]}
              id="report-value-note"
              type="textarea"
              label={gettext("Anything the admins should know (optional)")}
              maxlength={ValueReport.max_note()}
              rows="3"
            />

            <div class="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
              <.button
                id="report-value-cancel"
                type="button"
                phx-click="report_value_close"
                variant="ghost"
              >
                {gettext("Cancel")}
              </.button>
              <.button
                id="report-value-submit"
                type="submit"
                variant="danger"
                phx-disable-with={gettext("Sending...")}
              >
                <.icon name="hero-flag" class="size-4" />
                <span>{gettext("Send report")}</span>
              </.button>
            </div>
          </.form>
        </section>
      </div>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ReportValueDialog">
      export default {
        mounted() {
          // Escape closes the dialog through the server, which removes it.
          this.el.addEventListener("cancel", event => {
            event.preventDefault()
            this.pushEvent("report_value_close", {})
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
end
