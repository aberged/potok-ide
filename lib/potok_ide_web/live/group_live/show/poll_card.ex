defmodule PotokIdeWeb.GroupLive.Show.PollCard do
  @moduledoc """
  A poll as a card: in place of the text of its message in the chat, in the
  overview, and in the dialog over an app. It draws only from
  `PotokIde.Polls.View`, which holds what the viewer may see. Without one it says
  no more than that this is a poll.

  Who may vote sees the form, and after voting the bars, never both. The numbers
  are not in the card: `PollsState` keeps them in a style sheet of the page, so
  that a vote changes those rules and no message is sent again, and what a viewer
  may not see never reaches the page.

  The form sits in a `phx-update="ignore"`, as a stream puts a message back for
  any reason, say a reaction, and that would clear a choice not yet sent. The
  id holds `form_key`, so the form changes when its answers or the viewer's ballot
  do.
  """

  use PotokIdeWeb, :html

  alias PotokIde.Polls.View
  alias PotokIdeWeb.GroupLive.Show.{Components, RolesTab}

  attr :id, :string, required: true, doc: "unique on the page, as a poll can show twice"
  attr :view, :any, default: nil, doc: "the viewer's `PotokIde.Polls.View`"
  attr :mine, :boolean, default: false, doc: "in the bubble of the viewer's own message"

  attr :details_path, :string,
    default: nil,
    doc: "where its details open; without it the card shows no link"

  def card(%{view: %View{scope: :full}} = assigns) do
    ~H"""
    <section
      id={@id}
      data-poll-card={@view.poll_id}
      aria-label={@view.question}
      class={["min-w-0 rounded-2xl p-3", surface(@mine)]}
    >
      <.heading view={@view} mine={@mine} />
      <p class="mt-1 font-semibold wrap-break-word">{@view.question}</p>
      <div :if={@view.description != ""} class="mt-1 text-sm">
        <Components.formatted_content content={@view.description} content_format={:markdown} />
      </div>

      <.outcome :if={@view.outcome} view={@view} mine={@mine} />

      <div class="mt-3">
        <%= cond do %>
          <% @view.can_vote? and !@view.voted? -> %>
            <.voting id={@id} view={@view} mine={@mine} />
          <% @view.voted? and @view.can_vote? -> %>
            <div id={"#{@id}-shown"}>
              <.results :if={@view.results?} view={@view} mine={@mine} />
              <.answers :if={!@view.results?} view={@view} mine={@mine} />
            </div>
            <div id={"#{@id}-changing"} class="hidden">
              <.voting id={@id} view={@view} mine={@mine} />
            </div>
          <% @view.results? -> %>
            <.results view={@view} mine={@mine} />
          <% true -> %>
            <.answers view={@view} mine={@mine} />
        <% end %>
      </div>

      <.add_option :if={@view.can_add_option?} id={@id} view={@view} mine={@mine} />
      <.notes id={@id} view={@view} mine={@mine} details_path={@details_path} />
    </section>
    """
  end

  # Someone outside of a poll for members, or a path that brought no view: this
  # says no more than the message's text would.
  def card(assigns) do
    ~H"""
    <section id={@id} class={["min-w-0 rounded-2xl p-3", surface(@mine)]}>
      <p class={[
        "flex items-center gap-1.5 text-[11px] font-semibold uppercase tracking-wide",
        muted(@mine)
      ]}>
        <.icon name="hero-chart-bar" class="size-3.5" />
        {dgettext("polls", "Poll")}
      </p>
      <%= if @view do %>
        <p class="mt-1 font-semibold wrap-break-word">{@view.question}</p>
        <p class={["mt-1 flex items-center gap-1.5 text-xs", muted(@mine)]}>
          <.icon name="hero-lock-closed" class="size-3.5 shrink-0" />
          {dgettext("polls", "Members of the group vote here.")}
        </p>
      <% end %>
    </section>
    """
  end

  @doc "Where the details of the poll open: the overview of its group."
  def details_path(%View{group_id: group_id, poll_id: poll_id}) do
    ~p"/groups/#{group_id}/polls?#{[poll: poll_id]}"
  end

  attr :view, :any, default: nil, doc: "the `@poll_dialog` assign"

  @doc """
  The poll in a modal `<dialog>` over an app, which only reads polls: voting takes
  place on Potok's own page.
  """
  def dialog(assigns) do
    ~H"""
    <dialog
      :if={@view}
      id="poll-dialog"
      phx-hook=".PollDialog"
      phx-mounted={JS.ignore_attributes(["open"])}
      aria-label={@view.question}
      class="fixed inset-0 m-0 size-full max-h-none max-w-none overflow-hidden bg-transparent p-0 backdrop:bg-transparent"
    >
      <div class="flex size-full items-end justify-center sm:items-center sm:p-4">
        <div
          id="poll-dialog-backdrop"
          class="absolute inset-0 bg-black/30 backdrop-blur-[2px] dark:bg-black/60"
          phx-click="poll_dialog_close"
          aria-hidden="true"
        >
        </div>
        <section
          tabindex="-1"
          autofocus
          class="relative flex max-h-[85dvh] w-full flex-col overflow-hidden rounded-t-3xl border border-b-0 border-base-300/70 bg-base-100 text-base-content shadow-2xl shadow-base-content/10 outline-none sm:max-w-md sm:rounded-3xl sm:border-b"
        >
          <div class="flex justify-end px-2 pt-2">
            <.icon_button
              id="poll-dialog-close"
              type="button"
              phx-click="poll_dialog_close"
              icon="hero-x-mark"
              label={dgettext("polls", "Close")}
            />
          </div>
          <div class="min-h-0 flex-1 overflow-y-auto px-3 pb-[calc(0.75rem+var(--app-safe-area-bottom))] sm:pb-3">
            <.card id="poll-dialog-card" view={@view} details_path={details_path(@view)} />
          </div>
        </section>
      </div>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".PollDialog">
      export default {
        mounted() {
          // Escape and Android's back button close it through the server.
          this.el.addEventListener("cancel", event => {
            event.preventDefault()
            this.pushEvent("poll_dialog_close", {})
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

  defp surface(true), do: "bg-primary-content/10"
  defp surface(false), do: "bg-base-200/70"

  defp muted(true), do: "text-primary-content/90"
  defp muted(false), do: "text-base-content/65"

  attr :view, View, required: true
  attr :mine, :boolean, required: true

  defp heading(assigns) do
    ~H"""
    <p class={[
      "flex items-center gap-1.5 text-[11px] font-semibold uppercase tracking-wide",
      muted(@mine)
    ]}>
      <.icon name={heading_icon(@view)} class="size-3.5" />
      {heading_label(@view)}
    </p>
    """
  end

  defp heading_icon(%View{secret?: true}), do: "hero-lock-closed"
  defp heading_icon(%View{public?: true}), do: "hero-globe-alt"
  defp heading_icon(%View{}), do: "hero-chart-bar"

  defp heading_label(%View{open?: false}), do: dgettext("polls", "Voting ended")
  defp heading_label(%View{secret?: true}), do: dgettext("polls", "Secret poll")
  defp heading_label(%View{public?: true}), do: dgettext("polls", "Public poll")
  defp heading_label(%View{}), do: dgettext("polls", "Poll")

  attr :id, :string, required: true
  attr :view, View, required: true
  attr :mine, :boolean, required: true

  defp voting(%{view: %View{one_tap?: true}} = assigns) do
    ~H"""
    <div id={"#{@id}-form-#{@view.form_key}"} phx-update="ignore">
      <ul class="flex flex-col gap-1.5" aria-label={dgettext("polls", "Answers")}>
        <li :for={option <- @view.options}>
          <button
            id={"#{@id}-vote-#{option.id}"}
            type="button"
            phx-click="poll_vote"
            phx-value-poll={@view.poll_id}
            phx-value-option={option.id}
            aria-pressed={to_string(option.mine?)}
            class={[row_class(@mine), option.mine? && chosen_class(@mine)]}
          >
            <span class="min-w-0 flex-1 wrap-break-word">{option.text}</span>
          </button>
        </li>
      </ul>
    </div>
    """
  end

  defp voting(assigns) do
    ~H"""
    <div id={"#{@id}-form-#{@view.form_key}"} phx-update="ignore">
      <form id={"#{@id}-ballot"} phx-submit="poll_vote">
        <input type="hidden" name="poll" value={@view.poll_id} />
        <fieldset class="flex flex-col gap-1.5">
          <legend class="sr-only">{dgettext("polls", "Answers")}</legend>
          <label :for={option <- @view.options} class={[row_class(@mine), checked_class(@mine)]}>
            <input
              type={if(@view.kind == :single, do: "radio", else: "checkbox")}
              name="option_ids[]"
              value={option.id}
              checked={option.mine?}
              class="peer sr-only"
            />
            <span class={[
              "grid size-4 shrink-0 place-items-center border transition duration-150",
              if(@view.kind == :single, do: "rounded-full", else: "rounded"),
              mark_class(@mine)
            ]}>
            </span>
            <span class="min-w-0 flex-1 wrap-break-word">{option.text}</span>
          </label>
        </fieldset>
        <p
          :if={@view.kind == :multiple and @view.max_choices}
          class={["mt-1.5 text-xs", muted(@mine)]}
        >
          {dgettext("polls", "Up to %{count} answers.", count: @view.max_choices)}
        </p>
        <p :if={!@view.allow_change?} class={["mt-1.5 text-xs", muted(@mine)]}>
          {dgettext("polls", "A vote cannot be changed.")}
        </p>
        <button
          id={"#{@id}-submit"}
          type="submit"
          class={[
            "mt-2 inline-flex h-9 cursor-pointer items-center justify-center rounded-full px-4 text-sm font-semibold transition duration-150 active:scale-95 phx-submit-loading:opacity-70",
            if(@mine,
              do: "bg-primary-content text-primary hover:opacity-90",
              else: "bg-primary text-primary-content hover:opacity-90"
            )
          ]}
        >
          {dgettext("polls", "Cast vote")}
        </button>
      </form>
    </div>
    """
  end

  defp row_class(mine?) do
    [
      "flex w-full min-w-0 cursor-pointer items-center gap-2 rounded-xl border px-3 py-2 text-left text-sm transition duration-150 active:scale-[.99] has-focus-visible:ring-2 focus-visible:outline-none focus-visible:ring-2",
      if(mine?,
        do:
          "border-primary-content/30 hover:bg-primary-content/15 has-focus-visible:ring-primary-content/50 focus-visible:ring-primary-content/50",
        else:
          "border-base-300 bg-base-100 hover:border-primary/50 hover:bg-base-100 has-focus-visible:ring-primary/40 focus-visible:ring-primary/40"
      )
    ]
  end

  defp chosen_class(true), do: "border-primary-content bg-primary-content/15 font-semibold"
  defp chosen_class(false), do: "border-primary bg-primary/10 font-semibold"

  defp checked_class(true), do: "has-checked:border-primary-content has-checked:font-semibold"
  defp checked_class(false), do: "has-checked:border-primary has-checked:bg-primary/10"

  defp mark_class(true) do
    "border-primary-content/60 peer-checked:border-primary-content peer-checked:bg-primary-content peer-checked:shadow-[inset_0_0_0_3px_var(--color-primary)]"
  end

  defp mark_class(false) do
    "border-base-content/40 peer-checked:border-primary peer-checked:bg-primary peer-checked:shadow-[inset_0_0_0_3px_var(--color-base-100)]"
  end

  attr :view, View, required: true
  attr :mine, :boolean, required: true

  defp results(assigns) do
    ~H"""
    <ul class="flex flex-col gap-2.5" aria-label={dgettext("polls", "Results")}>
      <li :for={option <- @view.options} class="min-w-0">
        <div class="flex items-baseline justify-between gap-3 text-sm">
          <span class="flex min-w-0 items-center gap-1.5 wrap-break-word">
            <.icon :if={option.mine?} name="hero-check-circle-mini" class="size-4 shrink-0" />
            <span class={["min-w-0", option.id == @view.winner_option_id && "font-semibold"]}>
              {option.text}
            </span>
          </span>
          <span class={[
            "poll-count-#{option.id} shrink-0 text-xs tabular-nums",
            muted(@mine)
          ]}>
          </span>
        </div>
        <div class={[
          "mt-1 h-1.5 overflow-hidden rounded-full",
          if(@mine, do: "bg-primary-content/20", else: "bg-base-300")
        ]}>
          <div class={[
            "poll-bar-#{option.id} h-full w-0 rounded-full transition-[width] duration-300 ease-out",
            if(@mine, do: "bg-primary-content", else: "bg-primary")
          ]}>
          </div>
        </div>
      </li>
    </ul>
    """
  end

  attr :view, View, required: true
  attr :mine, :boolean, required: true

  # The answers with no numbers, for whoever may not see them yet.
  defp answers(assigns) do
    ~H"""
    <ul class="flex flex-col gap-1 text-sm" aria-label={dgettext("polls", "Answers")}>
      <li :for={option <- @view.options} class="flex min-w-0 items-center gap-1.5">
        <.icon
          name={if(option.mine?, do: "hero-check-circle-mini", else: "hero-minus-mini")}
          class={["size-4 shrink-0", !option.mine? && "opacity-40"]}
        />
        <span class="min-w-0 wrap-break-word">{option.text}</span>
      </li>
    </ul>
    """
  end

  attr :view, View, required: true
  attr :mine, :boolean, required: true

  defp outcome(assigns) do
    ~H"""
    <p class={[
      "mt-2 inline-flex max-w-full items-center gap-1.5 rounded-full px-2.5 py-1 text-xs font-semibold",
      if(@mine, do: "bg-primary-content/15", else: "bg-base-100")
    ]}>
      <.icon name={outcome_icon(@view.outcome)} class="size-4 shrink-0" />
      <span class="min-w-0 truncate">{outcome_text(@view)}</span>
    </p>
    """
  end

  defp outcome_icon(:passed), do: "hero-check-badge"
  defp outcome_icon(_outcome), do: "hero-no-symbol"

  defp outcome_text(%View{outcome: :passed} = view) do
    winner = Enum.find(view.options, &(&1.id == view.winner_option_id))

    if winner,
      do: dgettext("polls", "Decided: %{answer}", answer: winner.text),
      else: dgettext("polls", "Decided")
  end

  defp outcome_text(%View{outcome: :failed}), do: dgettext("polls", "Not decided")
  defp outcome_text(%View{outcome: :no_quorum}), do: dgettext("polls", "No quorum")
  defp outcome_text(%View{outcome: :tie}), do: dgettext("polls", "Tied")

  attr :id, :string, required: true
  attr :view, View, required: true
  attr :mine, :boolean, required: true

  defp add_option(assigns) do
    ~H"""
    <form
      id={"#{@id}-add-option"}
      phx-submit={JS.push("poll_add_option") |> JS.dispatch("reset")}
      class="mt-2 flex items-center gap-2"
    >
      <input type="hidden" name="poll" value={@view.poll_id} />
      <input
        type="text"
        name="text"
        required
        maxlength={PotokIde.Polls.PollOption.max_text()}
        placeholder={dgettext("polls", "Your answer")}
        aria-label={dgettext("polls", "Your answer")}
        class={[
          "h-9 min-w-0 flex-1 rounded-full border bg-transparent px-3 text-sm outline-none transition focus-visible:ring-2",
          if(@mine,
            do:
              "border-primary-content/30 placeholder:text-primary-content/70 focus-visible:ring-primary-content/50",
            else: "border-base-300 focus-visible:ring-primary/40"
          )
        ]}
      />
      <button
        type="submit"
        aria-label={dgettext("polls", "Add answer")}
        title={dgettext("polls", "Add answer")}
        class={[icon_button_class("ghost", "sm"), "shrink-0"]}
      >
        <.icon name="hero-plus" class="size-4" />
      </button>
    </form>
    """
  end

  attr :id, :string, required: true
  attr :view, View, required: true
  attr :mine, :boolean, required: true
  attr :details_path, :string, default: nil

  defp notes(assigns) do
    assigns = assign(assigns, :note, standing_note(assigns.view))

    ~H"""
    <p :if={@note} class={["mt-2 text-xs", muted(@mine)]}>{@note}</p>
    <p class={["mt-2 flex flex-wrap items-center gap-x-3 gap-y-1 text-xs", muted(@mine)]}>
      <span>
        {dgettext("polls", "Voted:")}
        <span class={"poll-voters-#{@view.poll_id} tabular-nums"}></span>
      </span>
      <span :if={@view.open? and @view.closes_at}>
        {dgettext("polls", "Until")}
        <Components.local_time id={"#{@id}-closes"} datetime={@view.closes_at} />
      </span>
      <button
        :if={@view.voted? and @view.can_vote?}
        id={"#{@id}-change"}
        type="button"
        phx-click={JS.toggle(to: "##{@id}-shown") |> JS.toggle(to: "##{@id}-changing")}
        class="cursor-pointer font-semibold underline-offset-2 hover:underline"
      >
        {dgettext("polls", "Change vote")}
      </button>
      <.link
        :if={@details_path}
        id={"#{@id}-details"}
        patch={@details_path}
        class="font-semibold underline-offset-2 hover:underline"
      >
        {details_label(@view)}
      </.link>
    </p>
    <p class={["mt-2 flex items-start gap-1.5 text-xs", muted(@mine)]}>
      <.icon
        name={if(@view.secret?, do: "hero-lock-closed", else: "hero-eye")}
        class="mt-px size-3.5 shrink-0"
      />
      <span class="min-w-0">{who_sees(@view)}</span>
    </p>
    """
  end

  # What stands between the viewer and a vote, or what has become of it.
  defp standing_note(%View{voted_with_other_profile?: true}),
    do: dgettext("polls", "Another profile of yours has already voted.")

  defp standing_note(%View{voted?: true, results?: false}),
    do: dgettext("polls", "Your vote is recorded.")

  defp standing_note(%View{voted?: true}), do: nil

  defp standing_note(%View{open?: true, voter_roles: []}),
    do: dgettext("polls", "Nobody can vote any more.")

  defp standing_note(%View{vote_block: :role} = view) do
    dgettext("polls", "Only these vote: %{roles}.", roles: role_names(view.voter_roles))
  end

  defp standing_note(%View{vote_block: :not_permitted}),
    do: dgettext("polls", "Your roles do not allow voting.")

  defp standing_note(%View{vote_block: :blocked}),
    do: dgettext("polls", "You cannot vote in this group.")

  defp standing_note(%View{public?: true}),
    do:
      dgettext("polls", "Anyone signed in can vote, so this shows a mood, not a count of people.")

  defp standing_note(%View{}), do: nil

  defp who_sees(%View{secret?: true}) do
    dgettext("polls", "Neither the group's admins nor the app can see who voted for what.")
  end

  defp who_sees(%View{detail_roles: roles}) do
    cond do
      Enum.any?(roles, &(&1.key == "everyone")) ->
        dgettext("polls", "Every member can see who voted for what.")

      roles == [] ->
        dgettext("polls", "The organizer and those who manage polls can see who voted for what.")

      true ->
        dgettext(
          "polls",
          "The organizer, those who manage polls and these roles can see who voted for what: %{roles}.",
          roles: role_names(roles)
        )
    end
  end

  defp role_names(roles), do: Enum.map_join(roles, ", ", &RolesTab.role_label/1)

  defp details_label(%View{details?: true}), do: dgettext("polls", "Details")
  defp details_label(%View{}), do: dgettext("polls", "View")
end
