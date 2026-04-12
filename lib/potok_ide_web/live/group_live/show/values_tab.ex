defmodule PotokIdeWeb.GroupLive.Show.ValuesTab do
  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.Components
  import PotokIdeWeb.GroupLive.Show.Components, only: [inspect_tree: 1]

  attr :values, :any, required: true
  attr :pagination, :map, required: true
  attr :current_profile, :map, default: nil
  attr :online_profile_ids, :any, required: true
  attr :expanded_value_ids, :any, required: true
  attr :editing_value_id, :integer, default: nil
  attr :edit_value_form, :any, default: nil
  attr :new_value_form, :any, required: true
  attr :is_member, :boolean, required: true

  def panel(assigns) do
    ~H"""
    <div id="group-panel-values" class="card flex min-h-0 flex-1 px-2 shadow-sm">
      <div class="flex min-h-0 flex-1 flex-col">
        <div
          id="group-values-feed"
          phx-hook=".ValuesFeed"
          class="flex h-[calc(100dvh-15rem)] pb-[env(safe-area-inset-bottom,0px)+env(safe-area-inset-top,0px)]+env(safe-area-inset-top,0px)] flex-col gap-4 overflow-y-auto px-4 py-5"
        >
          <div :if={@pagination.has_more?} class="flex justify-center">
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
              current_profile={@current_profile}
              online_profile_ids={@online_profile_ids}
              expanded_value_ids={@expanded_value_ids}
              editing_value_id={@editing_value_id}
              edit_value_form={@edit_value_form}
            />
          </div>
        </div>
        
        <div
          :if={@is_member}
          class="sticky bottom-0 z-10 border-t border-base-300/70 bg-base-100/95 px-4 py-4 shadow-[0_-12px_24px_rgba(0,0,0,0.08)] backdrop-blur sm:px-6"
        >
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
              class="w-full flex-auto overflow-hidden border-0 bg-transparent px-1 py-1 m-0 text-base leading-6 text-base-content placeholder:text-base-content/40 focus:outline-none"
              placeholder={gettext("Write a value...")}
              rows="1"
              type="textarea"
              phx-hook=".SubmitOnEnter"
            />
            <.button
              aria-label={gettext("Post value")}
              disabled={!@new_value_form[:content].value or @new_value_form[:content].value == ""}
              class="btn btn-primary btn-circle size-10 flex-none"
            >
              <.icon name="hero-paper-airplane" class="size-4" />
            </.button>
          </.form>
        </div>
        
        <div
          :if={!@is_member}
          class="sticky bottom-0 z-10 border-t border-base-300/70 bg-base-100/95 px-4 py-4 shadow-[0_-12px_24px_rgba(0,0,0,0.08)] backdrop-blur sm:px-6"
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

              this.handleEvent("scroll_values_to_latest", () => {
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
              this.handleInput = () => this.autoResize()
              this.handleKeydown = (event) => {
                if (true || event.key !== "Enter" || event.shiftKey || event.isComposing) {
                  return
                }

                event.preventDefault()
                this.el.form?.requestSubmit()
              }

              this.el.addEventListener("input", this.handleInput)
              this.el.addEventListener("keydown", this.handleKeydown)
              this.autoResize()
            },

            updated() {
              this.autoResize()
            },

            destroyed() {
              this.el.removeEventListener("input", this.handleInput)
              this.el.removeEventListener("keydown", this.handleKeydown)
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
end
