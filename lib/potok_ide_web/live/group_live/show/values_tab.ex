defmodule PotokIdeWeb.GroupLive.Show.ValuesTab do
  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.Components

  attr :values, :list, required: true
  attr :current_profile, :map, default: nil
  attr :expanded_value_ids, :any, required: true
  attr :editing_value_id, :integer, default: nil
  attr :edit_value_form, :any, default: nil
  attr :new_value_form, :any, required: true
  attr :is_member, :boolean, required: true

  def panel(assigns) do
    ~H"""
    <div id="group-panel-values" class="card flex min-h-0 flex-1 bg-base-200 shadow-sm pt-4 ">
      <div class="flex min-h-0 flex-1 flex-col">
        <div
          id="group-values-feed"
          phx-hook=".ValuesFeed"
          class="flex flex-col rev gap-4 overflow-y-auto px-4 py-5 h-[calc(100dvh-18rem)]"
        >
          <div
            :if={@values == []}
            class="flex min-h-56 items-center justify-center rounded-3xl border border-dashed border-base-300 bg-base-100/70 px-6 text-center text-sm text-base-content/60"
          >
            {gettext("No values yet. Start the conversation below.")}
          </div>

          <Components.value_message
            :for={value <- @values}
            value={value}
            current_profile={@current_profile}
            expanded_value_ids={@expanded_value_ids}
            editing_value_id={@editing_value_id}
            edit_value_form={@edit_value_form}
          />
        </div>

        <div class="flex flex-auto"></div>

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
              class="min-h-24 w-full flex-auto overflow-hidden border-0 bg-transparent px-1 py-1 text-sm leading-6 text-base-content placeholder:text-base-content/40 focus:outline-none"
              placeholder={gettext("Write a value...")}
              rows="1"
              type="textarea"
              phx-hook=".SubmitOnEnter"
              required
            />

            <.button
              aria-label={gettext("Post value")}
              class="btn btn-primary btn-circle size-12 flex-none"
            >
              <.icon name="hero-paper-airplane" class="size-4" />
            </.button>
          </.form>
        </div>

        <div
          :if={!@is_member}
          class="border-t border-base-300/70 bg-base-100/70 px-4 py-4 text-sm text-base-content/60 sm:px-6"
        >
          {gettext("Join this group to reply and post new values.")}
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".ValuesFeed">
          export default {
            mounted() {
              this.pendingScroll = false

              this.handleEvent("scroll_values_to_latest", () => {
                this.pendingScroll = true
              })
            },

            updated() {
              requestAnimationFrame(() => {
                this.scrollToLatest()
                this.pendingScroll = false
              })
            },

            scrollToLatest() {
              if (this.el.classList.contains("flex-col rev")) {
                console.log("Scrolling to top (flex-col rev)", this.el.scrollHeight)
                this.el.scrollTop = this.el.scrollHeight
                return
              }
              console.log("Scrolling to bottom this.el: ", this.el.scrollHeight)
              this.el.scrollTop = this.el.scrollHeight
            },
          }
        </script>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".SubmitOnEnter">
          export default {
            mounted() {
              this.handleInput = () => this.autoResize()
              this.handleKeydown = (event) => {
                if (event.key !== "Enter" || event.shiftKey || event.isComposing) {
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
