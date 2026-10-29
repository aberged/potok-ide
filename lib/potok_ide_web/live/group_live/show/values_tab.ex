defmodule PotokIdeWeb.GroupLive.Show.ValuesTab do
  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.Components
  import PotokIdeWeb.GroupLive.Show.Components, only: [inspect_tree: 1]

  attr :values, :any, required: true
  attr :has_more, :boolean, required: true
  attr :group, :map, required: true
  attr :current_profile, :map, default: nil
  attr :editing_value_id, :integer, default: nil
  attr :editing_value, :map, default: nil
  attr :edit_value_form, :any, default: nil
  attr :new_value_form, :any, required: true
  attr :is_member, :boolean, required: true

  def panel(assigns) do
    ~H"""
    <div id="group-panel-values" class="card flex min-h-0 flex-1 shadow-sm">
      <div class="flex min-h-0 flex-1 flex-col">
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
              can_react={@is_member}
            />
          </div>
        </div>

        <%!-- One picker for the whole feed; the `ReactionPicker` hook opens it from any `[data-reaction-trigger]`. --%>
        <div
          :if={@is_member}
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
          :if={@is_member}
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
            <.form
              for={@new_value_form}
              id="group-value-form"
              class="rounded-[1.75rem] flex border border-base-300 bg-base-100 p-3 shadow-sm"
              phx-change="validate_value"
              phx-submit="create_value"
            >
              <.input
                field={@new_value_form[:content]}
                id="group-value-content"
                aria-label={gettext("Value")}
                class="m-0 w-full flex-auto overflow-hidden border-0 bg-transparent px-1 py-1 text-base leading-6 text-base-content placeholder:text-base-content/40 focus:outline-none"
                placeholder={gettext("Write a value...")}
                rows="1"
                type="textarea"
                phx-debounce="400"
                phx-hook=".SubmitOnEnter"
              />
              <.button
                aria-label={gettext("Post value")}
                id="group-value-submit"
                class="btn btn-primary btn-circle size-10 flex-none"
              >
                <.icon name="hero-paper-airplane" class="size-4" />
              </.button>
            </.form>
          <% end %>
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

              this.el.addEventListener("click", this.handleClick)
              this.el.addEventListener("scroll", this.handleScroll)

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
              this.el.removeEventListener("click", this.handleClick)
              this.el.removeEventListener("scroll", this.handleScroll)
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
              // Enter sends on devices with a fine pointer (desktop web); touch
              // keyboards keep Enter as a newline. Shift+Enter is always a newline.
              this.sendOnEnter = window.matchMedia("(pointer: fine)").matches
              this.handleKeydown = (event) => {
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

            syncSubmitButton() {
              if (this.submitButton) {
                this.submitButton.disabled = this.el.value.trim() === ""
              }
            },

            autoResize() {
              this.el.style.height = "auto"
              this.el.style.height = `${this.el.scrollHeight}px`
            },
          }
        </script>
      </div>
    </div>
    """
  end

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
