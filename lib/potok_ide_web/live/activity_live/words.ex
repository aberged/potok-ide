defmodule PotokIdeWeb.ActivityLive.Words do
  @moduledoc """
  The words of a profile's timeline (`PotokIde.Activity`): what an entry is, what
  it says and where it leads.

  What an entry is comes as a name of a thing ("Message", "Vote in a poll"),
  never as what someone did, which Serbian would put in the gender of whoever
  did it. Such names have a context of their own in Gettext, as the same English
  word names a button elsewhere.
  """

  use Gettext, backend: PotokIdeWeb.Gettext
  use PotokIdeWeb, :verified_routes

  alias PotokIde.Activity
  alias PotokIde.Events.{Event, Format, Recurrence}
  alias PotokIde.Social.Profile
  alias PotokIde.Tags.Tag
  alias PotokIdeWeb.GroupLive.Show.RolesTab

  @doc "What a filter shows."
  def filter(:all), do: pgettext("activity", "All")
  def filter(:messages), do: pgettext("activity", "Messages")
  def filter(:files), do: pgettext("activity", "Files and pictures")
  def filter(:given), do: pgettext("activity", "My reactions")
  def filter(:received), do: pgettext("activity", "Reactions to mine")
  def filter(:votes), do: pgettext("activity", "Polls")
  def filter(:events), do: pgettext("activity", "Events")
  def filter(:groups), do: pgettext("activity", "Groups")
  def filter(:work), do: pgettext("activity", "Processes and records")
  def filter(:notices), do: pgettext("activity", "Notices and tags")

  @doc "The icon of a filter."
  def filter_icon(:all), do: "hero-queue-list"
  def filter_icon(:messages), do: "hero-chat-bubble-oval-left"
  def filter_icon(:files), do: "hero-paper-clip"
  def filter_icon(:given), do: "hero-face-smile"
  def filter_icon(:received), do: "hero-heart"
  def filter_icon(:votes), do: "hero-chart-bar"
  def filter_icon(:events), do: "hero-calendar-days"
  def filter_icon(:groups), do: "hero-user-group"
  def filter_icon(:work), do: "hero-arrow-path-rounded-square"
  def filter_icon(:notices), do: "hero-bell"

  @doc "What there is none of, for an empty list."
  def none(:all),
    do: gettext("Nothing here yet. What you write, react to and vote in shows up here.")

  def none(:messages), do: gettext("No messages of yours in the groups you read.")
  def none(:files), do: gettext("No files or pictures of yours in the groups you read.")
  def none(:given), do: gettext("You have not reacted to anything yet.")
  def none(:received), do: gettext("No one has reacted to a message of yours yet.")
  def none(:votes), do: gettext("No polls you voted in or started.")
  def none(:events), do: gettext("No events you answered or added.")
  def none(:groups), do: gettext("No groups you made, joined or left.")

  def none(:work),
    do: gettext("No forms, decisions, processes or records of yours.")

  def none(:notices), do: gettext("No notices you sent, groups you follow or tags you put.")

  @doc "What the entry is."
  def title(%{source: source} = entry) when source in [:message, :file],
    do:
      if(thread?(entry),
        do: pgettext("activity", "Message in a thread"),
        else: pgettext("activity", "Message")
      )

  def title(%{source: :given, value: %{announces: :event}}),
    do: pgettext("activity", "Reaction to an event")

  def title(%{source: :given, value: %{announces: :poll}}),
    do: pgettext("activity", "Reaction to a poll")

  def title(%{source: :given, value: %{mine?: true}}),
    do: pgettext("activity", "Reaction to your own message")

  def title(%{source: :given}), do: pgettext("activity", "Reaction to a message")

  def title(%{source: :received, value: %{announces: :event}}),
    do: pgettext("activity", "Reactions to your event")

  def title(%{source: :received, value: %{announces: :poll}}),
    do: pgettext("activity", "Reactions to your poll")

  def title(%{source: :received}), do: pgettext("activity", "Reactions to your message")

  def title(%{source: :ballot, poll: %{secret?: true}}),
    do: pgettext("activity", "Vote in a secret poll")

  def title(%{source: :ballot}), do: pgettext("activity", "Vote in a poll")
  def title(%{source: :poll}), do: pgettext("activity", "New poll")
  def title(%{source: :event}), do: pgettext("activity", "New event")
  def title(%{source: :rsvp}), do: pgettext("activity", "Answer to an event")
  def title(%{source: :group_made}), do: pgettext("activity", "New group")
  def title(%{source: :joined}), do: pgettext("activity", "Joining a group")
  def title(%{source: :left}), do: pgettext("activity", "Leaving a group")
  def title(%{source: :group_reaction}), do: pgettext("activity", "Reaction to a group")

  def title(%{source: :record, count: 1}), do: pgettext("activity", "Record in an app")

  def title(%{source: :record, count: count}) do
    if count > Activity.counted(),
      do: pgettext("activity", "More than %{count} records in an app", count: Activity.counted()),
      else:
        pngettext("activity", "%{count} record in an app", "%{count} records in an app", count)
  end

  def title(%{source: :run_answer, type: "formTask"}), do: pgettext("activity", "Filled in form")
  def title(%{source: :run_answer}), do: pgettext("activity", "Decision in a process")
  def title(%{source: :run_start}), do: pgettext("activity", "Process started")
  def title(%{source: :decision}), do: pgettext("activity", "Decision on a request")
  def title(%{source: :admission}), do: pgettext("activity", "Admission to a group")
  def title(%{source: :notice}), do: pgettext("activity", "Notice to followers")
  def title(%{source: :follow}), do: pgettext("activity", "Following a group")
  def title(%{source: :tag, target: {:group, _}}), do: pgettext("activity", "Tag on a group")
  def title(%{source: :tag, target: {:profile, _}}), do: pgettext("activity", "Tag on a profile")
  def title(%{source: :tag, target: {:event, _}}), do: pgettext("activity", "Tag on an event")
  def title(%{source: :tag, target: {:value, _}}), do: pgettext("activity", "Tag on a message")
  def title(%{source: :tag, target: {:file, _}}), do: pgettext("activity", "Tag on a file")

  @doc "The icon of the entry."
  def icon(%{source: :message}), do: "hero-chat-bubble-oval-left"
  def icon(%{source: :file}), do: "hero-paper-clip"
  def icon(%{source: :given}), do: "hero-face-smile"
  def icon(%{source: :group_reaction}), do: "hero-face-smile"
  def icon(%{source: :received}), do: "hero-heart"
  def icon(%{source: :ballot}), do: "hero-hand-thumb-up"
  def icon(%{source: :poll}), do: "hero-chart-bar"
  def icon(%{source: :event}), do: "hero-calendar-days"
  def icon(%{source: :rsvp}), do: "hero-calendar-days"
  def icon(%{source: :group_made}), do: "hero-folder-plus"
  def icon(%{source: :joined}), do: "hero-user-plus"
  def icon(%{source: :left}), do: "hero-arrow-right-start-on-rectangle"
  def icon(%{source: :record}), do: "hero-table-cells"
  def icon(%{source: :run_answer}), do: "hero-check-circle"
  def icon(%{source: :run_start}), do: "hero-play"
  def icon(%{source: :decision}), do: "hero-scale"
  def icon(%{source: :admission}), do: "hero-user-plus"
  def icon(%{source: :notice}), do: "hero-bell-alert"
  def icon(%{source: :follow}), do: "hero-bell"
  def icon(%{source: :tag}), do: "hero-hashtag"

  @doc "What the entry says, in one line, or nil; `today` is the reader's."
  def text(%{value: %{text: text}}, _today), do: text || no_text()
  def text(%{poll: poll}, _today), do: poll.question

  def text(%{source: :rsvp, event: event, on: date}, today),
    do: event.title <> " · " <> Format.date(date, today)

  def text(%{event: event}, today),
    do: event.title <> " · " <> Format.date(Recurrence.start_date(event), today)

  def text(%{notice: notice}, _today), do: notice.text || no_text()

  def text(%{source: source, process: process, label: label}, _today)
      when source in [:run_answer, :run_start],
      do: if(label, do: label <> " · " <> process, else: process)

  def text(%{source: :decision, person: person} = entry, _today),
    do: Profile.display_name(person) <> " · " <> subject(entry)

  def text(%{source: :admission, person: person}, _today), do: Profile.display_name(person)

  def text(%{source: :record, app: app}, _today), do: app && app.name

  def text(%{source: :tag, target: {:value, value}}, _today), do: value.text || no_text()
  def text(%{source: :tag, target: {:event, event}}, _today), do: event.title
  def text(%{source: :tag, target: {:file, file}}, _today), do: file.filename

  def text(%{source: :tag, target: {:profile, profile}}, _today),
    do: Profile.display_name(profile)

  def text(_entry, _today), do: nil

  defp no_text, do: gettext("(no text)")

  defp subject(%{role_key: nil}), do: gettext("Admission")
  defp subject(%{role: nil}), do: gettext("A role since deleted")
  defp subject(%{role: role}), do: RolesTab.role_label(role)

  @doc "Whose the thing is, when it is someone else's, or nil."
  def author(%{source: :given, value: %{mine?: false, author: author}}),
    do: Profile.display_name(author)

  def author(_entry), do: nil

  @doc "Who reacted: the last of them by name, and how many more."
  def people(%{people: people, people_count: count}) do
    names = Enum.join(people, ", ")

    case count - length(people) do
      0 ->
        names

      more ->
        gettext("%{names} and %{count} more", names: names, count: more)
    end
  end

  @doc "A short state of the entry, as `{label, tone}`, or nil."
  def mark(%{event: %Event{cancelled_at: %DateTime{}}}), do: {gettext("Cancelled"), :bad}
  def mark(%{source: :rsvp, status: :going}), do: {gettext("Going"), :good}
  def mark(%{source: :rsvp, status: :maybe}), do: {gettext("Maybe"), :neutral}
  def mark(%{source: :rsvp, status: :declined}), do: {gettext("Not going"), :neutral}
  def mark(%{source: :decision, decision: :granted}), do: {gettext("Given"), :good}
  def mark(%{source: :decision, decision: :declined}), do: {gettext("Refused"), :bad}
  def mark(%{source: :decision, decision: :voted}), do: {gettext("Put to a vote"), :neutral}

  def mark(%{source: :run_answer, outcome: outcome}) when is_binary(outcome),
    do: {outcome, :neutral}

  def mark(_entry), do: nil

  @doc "What the reader voted for, as a sentence, or nil where there is none to tell."
  def choice(%{source: :ballot, choice: [_ | _] = choice}),
    do: gettext("Your vote: %{choice}", choice: Enum.join(choice, ", "))

  def choice(_entry), do: nil

  @doc "The names of the tags put."
  def tags(%{tags: tags}), do: Enum.map(tags, fn %Tag{name: name} -> "#" <> name end)
  def tags(_entry), do: []

  @doc "Where the entry leads, or nil."
  def path(%{value: %{id: id}, group: group}),
    do: ~p"/groups/#{group.id}/values?#{[value: id]}"

  def path(%{poll: poll, group: group}), do: ~p"/groups/#{group.id}/polls?#{[poll: poll.id]}"

  def path(%{source: :rsvp, event: event, on: date, group: group}),
    do: ~p"/groups/#{group.id}/calendar?#{[event: event.id, on: Date.to_iso8601(date)]}"

  def path(%{event: event, group: group}),
    do: ~p"/groups/#{group.id}/calendar?#{[event: event.id]}"

  def path(%{notice: notice, group: group}),
    do: ~p"/groups/#{group.id}/notices?#{[notice: notice.id]}"

  def path(%{source: :record, group: group, app: app}),
    do: ~p"/groups/#{group.id}/group_home?#{[d: (app && app.id) || "default"]}"

  def path(%{source: source, group: group}) when source in [:run_answer, :run_start],
    do: ~p"/groups/#{group.id}/processes"

  def path(%{source: source}) when source in [:decision, :admission], do: ~p"/requests"

  def path(%{source: :tag, target: {:value, value}, group: group}),
    do: ~p"/groups/#{group.id}/values?#{[value: value.id]}"

  def path(%{source: :tag, target: {:event, event}, group: group}),
    do: ~p"/groups/#{group.id}/calendar?#{[event: event.id]}"

  def path(%{source: :tag, target: {:profile, profile}}), do: ~p"/u/#{profile.username}"
  def path(%{source: :tag, target: {:file, file}}), do: ~p"/files/#{file.id}"
  def path(%{group: group}), do: ~p"/groups/#{group.id}"

  @doc "Whether the entry leads out of the app's pages, to a file."
  def file?(%{source: :tag, target: {:file, _file}}), do: true
  def file?(_entry), do: false

  @doc "Whether the entry is in a thread."
  def thread?(%{group: %{parent_value_id: id}}), do: not is_nil(id)
  def thread?(_entry), do: false
end
