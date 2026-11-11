defmodule PotokIdeWeb.GroupLive.Show.NoticesTab do
  @moduledoc """
  A group's notices: following it, the composer for those who send them, and
  everything it sent, newest first, which everyone who sees the group reads.
  Followers hear from the group, so the author shows only to its members.
  """

  use PotokIdeWeb, :html

  alias PotokIde.Notices
  alias PotokIde.Notices.GroupNotice
  alias PotokIdeWeb.GroupLive.Show.Components
  alias PotokIdeWeb.NoticeComponents

  attr :group, :map, required: true
  attr :access, :any, required: true
  attr :current_profile, :map, required: true
  attr :state, :map, required: true, doc: "`notice_state` of `NoticesState`"
  attr :can_follow, :boolean, required: true
  attr :can_send, :boolean, required: true
  attr :form, :any, default: nil
  attr :notices, :any, required: true, doc: "the `:group_notices` stream"
  attr :empty, :boolean, required: true
  attr :more, :boolean, required: true
  attr :focus_id, :integer, default: nil

  def panel(assigns) do
    assigns = assign(assigns, :recipients, recipients(assigns.state))

    ~H"""
    <div id="group-panel-notices" class="card flex min-h-0 flex-1 flex-col">
      <Components.tab_body id="group-notices-body">
        <.page_header id="group-notices-header" icon="hero-bell-alert" class="px-1" compact>
          {gettext("Notices")}
          <:subtitle>
            <span id="group-notices-followers">
              {ngettext("%{count} follower", "%{count} followers", @state.followers)}
            </span>
          </:subtitle>
          <:actions :if={@can_follow}>
            <.button
              :if={!@state.following?}
              id="group-notices-follow"
              type="button"
              phx-click="notice_follow"
              variant="primary"
              size="sm"
            >
              <.icon name="hero-bell" class="size-4" />
              <span>{gettext("Follow")}</span>
            </.button>
            <.button
              :if={@state.following?}
              id="group-notices-unfollow"
              type="button"
              phx-click="notice_unfollow"
              variant="soft"
              size="sm"
              title={gettext("Stop following")}
            >
              <.icon name="hero-check" class="size-4" />
              <span>{gettext("Following")}</span>
            </.button>
          </:actions>
        </.page_header>

        <p
          :if={@can_follow and !@state.following?}
          id="group-notices-follow-hint"
          class="mb-4 px-1 text-sm text-base-content/70"
        >
          {gettext(
            "Follow the group and its notices come to you, with their own counter, apart from its messages."
          )}
        </p>

        <div
          :if={@state.following?}
          id="group-notices-push"
          class="mb-4 flex flex-col gap-1 rounded-2xl border border-base-300/70 bg-base-100/70 px-4 py-3"
        >
          <NoticeComponents.push_switch
            id="group-notices-push-switch"
            checked={@state.push?}
            disabled={!@current_profile.notice_push}
            label={gettext("Push notifications for this group's notices")}
            phx-click="notice_follow_push"
            phx-value-push={to_string(!@state.push?)}
          />
          <NoticeComponents.push_off_note
            :if={!@current_profile.notice_push}
            id="group-notices-push-off"
          />
        </div>

        <.form
          :if={@can_send && @form}
          for={@form}
          id="group-notice-form"
          phx-change="notice_validate"
          phx-submit="notice_send"
          class="mb-6 rounded-3xl border border-base-300/70 bg-base-100/80 p-4 shadow-sm sm:p-5"
        >
          <.input
            field={@form[:body]}
            id="group-notice-body"
            type="textarea"
            label={gettext("New notice")}
            placeholder={gettext("What should the followers know?")}
            rows="4"
            maxlength={GroupNotice.max_body_length()}
            phx-debounce="300"
          />
          <div class="mt-2 flex flex-wrap items-center justify-between gap-3">
            <span id="group-notice-length" class="text-xs tabular-nums text-base-content/60">
              {body_length(@form)} / {GroupNotice.max_body_length()}
            </span>
            <.button
              id="group-notice-send"
              type="submit"
              variant="primary"
              phx-disable-with={gettext("Sending...")}
              data-confirm={
                ngettext(
                  "Send this notice to %{count} follower? It cannot be changed afterwards.",
                  "Send this notice to %{count} followers? It cannot be changed afterwards.",
                  @recipients
                )
              }
            >
              <.icon name="hero-paper-airplane" class="size-4" />
              <span>
                {ngettext("Send to %{count} follower", "Send to %{count} followers", @recipients)}
              </span>
            </.button>
          </div>
          <p class="mt-3 text-xs text-base-content/60">
            {gettext(
              "It reaches the followers who see the group, as a push too. A notice cannot be edited; deleting it removes it for everyone."
            )}
          </p>
        </.form>

        <div
          id="group-notices"
          phx-update="stream"
          phx-hook=".NoticeFocus"
          class="flex flex-col gap-3"
        >
          <p
            id="group-notices-empty"
            class="hidden rounded-2xl border border-base-300/60 bg-base-100/70 px-4 py-3 text-sm text-base-content/70 only:block"
          >
            {gettext("The group has not sent a notice yet.")}
          </p>
          <article
            :for={{dom_id, notice} <- @notices}
            id={dom_id}
            data-focus={@focus_id == notice.id && "true"}
            class={[
              "rounded-3xl border bg-base-100/80 px-4 py-3 shadow-sm transition",
              if(@focus_id == notice.id,
                do: "border-primary ring-2 ring-primary/30",
                else: "border-base-300/70"
              )
            ]}
          >
            <header class="mb-1 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs text-base-content/60">
              <Components.local_time id={"#{dom_id}-time"} datetime={notice.inserted_at} />
              <span :if={@access.member? and notice.creator} id={"#{dom_id}-author"}>
                {"· " <> notice.creator.username}
              </span>
              <span :if={@can_send} id={"#{dom_id}-reached"}>
                {"· " <>
                  ngettext(
                    "reached %{count} follower",
                    "reached %{count} followers",
                    notice.recipients_count
                  )}
              </span>
              <.icon_button
                :if={Notices.can_delete?(@current_profile, @access, @group, notice)}
                id={"#{dom_id}-delete"}
                icon="hero-trash"
                label={gettext("Delete notice")}
                variant="danger"
                size="xs"
                class="ml-auto"
                phx-click="notice_delete"
                phx-value-id={notice.id}
                data-confirm={gettext("Delete this notice for everyone who received it?")}
              />
            </header>
            <NoticeComponents.notice_body body={notice.body} />
          </article>
        </div>

        <div :if={@more} class="mt-4 flex justify-center">
          <.button id="group-notices-load-more" type="button" phx-click="notice_load_more">
            {gettext("Load more")}
          </.button>
        </div>
      </Components.tab_body>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".NoticeFocus">
      // A link to one notice (a push, the list of notices) opens on it.
      export default {
        mounted() {
          this.el.querySelector("[data-focus='true']")?.scrollIntoView({block: "center"})
        },
      }
    </script>
    """
  end

  # The author is left out, as a notice never reaches the one who sends it.
  defp recipients(%{followers: followers, following?: following?}),
    do: max(followers - if(following?, do: 1, else: 0), 0)

  defp body_length(form) do
    case form[:body].value do
      body when is_binary(body) -> body |> String.codepoints() |> length()
      _none -> 0
    end
  end
end
