defmodule PotokIdeWeb.GroupLive.Show.RequestDialogs do
  @moduledoc """
  The two dialogs of requests (`PotokIde.Social.GroupRequests`): asking to
  join or for roles (`ask_dialog/1`), and deciding a request
  (`decide_dialog/1`), which the group page and the requests page share.

  Each is a top-layer `<dialog>`, as `PollForm`'s, drawn from a state the
  page keeps (nil when closed): `ask_state/4` and `decide_state/3` build it,
  `ask/5` and `decide/4` carry out what the form sent and return the words
  for the page to show.

  The ask dialog says, for each role, how it is had, and that a request that
  may go to a vote is read by the whole group, note and all: whoever asks
  knows before sending.
  """

  use PotokIdeWeb, :html

  alias PotokIde.Social.{Access, Group, GroupJoinRequest, GroupRequests, GroupRole}
  alias PotokIdeWeb.GroupLive.Show.{Components, RequestRules, RolesTab}

  ## Asking

  @doc """
  What the ask dialog shows the holder of `access` in `group`: `kind` is
  `:join` for a request to join, `:roles` for a member asking for roles, and
  `held` the roles they asked for already (`waiting`, shown so) and those a
  vote decides now (`voting`, left out). nil when there is nothing to ask for.
  """
  def ask_state(%Group{} = group, %Access{} = access, kind, held \\ %{waiting: [], voting: []}) do
    %{waiting: waiting_keys, voting: voting} = held

    roles =
      access
      |> GroupRequests.requestable_roles(group)
      |> Enum.map(fn role ->
        mode = GroupRequests.mode(role, group)

        %{
          key: role.key,
          label: RolesTab.role_label(role),
          mode: mode,
          text: RequestRules.rule_text(:role, mode, role.request_poll),
          public?: mode in [:choose, :vote],
          waiting?: role.key in waiting_keys
        }
      end)
      |> Enum.reject(&(&1.key in voting))

    if kind == :roles and roles == [] do
      nil
    else
      %{
        kind: kind,
        group_id: group.id,
        group_name: group.name,
        roles: roles,
        join_text:
          if(kind == :join, do: RequestRules.rule_text(:join, group.join_mode, group.join_poll)),
        public?: kind == :join and group.join_mode in [:choose, :vote],
        error: nil
      }
    end
  end

  @doc """
  Sends what the ask form holds, in `profile`'s name. Returns `{:ok, message}`
  or `{:error, message}`.
  """
  def ask(profile, account, %Group{} = group, %{kind: kind}, params) do
    attrs = %{
      "role_keys" => Map.get(params, "role_keys", []),
      "note" => Map.get(params, "note")
    }

    result =
      case kind do
        :join -> GroupRequests.request_access(profile, group, attrs, account: account)
        :roles -> GroupRequests.request_roles(profile, group, attrs, account: account)
      end

    case result do
      {:ok, _request} when kind == :join -> {:ok, gettext("Access request sent.")}
      {:ok, _request} -> {:ok, gettext("Your request for roles is sent.")}
      {:error, reason} -> {:error, error_message(reason)}
    end
  end

  attr :state, :map, default: nil, doc: "from `ask_state/4`, nil when closed"

  def ask_dialog(assigns) do
    ~H"""
    <dialog
      :if={@state}
      id="request-dialog"
      phx-hook=".RequestDialog"
      phx-mounted={JS.ignore_attributes(["open"])}
      aria-labelledby="request-dialog-title"
      data-close="request_dialog_close"
      class="fixed inset-0 m-0 size-full max-h-none max-w-none overflow-hidden bg-transparent p-0 backdrop:bg-transparent"
    >
      <div class="flex size-full items-end justify-center sm:items-center sm:p-4">
        <div
          id="request-dialog-backdrop"
          class="absolute inset-0 bg-black/30 backdrop-blur-[2px] dark:bg-black/60"
          phx-click="request_dialog_close"
          aria-hidden="true"
        >
        </div>
        <section
          tabindex="-1"
          autofocus
          class="relative flex max-h-[85dvh] w-full flex-col overflow-hidden rounded-t-3xl border border-b-0 border-base-300/70 bg-base-100 text-base-content shadow-2xl shadow-base-content/10 outline-none sm:max-w-lg sm:rounded-3xl sm:border-b"
        >
          <header class="flex items-start gap-3 border-b border-base-300/60 px-5 pt-5 pb-4">
            <span class="inline-flex size-10 shrink-0 items-center justify-center rounded-2xl bg-primary/10 text-primary">
              <.icon name="hero-hand-raised" class="size-5" />
            </span>
            <div class="min-w-0 flex-1 self-center">
              <h2 id="request-dialog-title" class="text-base font-semibold leading-tight">
                {if(@state.kind == :join,
                  do: gettext("Ask to join %{group}", group: @state.group_name),
                  else: gettext("Ask for roles")
                )}
              </h2>
            </div>
            <.icon_button
              id="request-dialog-close"
              type="button"
              phx-click="request_dialog_close"
              icon="hero-x-mark"
              label={gettext("Close")}
              class="-mr-1"
            />
          </header>

          <div class="min-h-0 flex-1 overflow-y-auto px-5 py-4">
            <.form for={to_form(%{}, as: :request)} id="request-form" phx-submit="request_send">
              <p
                :if={@state.join_text}
                id="request-dialog-admission"
                class="mb-4 flex items-start gap-2 rounded-2xl border border-base-300/70 bg-base-200/40 px-3 py-2.5 text-sm"
              >
                <.icon name="hero-user-plus" class="mt-0.5 size-4 shrink-0 text-primary" />
                <span>{@state.join_text}</span>
              </p>

              <fieldset :if={@state.roles != []} id="request-dialog-roles" class="mb-4">
                <legend class="mb-2 text-sm font-semibold">
                  {if(@state.kind == :join,
                    do: gettext("Roles you would like (optional)"),
                    else: gettext("Roles you would like")
                  )}
                </legend>
                <input type="hidden" name="request[role_keys][]" value="" />
                <div class="space-y-1.5">
                  <label
                    :for={role <- @state.roles}
                    id={"request-dialog-role-#{role.key}"}
                    class="flex cursor-pointer items-start gap-2.5 rounded-2xl border border-base-300 bg-base-100 px-3 py-2.5 transition duration-150 hover:border-primary/40 has-checked:border-primary/60 has-checked:bg-primary/5"
                  >
                    <input
                      type="checkbox"
                      name="request[role_keys][]"
                      value={role.key}
                      class="checkbox checkbox-sm checkbox-primary mt-0.5 shrink-0"
                    />
                    <span class="min-w-0">
                      <span class="flex flex-wrap items-center gap-x-2 text-sm font-semibold">
                        {role.label}
                        <span
                          :if={role.waiting?}
                          class="rounded-full bg-amber-500/10 px-2 text-[11px] font-medium text-amber-800 dark:text-amber-200"
                        >
                          {gettext("asked for already")}
                        </span>
                      </span>
                      <span class="block text-xs text-base-content/65">{role.text}</span>
                      <span
                        :if={role.public?}
                        class="mt-0.5 flex items-start gap-1 text-xs text-amber-800 dark:text-amber-200"
                      >
                        <.icon name="hero-megaphone" class="mt-px size-3.5 shrink-0" />
                        {gettext(
                          "If it goes to a vote, the whole group reads your request and what you wrote, under your name."
                        )}
                      </span>
                    </span>
                  </label>
                </div>
              </fieldset>

              <.input
                id="request-dialog-note"
                name="request[note]"
                value=""
                type="textarea"
                rows="3"
                maxlength={GroupJoinRequest.max_note()}
                label={gettext("Why you ask (optional)")}
                placeholder={gettext("A few words for whoever decides.")}
              />
              <p
                :if={@state.public?}
                id="request-dialog-public"
                class="mt-2 flex items-start gap-1 text-xs text-amber-800 dark:text-amber-200"
              >
                <.icon name="hero-megaphone" class="mt-px size-3.5 shrink-0" />
                {gettext(
                  "If admission goes to a vote, the whole group reads your request and what you wrote, under your name."
                )}
              </p>

              <p
                :if={@state.error}
                id="request-dialog-error"
                role="alert"
                class="mt-3 flex items-start gap-1.5 text-sm text-error"
              >
                <.icon name="hero-exclamation-circle" class="mt-0.5 size-4 shrink-0" />
                {@state.error}
              </p>
            </.form>
          </div>

          <footer class="flex items-center justify-end gap-2 border-t border-base-300/60 bg-base-200/40 px-5 pt-3 pb-[calc(0.75rem+var(--app-safe-area-bottom))] sm:pb-3">
            <.button type="button" phx-click="request_dialog_close" variant="ghost">
              {gettext("Cancel")}
            </.button>
            <.button
              id="request-dialog-submit"
              type="submit"
              form="request-form"
              phx-disable-with={gettext("Sending...")}
              variant="primary"
            >
              {gettext("Send the request")}
            </.button>
          </footer>
        </section>
      </div>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".RequestDialog">
      export default {
        mounted() {
          // Escape and Android's back button close it through the server.
          this.el.addEventListener("cancel", event => {
            event.preventDefault()
            this.pushEvent(this.el.dataset.close, {})
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

  ## Deciding

  @doc """
  What the decision dialog shows `access`'s holder about `request` of `group`
  (a `GroupJoinRequest` or a `GroupRoleRequest`, with its profile loaded).
  nil when they may not decide it, or a vote decides it now.
  """
  def decide_state(%Group{} = group, %Access{} = access, request) do
    {ref, profile, admission} =
      case request do
        %GroupJoinRequest{} = request ->
          {{:join, request.id}, request.requester, GroupRequests.admission_choices(group)}

        request ->
          {{:roles, request.id}, request.profile, nil}
      end

    roles = if access.manifest, do: access.manifest.roles, else: []

    cond do
      not GroupRequests.may_decide?(access, group) ->
        nil

      match?(%GroupJoinRequest{poll_id: id} when not is_nil(id), request) ->
        nil

      true ->
        %{
          ref: ref,
          group_id: group.id,
          group_name: group.name,
          profile: profile,
          note: request.note,
          inserted_at: request.inserted_at,
          admission: admission,
          roles:
            for key <- request.role_keys,
                role = Enum.find(roles, &(&1.key == key)),
                role != nil do
              choices = GroupRequests.choices(role, access, group)

              %{
                key: key,
                label: RolesTab.role_label(role),
                text:
                  RequestRules.rule_text(
                    :role,
                    GroupRequests.mode(role, group),
                    role.request_poll
                  ),
                choices: choices,
                default: GroupRequests.default_choice(choices)
              }
            end,
          error: nil
        }
    end
  end

  @doc """
  Carries out what the decision form holds, in `actor`'s name. Returns
  `{:ok, message}` or `{:error, message}`.
  """
  def decide(actor, %Group{} = group, %{ref: ref}, params) do
    case GroupRequests.decide(actor, group, ref, params) do
      {:ok, _parts} -> {:ok, gettext("The decision is saved.")}
      {:error, reason} -> {:error, error_message(reason)}
    end
  end

  attr :state, :map, default: nil, doc: "from `decide_state/3`, nil when closed"
  attr :current_profile, :map, required: true

  attr :card, :atom,
    default: :page,
    values: [:dialog, :page],
    doc: "how the name of who asks opens their card (`Components.profile_identity/1`)"

  def decide_dialog(assigns) do
    ~H"""
    <dialog
      :if={@state}
      id="request-decision-dialog"
      phx-hook=".RequestDecisionDialog"
      phx-mounted={JS.ignore_attributes(["open"])}
      aria-labelledby="request-decision-title"
      data-close="request_decision_close"
      class="fixed inset-0 m-0 size-full max-h-none max-w-none overflow-hidden bg-transparent p-0 backdrop:bg-transparent"
    >
      <div class="flex size-full items-end justify-center sm:items-center sm:p-4">
        <div
          id="request-decision-backdrop"
          class="absolute inset-0 bg-black/30 backdrop-blur-[2px] dark:bg-black/60"
          phx-click="request_decision_close"
          aria-hidden="true"
        >
        </div>
        <section
          tabindex="-1"
          autofocus
          class="relative flex max-h-[85dvh] w-full flex-col overflow-hidden rounded-t-3xl border border-b-0 border-base-300/70 bg-base-100 text-base-content shadow-2xl shadow-base-content/10 outline-none sm:max-w-lg sm:rounded-3xl sm:border-b"
        >
          <header class="flex items-start gap-3 border-b border-base-300/60 px-5 pt-5 pb-4">
            <span class="inline-flex size-10 shrink-0 items-center justify-center rounded-2xl bg-primary/10 text-primary">
              <.icon name="hero-scale" class="size-5" />
            </span>
            <div class="min-w-0 flex-1 self-center">
              <h2 id="request-decision-title" class="text-base font-semibold leading-tight">
                {if(@state.admission,
                  do: gettext("Request to join %{group}", group: @state.group_name),
                  else: gettext("Request for roles in %{group}", group: @state.group_name)
                )}
              </h2>
            </div>
            <.icon_button
              id="request-decision-close"
              type="button"
              phx-click="request_decision_close"
              icon="hero-x-mark"
              label={gettext("Close")}
              class="-mr-1"
            />
          </header>

          <div class="min-h-0 flex-1 overflow-y-auto px-5 py-4">
            <div class="mb-4 space-y-2">
              <Components.profile_identity
                profile={@state.profile}
                current_profile={@current_profile}
                card={@card}
              />
              <blockquote
                :if={@state.note}
                id="request-decision-note"
                class="rounded-2xl border-l-4 border-primary/40 bg-base-200/50 px-3 py-2 text-sm whitespace-pre-line"
                phx-no-format
              >{@state.note}</blockquote>
              <p :if={!@state.note} class="text-xs text-base-content/60">
                {gettext("They did not say why.")}
              </p>
            </div>

            <.form
              for={to_form(%{}, as: :decision)}
              id="request-decision-form"
              phx-submit="request_decide"
              class="group/decide"
            >
              <fieldset :if={@state.admission} id="request-decision-admission" class="mb-4">
                <legend class="mb-2 text-sm font-semibold">{gettext("Admission")}</legend>
                <div class="flex flex-wrap gap-1.5">
                  <.choice_pill
                    :for={choice <- @state.admission}
                    id={"request-decision-admission-#{choice}"}
                    name="decision[admission]"
                    value={choice}
                    checked={choice == hd(@state.admission)}
                    label={admission_label(choice)}
                  />
                </div>
              </fieldset>

              <fieldset
                :if={@state.roles != []}
                id="request-decision-roles"
                class={[
                  "mb-4",
                  @state.admission &&
                    "hidden group-has-[input[name='decision[admission]'][value=admit]:checked]/decide:block"
                ]}
              >
                <legend class="mb-2 text-sm font-semibold">{gettext("Roles asked for")}</legend>
                <div class="space-y-2">
                  <div
                    :for={role <- @state.roles}
                    id={"request-decision-role-#{role.key}"}
                    class="rounded-2xl border border-base-300/70 px-3 py-2.5"
                  >
                    <p class="text-sm font-semibold">{role.label}</p>
                    <p class="mb-2 text-xs text-base-content/65">{role.text}</p>
                    <div class="flex flex-wrap gap-1.5">
                      <.choice_pill
                        :for={choice <- role.choices}
                        id={"request-decision-role-#{role.key}-#{choice}"}
                        name={"decision[roles][#{role.key}]"}
                        value={choice}
                        checked={choice == role.default}
                        label={role_choice_label(choice)}
                      />
                    </div>
                  </div>
                </div>
              </fieldset>

              <.input
                id="request-decision-reason"
                name="decision[reason]"
                value=""
                type="textarea"
                rows="2"
                maxlength="300"
                label={gettext("What you tell them (optional)")}
              />

              <p
                :if={@state.error}
                id="request-decision-error"
                role="alert"
                class="mt-3 flex items-start gap-1.5 text-sm text-error"
              >
                <.icon name="hero-exclamation-circle" class="mt-0.5 size-4 shrink-0" />
                {@state.error}
              </p>
            </.form>
          </div>

          <footer class="flex items-center justify-end gap-2 border-t border-base-300/60 bg-base-200/40 px-5 pt-3 pb-[calc(0.75rem+var(--app-safe-area-bottom))] sm:pb-3">
            <.button type="button" phx-click="request_decision_close" variant="ghost">
              {gettext("Cancel")}
            </.button>
            <.button
              id="request-decision-submit"
              type="submit"
              form="request-decision-form"
              phx-disable-with={gettext("Saving...")}
              variant="primary"
            >
              {gettext("Save the decision")}
            </.button>
          </footer>
        </section>
      </div>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".RequestDecisionDialog">
      export default {
        mounted() {
          this.el.addEventListener("cancel", event => {
            event.preventDefault()
            this.pushEvent(this.el.dataset.close, {})
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

  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :value, :atom, required: true
  attr :checked, :boolean, default: false
  attr :label, :string, required: true

  defp choice_pill(assigns) do
    ~H"""
    <label
      id={@id}
      class="inline-flex cursor-pointer items-center gap-1.5 rounded-full border border-base-300 bg-base-100 px-3 py-1.5 text-sm font-medium transition duration-150 hover:border-primary/40 has-checked:border-primary/60 has-checked:bg-primary/10 has-checked:text-primary active:scale-95"
    >
      <input type="radio" name={@name} value={@value} checked={@checked} class="sr-only" />
      {@label}
    </label>
    """
  end

  @doc "The roles a request holds, as words: chips for a list."
  attr :keys, :list, required: true
  attr :roles, :list, required: true, doc: "the manifest's roles"
  attr :id, :string, required: true

  def role_chips(assigns) do
    assigns =
      assign(
        assigns,
        :named,
        for(
          key <- assigns.keys,
          role = Enum.find(assigns.roles, &(&1.key == key)),
          role != nil,
          do: role
        )
      )

    ~H"""
    <span :if={@named != []} id={@id} class="flex flex-wrap gap-1">
      <span
        :for={role <- @named}
        class="inline-flex items-center gap-1 rounded-full bg-primary/10 px-2 py-0.5 text-xs font-medium text-primary"
      >
        <.icon name={RolesTab.role_icon(role)} class="size-3" />
        {RolesTab.role_label(role)}
      </span>
    </span>
    """
  end

  defp admission_label(:admit), do: gettext("Admit")
  defp admission_label(:refuse), do: gettext("Refuse")
  defp admission_label(:vote), do: gettext("Put to a vote")

  defp role_choice_label(:grant), do: gettext("Give")
  defp role_choice_label(:refuse), do: gettext("Refuse")
  defp role_choice_label(:vote), do: gettext("Put to a vote")
  defp role_choice_label(:later), do: gettext("Later")

  @doc "What went wrong with a request, as words."
  def error_message(:not_permitted), do: gettext("Your roles in this group do not allow that.")
  def error_message(:not_allowed), do: gettext("This group takes no requests.")
  def error_message(:group_not_public), do: gettext("Only public groups accept access requests.")
  def error_message(:already_a_member), do: gettext("You are already a group member.")

  def error_message(:already_invited),
    do: gettext("You already have a pending invitation to this group.")

  def error_message(:blocked), do: gettext("You are blocked in this group.")

  def error_message(:role_not_requestable),
    do: gettext("One of those roles cannot be asked for, or you hold it already.")

  def error_message(:no_roles), do: gettext("Pick at least one role.")

  def error_message(:asked_lately) do
    gettext("You were refused this lately. You can ask again %{days} days after the decision.",
      days: GroupRequests.wait_days()
    )
  end

  def error_message(:in_vote), do: gettext("A vote decides this now.")
  def error_message(:rate_limited), do: gettext("Too many requests. Try again later.")
  def error_message(:request_not_found), do: gettext("Access request not found.")

  def error_message(%Ecto.Changeset{} = changeset) do
    if Keyword.has_key?(changeset.errors, :group_id) or
         Keyword.has_key?(changeset.errors, :requester_id),
       do: gettext("Access request already pending."),
       else: gettext("Could not send access request.")
  end

  def error_message(_reason), do: gettext("Could not send access request.")

  @doc "The role keys `role_chips/1` names, from the effective manifest of `access`."
  def manifest_roles(%Access{manifest: nil}), do: []

  def manifest_roles(%Access{manifest: manifest}),
    do: Enum.reject(manifest.roles, &(&1.key == GroupRole.everyone_key()))
end
