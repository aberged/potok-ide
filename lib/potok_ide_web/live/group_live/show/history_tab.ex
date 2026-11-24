defmodule PotokIdeWeb.GroupLive.Show.HistoryTab do
  @moduledoc """
  The history of a group: who changed what, the newest first, narrowed to a
  kind, a person or a day, and what a thing was before a change, in a dialog.
  `HistoryState` holds what it shows; plain function components, as an event of
  a LiveComponent would pass by the guard of a preview.
  """

  use PotokIdeWeb, :html

  alias PotokIde.History.{Feed, GroupChange}
  alias PotokIde.Social.Profile
  alias PotokIdeWeb.GroupLive.Show.{Components, HistoryDiff, HistorySnapshot, HistoryWords}

  attr :group, :map, required: true
  attr :access, :any, required: true
  attr :history, :map, default: nil, doc: "what `HistoryState` holds, nil until the tab is open"
  attr :entries, :any, required: true, doc: "the stream of entries"

  attr :at, :any,
    default: nil,
    doc: "the moment the address asks for, as the viewer's clock has it"

  def panel(assigns) do
    ~H"""
    <div id="group-panel-history" class="card flex min-h-0 flex-1 flex-col px-2">
      <Components.tab_body>
        <.page_header id="group-history-header" icon="hero-clock">
          {gettext("History")}
          <:subtitle>
            {gettext(
              "Who changed what in this group, when, and what it was before. Every member reads it, each thing by its own rules. Of messages only the fact is kept, and who voted for what never."
            )}
          </:subtitle>
        </.page_header>

        <HistorySnapshot.picker :if={@history} group={@group} history={@history} at={@at} />

        <HistorySnapshot.panel
          :if={@history && @history.snapshot}
          group={@group}
          history={@history}
        />

        <%= if @history && is_nil(@history.snapshot) do %>
          <div id="history-filters" class="mb-3 space-y-2">
            <div
              id="history-kinds"
              role="group"
              aria-label={gettext("What to show")}
              class="flex flex-wrap gap-1.5"
            >
              <button
                :for={filter <- Feed.filters()}
                type="button"
                id={"history-filter-#{filter}"}
                phx-click="history_filter"
                phx-value-filter={filter}
                aria-pressed={to_string(@history.filter == filter)}
                class={[
                  "rounded-full border px-3 py-1 text-sm transition duration-150 active:scale-[0.97]",
                  if(@history.filter == filter,
                    do: "border-primary bg-primary/10 font-semibold text-primary",
                    else: "border-base-300 bg-base-100 hover:bg-base-200"
                  )
                ]}
              >
                {filter_label(filter)}
              </button>
            </div>
            <div class="flex flex-wrap items-center gap-2">
              <.form
                for={to_form(%{"until" => @history.until && Date.to_iso8601(@history.until)})}
                id="history-until-form"
                phx-change="history_until"
                class="inline-flex items-center gap-2 text-sm"
              >
                <label for="history-until" class="text-base-content/65">
                  {gettext("Up to the day")}
                </label>
                <input
                  type="date"
                  id="history-until"
                  name="until"
                  value={@history.until && Date.to_iso8601(@history.until)}
                  class="rounded-full border border-base-300 bg-base-100 px-3 py-1 text-sm"
                />
              </.form>
              <.chip
                :if={@history.actor}
                id="history-actor"
                event="history_actor_clear"
                label={gettext("Only %{name}", name: @history.actor.name)}
              />
              <.chip
                :if={@history.subject}
                id="history-subject"
                event="history_subject_clear"
                label={gettext("Only %{thing}", thing: @history.subject_name)}
              />
            </div>
          </div>

          <p
            :if={@history.count == 0}
            id="history-empty"
            class="py-10 text-center text-sm text-base-content/60"
          >
            {if filtered?(@history),
              do: gettext("Nothing like that in the history."),
              else: gettext("Nothing has changed yet since the history began.")}
          </p>

          <ol id="history-list" phx-update="stream" class="space-y-1">
            <li
              :for={{dom_id, entry} <- @entries}
              id={dom_id}
              data-source={entry.source}
              data-type={entry.source == :change && entry.row.subject_type}
              class="flex items-start gap-3 rounded-2xl px-2 py-2 transition-colors hover:bg-base-200/60"
            >
              <span class="mt-0.5 inline-flex size-8 shrink-0 items-center justify-center rounded-xl bg-base-200 text-base-content/60">
                <.icon name={entry.icon} class="size-4" />
              </span>
              <div class="min-w-0 flex-1">
                <p class="text-sm [overflow-wrap:anywhere]">
                  {elem(entry.line, 0)}<button
                    :if={entry.actor_id}
                    type="button"
                    phx-click="history_actor"
                    phx-value-id={entry.actor_id}
                    title={gettext("Only what they changed")}
                    class="font-semibold hover:underline"
                  >{elem(entry.line, 1)}</button><span
                    :if={is_nil(entry.actor_id)}
                    class="font-semibold"
                  >{elem(entry.line, 1)}</span>{elem(entry.line, 2)}
                </p>
                <p class="flex flex-wrap items-center gap-x-2 text-xs text-base-content/55">
                  <Components.local_time id={"#{dom_id}-at"} datetime={entry.at} />
                  <span :if={entry.burst?}>{gettext("several changes in a row")}</span>
                  <span :if={entry.emptied?}>{gettext("old version emptied")}</span>
                </p>
              </div>
              <.link
                :if={entry.message_path}
                id={"#{dom_id}-message"}
                navigate={entry.message_path}
                class="btn btn-ghost btn-xs rounded-full"
              >
                {gettext("Message")}
              </.link>
              <.icon_button
                :if={entry.opens?}
                id={"#{dom_id}-open"}
                type="button"
                phx-click="history_open"
                phx-value-id={entry.row.id}
                icon="hero-magnifying-glass-plus"
                label={gettext("What it was")}
              />
            </li>
          </ol>

          <div :if={@history.cursor} class="mt-4 flex justify-center">
            <.button id="history-more" type="button" phx-click="history_more" size="sm">
              {gettext("Older changes")}
            </.button>
          </div>

          <p
            :if={is_nil(@history.cursor)}
            id="history-since"
            class="mt-6 text-center text-xs text-base-content/55"
          >
            {gettext("The history began on")}
            <Components.local_time id="history-since-at" datetime={@history.since} />
          </p>
        <% end %>
      </Components.tab_body>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :label, :string, required: true

  defp chip(assigns) do
    ~H"""
    <span
      id={@id}
      class="inline-flex max-w-full items-center gap-1 rounded-full bg-primary/10 py-0.5 pr-1 pl-3 text-sm text-primary"
    >
      <span class="truncate">{@label}</span>
      <button
        type="button"
        id={"#{@id}-clear"}
        phx-click={@event}
        aria-label={gettext("Show everything")}
        class="inline-flex size-6 items-center justify-center rounded-full hover:bg-primary/15"
      >
        <.icon name="hero-x-mark" class="size-4" />
      </button>
    </span>
    """
  end

  defp filtered?(history),
    do: (history.filter != :all or history.until) || history.actor || history.subject

  defp filter_label(:all), do: gettext("Everything")
  defp filter_label(:group), do: gettext("Group and descriptions")
  defp filter_label(:records), do: gettext("Records")
  defp filter_label(:processes), do: gettext("Processes")
  defp filter_label(:talk), do: gettext("Conversation")
  defp filter_label(:access), do: gettext("Access")

  # ---------
  # One change
  # ---------

  attr :open, :map,
    default: nil,
    doc:
      "while one is open: `%{mode: :change, change, text, sides, may_empty?}`, or `%{mode: :state, text, moment, values}`"

  attr :manifest, :any, required: true

  @doc "What a change made of a thing, side by side or line by line."
  def dialog(assigns) do
    ~H"""
    <dialog
      :if={@open}
      id="history-dialog"
      phx-hook=".HistoryDialog"
      phx-mounted={JS.ignore_attributes(["open"])}
      aria-labelledby="history-dialog-title"
      class="fixed inset-0 m-0 size-full max-h-none max-w-none overflow-hidden bg-transparent p-0 backdrop:bg-transparent"
    >
      <div class="flex size-full items-end justify-center sm:items-center sm:p-4">
        <div
          class="absolute inset-0 bg-black/30 backdrop-blur-[2px] dark:bg-black/60"
          phx-click="history_close"
          aria-hidden="true"
        >
        </div>
        <section
          tabindex="-1"
          autofocus
          class="relative flex max-h-[90dvh] w-full flex-col overflow-hidden rounded-t-3xl border border-b-0 border-base-300/70 bg-base-100 text-base-content shadow-2xl outline-none sm:max-w-3xl sm:rounded-3xl sm:border-b"
        >
          <header class="flex items-start gap-3 border-b border-base-300/60 px-5 pt-5 pb-4">
            <span class="inline-flex size-10 shrink-0 items-center justify-center rounded-2xl bg-primary/10 text-primary">
              <.icon name={@open.icon} class="size-5" />
            </span>
            <div class="min-w-0 flex-1">
              <h2 id="history-dialog-title" class="text-base font-semibold [overflow-wrap:anywhere]">
                {@open.text}
              </h2>
              <p :if={@open.mode == :state} class="text-xs text-base-content/60">
                {gettext("As it was on")}
                <Components.local_time id="history-dialog-moment" datetime={@open.moment} />
              </p>
              <p :if={@open.mode == :change} class="text-xs text-base-content/60">
                <Components.local_time id="history-dialog-at" datetime={@open.change.at} />
                <%= if @open.change.last_at do %>
                  –
                  <Components.local_time
                    id="history-dialog-last-at"
                    datetime={@open.change.last_at}
                    format="time"
                  />
                <% end %>
              </p>
            </div>
            <.icon_button
              id="history-dialog-close"
              type="button"
              phx-click="history_close"
              icon="hero-x-mark"
              label={gettext("Close")}
            />
          </header>
          <div
            :if={@open.mode == :state}
            id="history-values"
            class="min-h-0 flex-1 space-y-4 overflow-y-auto px-5 py-4"
          >
            <HistorySnapshot.values values={@open.values} manifest={@manifest} />
          </div>
          <div
            :if={@open.mode == :change}
            id="history-sides"
            class="min-h-0 flex-1 space-y-4 overflow-y-auto px-5 py-4"
          >
            <p
              :if={@open.change.purged_at}
              id="history-emptied"
              class="rounded-xl bg-base-200 px-3 py-2 text-sm text-base-content/70"
            >
              {emptied_text(@open.change)}
            </p>
            <p
              :if={@open.change.op == :deleted and is_integer(@open.change.cause["count"])}
              id="history-one-of"
              class="rounded-xl bg-base-200 px-3 py-2 text-sm text-base-content/70"
            >
              {gettext("One of the %{count}:", count: @open.change.cause["count"])}
            </p>
            <%!-- What is gone has no other side. --%>
            <HistorySnapshot.values
              :if={@open.change.op == :deleted}
              values={for {field, before, _now} <- @open.sides, do: {field, held(before)}}
              manifest={@manifest}
            />
            <.side
              :for={{field, before, now} <- @open.sides}
              :if={@open.change.op != :deleted}
              field={field}
              before={before}
              now={now}
              manifest={@manifest}
            />
            <p :if={@open.sides == []} id="history-sides-empty" class="text-sm text-base-content/60">
              {gettext("Nothing more is kept of this change.")}
            </p>
          </div>
          <footer
            :if={@open.mode == :change and (@open.may_empty? or @open.subject? or @open.restore)}
            class="flex flex-wrap items-center gap-2 border-t border-base-300/60 bg-base-200/40 px-5 pt-3 pb-[calc(0.75rem+var(--app-safe-area-bottom))] sm:pb-3"
          >
            <.button
              :if={@open.may_empty?}
              id="history-empty-versions"
              type="button"
              phx-click="history_empty"
              phx-value-id={@open.change.id}
              data-confirm={
                gettext(
                  "Empty all old versions of this? What it was is gone for good; that it changed, when and by whom stays, and so does who emptied it."
                )
              }
              variant="ghost"
              size="sm"
            >
              <.icon name="hero-trash" class="size-4" />
              {gettext("Empty old versions")}
            </.button>
            <span class="flex-1"></span>
            <.button
              :if={@open.subject?}
              id="history-only-this"
              type="button"
              phx-click="history_subject"
              phx-value-id={@open.change.id}
              variant="ghost"
              size="sm"
            >
              {gettext("All changes of this")}
            </.button>
            <.button
              :if={@open.restore == :here}
              id="history-restore"
              type="button"
              phx-click="history_restore"
              phx-value-id={@open.change.id}
              data-confirm={restore_confirm(@open.change)}
              variant="primary"
              size="sm"
            >
              <.icon name="hero-arrow-uturn-left" class="size-4" />
              {if @open.change.op == :deleted,
                do: gettext("Put it back"),
                else: gettext("Put this version back")}
            </.button>
            <.button
              :if={@open.restore == :editor}
              id="history-restore-editor"
              patch={"/groups/#{@open.change.group_id}/processes?process=#{@open.change.subject_id}&version=#{@open.change.id}"}
              variant="primary"
              size="sm"
            >
              <.icon name="hero-pencil-square" class="size-4" />
              {gettext("Open this drawing")}
            </.button>
          </footer>
        </section>
      </div>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".HistoryDialog">
      export default {
        mounted() {
          // Escape and Android's back button close it through the server.
          this.el.addEventListener("cancel", event => {
            event.preventDefault()
            this.pushEvent("history_close", {})
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

  defp restore_confirm(%GroupChange{op: :deleted, cause: %{"count" => count}}),
    do:
      ngettext(
        "Put %{count} record back, as it was? Files it named are gone for good.",
        "Put %{count} records back, as they were? Files they named are gone for good.",
        count
      )

  defp restore_confirm(%GroupChange{op: :deleted, subject_type: "description"}),
    do:
      gettext(
        "Put this description back, with the records of its app? Files they named are gone for good."
      )

  defp restore_confirm(%GroupChange{op: :deleted}), do: gettext("Put this back as it was?")

  defp restore_confirm(_change),
    do: gettext("Put back what it was before this change? What it is now stays in the history.")

  defp emptied_text(%GroupChange{purged_by: %Profile{} = profile}),
    do: gettext("%{name} emptied the old versions.", name: Profile.display_name(profile))

  defp emptied_text(_change), do: gettext("The old version is no longer kept.")

  attr :field, :string, required: true
  attr :before, :any, required: true
  attr :now, :any, required: true
  attr :manifest, :any, required: true

  defp side(assigns) do
    assigns = assign(assigns, :shape, shape(assigns.field, assigns.before, assigns.now))

    ~H"""
    <section id={"history-side-#{@field}"} data-shape={elem(@shape, 0)}>
      <h3 class="mb-1.5 text-xs font-semibold tracking-wide text-base-content/60 uppercase">
        {HistoryWords.field(@field)}
      </h3>
      <%= case @shape do %>
        <% {:lines, :too_long} -> %>
          <p class="rounded-xl bg-base-200 px-3 py-2 text-sm text-base-content/70">
            {gettext("From %{before} to %{now}, too long to compare here.",
              before: size(@before),
              now: size(@now)
            )}
          </p>
        <% {:lines, lines} -> %>
          <div class="overflow-x-auto rounded-xl border border-base-300/70 font-mono text-xs leading-5">
            <div class="min-w-fit">
              <.line :for={line <- lines} line={line} />
            </div>
          </div>
        <% {:paths, {rows, more?}} -> %>
          <.rows rows={rows} manifest={@manifest} field={@field} />
          <p :if={more?} class="mt-1 text-xs text-base-content/60">
            {gettext("And more that changed.")}
          </p>
        <% {:steps, {steps, flows?}} -> %>
          <ul class="space-y-1 text-sm">
            <li :for={{kind, label} <- steps} class="flex items-center gap-2">
              <.icon name={step_icon(kind)} class={["size-4 shrink-0", step_class(kind)]} />
              <span class="[overflow-wrap:anywhere]">{step_text(kind, label)}</span>
            </li>
            <li :if={flows?} class="text-base-content/70">
              {gettext("What leads to what changed.")}
            </li>
          </ul>
        <% {:short, _} -> %>
          <.rows
            rows={[{nil, plain(@field, @before, @manifest), plain(@field, @now, @manifest)}]}
            manifest={@manifest}
            field={@field}
          />
      <% end %>
    </section>
    """
  end

  attr :line, :any, required: true

  # Kept on one line, as its spaces are part of what is compared.
  defp line(assigns) do
    ~H"""
    <p class={["px-3 whitespace-pre-wrap [overflow-wrap:anywhere]", line_class(@line)]} phx-no-format>{line_text(@line)}</p>
    """
  end

  attr :rows, :list, required: true
  attr :field, :string, required: true
  attr :manifest, :any, required: true

  defp rows(assigns) do
    ~H"""
    <dl class="space-y-1.5">
      <div :for={{path, before, now} <- @rows} class="rounded-xl bg-base-200/60 px-3 py-2 text-sm">
        <dt :if={path} class="text-xs text-base-content/60 [overflow-wrap:anywhere]">{path}</dt>
        <dd class="flex flex-wrap items-baseline gap-x-2 [overflow-wrap:anywhere]">
          <span class={[
            "text-base-content/60",
            before not in [nil, "—"] && "line-through decoration-base-content/30"
          ]}>
            {before || "—"}
          </span>
          <.icon name="hero-arrow-right-mini" class="size-3.5 shrink-0 self-center opacity-60" />
          <span class="font-medium">{now || "—"}</span>
        </dd>
      </div>
    </dl>
    """
  end

  # How a field is best compared.
  defp shape(field, before, now) do
    values = for {:value, value} <- [before, now], do: value

    cond do
      Enum.any?([before, now], &(&1 in [:emptied, :hidden])) ->
        {:short, nil}

      field == "graph" ->
        {:steps, HistoryDiff.steps(plain_value(before), plain_value(now))}

      field in ["data", "managed", "attributes", "trigger_config", "fields"] ->
        {:paths, HistoryDiff.paths(plain_value(before), plain_value(now))}

      HistoryWords.long?(field, values) and Enum.all?(values, &(is_binary(&1) or is_nil(&1))) ->
        {:lines, HistoryDiff.lines(plain_value(before), plain_value(now))}

      true ->
        {:short, nil}
    end
  end

  defp held({:value, value}), do: value
  defp held(:none), do: nil
  defp held(gone), do: gone

  defp plain_value({:value, value}), do: value
  defp plain_value(_none), do: nil

  defp plain(_field, :emptied, _manifest), do: gettext("emptied")
  defp plain(_field, :hidden, _manifest), do: gettext("not shown to you then")
  defp plain(_field, :none, _manifest), do: nil
  defp plain("layout", {:value, _}, _manifest), do: gettext("moved around")
  defp plain(field, {:value, value}, manifest), do: HistoryWords.value(field, value, manifest)

  defp size({:value, text}) when is_binary(text),
    do: gettext("%{kb} KB", kb: div(byte_size(text) + 1023, 1024))

  defp size(_none), do: gettext("nothing")

  defp line_class(:gap), do: "bg-base-200/60 text-center text-base-content/50"
  defp line_class({:same, _}), do: "text-base-content/70"
  defp line_class({:removed, _}), do: "bg-rose-500/10 text-rose-700 dark:text-rose-300"
  defp line_class({:added, _}), do: "bg-emerald-500/10 text-emerald-700 dark:text-emerald-300"

  defp line_text(:gap), do: "⋯"
  defp line_text({:same, line}), do: "  " <> line
  defp line_text({:removed, line}), do: "− " <> line
  defp line_text({:added, line}), do: "+ " <> line

  defp step_icon(:added), do: "hero-plus-circle"
  defp step_icon(:removed), do: "hero-minus-circle"
  defp step_icon(:changed), do: "hero-pencil-square"

  defp step_class(:added), do: "text-emerald-600 dark:text-emerald-400"
  defp step_class(:removed), do: "text-rose-600 dark:text-rose-400"
  defp step_class(:changed), do: "text-base-content/60"

  defp step_text(:added, label), do: gettext("Step added: %{label}", label: label)
  defp step_text(:removed, label), do: gettext("Step taken out: %{label}", label: label)
  defp step_text(:changed, label), do: gettext("Step changed: %{label}", label: label)
end
