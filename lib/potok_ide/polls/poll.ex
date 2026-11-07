defmodule PotokIde.Polls.Poll do
  @moduledoc """
  A question put to a vote in a group. Its message in the chat
  (`value_id`) shows `PotokIdeWeb.GroupLive.Show.PollCard` in place of its text.

  Who votes and who sees what is written on the poll as lists of role keys, read
  by `PotokIde.Polls.Rules`. The lists are explicit: `"everyone"` is every
  member, and an empty list leaves a thing to the organizer and those with
  `manage_polls`.

  Once a ballot is in, what the voter saw is a promise: `schedule_changeset/3`
  is then all that can change.

  A secret poll keeps no link between a voter and an answer
  (`PotokIde.Polls.PollBallot`). So a vote cannot change, no count shows before
  the end, as next to the list of who voted it would give choices away, and
  nothing reopens it. The database holds that too.

  A public poll also takes the votes of signed-in non-members of a public group.
  They are not anyone's to count, so it has no quorum or decision.
  """

  use Ecto.Schema

  import Ecto.Changeset

  alias PotokIde.Events.Recurrence
  alias PotokIde.Polls.{PollBallot, PollOption}

  @kinds [:single, :multiple]
  @results_when [:always, :voted, :closed]
  @details_when [:always, :closed]
  @majorities [:none, :plurality, :simple, :two_thirds, :absolute]
  @outcomes [:passed, :failed, :no_quorum, :tie]
  @reminder_choices [60, 1440]

  @max_question 300
  @max_description 2000
  @min_options 2
  # The organizer's own; with answers from members a poll can grow up to the
  # second number.
  @max_options 10
  @max_options_with_members 30

  @fields [
    :question,
    :description,
    :kind,
    :max_choices,
    :allow_change,
    :secret,
    :allow_member_options,
    :closes_local,
    :reminder_minutes,
    :voter_role_keys,
    :results_role_keys,
    :details_role_keys,
    :results_when,
    :details_when,
    :quorum_percent,
    :majority,
    :is_public
  ]

  schema "polls" do
    field :question, :string
    field :description, :string, default: ""
    field :kind, Ecto.Enum, values: @kinds, default: :single
    # For `:multiple`: at most this many answers; nil for no limit.
    field :max_choices, :integer
    field :allow_change, :boolean, default: true
    field :secret, :boolean, default: false
    # Also takes the votes of signed-in non-members; set by those with
    # `publish_polls` (`PotokIde.Polls` drops the change for others).
    field :is_public, :boolean, default: false
    field :allow_member_options, :boolean, default: false

    field :closes_at, :utc_datetime
    # Set when it was closed, by hand or at `closes_at`.
    field :closed_at, :utc_datetime
    field :reminder_minutes, :integer
    # Set by `PotokIde.Polls`, never cast: when the reminder goes out, nil once
    # it has.
    field :remind_at, :utc_datetime
    field :last_nudged_at, :utc_datetime

    field :voter_role_keys, {:array, :string}, default: ["everyone"]
    field :results_role_keys, {:array, :string}, default: ["everyone"]
    field :details_role_keys, {:array, :string}, default: []
    field :results_when, Ecto.Enum, values: @results_when, default: :voted
    field :details_when, Ecto.Enum, values: @details_when, default: :always

    field :quorum_percent, :integer
    field :majority, Ecto.Enum, values: @majorities, default: :none
    # Written when it closes, so that a later change of members leaves the
    # decision as it was.
    field :eligible_count, :integer
    field :outcome, Ecto.Enum, values: @outcomes

    # Counted by `PotokIde.Polls.vote/4`: with several answers per ballot the
    # counts of the answers do not add up to the voters.
    field :voters_count, :integer, default: 0

    # The form edits the deadline as local time in the viewer's zone.
    field :closes_local, :naive_datetime, virtual: true

    belongs_to :group, PotokIde.Social.Group
    belongs_to :creator, PotokIde.Social.Profile
    # The chat value that carries the poll.
    belongs_to :value, PotokIde.Social.Value
    belongs_to :winner_option, PollOption

    has_many :options, PollOption, on_replace: :delete, preload_order: [asc: :position, asc: :id]
    has_many :ballots, PollBallot

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
  def results_when_values, do: @results_when
  def details_when_values, do: @details_when
  def majorities, do: @majorities
  def reminder_choices, do: @reminder_choices
  def max_question, do: @max_question
  def max_description, do: @max_description
  def min_options, do: @min_options
  def max_options, do: @max_options
  def max_options_with_members, do: @max_options_with_members

  @doc "Whether votes are taken at `now`. A vote checks this itself, so a deadline holds to the second."
  def open?(%__MODULE__{closed_at: closed_at}, _now) when not is_nil(closed_at), do: false
  def open?(%__MODULE__{closes_at: nil}, _now), do: true

  def open?(%__MODULE__{closes_at: closes_at}, %DateTime{} = now),
    do: DateTime.compare(now, closes_at) == :lt

  @doc "Whether a decision is worked out when it closes."
  def decides?(%__MODULE__{majority: majority}), do: majority != :none

  @doc """
  The form changeset. `group_id`, `creator_id`, the counts and what the poll
  writes as it closes are set by the caller, never cast. The deadline is read
  in `time_zone`, the viewer's.
  """
  def changeset(%__MODULE__{} = poll, attrs, time_zone) do
    poll
    |> with_form_fields(time_zone)
    |> cast(attrs, @fields)
    |> update_change(:question, &trim/1)
    |> update_change(:description, &trim/1)
    |> put_blank_description()
    |> update_change(:voter_role_keys, &normalize_role_keys/1)
    |> update_change(:results_role_keys, &normalize_role_keys/1)
    |> update_change(:details_role_keys, &normalize_role_keys/1)
    |> validate_required([:question])
    |> validate_length(:question, max: @max_question, count: :codepoints)
    |> validate_length(:description, max: @max_description)
    |> cast_assoc(:options,
      with: &PollOption.changeset/3,
      sort_param: :options_sort,
      drop_param: :options_drop,
      required: true
    )
    |> validate_length(:options, min: @min_options, max: @max_options)
    |> validate_unique_options()
    |> keep_promises()
    |> validate_number(:max_choices, greater_than_or_equal_to: 1, less_than_or_equal_to: 30)
    |> validate_number(:quorum_percent, greater_than_or_equal_to: 1, less_than_or_equal_to: 100)
    |> validate_inclusion(:reminder_minutes, @reminder_choices)
    |> validate_voters()
    |> put_deadline(time_zone)
    |> check_constraint(:secret, name: :polls_secret_check)
    |> check_constraint(:max_choices, name: :polls_max_choices_check)
    |> check_constraint(:quorum_percent, name: :polls_quorum_percent_check)
  end

  @doc "All that changes once a ballot is in: the deadline and the reminder."
  def schedule_changeset(%__MODULE__{} = poll, attrs, time_zone) do
    poll
    |> with_form_fields(time_zone)
    |> cast(attrs, [:closes_local, :reminder_minutes])
    |> validate_inclusion(:reminder_minutes, @reminder_choices)
    |> put_deadline(time_zone)
  end

  @doc "Fills `closes_local` from `closes_at`, for the form."
  def with_form_fields(%__MODULE__{closes_at: %DateTime{} = closes_at} = poll, time_zone) do
    local = closes_at |> DateTime.shift_zone!(time_zone) |> DateTime.to_naive()
    %{poll | closes_local: local}
  end

  def with_form_fields(%__MODULE__{} = poll, _time_zone), do: poll

  # What a kind of poll cannot be, whatever the form sends. A form with the
  # setting hidden still sends what it last held.
  defp keep_promises(changeset) do
    changeset
    |> keep_secret()
    |> keep_public()
    |> keep_kind()
    |> keep_decision()
  end

  defp keep_secret(changeset) do
    if get_field(changeset, :secret) do
      changeset
      |> put_change(:allow_change, false)
      |> put_change(:results_when, :closed)
      |> put_change(:allow_member_options, false)
    else
      changeset
    end
  end

  defp keep_public(changeset) do
    if get_field(changeset, :is_public) do
      changeset
      |> put_change(:voter_role_keys, ["everyone"])
      |> put_change(:allow_member_options, false)
      |> put_change(:quorum_percent, nil)
      |> put_change(:majority, :none)
    else
      changeset
    end
  end

  defp keep_kind(changeset) do
    case get_field(changeset, :kind) do
      :single ->
        put_change(changeset, :max_choices, nil)

      _multiple ->
        changeset
        |> put_change(:quorum_percent, nil)
        |> put_change(:majority, :none)
    end
  end

  defp keep_decision(changeset) do
    if get_field(changeset, :majority) == :none,
      do: put_change(changeset, :quorum_percent, nil),
      else: changeset
  end

  defp validate_voters(changeset) do
    validate_change(changeset, :voter_role_keys, fn :voter_role_keys, keys ->
      if keys == [], do: [voter_role_keys: "pick who votes"], else: []
    end)
  end

  defp validate_unique_options(changeset) do
    texts =
      changeset
      |> get_assoc(:options, :struct)
      |> Enum.map(&PollOption.normalize(&1.text))
      |> Enum.reject(&(&1 == ""))

    if texts == Enum.uniq(texts),
      do: changeset,
      else: add_error(changeset, :options, "has the same answer twice")
  end

  defp put_deadline(changeset, time_zone) do
    case fetch_change(changeset, :closes_local) do
      {:ok, nil} ->
        put_change(changeset, :closes_at, nil)

      {:ok, %NaiveDateTime{} = local} ->
        put_future_deadline(changeset, local, time_zone)

      :error ->
        changeset
    end
    |> put_reminder()
  end

  defp put_future_deadline(changeset, local, time_zone) do
    closes_at =
      Recurrence.to_utc(NaiveDateTime.to_date(local), NaiveDateTime.to_time(local), time_zone)

    if DateTime.compare(closes_at, DateTime.utc_now(:second)) == :gt do
      put_change(changeset, :closes_at, closes_at)
    else
      add_error(changeset, :closes_local, "must be in the future")
    end
  end

  defp put_reminder(changeset) do
    closes_at = get_field(changeset, :closes_at)
    minutes = get_field(changeset, :reminder_minutes)

    put_change(changeset, :remind_at, remind_at(closes_at, minutes))
  end

  defp remind_at(%DateTime{} = closes_at, minutes) when is_integer(minutes) do
    at = DateTime.add(closes_at, -minutes, :minute)
    if DateTime.compare(at, DateTime.utc_now(:second)) == :gt, do: at
  end

  defp remind_at(_closes_at, _minutes), do: nil

  # Clearing a text field casts to a nil change.
  defp trim(text) when is_binary(text), do: String.trim(text)
  defp trim(text), do: text

  # The column is NOT NULL, and casting "" yields nil.
  defp put_blank_description(changeset) do
    if get_field(changeset, :description) == nil,
      do: put_change(changeset, :description, ""),
      else: changeset
  end

  # Checkbox groups send a hidden "" so that clearing every box is a change.
  defp normalize_role_keys(keys) when is_list(keys) do
    keys |> Enum.reject(&(&1 in [nil, ""])) |> Enum.uniq()
  end

  defp normalize_role_keys(_keys), do: []
end
