defmodule PotokIdeWeb.GroupLive.Show.PollsTab do
  @moduledoc """
  The overview of polls: the group's, or at the root all of the viewer's and the
  public ones. A poll opens beside the list, with its details for those who may
  see them. `PollsState` holds what this draws.
  """

  use PotokIdeWeb, :html

  alias PotokIde.Polls.{Rules, Stats, View}
  alias PotokIde.Social.Access
  alias PotokIdeWeb.GroupLive.Show.{CalendarTab, Components, PollCard, RolesTab}

  attr :group, :map, required: true
  attr :access, :map, required: true
  attr :status, :string, required: true
  attr :rows, :any, required: true, doc: "stream of `Polls.overview/4` rows"
  attr :empty, :boolean, default: true
  attr :more, :boolean, default: false
  attr :detail, :any, default: nil, doc: "`%{view:, group:, stats:}` of the open poll"
  attr :include_subgroups, :boolean, default: false
  attr :show_groups, :boolean, default: true
  attr :show_public, :boolean, default: true

  def panel(assigns) do
    ~H"""
    <div id="group-panel-polls" class="card flex min-h-0 flex-1 flex-col px-2">
      <div data-tab-scroll class="min-h-0 flex-1 overflow-y-auto overscroll-contain pt-4 pb-4">
        <.page_header id="group-polls-header" icon="hero-chart-bar" class="px-1" compact>
          {if(@group.is_root,
            do: dgettext("polls", "My polls"),
            else: dgettext("polls", "Polls")
          )}
          <:subtitle>{scope_text(assigns)}</:subtitle>
          <:actions :if={Rules.can_create?(@access, @group)}>
            <.button
              id="polls-new"
              type="button"
              phx-click="poll_form_open"
              variant="primary"
              size="sm"
            >
              <.icon name="hero-plus" class="size-4" />
              <span>{dgettext("polls", "New poll")}</span>
            </.button>
          </:actions>
        </.page_header>

        <div class={[
          @detail && "lg:grid lg:grid-cols-[minmax(0,1fr)_26rem] lg:items-start lg:gap-4"
        ]}>
          <section id="polls-main" class={["min-w-0", @detail && "hidden lg:block"]}>
            <div
              id="polls-status"
              role="group"
              aria-label={dgettext("polls", "Show polls")}
              class="mb-3 flex flex-wrap items-center gap-1.5 px-1"
            >
              <.link
                :for={{status, label} <- statuses()}
                id={"polls-status-#{status}"}
                patch={status_path(@group, status)}
                aria-current={@status == status && "true"}
                class={status_class(@status == status)}
              >
                {label}
              </.link>
            </div>

            <div
              :if={@group.is_root or @access.member?}
              class="mb-3 flex flex-wrap items-center gap-x-5 gap-y-2 px-1"
            >
              <%= if @group.is_root do %>
                <CalendarTab.switch
                  id="polls-groups-toggle"
                  event="polls_toggle_groups"
                  checked={@show_groups}
                  icon="hero-user-group"
                  label={dgettext("polls", "My groups")}
                />
                <CalendarTab.switch
                  id="polls-public-toggle"
                  event="polls_toggle_public"
                  checked={@show_public}
                  icon="hero-globe-alt"
                  label={dgettext("polls", "Public polls")}
                />
              <% else %>
                <CalendarTab.switch
                  id="polls-subgroups-toggle"
                  event="polls_toggle_subgroups"
                  checked={@include_subgroups}
                  label={dgettext("polls", "Include sub-groups")}
                />
              <% end %>
            </div>

            <div id="polls-list" phx-update="stream" class="flex flex-col gap-2">
              <.row
                :for={{dom_id, row} <- @rows}
                id={dom_id}
                row={row}
                group={@group}
                status={@status}
              />
            </div>

            <div
              :if={@empty}
              id="polls-empty"
              class="flex min-h-48 flex-col items-center justify-center gap-2 rounded-3xl border border-dashed border-base-300 bg-base-100/70 px-6 text-center text-sm text-base-content/65"
            >
              <.icon name="hero-chart-bar" class="size-6 text-base-content/35" />
              {empty_text(@status)}
            </div>

            <div :if={@more} class="mt-3 flex justify-center">
              <.button id="polls-load-more" type="button" phx-click="polls_load_more" size="sm">
                {dgettext("polls", "Load earlier polls")}
              </.button>
            </div>
          </section>

          <aside :if={@detail} id="polls-side" class="min-w-0 lg:sticky lg:top-0">
            <.detail detail={@detail} group={@group} status={@status} />
          </aside>
        </div>
      </div>
    </div>
    """
  end

  defp statuses do
    [
      {"open", dgettext("polls", "Open")},
      {"waiting", dgettext("polls", "Waiting for my vote")},
      {"closed", dgettext("polls", "Finished")}
    ]
  end

  defp status_path(group, "open"), do: ~p"/groups/#{group.id}/polls"
  defp status_path(group, status), do: ~p"/groups/#{group.id}/polls?#{[status: status]}"

  defp row_path(group, status, poll_id) do
    query = if status == "open", do: [poll: poll_id], else: [status: status, poll: poll_id]
    ~p"/groups/#{group.id}/polls?#{query}"
  end

  defp status_class(active?) do
    [
      "inline-flex h-8 items-center rounded-full border px-3 text-xs font-semibold transition duration-150 ease-out active:scale-95",
      if(active?,
        do: "border-primary bg-primary text-primary-content",
        else: "border-base-300 bg-base-100 text-base-content/70 hover:text-base-content"
      )
    ]
  end

  defp empty_text("waiting"), do: dgettext("polls", "No poll is waiting for you.")
  defp empty_text("closed"), do: dgettext("polls", "No finished polls.")
  defp empty_text(_open), do: dgettext("polls", "No polls in progress.")

  defp scope_text(%{group: %{is_root: true}}), do: dgettext("polls", "From all your groups")
  defp scope_text(%{access: %Access{member?: false}}), do: dgettext("polls", "Public polls")
  defp scope_text(%{group: group}), do: group.name

  attr :id, :string, required: true
  attr :row, :map, required: true
  attr :group, :map, required: true
  attr :status, :string, required: true

  defp row(assigns) do
    ~H"""
    <.link
      id={@id}
      patch={row_path(@group, @status, @row.id)}
      class="group/poll flex min-w-0 items-center gap-3 rounded-2xl border border-base-300/70 bg-base-100 px-3 py-2.5 transition duration-150 hover:-translate-y-px hover:border-primary/40"
    >
      <span class={[
        "inline-flex size-9 shrink-0 items-center justify-center rounded-xl",
        row_tone(@row.view)
      ]}>
        <.icon name={row_icon(@row.view)} class="size-5" />
      </span>
      <span class="min-w-0 flex-1">
        <span class="block truncate text-sm font-semibold">{@row.view.question}</span>
        <span class="block truncate text-xs text-base-content/65">
          <span :if={@row.group.id != @group.id}>{@row.group.name <> " · "}</span>{row_status(
            @row.view
          )}
        </span>
      </span>
      <span class="shrink-0 text-xs font-semibold tabular-nums text-base-content/65">
        {@row.view.voters_count}
      </span>
      <.icon
        name="hero-chevron-right"
        class="size-4 shrink-0 opacity-50 transition-transform group-hover/poll:translate-x-0.5"
      />
    </.link>
    """
  end

  defp row_tone(%View{can_vote?: true, voted?: false}), do: "bg-primary text-primary-content"
  defp row_tone(%View{}), do: "bg-base-200 text-base-content/65"

  defp row_icon(%View{secret?: true}), do: "hero-lock-closed"
  defp row_icon(%View{public?: true}), do: "hero-globe-alt"
  defp row_icon(%View{}), do: "hero-chart-bar"

  defp row_status(%View{open?: false}), do: dgettext("polls", "Ended")
  defp row_status(%View{voted?: true}), do: dgettext("polls", "You voted")
  defp row_status(%View{can_vote?: true}), do: dgettext("polls", "Waiting for your vote")
  defp row_status(%View{}), do: dgettext("polls", "In progress")

  attr :detail, :map, required: true
  attr :group, :map, required: true
  attr :status, :string, required: true

  defp detail(assigns) do
    assigns = assign(assigns, :view, assigns.detail.view)

    ~H"""
    <article
      id="poll-detail"
      class="rounded-3xl border border-base-300/70 bg-base-100 p-3 sm:p-4"
      aria-label={@view.question}
    >
      <div class="mb-3 flex items-center justify-between gap-2">
        <.link
          id="poll-detail-close"
          patch={
            if(@status == "open", do: status_path(@group, "open"), else: status_path(@group, @status))
          }
          class="inline-flex items-center gap-1 text-sm font-semibold text-base-content/70 transition-colors hover:text-base-content"
        >
          <.icon name="hero-arrow-left" class="size-4" />
          {dgettext("polls", "All polls")}
        </.link>
        <.link
          :if={@view.group_id != @group.id}
          id="poll-detail-group"
          navigate={~p"/groups/#{@view.group_id}/polls?#{[poll: @view.poll_id]}"}
          class="min-w-0 truncate text-sm font-semibold text-primary underline-offset-2 hover:underline"
        >
          {dgettext("polls", "Open in %{group}", group: @detail.group.name)}
        </.link>
      </div>

      <PollCard.card id="poll-detail-card" view={@view} />

      <.stats :if={@detail.stats} view={@view} stats={@detail.stats} />
      <.removable_options view={@view} />

      <.actions view={@view} group={@group} />
    </article>
    """
  end

  attr :view, View, required: true

  # Those who manage a poll clear out answers nobody chose, which members may
  # have added.
  defp removable_options(assigns) do
    assigns =
      assign(
        assigns,
        :options,
        Enum.filter(assigns.view.options, &(&1.id in assigns.view.removable_option_ids))
      )

    ~H"""
    <section :if={@options != []} id="poll-removable-options" class="mt-4">
      <.stats_title>{dgettext("polls", "Answers without votes")}</.stats_title>
      <ul class="flex flex-col gap-1">
        <li :for={option <- @options} class="flex min-w-0 items-center justify-between gap-2 text-sm">
          <span class="min-w-0 wrap-break-word">{option.text}</span>
          <.icon_button
            id={"poll-remove-option-#{option.id}"}
            type="button"
            phx-click="poll_delete_option"
            phx-value-poll={@view.poll_id}
            phx-value-option={option.id}
            data-confirm={dgettext("polls", "Remove this answer?")}
            icon="hero-x-mark"
            label={dgettext("polls", "Remove answer")}
            size="xs"
          />
        </li>
      </ul>
    </section>
    """
  end

  attr :view, View, required: true
  attr :group, :map, required: true

  defp actions(assigns) do
    ~H"""
    <div
      :if={@view.manage? or @view.results? or @view.details?}
      id="poll-actions"
      class="mt-4 flex flex-wrap items-center gap-2 border-t border-base-300/60 pt-3"
    >
      <.button
        :if={@view.results?}
        id="poll-export-results"
        href={~p"/polls/#{@view.poll_id}/results.csv?#{[part: "results"]}"}
        download
        size="sm"
      >
        <.icon name="hero-arrow-down-tray" class="size-4" />
        {dgettext("polls", "Results (CSV)")}
      </.button>
      <.button
        :if={@view.details?}
        id="poll-export-voters"
        href={~p"/polls/#{@view.poll_id}/results.csv?#{[part: "voters"]}"}
        download
        size="sm"
      >
        <.icon name="hero-arrow-down-tray" class="size-4" />
        {dgettext("polls", "Voters (CSV)")}
      </.button>
      <%= if @view.manage? do %>
        <.button
          :if={@view.open? and @view.group_id == @group.id}
          id="poll-edit"
          type="button"
          phx-click="poll_form_open"
          phx-value-id={@view.poll_id}
          size="sm"
        >
          <.icon name="hero-pencil-square" class="size-4" />
          {if(@view.voters_count > 0,
            do: dgettext("polls", "Change deadline"),
            else: dgettext("polls", "Edit")
          )}
        </.button>
        <.button
          :if={@view.open?}
          id="poll-close"
          type="button"
          phx-click="poll_close"
          phx-value-id={@view.poll_id}
          data-confirm={dgettext("polls", "End this poll now?")}
          size="sm"
        >
          <.icon name="hero-stop-circle" class="size-4" />
          {dgettext("polls", "End the poll")}
        </.button>
        <.button
          :if={!@view.open? and !@view.secret?}
          id="poll-reopen"
          type="button"
          phx-click="poll_reopen"
          phx-value-id={@view.poll_id}
          size="sm"
        >
          <.icon name="hero-arrow-path" class="size-4" />
          {dgettext("polls", "Open again")}
        </.button>
        <.button
          id="poll-delete"
          type="button"
          phx-click="poll_delete"
          phx-value-id={@view.poll_id}
          data-confirm={dgettext("polls", "Delete this poll with all its votes and its message?")}
          variant="ghost"
          size="sm"
        >
          <.icon name="hero-trash" class="size-4" />
          {dgettext("polls", "Delete")}
        </.button>
      <% end %>
    </div>
    """
  end

  attr :view, View, required: true
  attr :stats, :map, required: true

  defp stats(assigns) do
    ~H"""
    <div id="poll-stats" class="mt-4 flex flex-col gap-4">
      <.turnout stats={@stats} />

      <section :if={@stats.by_option != %{}} id="poll-stats-answers">
        <.stats_title>{dgettext("polls", "Who voted for what")}</.stats_title>
        <ul class="flex flex-col gap-3">
          <li :for={option <- @view.options} id={"poll-stats-answer-#{option.id}"} class="min-w-0">
            <p class="mb-1 text-sm font-semibold wrap-break-word">{option.text}</p>
            <.names
              id={"poll-stats-answer-#{option.id}-names"}
              profiles={Map.get(@stats.by_option, option.id, [])}
              empty={dgettext("polls", "Nobody")}
            />
          </li>
        </ul>
      </section>

      <section :if={@view.secret?} id="poll-stats-took-part">
        <.stats_title>{dgettext("polls", "Who took part")}</.stats_title>
        <.names
          id="poll-stats-voters"
          profiles={@stats.voters_list}
          empty={dgettext("polls", "Nobody yet")}
        />
      </section>

      <section :if={@stats.by_role != []} id="poll-stats-roles">
        <.stats_title>{dgettext("polls", "By role")}</.stats_title>
        <ul class="flex flex-col gap-1.5 text-sm">
          <li
            :for={row <- @stats.by_role}
            id={"poll-stats-role-#{row.role.key}"}
            class="flex flex-wrap items-baseline justify-between gap-x-3"
          >
            <span class="min-w-0 font-medium">{RolesTab.role_label(row.role)}</span>
            <span class="text-xs tabular-nums text-base-content/65">
              {role_line(row, @view)}
            </span>
          </li>
          <li
            :if={@stats.outsiders}
            id="poll-stats-outsiders"
            class="flex flex-wrap items-baseline justify-between gap-x-3"
          >
            <span class="min-w-0 font-medium">{dgettext("polls", "Non-members")}</span>
            <span class="text-xs tabular-nums text-base-content/65">
              {outsiders_line(@stats.outsiders, @view)}
            </span>
          </li>
        </ul>
      </section>

      <.timeline points={@stats.timeline} />

      <section id="poll-stats-not-voted">
        <.stats_title>{dgettext("polls", "Have not voted")}</.stats_title>
        <.names
          id="poll-stats-not-voted-names"
          profiles={@stats.not_voted}
          empty={dgettext("polls", "Nobody")}
        />
        <.button
          :if={@view.manage? and @view.open? and @stats.not_voted != []}
          id="poll-nudge"
          type="button"
          phx-click="poll_nudge"
          phx-value-id={@view.poll_id}
          class="mt-2"
          size="sm"
        >
          <.icon name="hero-bell" class="size-4" />
          {dgettext("polls", "Remind them")}
        </.button>
      </section>
    </div>
    """
  end

  slot :inner_block, required: true

  defp stats_title(assigns) do
    ~H"""
    <h4 class="mb-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/65">
      {render_slot(@inner_block)}
    </h4>
    """
  end

  attr :stats, :map, required: true

  defp turnout(assigns) do
    assigns = assign(assigns, :percent, percent(assigns.stats.voters, assigns.stats.eligible))

    ~H"""
    <section id="poll-stats-turnout">
      <.stats_title>{dgettext("polls", "Turnout")}</.stats_title>
      <p class="flex items-baseline gap-2">
        <span class="text-2xl font-bold tabular-nums">{@stats.voters}</span>
        <span :if={@stats.eligible} class="text-sm text-base-content/65">
          {dgettext("polls", "of %{count} who may vote", count: @stats.eligible)}
        </span>
        <span :if={@percent} class="ml-auto text-sm font-semibold tabular-nums">{@percent}%</span>
      </p>
      <div :if={@percent} class="mt-1 h-1.5 overflow-hidden rounded-full bg-base-300">
        <div class="h-full rounded-full bg-primary" style={"width:#{min(@percent, 100)}%"}></div>
      </div>
    </section>
    """
  end

  defp percent(_voters, nil), do: nil
  defp percent(_voters, 0), do: nil
  defp percent(voters, eligible), do: round(voters * 100 / eligible)

  attr :id, :string, required: true
  attr :profiles, :list, required: true
  attr :empty, :string, required: true

  # The first names show; the rest stay a tap away.
  defp names(assigns) do
    {shown, rest} = Enum.split(assigns.profiles, Stats.names_shown())
    assigns = assign(assigns, shown: shown, rest: rest)

    ~H"""
    <p :if={@profiles == []} id={@id} class="text-sm text-base-content/65">{@empty}</p>
    <div :if={@profiles != []} id={@id}>
      <ul class="flex flex-wrap gap-x-3 gap-y-1">
        <li :for={profile <- @shown}>
          <Components.profile_identity profile={profile} avatar_size="size-5" text_class="text-sm" />
        </li>
      </ul>
      <details :if={@rest != []} class="mt-1" phx-mounted={JS.ignore_attributes(["open"])}>
        <summary class="cursor-pointer text-xs font-semibold text-primary">
          {dgettext("polls", "Show all (%{count})", count: length(@profiles))}
        </summary>
        <ul class="mt-1 flex flex-wrap gap-x-3 gap-y-1">
          <li :for={profile <- @rest}>
            <Components.profile_identity
              profile={profile}
              avatar_size="size-5"
              text_class="text-sm"
            />
          </li>
        </ul>
      </details>
    </div>
    """
  end

  defp role_line(%{counts: nil} = row, _view) do
    dgettext("polls", "%{voted} of %{members} voted", voted: row.voted, members: row.members)
  end

  defp role_line(row, %View{} = view) do
    summary = counts_line(row.counts, view)

    dgettext("polls", "%{voted} of %{members}: %{summary}",
      voted: row.voted,
      members: row.members,
      summary: summary
    )
  end

  defp outsiders_line(%{counts: nil, voted: voted}, _view), do: to_string(voted)

  defp outsiders_line(%{counts: counts, voted: voted}, %View{} = view),
    do: "#{voted}: #{counts_line(counts, view)}"

  defp counts_line(counts, %View{options: options}) do
    Enum.map_join(options, ", ", &"#{&1.text} #{Map.get(counts, &1.id, 0)}")
  end

  attr :points, :list, required: true

  # One series over time, so one colour and no legend. The bars rest on the
  # baseline and every column answers on hover; those who cannot hover have the
  # same numbers in the sentence read out for the chart.
  defp timeline(assigns) do
    max_count = assigns.points |> Enum.map(& &1.count) |> Enum.max(fn -> 0 end)
    assigns = assign(assigns, :max_count, max_count)

    ~H"""
    <section :if={length(@points) > 1} id="poll-stats-timeline">
      <.stats_title>{dgettext("polls", "Course of the voting")}</.stats_title>
      <div
        role="img"
        aria-label={timeline_label(@points)}
        class="flex h-16 items-end gap-0.5 border-b border-base-300"
      >
        <div
          :for={point <- @points}
          title={"#{point_label(point)}: #{point.count}"}
          class="flex h-full min-w-0 max-w-6 flex-1 items-end"
        >
          <div
            class="w-full rounded-t bg-primary"
            style={"height:#{max(round(point.count * 100 / @max_count), 6)}%"}
          >
          </div>
        </div>
      </div>
      <div class="mt-1 flex justify-between text-xs tabular-nums text-base-content/65">
        <span>{point_label(hd(@points))}</span>
        <span>{point_label(List.last(@points))}</span>
      </div>
    </section>
    """
  end

  defp timeline_label(points) do
    Enum.map_join(points, ", ", &"#{point_label(&1)}: #{&1.count}")
  end

  defp point_label(%{at: at, step: :hour}), do: Calendar.strftime(at, "%d.%m. %H:%M")
  defp point_label(%{at: at, step: :day}), do: Calendar.strftime(at, "%d.%m.")
end
