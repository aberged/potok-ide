defmodule PotokIdeWeb.GroupLive.Show.HistorySnapshot do
  @moduledoc """
  The group as it was at a moment (`PotokIde.History.Snapshot`), in the place
  of its changes: itself, what it had, and what its apps kept, each thing to
  be opened as it was. An app of that time is not run, as what it would write
  it would write today.
  """

  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.{Components, HistoryDiff, HistoryWords}

  attr :history, :map, required: true
  attr :at, :any, required: true, doc: "the moment asked for, as the viewer's clock has it"
  attr :group, :map, required: true

  @doc "Asks for a moment, and leads back to the changes."
  def picker(assigns) do
    ~H"""
    <div id="history-moment" class="mb-3 flex flex-wrap items-center gap-2 text-sm">
      <.form
        for={to_form(%{"at" => local(@at)})}
        id="history-at-form"
        phx-change="history_at"
        phx-submit="history_at"
        class="inline-flex flex-wrap items-center gap-2"
      >
        <label for="history-at" class="text-base-content/65">{gettext("As it was on")}</label>
        <input
          type="datetime-local"
          id="history-at"
          name="at"
          value={local(@at)}
          phx-debounce="blur"
          class="rounded-full border border-base-300 bg-base-100 px-3 py-1 text-sm"
        />
      </.form>
      <.link
        :if={@at}
        id="history-at-clear"
        patch={"/groups/#{@group.id}/history"}
        class="text-primary hover:underline"
      >
        {gettext("Back to the changes")}
      </.link>
    </div>
    """
  end

  defp local(%NaiveDateTime{} = at), do: at |> NaiveDateTime.to_iso8601() |> String.slice(0, 16)
  defp local(_none), do: nil

  attr :group, :map, required: true
  attr :history, :map, required: true

  def panel(assigns) do
    values =
      case assigns.history.snapshot.group do
        {:ok, values} -> values
        _none -> %{}
      end

    assigns = assign(assigns, :values, values)

    ~H"""
    <div id="history-snapshot" class="space-y-4">
      <p
        :if={@history.before_since?}
        id="history-before-since"
        class="rounded-2xl bg-warning/10 px-4 py-3 text-sm"
      >
        {gettext("The history had not begun yet. This is the group as it was when it did:")}
        <Components.local_time id="history-snapshot-since" datetime={@history.since} />
      </p>

      <section
        id="history-snapshot-group"
        class="rounded-3xl border border-base-300/70 bg-base-100/70 p-4 shadow-sm"
      >
        <div class="flex items-start gap-3">
          <h3 class="min-w-0 flex-1 text-lg font-semibold [overflow-wrap:anywhere]">
            {text(@values["name"])}
          </h3>
          <.button
            id="history-snapshot-group-open"
            type="button"
            phx-click="history_thing"
            phx-value-type="group"
            phx-value-id={@group.id}
            variant="ghost"
            size="sm"
          >
            {gettext("All of it")}
          </.button>
        </div>
        <div class="mt-2">
          <.description values={@values} id="history-snapshot-text" />
        </div>
      </section>

      <section
        :for={{type, things} <- @history.snapshot.things}
        id={"history-snapshot-#{type}"}
        class="rounded-3xl border border-base-300/70 bg-base-100/70 p-4 shadow-sm"
      >
        <h3 class="mb-2 text-sm font-semibold">{plural(type)}</h3>
        <ul class="flex flex-wrap gap-1.5">
          <li :for={thing <- things}>
            <button
              type="button"
              id={"history-thing-#{type}-#{thing.id}"}
              phx-click="history_thing"
              phx-value-type={type}
              phx-value-id={thing.id}
              class="max-w-full truncate rounded-full border border-base-300 bg-base-100 px-3 py-1 text-sm transition hover:bg-base-200 active:scale-[0.97]"
            >
              {thing.name || gettext("no name")}
            </button>
          </li>
        </ul>
      </section>

      <section
        :if={@history.snapshot.records != []}
        id="history-snapshot-records"
        class="rounded-3xl border border-base-300/70 bg-base-100/70 p-4 shadow-sm"
      >
        <h3 class="mb-2 text-sm font-semibold">{gettext("Records of apps")}</h3>
        <ul class="flex flex-wrap gap-1.5">
          <li :for={{collection, index} <- Enum.with_index(@history.snapshot.records)}>
            <button
              type="button"
              id={"history-records-#{index}"}
              phx-click="history_records"
              phx-value-index={index}
              aria-pressed={to_string(@history.records && @history.records.index == index)}
              class={[
                "rounded-full border px-3 py-1 text-sm transition hover:bg-base-200 active:scale-[0.97]",
                if(@history.records && @history.records.index == index,
                  do: "border-primary bg-primary/10",
                  else: "border-base-300 bg-base-100"
                )
              ]}
            >
              {collection_name(collection)}
              <span class="text-base-content/55">{collection.count}</span>
            </button>
          </li>
        </ul>
        <%= if @history.records do %>
          <ul id="history-records-list" class="mt-3 space-y-1">
            <li :for={row <- @history.records.rows}>
              <button
                type="button"
                id={"history-record-#{row.id}"}
                phx-click="history_record"
                phx-value-id={row.id}
                class="flex w-full items-baseline gap-2 rounded-xl px-2 py-1.5 text-left text-sm hover:bg-base-200"
              >
                <span class="shrink-0 text-xs text-base-content/50">{row.id}</span>
                <span class="min-w-0 flex-1 truncate">{gist(row.values)}</span>
              </button>
            </li>
          </ul>
          <.button
            :if={@history.records.more?}
            id="history-records-more"
            type="button"
            phx-click="history_records_more"
            size="sm"
          >
            {gettext("Older records")}
          </.button>
        <% end %>
      </section>

      <p id="history-snapshot-note" class="text-center text-xs text-base-content/55">
        {gettext(
          "Messages are not here, as no old text of theirs is kept, and neither is who the members were."
        )}
      </p>
    </div>
    """
  end

  attr :values, :list, required: true, doc: "`[{field, value}]`"
  attr :manifest, :any, required: true

  @doc "What a thing was, field by field."
  def values(assigns) do
    map = Map.new(assigns.values)

    assigns =
      assign(assigns,
        map: map,
        rest: Enum.reject(assigns.values, fn {field, _value} -> skipped?(field, map) end)
      )

    ~H"""
    <section :if={Map.has_key?(@map, "description") and text(@map["description"]) != ""}>
      <h3 class="mb-1.5 text-xs font-semibold tracking-wide text-base-content/60 uppercase">
        {HistoryWords.field("description")}
      </h3>
      <.description values={@map} id="history-values-description" />
    </section>
    <section :for={{field, value} <- @rest} id={"history-value-#{field}"}>
      <h3 class="mb-1 text-xs font-semibold tracking-wide text-base-content/60 uppercase">
        {HistoryWords.field(field)}
      </h3>
      <.value field={field} value={value} manifest={@manifest} />
    </section>
    """
  end

  # What says nothing, and what the description shows already.
  defp skipped?(field, map) do
    field in [
      "description",
      "layout",
      "published_at",
      "lock_version",
      "inserted_at",
      "updated_at"
    ] or
      map[field] in [nil, "", [], %{}] or
      (field == "content" and map["content"] == "data:") or
      (field in ["description_format", "content_format"] and is_binary(map[field]))
  end

  attr :field, :string, required: true
  attr :value, :any, required: true
  attr :manifest, :any, required: true

  defp value(%{value: hidden} = assigns) when hidden in [:emptied, :hidden] do
    ~H"""
    <p class="text-sm text-base-content/60 italic">
      {if @value == :emptied, do: gettext("emptied"), else: gettext("not shown to you then")}
    </p>
    """
  end

  defp value(%{field: "graph"} = assigns) do
    {steps, _flows?} = HistoryDiff.steps(nil, assigns.value)
    assigns = assign(assigns, :steps, steps)

    ~H"""
    <ul class="list-inside list-disc text-sm">
      <li :for={{_kind, label} <- @steps}>{label}</li>
    </ul>
    """
  end

  defp value(%{field: field} = assigns)
       when field in ["data", "managed", "attributes", "trigger_config", "fields"] do
    {rows, more?} = HistoryDiff.paths(nil, assigns.value)
    assigns = assign(assigns, rows: rows, more?: more?)

    ~H"""
    <dl class="space-y-1">
      <div :for={{path, _before, now} <- @rows} class="rounded-xl bg-base-200/60 px-3 py-1.5 text-sm">
        <dt class="text-xs text-base-content/60 [overflow-wrap:anywhere]">{path}</dt>
        <dd class="whitespace-pre-wrap [overflow-wrap:anywhere]">{now}</dd>
      </div>
    </dl>
    <p :if={@more?} class="mt-1 text-xs text-base-content/60">{gettext("And more.")}</p>
    """
  end

  defp value(assigns) do
    ~H"""
    <p class="max-h-96 overflow-y-auto text-sm whitespace-pre-wrap [overflow-wrap:anywhere]">
      {HistoryWords.value(@field, @value, @manifest)}
    </p>
    """
  end

  attr :values, :map, required: true
  attr :id, :string, required: true

  defp description(assigns) do
    ~H"""
    <div id={@id}>
      <%= cond do %>
        <% @values["description"] in [:emptied, :hidden] -> %>
          <.value field="description" value={@values["description"]} manifest={nil} />
        <% text(@values["description"]) == "" -> %>
          <p class="text-sm text-base-content/60">{gettext("No description.")}</p>
        <% @values["uses_api"] == true -> %>
          <p class="rounded-xl bg-base-200 px-3 py-2 text-sm text-base-content/70">
            {gettext(
              "An app, %{kb} KB. It does not run here, as it would write what it writes today.",
              kb: div(byte_size(@values["description"]) + 1023, 1024)
            )}
          </p>
        <% true -> %>
          <Components.formatted_content
            content={@values["description"]}
            content_format={format(@values["description_format"])}
            class="max-h-96 overflow-y-auto"
          />
      <% end %>
    </div>
    """
  end

  defp format("html"), do: :html
  defp format(_format), do: :markdown

  defp text(value) when is_binary(value), do: value
  defp text(_value), do: ""

  # A record in a line: its first few short values.
  defp gist(%{"data" => data}) when is_map(data) and data != %{} do
    {rows, _more?} = HistoryDiff.paths(nil, data)

    rows
    |> Enum.map(&elem(&1, 2))
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.take(4)
    |> Enum.join(" · ")
    |> String.slice(0, 160)
  end

  defp gist(%{"content" => content}) when is_binary(content), do: String.slice(content, 0, 160)
  defp gist(_values), do: ""

  defp collection_name(%{collection: nil}), do: gettext("Records")
  defp collection_name(%{collection: "config"}), do: gettext("Settings of the app")
  defp collection_name(%{collection: name}), do: name

  defp plural("description"), do: gettext("Alternative descriptions")
  defp plural("process"), do: gettext("Processes")
  defp plural("field"), do: gettext("Fields")
  defp plural("entity"), do: gettext("Entities")
  defp plural("template"), do: gettext("Templates")
  defp plural("poll"), do: dgettext("polls", "Polls")
  defp plural("event"), do: gettext("Events")
end
