defmodule PotokIdeWeb.GroupLive.Show.ValuesTab do
  use PotokIdeWeb, :html

  alias PotokIde.Social.{Access, Value}
  alias PotokIde.Storage
  alias PotokIdeWeb.GroupLive.Show.Components
  import PotokIdeWeb.GroupLive.Show.Components, only: [inspect_tree: 1]

  attr :values, :any, required: true
  attr :has_more, :boolean, required: true
  attr :group, :map, required: true
  attr :current_profile, :map, default: nil
  attr :group_path, :list, required: true
  attr :editing_value_id, :integer, default: nil
  attr :editing_value, :map, default: nil
  attr :edit_value_form, :any, default: nil
  attr :new_value_form, :any, required: true
  attr :replying_to_value, :map, default: nil
  attr :thread_origin, :map, default: nil
  attr :is_member, :boolean, required: true
  attr :access, Access, required: true
  attr :attachments, Phoenix.LiveView.UploadConfig, required: true
  attr :can_attach, :boolean, default: false

  def panel(assigns) do
    access = assigns.access

    assigns =
      assigns
      |> assign(:can_post, Access.can?(access, :post_values))
      |> assign(:can_react, Access.can?(access, :react))
      |> assign(:can_delete_any, Access.can?(access, :delete_values))
      # Threads are sub-groups, which direct conversations do not have.
      |> assign(
        :can_thread,
        Access.can?(access, :open_threads) and not assigns.group.is_direct
      )

    ~H"""
    <div id="group-panel-values" class="card flex min-h-0 flex-1 shadow-sm">
      <div class="flex min-h-0 flex-1 flex-col">
        <Components.group_path
          path={@group_path}
          group={@group}
          current_profile={@current_profile}
          class="mx-2 shadow-md"
        />
        <div
          :if={@thread_origin}
          id="group-thread-origin"
          class="relative z-10 flex shrink-0 items-start gap-3 border-b border-base-300/70 bg-base-100/95 px-4 py-3 backdrop-blur sm:px-6"
        >
          <span class="mt-0.5 inline-flex size-8 shrink-0 items-center justify-center rounded-full bg-primary/10 text-primary">
            <.icon name="hero-chat-bubble-left-right" class="size-4" />
          </span>
          <div class="min-w-0 flex-1">
            <p class="flex items-center gap-1.5 text-xs text-base-content/55">
              <span class="font-semibold uppercase tracking-[0.14em]">{gettext("Thread")}</span>
              <span aria-hidden="true">·</span>
              <span class="truncate font-semibold text-base-content">
                {@thread_origin.creator.username}
              </span>
            </p>
            <p class="mt-0.5 line-clamp-2 text-sm text-base-content/75 wrap-break-word">
              {Value.excerpt(@thread_origin, 240)}
            </p>
          </div>
          <.link
            id="group-thread-origin-link"
            navigate={~p"/groups/#{@thread_origin.group_id}/values"}
            title={gettext("Show original value")}
            aria-label={gettext("Show original value")}
            class="inline-flex size-8 shrink-0 items-center justify-center rounded-full text-base-content/55 transition-colors hover:bg-base-300 hover:text-base-content"
          >
            <.icon name="hero-arrow-up-right" class="size-4" />
          </.link>
        </div>

        <div
          id="group-values-feed"
          phx-hook=".ValuesFeed"
          class={[
            "flex min-h-0 flex-1 overflow-y-auto overscroll-contain flex-col gap-4 px-4 py-5 sm:px-6"
          ]}
        >
          <div :if={@has_more} class="flex justify-center">
            <button
              id="group-values-load-more"
              type="button"
              phx-click="load_more_values"
              class="btn btn-ghost btn-sm rounded-full border border-base-300 bg-base-100/80 px-4"
            >
              {gettext("Load earlier values")}
            </button>
          </div>

          <div id="group-values-list" class="flex flex-col gap-2" phx-update="stream">
            <div
              id="group-values-empty"
              class="hidden min-h-56 items-center justify-center rounded-3xl border border-dashed border-base-300 bg-base-100/70 px-6 text-center text-sm text-base-content/60 only:flex"
            >
              {gettext("No values yet. Start the conversation below.")}
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
            />
          </div>
        </div>

        <%!-- One picker for the whole feed; the `ReactionPicker` hook opens it from any `[data-reaction-trigger]`. --%>
        <div
          :if={@can_react}
          id="reaction-picker"
          phx-hook="ReactionPicker"
          phx-update="ignore"
          hidden
          role="dialog"
          aria-label={gettext("Add reaction")}
          data-locale={emoji_data_locale()}
          data-data-source={emoji_data_source()}
          data-i18n={Jason.encode!(emoji_picker_i18n())}
          class="reaction-picker fixed z-50 overflow-hidden border border-base-300 bg-base-100 opacity-0 translate-y-1 shadow-2xl shadow-base-content/10 transition duration-150 ease-out"
        >
        </div>

        <div
          :if={@is_member and (@can_post or @editing_value)}
          class="relative z-10 shrink-0 border-t border-base-300/70 bg-base-100/95 px-4 py-4 shadow-[0_-12px_24px_rgba(0,0,0,0.08)] backdrop-blur sm:px-6"
        >
          <%= if @editing_value do %>
            <.form
              for={@edit_value_form}
              id={"edit-value-form-#{@editing_value.id}"}
              class="space-y-3 rounded-[1.75rem] border border-base-300 bg-base-100 p-3 h-[18rem] shadow-sm"
              phx-change="validate_edit_value"
              phx-submit="save_edit_value"
            >
              <div
                id={"edit-value-editor-#{@editing_value.id}"}
                phx-hook="MarkdownEditor"
                class="space-y-2"
                data-placeholder={gettext("Write your value in Markdown")}
              >
                <div
                  id={"edit-value-editor-shell-#{@editing_value.id}"}
                  class="markdown-editor flex flex-col-reverse"
                  phx-update="ignore"
                >
                  <div
                    id={"edit-value-editor-surface-#{@editing_value.id}"}
                    data-markdown-target="editor"
                    phx-update="ignore"
                    class="!h-[10rem]"
                  >
                  </div>
                </div>
                <textarea
                  id={"edit-value-content-#{@editing_value.id}"}
                  name={@edit_value_form[:content].name}
                  data-markdown-target="input"
                  class="sr-only"
                  aria-label={gettext("Value")}
                >{Phoenix.HTML.Form.normalize_value("textarea", @edit_value_form[:content].value)}</textarea>
                <p
                  :for={error <- @edit_value_form[:content].errors}
                  class="mt-1.5 flex items-center gap-2 text-sm text-error"
                >
                  <.icon name="hero-exclamation-circle" class="size-5" /> {translate_error(error)}
                </p>
              </div>

              <div class="flex justify-end gap-2">
                <.button type="submit" variant="primary">{gettext("Save changes")}</.button>
                <.button type="button" phx-click="cancel_edit_value">{gettext("Cancel")}</.button>
              </div>
            </.form>
          <% else %>
            <div
              :if={@replying_to_value}
              id="group-value-reply-preview"
              phx-mounted={
                JS.transition(
                  {"transition ease-out duration-150", "opacity-0 translate-y-1",
                   "opacity-100 translate-y-0"}
                )
              }
              class="mb-2 flex items-center gap-3 rounded-2xl border-l-4 border-primary bg-base-200/70 py-2 pr-2 pl-3"
            >
              <.icon name="hero-arrow-uturn-left" class="size-4 shrink-0 text-primary" />
              <div class="min-w-0 flex-1">
                <p class="truncate text-xs font-semibold text-primary">
                  {gettext("Replying to %{username}",
                    username: @replying_to_value.creator.username
                  )}
                </p>
                <p class="truncate text-sm text-base-content/70">
                  {Value.excerpt(@replying_to_value, 160)}
                </p>
              </div>
              <button
                id="group-value-reply-cancel"
                type="button"
                phx-click="cancel_reply_value"
                aria-label={gettext("Cancel reply")}
                title={gettext("Cancel reply")}
                class="inline-flex size-8 shrink-0 items-center justify-center rounded-full text-base-content/55 transition-colors hover:bg-base-300 hover:text-base-content"
              >
                <.icon name="hero-x-mark" class="size-4" />
              </button>
            </div>
            <%!-- `.MentionComposer` suggests `@` mentions; it handles keys before `.SubmitOnEnter`. --%>
            <div id="group-value-mentions" phx-hook=".MentionComposer" class="relative">
              <div
                id="group-value-mention-menu"
                phx-update="ignore"
                hidden
                role="listbox"
                aria-label={gettext("Mention suggestions")}
                class="absolute inset-x-0 bottom-full z-30 mb-2 max-h-72 overflow-y-auto rounded-2xl border border-base-300/70 bg-base-100 p-1.5 shadow-xl shadow-base-content/10"
              >
              </div>
              <%!-- Files can be dropped anywhere on the form; LiveView marks it `phx-drop-target-active` meanwhile. --%>
              <.form
                for={@new_value_form}
                id="group-value-form"
                class="rounded-[1.75rem] flex flex-col border border-base-300 bg-base-100 p-3 shadow-sm transition-colors duration-150 [&.phx-drop-target-active]:border-primary [&.phx-drop-target-active]:bg-primary/5"
                phx-change="validate_value"
                phx-submit="create_value"
                phx-drop-target={@can_attach && @attachments.ref}
              >
                <div
                  :if={@can_attach and @attachments.entries != []}
                  id="group-value-attachments"
                  class="mb-2 flex flex-col gap-1.5"
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
                      "flex items-center gap-3 rounded-2xl border py-2 pr-2 pl-2.5",
                      if(entry.valid?,
                        do: "border-base-300 bg-base-200/60",
                        else: "border-error/40 bg-error/5"
                      )
                    ]}
                  >
                    <span class={[
                      "inline-flex size-9 shrink-0 items-center justify-center rounded-xl",
                      if(entry.valid?,
                        do: "bg-base-100 text-base-content/60",
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
                        <span class="shrink-0 text-xs tabular-nums text-base-content/50">
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
                    <button
                      id={"group-value-attachment-cancel-#{entry.ref}"}
                      type="button"
                      phx-click="cancel_attachment"
                      phx-value-ref={entry.ref}
                      aria-label={gettext("Remove file")}
                      title={gettext("Remove file")}
                      class="inline-flex size-8 shrink-0 items-center justify-center rounded-full text-base-content/55 transition-colors hover:bg-base-300 hover:text-base-content"
                    >
                      <.icon name="hero-x-mark" class="size-4" />
                    </button>
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
                <div class="flex items-end gap-1.5">
                  <label
                    :if={@can_attach}
                    id="group-value-attach"
                    title={gettext("Add files")}
                    class="inline-flex size-10 flex-none cursor-pointer items-center justify-center rounded-full text-base-content/55 transition duration-150 ease-out hover:bg-base-200 hover:text-base-content active:scale-95 has-focus-visible:ring-2 has-focus-visible:ring-primary/40"
                  >
                    <.icon name="hero-paper-clip" class="size-5" />
                    <span class="sr-only">{gettext("Add files")}</span>
                    <.live_file_input upload={@attachments} class="sr-only" />
                  </label>
                  <.input
                    field={@new_value_form[:content]}
                    id="group-value-content"
                    aria-label={gettext("Value")}
                    aria-autocomplete="list"
                    aria-controls="group-value-mention-menu"
                    class="m-0 w-full flex-auto overflow-hidden border-0 bg-transparent px-1 py-1 text-base leading-6 text-base-content placeholder:text-base-content/40 focus:outline-none"
                    placeholder={gettext("Write a value...")}
                    rows="1"
                    type="textarea"
                    phx-debounce="400"
                    phx-hook=".SubmitOnEnter"
                  />
                  <%!-- `.ComposerSubmit` re-checks the button when files come and go; typing is handled by `.SubmitOnEnter`. --%>
                  <.button
                    aria-label={gettext("Post value")}
                    id="group-value-submit"
                    phx-hook=".ComposerSubmit"
                    data-has-attachments={
                      to_string(@can_attach and Enum.any?(@attachments.entries, & &1.valid?))
                    }
                    class="btn btn-primary btn-circle size-10 flex-none"
                  >
                    <.icon name="hero-paper-airplane" class="size-4" />
                  </.button>
                </div>
              </.form>
            </div>
          <% end %>
        </div>

        <div
          :if={@is_member and !@can_post and !@editing_value}
          id="group-value-composer-disabled"
          class="relative z-10 flex shrink-0 items-center gap-2 border-t border-base-300/70 bg-base-100/95 px-4 py-4 text-sm text-base-content/65 backdrop-blur sm:px-6"
        >
          <.icon name="hero-no-symbol" class="size-4 shrink-0" />
          {gettext("Your roles in this group do not allow posting values.")}
        </div>

        <div
          :if={!@is_member}
          class="relative z-10 shrink-0 border-t border-base-300/70 bg-base-100/95 px-4 py-4 shadow-[0_-12px_24px_rgba(0,0,0,0.08)] backdrop-blur sm:px-6"
        >
          {gettext("Join this group to reply and post new values.")}
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".ValuesFeed">
          export default {
            mounted() {
              this.pendingPrependAdjustment = null
              this.loadingMoreValues = false

              this.handleClick = (event) => {
                const loadMoreButton = event.target.closest("#group-values-load-more")
                if (!loadMoreButton) return

                this.loadingMoreValues = true
                this.pendingPrependAdjustment = {
                  scrollTop: this.el.scrollTop,
                  scrollHeight: this.el.scrollHeight,
                }
              }

              this.handleScroll = () => {
                if (this.el.scrollTop > 16) {
                  return
                }

                this.loadMoreValues()
              }

              // Reply quotes dispatch this on the quoted value (`JS.dispatch`).
              this.handleScrollToValue = (event) => {
                const target = event.target
                target.scrollIntoView({ block: "center", behavior: "smooth" })

                clearTimeout(this.highlightTimer)
                this.highlighted?.removeAttribute("data-highlighted")
                target.setAttribute("data-highlighted", "true")
                this.highlighted = target
                this.highlightTimer = setTimeout(() => {
                  target.removeAttribute("data-highlighted")
                }, 1600)
              }

              this.el.addEventListener("click", this.handleClick)
              this.el.addEventListener("scroll", this.handleScroll)
              this.el.addEventListener("potok:scroll-to-value", this.handleScrollToValue)

              requestAnimationFrame(() => {
                this.scrollToLatest()
              })

              this.handleEvent("scroll_values_to_latest", (data) => {
                this.scrollToLatest()
              })
            },

            updated() {
              requestAnimationFrame(() => {
                this.loadingMoreValues = false

                if (!this.pendingPrependAdjustment) {
                  return
                }

                const { scrollTop, scrollHeight } = this.pendingPrependAdjustment
                const heightDelta = this.el.scrollHeight - scrollHeight

                this.el.scrollTop = scrollTop + heightDelta
                this.pendingPrependAdjustment = null
              })
            },

            destroyed() {
              clearTimeout(this.highlightTimer)
              this.el.removeEventListener("click", this.handleClick)
              this.el.removeEventListener("scroll", this.handleScroll)
              this.el.removeEventListener("potok:scroll-to-value", this.handleScrollToValue)
            },

            scrollToLatest() {
              this.el.scrollTop = this.el.scrollHeight
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
              this.pendingPrependAdjustment = {
                scrollTop: this.el.scrollTop,
                scrollHeight: this.el.scrollHeight,
              }

              this.pushEvent("load_more_values", {})
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
                if (event.target.id === "group-value-content") this.scheduleLookup(event.target)
              }

              this.handleKeydown = (event) => {
                if (event.target.id !== "group-value-content" || !this.isOpen()) return

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
              return this.el.querySelector("#group-value-content")
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
                hint.className = "truncate text-xs text-base-content/55"
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
              this.submitButton = this.el.form?.querySelector("#group-value-submit")
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
              // Enter sends on devices with a fine pointer (desktop web); touch
              // keyboards keep Enter as a newline. Shift+Enter is always a newline.
              this.sendOnEnter = window.matchMedia("(pointer: fine)").matches
              this.handleKeydown = (event) => {
                if (event.key === "Escape" && document.getElementById("group-value-reply-preview")) {
                  event.preventDefault()
                  this.pushEvent("cancel_reply_value", {})
                  return
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
              this.sync()
            },

            updated() {
              this.sync()
            },

            sync() {
              const textarea = this.el.form?.querySelector("#group-value-content")
              const empty = !textarea || textarea.value.trim() === ""

              this.el.disabled = empty && this.el.dataset.hasAttachments !== "true"
            },
          }
        </script>
      </div>
    </div>
    """
  end

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

  # Emojibase has no Serbian data, so `sr` searches with English keywords.
  defp emoji_data_locale do
    case Gettext.get_locale(PotokIdeWeb.Gettext) do
      "pl" -> "pl"
      _ -> "en"
    end
  end

  defp emoji_data_source do
    case emoji_data_locale() do
      "pl" -> ~p"/emoji/pl.json"
      _ -> ~p"/emoji/en.json"
    end
  end

  # Labels for emoji-picker-element; the shape follows its `i18n/en.js`.
  defp emoji_picker_i18n do
    %{
      categoriesLabel: pgettext("emoji picker", "Categories"),
      emojiUnsupportedMessage:
        pgettext("emoji picker", "Your browser does not support color emoji."),
      favoritesLabel: pgettext("emoji picker", "Favorites"),
      loadingMessage: pgettext("emoji picker", "Loading…"),
      networkErrorMessage: pgettext("emoji picker", "Could not load emoji."),
      regionLabel: pgettext("emoji picker", "Emoji picker"),
      searchDescription:
        pgettext(
          "emoji picker",
          "When search results are available, press up or down to select and enter to choose."
        ),
      searchLabel: pgettext("emoji picker", "Search"),
      searchResultsLabel: pgettext("emoji picker", "Search results"),
      skinToneDescription:
        pgettext("emoji picker", "When expanded, press up or down to select and enter to choose."),
      # `{skinTone}` is filled in by the picker, not by Gettext.
      skinToneLabel: pgettext("emoji picker", "Choose a skin tone (currently {skinTone})"),
      skinTonesLabel: pgettext("emoji picker", "Skin tones"),
      skinTones: [
        pgettext("emoji skin tone", "Default"),
        pgettext("emoji skin tone", "Light"),
        pgettext("emoji skin tone", "Medium-Light"),
        pgettext("emoji skin tone", "Medium"),
        pgettext("emoji skin tone", "Medium-Dark"),
        pgettext("emoji skin tone", "Dark")
      ],
      categories: %{
        "custom" => pgettext("emoji category", "Custom"),
        "smileys-emotion" => pgettext("emoji category", "Smileys and emoticons"),
        "people-body" => pgettext("emoji category", "People and body"),
        "animals-nature" => pgettext("emoji category", "Animals and nature"),
        "food-drink" => pgettext("emoji category", "Food and drink"),
        "travel-places" => pgettext("emoji category", "Travel and places"),
        "activities" => pgettext("emoji category", "Activities"),
        "objects" => pgettext("emoji category", "Objects"),
        "symbols" => pgettext("emoji category", "Symbols"),
        "flags" => pgettext("emoji category", "Flags")
      }
    }
  end
end
