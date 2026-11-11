defmodule PotokIdeWeb.GroupLive.Show.ValueSearch do
  @moduledoc """
  The search of a group's messages, opened from the magnifier in the header
  while the chat shows. `GroupLive.Show` delegates every `"value_search_*"`
  event here.

  It is a modal `<dialog>` (the whole screen on a phone, where the keyboard
  needs the room): a box, and the messages found, newest first, a page at a
  time. Case, diacritics and script do not count, and members also search
  the threads they are in (`Social.search_group_values/3`). A message of this
  chat opens in the feed through `potok:show-value`, as a reply quote does,
  which loads the chat around it when it is not loaded; one from a thread
  opens that thread at it.
  """

  use PotokIdeWeb, :html

  import Phoenix.LiveView, only: [stream: 3, stream: 4, stream_configure: 3]

  alias PotokIde.Events.Format
  alias PotokIde.{PlainText, RateLimit, Social}
  alias PotokIde.Social.{Access, NameSearch, Value}
  alias PotokIdeWeb.Avatars
  alias PotokIdeWeb.GroupLive.Show.Components

  @min_length 2
  # Graphemes of a message shown before the first match.
  @lead 40

  @doc "The assigns and the stream of results a page starts with."
  def init(socket) do
    socket
    |> assign(:value_search, nil)
    |> stream_configure(:value_search_results, dom_id: &"value-search-result-#{&1.id}")
    |> stream(:value_search_results, [])
  end

  @doc "Whether the page offers the search: while a chat it may read shows."
  def available?(group, active_tab, access) do
    active_tab == "values" and group.parent_id != nil and Access.can_read_chat?(access, group)
  end

  def handle_event("value_search_open", _params, socket) do
    if available?(socket.assigns.group, socket.assigns.active_tab, socket.assigns.access) do
      {:noreply, socket |> assign(:value_search, new_state("")) |> reset_results()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("value_search_close", _params, socket) do
    {:noreply, socket |> assign(:value_search, nil) |> reset_results()}
  end

  def handle_event("value_search_change", %{"value_search" => %{"q" => query}}, socket)
      when is_binary(query) do
    {:noreply, search(socket, query)}
  end

  def handle_event("value_search_reset", _params, socket) do
    {:noreply, search(socket, "")}
  end

  def handle_event("value_search_more", _params, socket) do
    case socket.assigns.value_search do
      %{more?: true, query: query, oldest_id: oldest_id} ->
        {:noreply, search(socket, query, oldest_id)}

      _state ->
        {:noreply, socket}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp new_state(query) do
    %{
      form: to_form(%{"q" => query}, as: :value_search),
      query: query,
      status: :idle,
      more?: false,
      oldest_id: nil
    }
  end

  defp reset_results(socket), do: stream(socket, :value_search_results, [], reset: true)

  # A first page replaces the results; a next one (`before_id`) adds to them.
  defp search(socket, query, before_id \\ nil) do
    %{group: group, access: access, current_profile: profile} = socket.assigns
    state = %{new_state(query) | oldest_id: before_id}
    term = NameSearch.term(query)

    cond do
      socket.assigns.value_search == nil or
          not available?(group, socket.assigns.active_tab, access) ->
        socket

      term == nil or String.length(String.trim(query)) < @min_length ->
        socket |> assign(:value_search, state) |> reset_results()

      RateLimit.hit(:value_search, rate_key(profile)) != :ok ->
        assign(socket, :value_search, %{state | status: :rate_limited})

      true ->
        case Social.search_group_values(group, term,
               threads_for: if(access.member?, do: profile),
               outsider: not access.member?,
               before_id: before_id
             ) do
          {:ok, {values, more?}} ->
            status = if values == [] and before_id == nil, do: :empty, else: :found

            socket
            |> assign(:value_search, %{
              state
              | status: status,
                more?: more?,
                oldest_id: oldest_id(values, before_id)
            })
            |> stream(:value_search_results, values, reset: before_id == nil)

          {:error, :timeout} ->
            assign(socket, :value_search, %{state | status: :timeout})
        end
    end
  end

  defp rate_key(nil), do: {:page, self()}
  defp rate_key(profile), do: profile.id

  defp oldest_id([], before_id), do: before_id
  defp oldest_id(values, _before_id), do: List.last(values).id

  @doc """
  The message as one line of plain text that starts shortly before the
  first place the query matches, so the match shows in a short row.
  """
  def snippet(%Value{content: content, content_format: format}, query) do
    text = PlainText.excerpt(content, format, 2_000) || ""

    lead =
      text
      |> PotokIde.TextFold.segments(query)
      |> Enum.take_while(&(not &1.match?))
      |> Enum.map(&String.length(&1.text))
      |> Enum.sum()

    if lead > @lead do
      "…" <> String.trim_leading(String.slice(text, (lead - @lead)..-1//1))
    else
      text
    end
  end

  attr :state, :map, default: nil, doc: "the `@value_search` assign"
  attr :results, :any, required: true
  attr :group, :map, required: true
  attr :member, :boolean, default: false
  attr :time_zone, :string, default: "Etc/UTC"

  @doc """
  The dialog, while open. Escape and Android's back button close it through
  the server, as `PollForm.dialog/1` does.
  """
  def dialog(assigns) do
    ~H"""
    <dialog
      :if={@state}
      id="value-search-dialog"
      phx-hook=".ValueSearchDialog"
      phx-mounted={JS.ignore_attributes(["open"])}
      aria-labelledby="value-search-title"
      class="fixed inset-0 m-0 size-full max-h-none max-w-none overflow-hidden bg-transparent p-0 backdrop:bg-transparent"
    >
      <div class="flex h-[var(--app-visual-height,100dvh)] w-full items-start justify-center sm:h-full sm:p-4 sm:pt-[8vh]">
        <div
          id="value-search-backdrop"
          class="absolute inset-0 bg-black/30 backdrop-blur-[2px] dark:bg-black/60"
          phx-click="value_search_close"
          aria-hidden="true"
        >
        </div>
        <section class="relative flex h-full w-full flex-col overflow-hidden bg-base-100 pt-(--app-safe-area-top) pb-(--app-safe-area-bottom) text-base-content shadow-2xl shadow-base-content/10 sm:h-auto sm:max-h-[80dvh] sm:max-w-lg sm:rounded-3xl sm:border sm:border-base-300/70 sm:pt-0 sm:pb-0">
          <header class="flex items-center gap-2 border-b border-base-300/60 px-3 py-3 sm:px-4">
            <h2 id="value-search-title" class="sr-only">{gettext("Search messages")}</h2>
            <.form
              for={@state.form}
              id="value-search-form"
              phx-change="value_search_change"
              phx-submit="value_search_change"
              class="relative min-w-0 flex-1"
            >
              <.icon
                name="hero-magnifying-glass"
                class="pointer-events-none absolute left-3.5 top-1/2 size-4 -translate-y-1/2 text-base-content/55"
              />
              <.input
                field={@state.form[:q]}
                id="value-search-input"
                type="search"
                phx-debounce="300"
                autocomplete="off"
                autofocus
                enterkeyhint="search"
                maxlength="120"
                placeholder={gettext("Search messages")}
                aria-label={gettext("Search messages")}
                class="h-11 w-full rounded-full border border-base-300 bg-base-200/60 pr-11 pl-10 text-base transition-colors duration-150 placeholder:text-base-content/50 focus:border-primary/60 focus:bg-base-100 focus:outline-none sm:text-sm [&::-webkit-search-cancel-button]:hidden"
              />
              <%!-- Clears in the browser, which then sends the change, as typing does. --%>
              <button
                :if={@state.query != ""}
                id="value-search-clear"
                type="button"
                data-clear-search
                aria-label={gettext("Clear search")}
                class="absolute right-1.5 top-1/2 inline-flex size-8 -translate-y-1/2 cursor-pointer items-center justify-center rounded-full text-base-content/60 transition-colors duration-150 hover:bg-base-300/60 hover:text-base-content focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </.form>
            <.icon_button
              id="value-search-close"
              type="button"
              phx-click="value_search_close"
              icon="hero-x-mark"
              label={gettext("Close")}
            />
          </header>

          <div
            id="value-search-body"
            class="min-h-0 flex-1 overflow-y-auto overscroll-contain px-2 py-2 sm:px-3"
          >
            <p
              :if={@state.status != :found}
              id={"value-search-status-#{@state.status}"}
              class="flex items-start gap-2.5 px-3 py-4 text-sm text-base-content/65"
            >
              <.icon name={status_icon(@state.status)} class="mt-0.5 size-4 shrink-0" />
              <span>{status_text(@state.status, @member)}</span>
            </p>

            <ul id="value-search-results" phx-update="stream" class="flex flex-col">
              <li :for={{dom_id, value} <- @results} id={dom_id}>
                <.result
                  value={value}
                  group={@group}
                  query={@state.query}
                  time_zone={@time_zone}
                />
              </li>
            </ul>

            <div :if={@state.more?} class="flex justify-center py-3">
              <.button id="value-search-more" type="button" phx-click="value_search_more" size="sm">
                {gettext("Show more")}
              </.button>
            </div>
          </div>
        </section>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".ValueSearchDialog">
        export default {
          mounted() {
            this.el.addEventListener("cancel", event => {
              event.preventDefault()
              this.pushEvent("value_search_close", {})
            })

            this.el.addEventListener("click", event => {
              if (!event.target.closest("[data-clear-search]")) return
              const input = this.el.querySelector("#value-search-input")
              input.value = ""
              input.dispatchEvent(new Event("input", { bubbles: true }))
              input.focus()
            })

            this.el.showModal()
          },

          updated() {
            if (!this.el.open) this.el.showModal()
          },
        }
      </script>
    </dialog>
    """
  end

  attr :value, Value, required: true
  attr :group, :map, required: true
  attr :query, :string, required: true
  attr :time_zone, :string, required: true

  # A message of this chat opens in its feed; one from a thread, the thread.
  defp result(assigns) do
    assigns =
      assigns
      |> assign(:thread?, assigns.value.group_id != assigns.group.id)
      |> assign(:snippet, snippet(assigns.value, assigns.query))

    ~H"""
    <.link
      :if={@thread?}
      id={"value-search-open-#{@value.id}"}
      navigate={~p"/groups/#{@value.group_id}/values?#{[value: @value.id]}"}
      class={result_class()}
    >
      <.result_body value={@value} snippet={@snippet} query={@query} time_zone={@time_zone} thread />
    </.link>
    <button
      :if={!@thread?}
      id={"value-search-open-#{@value.id}"}
      type="button"
      phx-click={
        JS.dispatch("potok:show-value", to: "#group-values-feed", detail: %{id: @value.id})
        |> JS.push("value_search_close")
      }
      class={result_class()}
    >
      <.result_body value={@value} snippet={@snippet} query={@query} time_zone={@time_zone} />
    </button>
    """
  end

  defp result_class do
    "flex w-full cursor-pointer items-start gap-3 rounded-2xl px-3 py-2.5 text-left transition-colors duration-150 hover:bg-base-200 focus-visible:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-primary/40"
  end

  attr :value, Value, required: true
  attr :snippet, :string, required: true
  attr :query, :string, required: true
  attr :time_zone, :string, required: true
  attr :thread, :boolean, default: false

  defp result_body(assigns) do
    ~H"""
    <img
      src={Avatars.profile_avatar_url(@value.creator)}
      alt=""
      class="mt-0.5 size-9 shrink-0 rounded-full border border-base-300 object-cover"
    />
    <span class="min-w-0 flex-1">
      <span class="flex min-w-0 items-center gap-2 text-xs leading-5">
        <span class="truncate font-semibold text-base-content">{@value.creator.username}</span>
        <span
          :if={@thread}
          class="inline-flex shrink-0 items-center gap-1 rounded-full bg-primary/10 px-2 font-medium text-primary"
        >
          <.icon name="hero-chat-bubble-left-right" class="size-3" />
          {gettext("In a thread")}
        </span>
        <time
          datetime={DateTime.to_iso8601(@value.inserted_at)}
          class="ml-auto shrink-0 tabular-nums text-base-content/60"
        >
          {Format.recent(@value.inserted_at, @time_zone, DateTime.utc_now())}
        </time>
      </span>
      <span class="mt-0.5 line-clamp-2 text-sm text-base-content/80 wrap-break-word">
        <Components.highlighted_text text={@snippet} query={@query} />
      </span>
    </span>
    """
  end

  defp status_icon(:idle), do: "hero-magnifying-glass"
  defp status_icon(:empty), do: "hero-face-frown"
  defp status_icon(_status), do: "hero-clock"

  defp status_text(:idle, true),
    do:
      gettext(
        "Type at least two letters. Diacritics, Latin or Cyrillic do not matter, and the threads you are in are searched too."
      )

  defp status_text(:idle, false),
    do: gettext("Type at least two letters. Diacritics, Latin or Cyrillic do not matter.")

  defp status_text(:empty, _member), do: gettext("No messages with those words.")

  defp status_text(:timeout, _member),
    do: gettext("The search took too long. Try more exact words.")

  defp status_text(:rate_limited, _member),
    do: gettext("Too many searches in a short time. Wait a moment and try again.")
end
