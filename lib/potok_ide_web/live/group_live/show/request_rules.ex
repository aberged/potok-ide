defmodule PotokIdeWeb.GroupLive.Show.RequestRules do
  @moduledoc """
  How a role is had and how a request to join is decided, on screen: the
  fields an admin writes them with (`rule_fields/1`) and the words that tell
  them to anyone (`rule_text/3`). The roles tab, the group's settings and the
  request dialog draw from here, so that they all say the same.

  The fields send `rule[mode]` and, for a mode that votes, `rule[poll][...]`
  (`PotokIde.Social.RequestPoll`); `params/2` turns them into what `Social`
  takes. The rules of the vote show only while a mode that votes is picked,
  which the browser decides from the picked radio, with no round trip.
  """

  use PotokIdeWeb, :html

  alias PotokIde.Social.RequestPoll

  attr :id, :string, required: true
  attr :kind, :atom, values: [:role, :join], required: true
  attr :mode, :atom, required: true
  attr :poll, :any, default: nil, doc: "the stored `RequestPoll`, or nil for the defaults"
  attr :modes, :list, default: nil, doc: "the modes offered, all of the kind's by default"

  attr :form, :string,
    default: nil,
    doc: "the id of the form the fields belong to, when they stand outside it"

  def rule_fields(assigns) do
    assigns =
      assigns
      |> assign(:poll, assigns.poll || %RequestPoll{})
      |> assign(:modes, assigns.modes || modes(assigns.kind))

    ~H"""
    <fieldset id={@id} class="group/rule min-w-0">
      <legend class="sr-only">{legend(@kind)}</legend>
      <div class="grid gap-1.5 sm:grid-cols-2">
        <label
          :for={mode <- @modes}
          id={"#{@id}-mode-#{mode}"}
          class="flex cursor-pointer items-start gap-2 rounded-2xl border border-base-300 bg-base-100 px-3 py-2 transition duration-150 hover:border-primary/40 has-checked:border-primary/60 has-checked:bg-primary/5"
        >
          <input
            type="radio"
            name="rule[mode]"
            value={mode}
            checked={mode == @mode}
            form={@form}
            class="radio radio-sm radio-primary mt-0.5 shrink-0"
          />
          <span class="min-w-0">
            <span class="block text-sm font-semibold">{mode_label(@kind, mode)}</span>
            <span class="block text-xs text-base-content/65">{mode_hint(@kind, mode)}</span>
          </span>
        </label>
      </div>

      <div
        id={"#{@id}-poll"}
        class="mt-3 hidden gap-x-3 rounded-2xl border border-base-300/70 px-3 pt-3 sm:grid-cols-2 group-has-[input[value=choose]:checked]/rule:grid group-has-[input[value=vote]:checked]/rule:grid"
      >
        <p class="mb-2 text-xs font-semibold text-base-content/70 sm:col-span-2">
          {gettext("How the vote goes")}
        </p>
        <.input
          id={"#{@id}-quorum"}
          name="rule[poll][quorum_percent]"
          value={@poll.quorum_percent}
          type="number"
          min="1"
          max="100"
          form={@form}
          label={dgettext("polls", "Quorum: percent of those who may vote")}
        />
        <.input
          id={"#{@id}-majority"}
          name="rule[poll][majority]"
          value={@poll.majority}
          type="select"
          form={@form}
          label={dgettext("polls", "Decision")}
          options={[
            {dgettext("polls", "More than half of the votes"), :simple},
            {dgettext("polls", "Two thirds of the votes"), :two_thirds},
            {dgettext("polls", "More than half of those who may vote"), :absolute}
          ]}
        />
        <.input
          id={"#{@id}-hours"}
          name="rule[poll][hours]"
          value={@poll.hours}
          type="select"
          form={@form}
          label={gettext("How long it runs")}
          options={Enum.map(RequestPoll.hours_choices(), &{days(&1), &1})}
        />
        <.input
          id={"#{@id}-unique"}
          name="rule[poll][unique_votes]"
          value={@poll.unique_votes}
          type="select"
          form={@form}
          label={dgettext("polls", "Unique profiles")}
          options={[
            {dgettext("polls", "Vote, one vote per account"), :yes},
            {dgettext("polls", "Do not vote"), :no}
          ]}
        />
        <.input
          id={"#{@id}-shared"}
          name="rule[poll][shared_votes]"
          value={@poll.shared_votes}
          type="select"
          form={@form}
          label={dgettext("polls", "Shared profiles")}
          options={[
            {dgettext("polls", "One vote for all who hold it"), :as_one},
            {dgettext("polls", "Each holder votes separately"), :each_holder},
            {dgettext("polls", "Do not vote"), :no}
          ]}
        />
        <div class="sm:col-span-2">
          <.input
            id={"#{@id}-secret"}
            name="rule[poll][secret]"
            value={@poll.secret}
            type="checkbox"
            form={@form}
            label={dgettext("polls", "Secret poll")}
          />
        </div>
        <p class="mb-3 text-xs text-base-content/65 sm:col-span-2">
          {gettext(
            "All members who may vote take part, by these rules, on every request alike. Whoever asks reads them before sending."
          )}
        </p>
      </div>
    </fieldset>
    """
  end

  @doc """
  What the fields sent, as `Social.set_role_request_rule/4` (`:role`) or
  `Social.set_join_rule/3` (`:join`) take it.
  """
  def params(:role, rule), do: %{"request_mode" => rule["mode"], "request_poll" => rule["poll"]}
  def params(:join, rule), do: %{"join_mode" => rule["mode"], "join_poll" => rule["poll"]}

  @doc "Every mode of a kind of rule, in the order the fields offer them."
  def modes(:role), do: [:closed, :approve, :choose, :vote]
  def modes(:join), do: [:approve, :choose, :vote]

  @doc "How a role is had or a request to join decided, in one sentence or two."
  def rule_text(kind, mode, poll) do
    case poll_text(poll) do
      nil -> mode_hint(kind, mode)
      text when mode in [:choose, :vote] -> mode_hint(kind, mode) <> " " <> text
      _text -> mode_hint(kind, mode)
    end
  end

  @doc "The rules of a vote, as a sentence; nil for none."
  def poll_text(nil), do: nil

  def poll_text(%RequestPoll{} = poll) do
    gettext("The vote: a quorum of %{quorum} %, %{majority}, over %{days}.",
      quorum: poll.quorum_percent,
      majority: majority_words(poll.majority),
      days: days(poll.hours)
    )
    |> then(fn text ->
      case voters_words(poll) do
        nil -> text
        voters -> text <> " " <> voters
      end
    end)
    |> then(fn text ->
      if poll.secret, do: text <> " " <> gettext("Nobody sees who voted for what."), else: text
    end)
  end

  def mode_label(:role, :closed), do: gettext("Not asked for")
  def mode_label(:role, :approve), do: gettext("Given on request")
  def mode_label(:role, :choose), do: gettext("On request, or by a vote")
  def mode_label(:role, :vote), do: gettext("Always by a vote")
  def mode_label(:join, :approve), do: gettext("Admitted on request")
  def mode_label(:join, :choose), do: gettext("On request, or by a vote")
  def mode_label(:join, :vote), do: gettext("Always by a vote")

  def mode_hint(:role, :closed), do: gettext("Nobody can ask for this role; an admin gives it.")

  def mode_hint(:role, :approve),
    do: gettext("Whoever manages requests gives the role or refuses it.")

  def mode_hint(:role, :choose),
    do: gettext("Whoever manages requests gives the role, refuses it or puts it to a vote.")

  def mode_hint(:role, :vote), do: gettext("Every request for the role is put to a vote.")

  def mode_hint(:join, :approve),
    do: gettext("Whoever manages requests admits the one who asks or refuses.")

  def mode_hint(:join, :choose),
    do: gettext("Whoever manages requests admits, refuses or puts it to a vote.")

  def mode_hint(:join, :vote), do: gettext("Every request to join is put to a vote.")

  defp legend(:role), do: gettext("How the role is had")
  defp legend(:join), do: gettext("How a request to join is decided")

  defp majority_words(:simple), do: gettext("more than half of the votes")
  defp majority_words(:two_thirds), do: gettext("two thirds of the votes")
  defp majority_words(:absolute), do: gettext("more than half of those who may vote")

  defp voters_words(%RequestPoll{unique_votes: :yes, shared_votes: :as_one}), do: nil

  defp voters_words(%RequestPoll{unique_votes: :yes, shared_votes: :each_holder}),
    do: dgettext("polls", "Each holder of a shared profile votes through it as themself.")

  defp voters_words(%RequestPoll{unique_votes: :yes, shared_votes: :no}),
    do: dgettext("polls", "Only unique profiles vote; shared profiles do not.")

  defp voters_words(%RequestPoll{unique_votes: :no, shared_votes: :as_one}),
    do: dgettext("polls", "Only shared profiles vote, once for all who hold each.")

  defp voters_words(%RequestPoll{unique_votes: :no, shared_votes: :each_holder}),
    do: dgettext("polls", "Only shared profiles vote, each of their holders separately.")

  defp voters_words(%RequestPoll{}), do: nil

  defp days(hours) do
    count = div(hours, 24)
    ngettext("%{count} day", "%{count} days", count, count: count)
  end
end
