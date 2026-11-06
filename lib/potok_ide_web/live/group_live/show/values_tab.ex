defmodule PotokIdeWeb.GroupLive.Show.ValuesTab do
  use PotokIdeWeb, :html

  alias PotokIde.Social.{Access, Group, Value}
  alias PotokIde.Storage
  alias PotokIdeWeb.GroupLive.Show.Components
  import PotokIdeWeb.GroupLive.Show.Components, only: [inspect_tree: 1]

  attr :values, :any, required: true
  attr :has_more, :boolean, required: true

  attr :has_newer, :boolean,
    default: false,
    doc: "the feed shows earlier values and newer ones are not loaded"

  attr :group, :map, required: true
  attr :current_profile, :map, default: nil
  attr :editing_value_id, :integer, default: nil
  attr :editing_value, :map, default: nil
  attr :edit_value_form, :any, default: nil
  attr :new_value_form, :any, required: true
  attr :replying_to_value, :map, default: nil
  attr :thread_origin, :map, default: nil

  attr :focus_value_id, :integer,
    default: nil,
    doc: "the linked value (`?value=`) the feed opens at instead of the newest"

  attr :is_member, :boolean, required: true
  attr :access, Access, required: true
  attr :attachments, Phoenix.LiveView.UploadConfig, required: true
  attr :can_attach, :boolean, default: false

  attr :share_id, :string,
    default: nil,
    doc: "content shared from another app (`?share=`) for the composer to take"

  def panel(%{access: access, group: group, current_profile: profile} = assigns) do
    assigns =
      assigns
      |> assign(:can_post, Access.can_post_in_chat?(profile, access, group))
      |> assign(:can_react, Access.can_react_in_chat?(profile, access, group))
      |> assign(:can_delete_any, Access.can?(access, :delete_values))
      |> assign(:can_block, Access.can?(access, :remove_members) and Group.open_chat?(group))
      # Threads are sub-groups, which direct conversations do not have.
      |> assign(
        :can_thread,
        Access.can?(access, :open_threads) and not group.is_direct
      )

    ~H"""
    <div id="group-panel-values" class="card flex min-h-0 flex-1 shadow-sm">
      <div class="flex min-h-0 flex-1 flex-col">
        <div
          :if={@thread_origin}
          id="group-thread-origin"
          class="relative z-10 flex shrink-0 items-start gap-3 border-b border-base-300/70 bg-base-100/95 px-4 py-3 backdrop-blur cramped:items-center cramped:py-1 sm:px-6"
        >
          <span class="mt-0.5 inline-flex size-8 shrink-0 items-center justify-center rounded-full bg-primary/10 text-primary cramped:hidden">
            <.icon name="hero-chat-bubble-left-right" class="size-4" />
          </span>
          <div class="min-w-0 flex-1">
            <p class="flex items-center gap-1.5 text-xs text-base-content/65 cramped:hidden">
              <span class="font-semibold uppercase tracking-[0.14em]">{gettext("Thread")}</span>
              <span aria-hidden="true">·</span>
              <span class="truncate font-semibold text-base-content">
                {@thread_origin.creator.username}
              </span>
            </p>
            <p class="mt-0.5 line-clamp-2 text-sm text-base-content/75 wrap-break-word cramped:mt-0 cramped:line-clamp-1">
              {Value.excerpt(@thread_origin, 240)}
            </p>
          </div>
          <.icon_button
            id="group-thread-origin-link"
            navigate={~p"/groups/#{@thread_origin.group_id}/values?#{[value: @thread_origin.id]}"}
            icon="hero-arrow-up-right"
            label={gettext("Show original message")}
          />
        </div>

        <div class="relative flex min-h-0 flex-1 flex-col">
          <div
            id="group-values-feed"
            phx-hook=".ValuesFeed"
            data-focus-value-id={@focus_value_id}
            data-has-newer={to_string(@has_newer)}
            data-today-label={gettext("Today")}
            data-yesterday-label={dgettext("events", "Yesterday")}
            class={[
              "relative flex min-h-0 flex-1 overflow-y-auto overscroll-contain flex-col gap-4 px-2 py-2 [overflow-anchor:none] sm:px-6 sm:py-5"
            ]}
          >
            <div :if={@has_more} class="flex justify-center">
              <.button
                id="group-values-load-more"
                type="button"
                phx-click="load_more_values"
                size="sm"
              >
                {gettext("Load earlier messages")}
              </.button>
            </div>

            <div id="group-values-list" class="flex flex-col" phx-update="stream">
              <div
                id="group-values-empty"
                class="hidden min-h-56 items-center justify-center rounded-3xl border border-dashed border-base-300 bg-base-100/70 px-6 text-center text-sm text-base-content/65 only:flex"
              >
                {if(@can_post,
                  do: gettext("No messages yet. Start the conversation below."),
                  else: gettext("No messages yet.")
                )}
              </div>

              <.inspect_tree
                :if={false}
                id="value-message-assigns"
                data={@values}
                label="values"
                class="mb-3 w-full"
              />
              <Components.value_message
                :for={{dom_id, value} <- @values}
                dom_id={dom_id}
                value={value}
                uses_api={@group.uses_api}
                current_profile={@current_profile}
                editing_value_id={@editing_value_id}
                can_react={@can_react}
                can_reply={@can_post}
                can_thread={@can_thread}
                can_join_thread={@is_member}
                can_delete_any={@can_delete_any}
                can_block={@can_block}
                can_tag={@is_member}
                outsider={!@is_member}
              />
            </div>

            <div :if={@has_newer} class="flex justify-center">
              <.button
                id="group-values-load-newer"
                type="button"
                phx-click="load_newer_values"
                size="sm"
              >
                {gettext("Load newer messages")}
              </.button>
            </div>
          </div>

          <%!-- `.ValuesFeed` shows the button while the feed is scrolled away from the newest values,
             and lights the dot when others post meanwhile. Ignored so patches keep its state. --%>
          <div
            id="group-values-jump-latest-wrap"
            phx-update="ignore"
            class="pointer-events-none absolute right-4 bottom-4 z-20 sm:right-6"
          >
            <button
              id="group-values-jump-latest"
              type="button"
              inert
              aria-label={gettext("Jump to latest messages")}
              title={gettext("Jump to latest messages")}
              class="relative inline-flex size-10 translate-y-2 items-center justify-center rounded-full border border-base-300 bg-base-100/95 text-base-content/70 opacity-0 shadow-lg shadow-base-content/10 backdrop-blur transition duration-200 ease-out hover:bg-base-200 hover:text-base-content active:scale-95 data-visible:pointer-events-auto data-visible:translate-y-0 data-visible:opacity-100"
            >
              <.icon name="hero-arrow-down" class="size-5" />
              <span
                data-new-values
                hidden
                class="absolute -top-0.5 -right-0.5 size-3 rounded-full bg-primary ring-2 ring-base-100"
              >
              </span>
            </button>
          </div>
        </div>

        <Components.reaction_picker :if={@can_react} />

        <.value_sheet />

        <div
          :if={@can_post or @editing_value}
          class="relative z-10 shrink-0 border-t border-base-300/70 bg-base-100/95 px-2 py-1.5 shadow-[0_-12px_24px_rgba(0,0,0,0.08)] backdrop-blur sm:px-6 sm:py-4"
        >
          <.composer_context
            :if={@replying_to_value && !@editing_value}
            id="group-value-reply-preview"
            icon="hero-arrow-uturn-left"
            title={gettext("Replying to %{username}", username: @replying_to_value.creator.username)}
            text={Value.excerpt(@replying_to_value, 160)}
            cancel_id="group-value-reply-cancel"
            cancel_event="cancel_reply_value"
            cancel_label={gettext("Cancel reply")}
          />
          <%!-- Fills the composer with what was shared from another app (`assets/js/share_inbox.js`). --%>
          <div
            :if={@share_id && !@editing_value}
            id="group-value-share"
            phx-hook="ShareComposer"
            data-share-id={@share_id}
            data-can-attach={to_string(@can_attach)}
            data-max-files={Storage.max_files()}
            data-max-file-size={Storage.max_file_size()}
            hidden
          >
          </div>
          <%!-- `.MentionComposer` suggests `@` mentions; it handles keys before `.SubmitOnEnter`. --%>
          <div id="group-value-mentions" phx-hook=".MentionComposer" class="relative">
            <div
              id="group-value-mention-menu"
              phx-update="ignore"
              hidden
              role="listbox"
              aria-label={gettext("Mention suggestions")}
              class="absolute inset-x-0 bottom-full z-30 mb-2 max-h-[min(18rem,40dvh)] overflow-y-auto rounded-2xl border border-base-300/70 bg-base-100 p-1.5 shadow-xl shadow-base-content/10"
            >
            </div>
            <%= if @editing_value do %>
              <%!-- Files stay as they are, so a value with files may lose its text. --%>
              <.form
                for={@edit_value_form}
                id={"edit-value-form-#{@editing_value.id}"}
                class={composer_form_class()}
                phx-change="validate_edit_value"
                phx-submit="save_edit_value"
              >
                <.composer_context
                  id="group-value-edit-bar"
                  icon="hero-pencil-square"
                  title={gettext("Editing message")}
                  text={Value.excerpt(@editing_value, 160)}
                  cancel_id="group-value-edit-cancel"
                  cancel_event="cancel_edit_value"
                  cancel_label={gettext("Cancel")}
                />
                <.composer_row
                  field={@edit_value_form[:content]}
                  input_id={"edit-value-content-#{@editing_value.id}"}
                  submit_id={"edit-value-submit-#{@editing_value.id}"}
                  submit_icon="hero-check"
                  submit_label={gettext("Save changes")}
                  has_attachments={attachments?(@editing_value)}
                  focus_on_mount
                />
              </.form>
            <% else %>
              <%!-- Files can be dropped anywhere on the form; LiveView marks it `phx-drop-target-active` meanwhile. --%>
              <.form
                for={@new_value_form}
                id="group-value-form"
                class={composer_form_class()}
                phx-change="validate_value"
                phx-submit="create_value"
                phx-drop-target={@can_attach && @attachments.ref}
              >
                <div
                  :if={@can_attach and @attachments.entries != []}
                  id="group-value-attachments"
                  class="mb-2 flex max-h-28 flex-col gap-1.5 overflow-y-auto sm:max-h-56"
                >
                  <div
                    :for={entry <- @attachments.entries}
                    id={"group-value-attachment-#{entry.ref}"}
                    phx-mounted={
                      JS.transition(
                        {"transition ease-out duration-150", "opacity-0 translate-y-1",
                         "opacity-100 translate-y-0"}
                      )
                    }
                    class={[
                      "flex shrink-0 items-center gap-3 rounded-2xl border py-2 pr-2 pl-2.5",
                      if(entry.valid?,
                        do: "border-base-300 bg-base-200/60",
                        else: "border-error/40 bg-error/5"
                      )
                    ]}
                  >
                    <span class={[
                      "inline-flex size-9 shrink-0 items-center justify-center rounded-xl",
                      if(entry.valid?,
                        do: "bg-base-100 text-base-content/65",
                        else: "bg-error/10 text-error"
                      )
                    ]}>
                      <.icon name={Components.file_icon(entry.client_type)} class="size-5" />
                    </span>
                    <div class="min-w-0 flex-1">
                      <div class="flex items-baseline gap-2">
                        <p class="truncate text-sm font-medium text-base-content">
                          {entry.client_name}
                        </p>
                        <span class="shrink-0 text-xs tabular-nums text-base-content/65">
                          {Components.format_bytes(entry.client_size)}
                        </span>
                      </div>
                      <div
                        :if={entry.valid? and entry.progress > 0 and !entry.done?}
                        role="progressbar"
                        aria-valuemin="0"
                        aria-valuemax="100"
                        aria-valuenow={entry.progress}
                        aria-label={gettext("Upload progress")}
                        class="mt-1.5 h-1 overflow-hidden rounded-full bg-base-300"
                      >
                        <div
                          class="h-full rounded-full bg-primary transition-[width] duration-200 ease-out"
                          style={"width: #{entry.progress}%"}
                        >
                        </div>
                      </div>
                      <p
                        :for={error <- upload_errors(@attachments, entry)}
                        class="mt-0.5 text-xs text-error"
                      >
                        {upload_error_message(error)}
                      </p>
                    </div>
                    <.icon_button
                      id={"group-value-attachment-cancel-#{entry.ref}"}
                      type="button"
                      phx-click="cancel_attachment"
                      phx-value-ref={entry.ref}
                      icon="hero-x-mark"
                      label={gettext("Remove file")}
                    />
                  </div>
                </div>
                <p
                  :for={error <- if(@can_attach, do: upload_errors(@attachments), else: [])}
                  id={"group-value-attachments-error-#{error}"}
                  class="mb-2 flex items-center gap-2 px-1 text-sm text-error"
                >
                  <.icon name="hero-exclamation-circle" class="size-4 shrink-0" />
                  {upload_error_message(error)}
                </p>
                <%!-- `.ComposerSubmit` re-checks the button when files come and go; typing is handled by `.SubmitOnEnter`. --%>
                <.composer_row
                  field={@new_value_form[:content]}
                  input_id="group-value-content"
                  submit_id="group-value-submit"
                  submit_icon="hero-paper-airplane"
                  submit_label={gettext("Send message")}
                  has_attachments={@can_attach and Enum.any?(@attachments.entries, & &1.valid?)}
                >
                  <label
                    :if={@can_attach}
                    id="group-value-attach"
                    title={gettext("Add files")}
                    class={[
                      icon_button_class("ghost", "md"),
                      "has-focus-visible:ring-2 has-focus-visible:ring-primary/40"
                    ]}
                  >
                    <.icon name="hero-paper-clip" class="size-5" />
                    <span class="sr-only">{gettext("Add files")}</span>
                    <.live_file_input upload={@attachments} class="sr-only" />
                  </label>
                </.composer_row>
              </.form>
            <% end %>
          </div>
        </div>

        <div
          :if={!@can_post and !@editing_value}
          id="group-value-composer-disabled"
          class="relative z-10 flex shrink-0 items-center gap-2 border-t border-base-300/70 bg-base-100/95 px-4 py-4 text-sm text-base-content/65 backdrop-blur sm:px-6"
        >
          <.icon name="hero-no-symbol" class="size-4 shrink-0" />
          {if(@is_member,
            do: gettext("Your roles in this group do not allow posting messages."),
            else: gettext("You cannot write in this group.")
          )}
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".ValuesFeed">
          // The feed counts as showing the newest values this close to its bottom.
          const NEAR_LATEST_PX = 200
          // The feed counts as resting on the newest value this close to its bottom.
          const AT_BOTTOM_PX = 4
          // One author's values this close in time read as one run.
          const RUN_GAP_MS = 5 * 60 * 1000
          // The reader moving the feed, which ends holding a value in view.
          const READER_MOVES = ["wheel", "touchstart", "pointerdown", "keydown"]

          // The feed may show a run of earlier values without the newest ones
          // (`data-has-newer`): after a jump to a quoted or linked value, or once
          // the newest were dropped to keep the feed short. Scrolling then loads
          // newer pages, and the jump button reloads the newest.
          export default {
            mounted() {
              this.loadingMoreValues = false
              this.loadingNewerValues = false
              this.nearLatest = true
              this.atBottom = true
              this.lastScrollTop = 0
              this.hadNewer = this.hasNewer()
              this.anchor = null
              this.heldValue = null
              this.jumpButton = document.getElementById("group-values-jump-latest")
              this.newValuesDot = this.jumpButton?.querySelector("[data-new-values]")

              this.handleClick = (event) => {
                if (event.target.closest("#group-values-load-more")) this.loadingMoreValues = true
                if (event.target.closest("#group-values-load-newer")) this.loadingNewerValues = true
              }

              this.handleScroll = () => {
                this.anchor = this.findAnchor()
                this.notePosition()

                if (this.el.scrollTop <= 16) {
                  this.loadMoreValues()
                } else if (this.distanceToBottom() <= NEAR_LATEST_PX && this.hasNewer()) {
                  this.loadNewerValues()
                }
              }

              // Reply quotes dispatch this with the quoted value's id (`JS.dispatch`).
              this.handleShowValue = (event) => {
                const id = event.detail.id
                const target = document.getElementById(`value-${id}`)

                if (target) {
                  this.showValue(target, "smooth")
                } else {
                  this.pushEvent("show_value", { id })
                }
              }

              this.releaseValue = () => {
                this.heldValue = null
              }

              this.handleJumpClick = () => {
                if (this.hasNewer()) {
                  this.pushEvent("jump_to_latest_values", {})
                } else {
                  this.el.scrollTo({ top: this.el.scrollHeight, behavior: "smooth" })
                }
              }

              this.el.addEventListener("click", this.handleClick)
              this.el.addEventListener("scroll", this.handleScroll)
              this.el.addEventListener("potok:show-value", this.handleShowValue)
              READER_MOVES.forEach(name => this.el.addEventListener(name, this.releaseValue, { passive: true }))
              this.jumpButton?.addEventListener("click", this.handleJumpClick)

              this.feedHeight = this.el.clientHeight
              this.resizeObserver = new ResizeObserver(() => this.keepViewOnResize())
              this.resizeObserver.observe(this.el)
              this.resizeObserver.observe(this.el.querySelector("#group-values-list"))
              this.markRuns()

              // A link to a value (`?value=`) opens the feed at it instead of the newest.
              requestAnimationFrame(() => {
                const focusValueId = this.el.dataset.focusValueId
                const target = focusValueId && document.getElementById(`value-${focusValueId}`)

                if (target) {
                  this.showValue(target, "instant")
                } else {
                  this.scrollToLatest()
                }
              })

              // Others' values do not pull a feed scrolled up to earlier ones;
              // the dot on the jump button tells of them instead.
              this.handleEvent("scroll_values_to_latest", ({ force }) => {
                if (force || (this.nearLatest && !this.hasNewer())) {
                  this.scrollToLatest()
                } else {
                  this.newValuesDot?.removeAttribute("hidden")
                }
              })

              // The server loaded the chat around a quoted value.
              this.handleEvent("show_value", ({ id }) => {
                const target = document.getElementById(`value-${id}`)
                if (target) this.showValue(target, "instant")
              })
            },

            updated() {
              this.markRuns()

              // Values that came or went above the view (an earlier page, values
              // dropped to keep the feed short, a reload) would move what is on
              // screen; scrolling by as much keeps the value at the top in place.
              // The feed sets `overflow-anchor: none`, so the browser never moves
              // it first. The shift counts from the position noted with the
              // anchor: values removed before others were added can clamp
              // `scrollTop` in the middle of the patch.
              const anchored = this.anchor && document.getElementById(this.anchor.id)

              if (anchored) {
                const shift = anchored.offsetTop - this.anchor.offset
                if (shift !== 0) this.el.scrollTop = this.anchor.scrollTop + shift
              }

              this.anchor = this.findAnchor()

              // Not on every update: a value just added below would turn off
              // following the newest before `scroll_values_to_latest` comes.
              if (this.hasNewer() !== this.hadNewer) {
                this.hadNewer = this.hasNewer()
                this.setNearLatest(this.distanceToBottom() <= NEAR_LATEST_PX && !this.hadNewer)
              }

              requestAnimationFrame(() => {
                this.loadingMoreValues = false
                this.loadingNewerValues = false
              })
            },

            destroyed() {
              clearTimeout(this.highlightTimer)
              this.resizeObserver.disconnect()
              this.el.removeEventListener("click", this.handleClick)
              this.el.removeEventListener("scroll", this.handleScroll)
              this.el.removeEventListener("potok:show-value", this.handleShowValue)
              READER_MOVES.forEach(name => this.el.removeEventListener(name, this.releaseValue))
              this.jumpButton?.removeEventListener("click", this.handleJumpClick)
            },

            // Streamed values do not know their neighbours, which change as pages
            // load and values go, so what depends on them is worked out here.
            markRuns() {
              const items = this.el.querySelectorAll("#group-values-list > [data-creator-id]")
              let previous = null

              items.forEach(item => {
                const at = new Date(item.dataset.at)
                const newDay = !previous || at.toDateString() !== previous.at.toDateString()
                const continued =
                  !newDay &&
                  item.dataset.creatorId === previous.creator &&
                  at - previous.at <= RUN_GAP_MS

                item.toggleAttribute("data-continued", continued)

                const label = newDay ? this.dayLabel(at) : null
                if (label !== item.getAttribute("data-day-label")) {
                  label ? item.setAttribute("data-day-label", label) : item.removeAttribute("data-day-label")
                }

                previous = { at, creator: item.dataset.creatorId }
              })
            },

            dayLabel(date) {
              const today = new Date()
              const yesterday = new Date(today)
              yesterday.setDate(today.getDate() - 1)

              if (date.toDateString() === today.toDateString()) return this.el.dataset.todayLabel
              if (date.toDateString() === yesterday.toDateString()) return this.el.dataset.yesterdayLabel

              // Intl writes a bare `sr` in Cyrillic, while the app's `sr` is Latin.
              const language = document.documentElement.lang

              return new Intl.DateTimeFormat(language === "sr" ? "sr-Latn" : language, {
                weekday: "long",
                day: "numeric",
                month: "long",
                year: date.getFullYear() === today.getFullYear() ? undefined : "numeric",
              }).format(date)
            },

            // The feed loses height to the keyboard, a reply or a longer text, and
            // it would lose it at the bottom, where the newest values are. The
            // feed sets `overflow-anchor: none`, so the browser does not help.
            // Values grow too, with a reaction or a picture that loads; that
            // only moves a feed resting on the newest value, so nobody reading
            // earlier ones is pulled down. A value jumped to stays where it is.
            keepViewOnResize() {
              const change = this.feedHeight - this.el.clientHeight
              this.feedHeight = this.el.clientHeight

              if (this.heldValue?.isConnected) {
                this.heldValue.scrollIntoView({ block: "center", behavior: "instant" })
              } else if (change === 0) {
                if (this.atBottom && !this.hasNewer()) this.scrollToLatest()
              } else if (this.nearLatest) {
                this.scrollToLatest()
              } else {
                this.el.scrollTop += change
              }
            },

            hasNewer() {
              return this.el.dataset.hasNewer === "true"
            },

            distanceToBottom() {
              return this.el.scrollHeight - this.el.scrollTop - this.el.clientHeight
            },

            // Content that grows moves no scroll position, and it can grow between
            // a scroll and its event, a frame later: a picture, a font. So a feed
            // resting on the newest value leaves it only by going up; the resize
            // observer takes it back down.
            notePosition() {
              const stayed = this.atBottom && this.el.scrollTop >= this.lastScrollTop
              const distance = stayed ? 0 : this.distanceToBottom()

              this.lastScrollTop = this.el.scrollTop
              this.atBottom = distance <= AT_BOTTOM_PX
              this.setNearLatest(distance <= NEAR_LATEST_PX && !this.hasNewer())
            },

            // The first value showing at the top of the feed, found by binary
            // search, with its place in the scrolled content (the feed is the
            // values' offset parent) and the scroll position at the time.
            findAnchor() {
              const items = this.el.querySelectorAll("#group-values-list > [id^='value-']")
              const top = this.el.scrollTop
              let low = 0
              let high = items.length - 1
              let anchor = null

              while (low <= high) {
                const mid = (low + high) >> 1
                const item = items[mid]

                if (item.offsetTop + item.offsetHeight > top) {
                  anchor = item
                  high = mid - 1
                } else {
                  low = mid + 1
                }
              }

              return anchor && { id: anchor.id, offset: anchor.offsetTop, scrollTop: top }
            },

            scrollToLatest() {
              this.heldValue = null
              this.el.scrollTop = this.el.scrollHeight
              this.lastScrollTop = this.el.scrollTop
              this.atBottom = true
              this.setNearLatest(!this.hasNewer())
            },

            showValue(target, behavior) {
              target.scrollIntoView({ block: "center", behavior })
              // Pictures above it get their height only after this and would push
              // it out of view, so the feed holds it until the reader moves. The
              // position is noted now, as the scroll event comes a frame after the
              // resize observer's first report.
              this.heldValue = target
              this.atBottom = false
              this.notePosition()

              clearTimeout(this.highlightTimer)
              this.highlighted?.removeAttribute("data-highlighted")
              target.setAttribute("data-highlighted", "true")
              this.highlighted = target
              this.highlightTimer = setTimeout(() => {
                target.removeAttribute("data-highlighted")
              }, 1600)
            },

            // Away from the newest values the jump button shows; back at them
            // it hides and the dot goes out.
            setNearLatest(near) {
              if (near === this.nearLatest) {
                return
              }

              this.nearLatest = near

              if (!this.jumpButton) {
                return
              }

              this.jumpButton.toggleAttribute("data-visible", !near)
              this.jumpButton.inert = near

              if (near) {
                this.newValuesDot?.setAttribute("hidden", "")
              }
            },

            loadMoreValues() {
              if (this.loadingMoreValues) {
                return
              }

              const loadMoreButton = this.el.querySelector("#group-values-load-more")
              if (!loadMoreButton) {
                return
              }

              this.loadingMoreValues = true
              this.pushEvent("load_more_values", {})
            },

            loadNewerValues() {
              if (this.loadingNewerValues || !this.el.querySelector("#group-values-load-newer")) {
                return
              }

              this.loadingNewerValues = true
              this.pushEvent("load_newer_values", {})
            },
          }
        </script>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".MentionComposer">
          // Suggests members and roles for the `@handle` being typed in the
          // composer. Suggestions come from the server (`suggest_mentions`).
          // Keys are caught in the capture phase, before `.SubmitOnEnter`, so
          // Enter picks a suggestion instead of sending the value.
          const MENTION_AT_CARET = /(?:^|[^\p{L}\p{Nd}_.@-])@([\p{L}\p{Nd}_.-]{0,32})$/u

          export default {
            mounted() {
              this.menu = this.el.querySelector("#group-value-mention-menu")
              this.items = []
              this.activeIndex = 0
              this.range = null
              this.requestId = 0

              this.handleInput = (event) => {
                if (event.target.matches("textarea")) this.scheduleLookup(event.target)
              }

              this.handleKeydown = (event) => {
                if (!event.target.matches("textarea") || !this.isOpen()) return

                if (event.key === "ArrowDown" || event.key === "ArrowUp") {
                  const step = event.key === "ArrowDown" ? 1 : -1
                  this.activeIndex = (this.activeIndex + step + this.items.length) % this.items.length
                  this.render()
                } else if ((event.key === "Enter" || event.key === "Tab") && !event.shiftKey) {
                  this.select(this.activeIndex)
                } else if (event.key === "Escape") {
                  this.close()
                } else {
                  return
                }

                event.preventDefault()
                event.stopPropagation()
              }

              // Keep the textarea focused while a suggestion is clicked.
              this.handleMenuMousedown = (event) => event.preventDefault()
              this.handleMenuClick = (event) => {
                const option = event.target.closest("[data-mention-index]")
                if (option) this.select(Number(option.dataset.mentionIndex))
              }
              this.handleFocusOut = (event) => {
                if (!this.el.contains(event.relatedTarget)) this.close()
              }

              this.el.addEventListener("input", this.handleInput)
              this.el.addEventListener("keydown", this.handleKeydown, true)
              this.el.addEventListener("focusout", this.handleFocusOut)
              this.menu.addEventListener("mousedown", this.handleMenuMousedown)
              this.menu.addEventListener("click", this.handleMenuClick)
              this.handleEvent("value_composer_reset", () => this.close())
            },

            destroyed() {
              clearTimeout(this.lookupTimer)
              this.el.removeEventListener("input", this.handleInput)
              this.el.removeEventListener("keydown", this.handleKeydown, true)
              this.el.removeEventListener("focusout", this.handleFocusOut)
            },

            textarea() {
              return this.el.querySelector("textarea")
            },

            isOpen() {
              return !this.menu.hidden && this.items.length > 0
            },

            // The `@handle` that ends at the caret, if any.
            mentionAtCaret(textarea) {
              if (!textarea || textarea.selectionStart !== textarea.selectionEnd) return null

              const caret = textarea.selectionStart
              const match = textarea.value.slice(0, caret).match(MENTION_AT_CARET)
              if (!match) return null

              return { query: match[1], start: caret - match[1].length - 1, end: caret }
            },

            scheduleLookup(textarea) {
              clearTimeout(this.lookupTimer)
              const mention = this.mentionAtCaret(textarea)

              if (!mention) {
                this.close()
                return
              }

              this.lookupTimer = setTimeout(() => this.lookup(mention), 120)
            },

            lookup(mention) {
              const requestId = ++this.requestId

              this.pushEvent("suggest_mentions", { query: mention.query }, (reply) => {
                // Drop stale replies and replies for a caret that moved on.
                const current = this.mentionAtCaret(this.textarea())
                if (requestId !== this.requestId || !current || current.start !== mention.start) return

                this.range = current
                this.items = reply.items || []
                this.activeIndex = 0
                this.render()
              })
            },

            render() {
              if (this.items.length === 0) {
                this.close()
                return
              }

              this.menu.replaceChildren(...this.items.map((item, index) => this.renderItem(item, index)))
              this.menu.hidden = false
              this.textarea()?.setAttribute("aria-expanded", "true")
              this.menu.querySelector("[aria-selected=true]")?.scrollIntoView({ block: "nearest" })
            },

            renderItem(item, index) {
              const option = document.createElement("button")
              option.type = "button"
              option.id = `group-value-mention-option-${index}`
              option.dataset.mentionIndex = String(index)
              option.dataset.mentionKind = item.kind
              option.setAttribute("role", "option")
              option.setAttribute("aria-selected", String(index === this.activeIndex))
              option.className =
                "flex w-full items-center gap-3 rounded-xl px-2.5 py-2 text-left text-sm transition-colors duration-100 hover:bg-base-200 aria-selected:bg-primary/10 aria-selected:text-primary"

              const badge = document.createElement("span")

              if (item.kind === "role") {
                badge.className =
                  "inline-flex size-8 shrink-0 items-center justify-center rounded-full bg-primary/10 text-primary"
                const icon = document.createElement("span")
                icon.className = item.everyone ? "hero-megaphone size-4" : "hero-user-group size-4"
                badge.append(icon)
              } else {
                badge.className =
                  "inline-flex size-8 shrink-0 items-center justify-center overflow-hidden rounded-full border border-base-300 bg-base-300 text-xs font-semibold uppercase text-base-content/75"
                badge.textContent = item.name.slice(0, 2)

                if (item.avatar_url) {
                  const img = document.createElement("img")
                  img.src = item.avatar_url
                  img.alt = ""
                  img.className = "size-full object-cover"
                  img.addEventListener("error", () => img.remove())
                  badge.replaceChildren(img)
                }
              }

              const text = document.createElement("span")
              text.className = "flex min-w-0 flex-1 flex-col"

              const name = document.createElement("span")
              name.className = "truncate font-semibold"
              name.textContent = `@${item.name}`
              text.append(name)

              if (item.hint) {
                const hint = document.createElement("span")
                hint.className = "truncate text-xs text-base-content/65"
                hint.textContent = item.hint
                text.append(hint)
              }

              option.append(badge, text)
              return option
            },

            select(index) {
              const item = this.items[index]
              const textarea = this.textarea()
              if (!item || !textarea || !this.range) return

              const { start, end } = this.range
              const insert = `@${item.name} `
              textarea.value = textarea.value.slice(0, start) + insert + textarea.value.slice(end)

              const caret = start + insert.length
              textarea.setSelectionRange(caret, caret)
              this.close()
              textarea.focus()
              // Lets LiveView, autoresize and the send button see the new text.
              textarea.dispatchEvent(new Event("input", { bubbles: true }))
            },

            close() {
              clearTimeout(this.lookupTimer)
              this.requestId++
              this.items = []
              this.range = null
              this.menu.hidden = true
              this.menu.replaceChildren()
              this.textarea()?.setAttribute("aria-expanded", "false")
            },
          }
        </script>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".SubmitOnEnter">
          export default {
            mounted() {
              // Typing is debounced on the server, so the send button and the
              // post-submit reset are handled here instead of waiting for diffs.
              this.submitButton = this.el.form?.querySelector("button[type=submit]")
              this.handleInput = () => {
                this.autoResize()
                this.syncSubmitButton()
              }
              this.handleEvent("value_composer_reset", () => {
                this.el.value = ""
                this.autoResize()
                this.syncSubmitButton()
              })
              // Sent when a reply starts, so typing can begin right away.
              this.handleEvent("value_composer_focus", () => {
                this.el.focus()
              })
              // Enter sends on devices with a mouse (desktop web); touch keyboards
              // keep Enter as a newline, also on phones with a stylus, which report
              // a fine pointer. Shift+Enter is always a newline.
              this.sendOnEnter = window.matchMedia("(hover: hover)").matches
              this.handleKeydown = (event) => {
                if (event.key === "Escape") {
                  const editing = document.getElementById("group-value-edit-bar")

                  if (editing || document.getElementById("group-value-reply-preview")) {
                    event.preventDefault()
                    this.pushEvent(editing ? "cancel_edit_value" : "cancel_reply_value", {})
                    return
                  }
                }

                if (!this.sendOnEnter || event.key !== "Enter" || event.shiftKey || event.isComposing) {
                  return
                }

                event.preventDefault()
                this.el.form?.requestSubmit()
              }

              this.el.addEventListener("input", this.handleInput)
              this.el.addEventListener("keydown", this.handleKeydown)
              this.autoResize()
              this.syncSubmitButton()

              // An edit starts with the caret after the text.
              if (this.el.dataset.focusOnMount === "true") {
                this.el.focus()
                this.el.setSelectionRange(this.el.value.length, this.el.value.length)
                this.el.scrollTop = this.el.scrollHeight
              }
            },

            updated() {
              this.autoResize()
              this.syncSubmitButton()
            },

            destroyed() {
              this.el.removeEventListener("input", this.handleInput)
              this.el.removeEventListener("keydown", this.handleKeydown)
            },

            // A value needs text or at least one file.
            syncSubmitButton() {
              if (this.submitButton) {
                this.submitButton.disabled =
                  this.el.value.trim() === "" && this.submitButton.dataset.hasAttachments !== "true"
              }
            },

            autoResize() {
              this.el.style.height = "auto"
              this.el.style.height = `${this.el.scrollHeight}px`
            },
          }
        </script>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".ComposerSubmit">
          export default {
            mounted() {
              // A tap that moved the focus here would close the keyboard.
              this.el.addEventListener("mousedown", event => event.preventDefault())
              this.sync()
            },

            updated() {
              this.sync()
            },

            sync() {
              const textarea = this.el.form?.querySelector("textarea")
              const empty = !textarea || textarea.value.trim() === ""

              this.el.disabled = empty && this.el.dataset.hasAttachments !== "true"
            },
          }
        </script>
      </div>
    </div>
    """
  end

  # The menu of a value on touch screens, opened by a long press and filled by
  # the `ValueSheet` hook (`assets/js/value_sheet.js`), which owns its content.
  defp value_sheet(assigns) do
    ~H"""
    <dialog
      id="value-sheet"
      phx-hook="ValueSheet"
      phx-update="ignore"
      aria-labelledby="value-sheet-title"
      class="fixed inset-0 m-0 size-full max-h-none max-w-none overflow-hidden bg-transparent p-0 backdrop:bg-transparent"
    >
      <div class="flex size-full items-end justify-center sm:items-center sm:p-4">
        <div
          class="absolute inset-0 bg-black/30 backdrop-blur-[2px] dark:bg-black/60"
          data-sheet-close
          aria-hidden="true"
        >
        </div>
        <section
          tabindex="-1"
          autofocus
          class="relative flex max-h-[85dvh] w-full flex-col overflow-hidden rounded-t-3xl border border-b-0 border-base-300/70 bg-base-100 pb-[calc(0.5rem+var(--app-safe-area-bottom))] text-base-content shadow-2xl shadow-base-content/10 outline-none sm:max-w-md sm:rounded-3xl sm:border-b sm:pb-2"
        >
          <header class="flex items-start gap-3 border-b border-base-300/60 px-5 pt-4 pb-3">
            <div class="min-w-0 flex-1">
              <p class="flex items-baseline gap-2">
                <span
                  id="value-sheet-title"
                  data-sheet-title
                  class="truncate text-sm font-semibold"
                >
                </span>
                <span data-sheet-time class="shrink-0 text-xs text-base-content/65"></span>
              </p>
              <p
                data-sheet-text
                class="mt-0.5 line-clamp-2 text-sm text-base-content/70 wrap-break-word"
              >
              </p>
            </div>
            <.icon_button
              id="value-sheet-close"
              type="button"
              data-sheet-close
              icon="hero-x-mark"
              label={gettext("Close")}
              class="-mr-1"
            />
          </header>

          <div
            id="value-sheet-reactions"
            data-sheet-reactions
            class="flex items-center justify-between gap-1 border-b border-base-300/60 px-3 py-1.5"
          >
            <button
              :for={emoji <- ~w(👍 ❤️ 😂 😮 😢 🙏)}
              type="button"
              data-sheet-reaction={emoji}
              class="inline-flex size-11 items-center justify-center rounded-full text-2xl leading-none transition duration-150 hover:bg-base-200 active:scale-90"
            >
              {emoji}
            </button>
            <button
              type="button"
              data-sheet-more
              aria-label={gettext("Add reaction")}
              class="inline-flex size-11 shrink-0 items-center justify-center rounded-full text-base-content/65 transition duration-150 hover:bg-base-200 active:scale-90"
            >
              <.icon name="hero-plus" class="size-5" />
            </button>
          </div>

          <div class="min-h-0 flex-1 overflow-y-auto px-3 pt-2">
            <button
              id="value-sheet-copy"
              type="button"
              data-sheet-copy
              class="flex w-full items-center gap-3 rounded-2xl px-3 py-2.5 text-left text-sm font-medium transition duration-150 hover:bg-base-200 active:scale-[0.99]"
            >
              <.icon name="hero-clipboard-document" class="size-5 shrink-0 opacity-60" />
              {gettext("Copy")}
            </button>
            <div data-sheet-actions></div>
          </div>
        </section>
      </div>
    </dialog>
    """
  end

  defp composer_form_class do
    "flex flex-col rounded-[1.75rem] border border-base-300 bg-base-100 px-1 py-0.5 shadow-sm transition-colors duration-150 sm:p-3 [&.phx-drop-target-active]:border-primary [&.phx-drop-target-active]:bg-primary/5"
  end

  attr :id, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :text, :string, required: true
  attr :cancel_id, :string, required: true
  attr :cancel_event, :string, required: true
  attr :cancel_label, :string, required: true

  # What the composer is working on: the value replied to or edited.
  defp composer_context(assigns) do
    ~H"""
    <div
      id={@id}
      phx-mounted={
        JS.transition(
          {"transition ease-out duration-150", "opacity-0 translate-y-1", "opacity-100 translate-y-0"}
        )
      }
      class="mb-1.5 flex items-center gap-3 rounded-2xl border-l-4 border-primary bg-base-200/70 py-1 pr-1 pl-3 sm:mb-2 sm:py-2 sm:pr-2"
    >
      <.icon name={@icon} class="size-4 shrink-0 text-primary" />
      <div class="min-w-0 flex-1">
        <p class="truncate text-xs font-semibold text-primary">{@title}</p>
        <p class="truncate text-sm text-base-content/70">{@text}</p>
      </div>
      <.icon_button
        id={@cancel_id}
        type="button"
        phx-click={@cancel_event}
        icon="hero-x-mark"
        label={@cancel_label}
      />
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true
  attr :input_id, :string, required: true
  attr :submit_id, :string, required: true
  attr :submit_icon, :string, required: true
  attr :submit_label, :string, required: true
  attr :has_attachments, :boolean, default: false
  attr :focus_on_mount, :boolean, default: false
  slot :inner_block, doc: "what goes before the text, such as the button for files"

  # The text and its submit button, the same for a new value and an edit. Past
  # the height limit the text scrolls, so the button never leaves the screen.
  defp composer_row(assigns) do
    ~H"""
    <div class="flex items-end gap-1 sm:gap-1.5 [&_.fieldset]:p-0">
      {render_slot(@inner_block)}
      <.input
        field={@field}
        id={@input_id}
        aria-label={gettext("Message")}
        aria-autocomplete="list"
        aria-controls="group-value-mention-menu"
        class="m-0 block max-h-[min(9rem,30dvh)] w-full flex-auto resize-none overflow-y-auto border-0 bg-transparent px-1 py-2 text-base leading-6 text-base-content placeholder:text-base-content/40 focus:outline-none"
        placeholder={gettext("Write a message...")}
        rows="1"
        type="textarea"
        phx-debounce="400"
        phx-hook=".SubmitOnEnter"
        data-focus-on-mount={to_string(@focus_on_mount)}
      />
      <.icon_button
        id={@submit_id}
        type="submit"
        phx-hook=".ComposerSubmit"
        data-has-attachments={to_string(@has_attachments)}
        icon={@submit_icon}
        label={@submit_label}
        variant="primary"
        size="md"
      />
    </div>
    """
  end

  defp attachments?(%Value{attachments: [_ | _]}), do: true
  defp attachments?(_value), do: false

  defp upload_error_message(:too_large),
    do:
      gettext("This file is larger than %{size}.",
        size: Components.format_bytes(Storage.max_file_size())
      )

  defp upload_error_message(:too_many_files),
    do: gettext("Attach at most %{count} files.", count: Storage.max_files())

  defp upload_error_message(:external_client_failure),
    do: gettext("The upload failed. Remove the file and try again.")

  defp upload_error_message(_error), do: gettext("This file cannot be attached.")
end
