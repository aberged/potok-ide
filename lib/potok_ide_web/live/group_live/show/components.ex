defmodule PotokIdeWeb.GroupLive.Show.Components do
  use PotokIdeWeb, :html

  alias PotokIdeWeb.Avatars
  alias PotokIdeWeb.GroupLive.Show.{EventCard, MediaViewer}
  alias PotokIdeWeb.TagComponents

  alias PotokIde.Social.{Group, Mentions, Profile, Value, ValueAttachment}
  alias PotokIde.UTF8

  import Phoenix.HTML, only: [raw: 1]

  @max_group_picture_upload_size 5 * 1024 * 1024
  @max_group_picture_dimension 200

  attr :id, :string, required: true
  attr :datetime, :any, required: true
  attr :class, :any, default: nil

  def local_time(assigns) do
    assigns = assign(assigns, :iso8601, datetime_to_iso8601(assigns.datetime))

    ~H"""
    <time
      id={@id}
      phx-hook=".LocalTime"
      datetime={@iso8601}
      data-utc={@iso8601}
      class={@class}
    >
      {Calendar.strftime(datetime_to_utc_datetime(@datetime), "%Y-%m-%d %H:%M UTC")}
    </time>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".LocalTime">
      const formatter = new Intl.DateTimeFormat(undefined, {
        dateStyle: "medium",
        timeStyle: "short",
        hour12: false,
      })

      const renderLocalTime = (el) => {
        const utcValue = el.dataset.utc
        if (!utcValue) return

        const date = new Date(utcValue)
        if (Number.isNaN(date.getTime())) return

        el.textContent = formatter.format(date).replace(",", "")
      }

      export default {
        mounted() {
          renderLocalTime(this.el)
        },

        updated() {
          renderLocalTime(this.el)
        },
      }
    </script>
    """
  end

  attr :id, :string, required: true
  attr :tab, :string, required: true
  attr :active_tab, :string, required: true
  attr :label, :string, required: true
  attr :icon, :string, default: nil
  attr :icon_class, :string, default: "size-4"

  def group_tab_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      data-dropdown-close
      phx-click="switch_tab"
      phx-value-tab={@tab}
      class={[
        if(@icon != nil and (@label == nil or @label == ""), do: "", else: "w-full"),
        "flex flex-row items-center rounded-md px-4 py-2 text-left text-sm font-medium transition-colors",
        if(@active_tab == @tab,
          do: "bg-base-content text-base-100 shadow-sm",
          else: "bg-base-200 text-base-content/70 hover:bg-base-300 hover:text-base-content"
        )
      ]}
    >
      <.icon :if={@icon} name={@icon} class={@icon_class} />
      <span :if={@label != nil and @label != ""} class="ml-2 truncate">{@label}</span>
    </button>
    """
  end

  attr :id, :string, required: true
  attr :event, :string, required: true
  attr :view, :string, required: true
  attr :active, :boolean, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :label_class, :any, default: nil

  # One option of a list/folders view switch.
  def view_toggle_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click={@event}
      phx-value-view={@view}
      aria-pressed={to_string(@active)}
      title={@label}
      class={[
        "inline-flex items-center gap-1.5 rounded-full px-3 py-1 text-xs font-semibold transition duration-150 ease-out phx-click-loading:opacity-70",
        if(@active,
          do: "bg-base-100 text-base-content shadow-sm",
          else: "text-base-content/60 hover:text-base-content"
        )
      ]}
    >
      <.icon name={@icon} class="size-4" />
      <span class={@label_class}>{@label}</span>
    </button>
    """
  end

  attr :field, :any, required: true

  def group_picture_form_field(assigns) do
    assigns =
      assigns
      |> assign(:max_group_picture_upload_size, @max_group_picture_upload_size)
      |> assign(:max_group_picture_dimension, @max_group_picture_dimension)

    ~H"""
    <.input
      field={@field}
      id={@field.id}
      label={gettext("Group picture URL")}
      type="text"
      placeholder={gettext("https://example.com/group.png or data:image/...")}
    />
    <div
      id={"#{@field.id}-picker"}
      phx-hook=".GroupPicturePicker"
      phx-update="ignore"
      data-input-id={@field.id}
      data-max-file-size={@max_group_picture_upload_size}
      data-max-dimension={@max_group_picture_dimension}
      data-file-too-large-message={gettext("Choose an image smaller than 5 MB.")}
      data-invalid-image-message={gettext("Choose a valid image file.")}
      data-processing-message={gettext("Could not process that image.")}
      class="mb-4 rounded-3xl border border-base-300/70 bg-base-200/40 p-4"
    >
      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div class="space-y-1">
          <p class="text-sm font-semibold text-base-content">{gettext("Upload from your device")}</p>

          <p class="text-xs leading-5 text-base-content/70">
            {gettext("Images are resized to fit within 200 x 200 and files over 5 MB are rejected.")}
          </p>
        </div>

        <div class="flex flex-wrap gap-2">
          <label
            for={"#{@field.id}-file"}
            class="inline-flex cursor-pointer items-center gap-2 rounded-full bg-base-content px-4 py-2 text-sm font-medium text-base-100 transition hover:opacity-90"
          >
            <.icon name="hero-photo" class="size-5" /> {gettext("Choose image")}
          </label>
          <button
            type="button"
            data-group-picture-clear
            class="inline-flex items-center gap-2 rounded-full border border-base-300 bg-base-100 px-4 py-2 text-sm font-medium text-base-content transition hover:border-base-content/30 hover:bg-base-100/80"
          >
            <.icon name="hero-x-mark" class="size-5" /> {gettext("Clear image")}
          </button>
        </div>
      </div>

      <input
        id={"#{@field.id}-file"}
        type="file"
        accept="image/*"
        class="sr-only"
        data-group-picture-file
      />
      <p
        data-group-picture-error
        class="mt-3 hidden items-center gap-2 text-sm text-error"
        role="status"
        aria-live="polite"
      >
        <.icon name="hero-exclamation-circle" class="size-5 shrink-0" /> <span></span>
      </p>
    </div>

    <%= if preview_url = group_picture_url(@field.value) do %>
      <div class="mb-4 flex items-center gap-4 rounded-3xl border border-base-300/70 bg-base-100 p-4 shadow-sm">
        <div class="flex size-[72px] items-center justify-center overflow-hidden rounded-2xl border border-base-300/70 bg-base-200">
          <img
            src={preview_url}
            alt={gettext("Group picture preview")}
            class="h-full w-full object-cover"
          />
        </div>

        <p class="text-sm text-base-content/70">
          {gettext("Preview of the current group picture value.")}
        </p>
      </div>
    <% end %>

    <script :type={Phoenix.LiveView.ColocatedHook} name=".GroupPicturePicker">
      const supportedOutputTypes = new Set(["image/jpeg", "image/png", "image/webp"])

      const readMaxValue = (value, fallback) => {
        const parsedValue = Number.parseInt(value || "", 10)

        return Number.isNaN(parsedValue) ? fallback : parsedValue
      }

      const outputTypeFor = file => {
        if (supportedOutputTypes.has(file.type)) {
          return file.type
        }

        return "image/png"
      }

      const loadImage = file =>
        new Promise((resolve, reject) => {
          const objectUrl = URL.createObjectURL(file)
          const image = new Image()

          image.onload = () => {
            URL.revokeObjectURL(objectUrl)
            resolve(image)
          }

          image.onerror = () => {
            URL.revokeObjectURL(objectUrl)
            reject(new Error("invalid-image"))
          }

          image.src = objectUrl
        })

      const resizeImage = (image, maxDimension, file) => {
        const scale = Math.min(
          maxDimension / image.naturalWidth,
          maxDimension / image.naturalHeight,
          1
        )
        const width = Math.max(1, Math.round(image.naturalWidth * scale))
        const height = Math.max(1, Math.round(image.naturalHeight * scale))
        const canvas = document.createElement("canvas")
        const context = canvas.getContext("2d")

        if (!context) {
          throw new Error("missing-canvas-context")
        }

        canvas.width = width
        canvas.height = height
        context.drawImage(image, 0, 0, width, height)

        return canvas.toDataURL(outputTypeFor(file), 0.92)
      }

      const dispatchFormUpdate = input => {
        input.dispatchEvent(new Event("input", { bubbles: true }))
        input.dispatchEvent(new Event("change", { bubbles: true }))
      }

      export default {
        mounted() {
          this.fileInput = this.el.querySelector("[data-group-picture-file]")
          this.errorContainer = this.el.querySelector("[data-group-picture-error]")
          this.errorText = this.errorContainer?.querySelector("span")
          this.clearButton = this.el.querySelector("[data-group-picture-clear]")
          this.maxFileSize = readMaxValue(this.el.dataset.maxFileSize, 5 * 1024 * 1024)
          this.maxDimension = readMaxValue(this.el.dataset.maxDimension, 200)

          this.handleFileChange = async event => {
            const file = event.target.files?.[0]

            this.clearError()

            if (!file) {
              return
            }

            if (file.size > this.maxFileSize) {
              this.showError(this.el.dataset.fileTooLargeMessage)
              this.fileInput.value = ""
              return
            }

            try {
              const image = await loadImage(file)
              const resizedDataUrl = resizeImage(image, this.maxDimension, file)
              const sourceInput = document.getElementById(this.el.dataset.inputId)

              if (!sourceInput) {
                throw new Error("missing-source-input")
              }

              sourceInput.value = resizedDataUrl
              dispatchFormUpdate(sourceInput)
            } catch (error) {
              console.error("Unable to process selected group image", error)
              this.showError(
                this.el.dataset.processingMessage || this.el.dataset.invalidImageMessage
              )
            } finally {
              if (this.fileInput) {
                this.fileInput.value = ""
              }
            }
          }

          this.handleClear = event => {
            event.preventDefault()
            this.clearError()

            const sourceInput = document.getElementById(this.el.dataset.inputId)

            if (!sourceInput) {
              return
            }

            sourceInput.value = ""
            dispatchFormUpdate(sourceInput)

            if (this.fileInput) {
              this.fileInput.value = ""
            }
          }

          this.fileInput?.addEventListener("change", this.handleFileChange)
          this.clearButton?.addEventListener("click", this.handleClear)
        },

        destroyed() {
          this.fileInput?.removeEventListener("change", this.handleFileChange)
          this.clearButton?.removeEventListener("click", this.handleClear)
        },

        showError(message) {
          if (!this.errorContainer || !this.errorText || !message) {
            return
          }

          this.errorText.textContent = message
          this.errorContainer.classList.remove("hidden")
          this.errorContainer.classList.add("flex")
        },

        clearError() {
          if (!this.errorContainer || !this.errorText) {
            return
          }

          this.errorText.textContent = ""
          this.errorContainer.classList.add("hidden")
          this.errorContainer.classList.remove("flex")
        },
      }
    </script>
    """
  end

  attr :text, :string, required: true
  attr :query, :string, default: ""
  attr :class, :any, default: nil
  attr :match_class, :string, default: "rounded bg-yellow-300 px-0 text-yellow-950"

  def highlighted_text(assigns) do
    assigns = assign(assigns, :segments, highlighted_text_segments(assigns.text, assigns.query))

    ~H"""
    <span class={@class}>
      <span
        :for={segment <- @segments}
        class={if segment.match?, do: @match_class, else: nil}
      >
        {segment.text}
      </span>
    </span>
    """
  end

  attr :id, :string, default: nil
  slot :inner_block, required: true

  @doc """
  The scrolling body of a group tab under its path: one centered column, so
  the settings-like tabs share a width and place. The top space is the
  column's, so a `sticky top-0` bar sticks flush to the scroll area's edge.
  """
  def tab_body(assigns) do
    ~H"""
    <div
      id={@id}
      data-tab-scroll
      class="min-h-0 flex-1 overflow-y-auto overscroll-contain px-2 pb-4 sm:px-4"
    >
      <div class="mx-auto w-full max-w-3xl pt-4">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :tabs, :list, required: true, doc: "`{key, panel id, label, danger?}`, in order"
  attr :current, :string, required: true, doc: "the key of the card on screen"
  attr :event, :string, required: true, doc: "pushed with the picked key as `section`"

  attr :tab_id_prefix, :string,
    required: true,
    doc: "each tab's id is the prefix, `-` and its key"

  @doc """
  The tab bar of a settings tab (edit group, create sub-group): it sticks to
  the top of the `tab_body/1` it is in, and a picked tab starts its card at
  the top.
  """
  def settings_tabs(assigns) do
    ~H"""
    <nav
      id={@id}
      phx-hook=".SectionTabs"
      role="tablist"
      aria-label={gettext("Sections")}
      class="sticky top-0 z-10 -mx-1 mb-4 flex gap-1 overflow-x-auto rounded-full border border-base-300/70 bg-base-100/90 p-1 shadow-sm backdrop-blur"
    >
      <button
        :for={{key, panel_id, label, danger?} <- @tabs}
        id={"#{@tab_id_prefix}-#{key}"}
        type="button"
        role="tab"
        aria-selected={to_string(@current == key)}
        aria-controls={panel_id}
        phx-click={@event}
        phx-value-section={key}
        class={[
          "shrink-0 rounded-full px-3 py-1.5 text-sm font-medium transition duration-150 ease-out active:scale-95",
          settings_tab_class(@current == key, danger?)
        ]}
      >
        {label}
      </button>
    </nav>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".SectionTabs">
      // A new card starts at the top of the tab, under its header.
      export default {
        mounted() {
          this.el.addEventListener("click", event => {
            if (!event.target.closest("[role='tab']")) return

            this.el.closest("[data-tab-scroll]")?.scrollTo({top: 0})
          })
        },
      }
    </script>
    """
  end

  defp settings_tab_class(true, false), do: "bg-base-content text-base-100 shadow-sm"
  defp settings_tab_class(true, true), do: "bg-error text-error-content shadow-sm"

  defp settings_tab_class(false, false),
    do: "text-base-content/70 hover:bg-base-200 hover:text-base-content"

  defp settings_tab_class(false, true), do: "text-error/80 hover:bg-error/10 hover:text-error"

  attr :id, :string, required: true
  attr :tab_id, :string, required: true, doc: "the id of the tab that shows the card"
  attr :active, :boolean, required: true, doc: "whether the card is on screen"
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, required: true
  slot :inner_block, required: true

  @doc """
  One card of a settings tab. A card that is not on screen is only hidden,
  so a form around the cards still sends every field.
  """
  def settings_card(assigns) do
    ~H"""
    <section
      id={@id}
      role="tabpanel"
      aria-labelledby={@tab_id}
      class={[
        "rounded-3xl border border-base-300/70 bg-base-100/80 p-4 shadow-sm sm:p-5",
        !@active && "hidden"
      ]}
    >
      <.card_title icon={@icon} title={@title} subtitle={@subtitle} class="mb-4" />
      {render_slot(@inner_block)}
    </section>
    """
  end

  attr :group, :map, required: true

  attr :path, :list,
    required: true,
    doc: "`Social.list_visible_group_path_for_profile/2` of the group, loaded by the LiveView"

  attr :current_profile, :map, default: nil
  attr :id, :string, default: "group-path"
  attr :class, :any, default: nil

  def group_path(assigns) do
    ~H"""
    <div id={@id} class={["px-4 py-4 text-sm text-base-content/60 relative z-40", @class]}>
      <nav
        aria-label={gettext("Current group path")}
        class="flex flex-wrap items-center align-center gap-x-1 gap-y-1"
      >
        <%= for {path_group, idx} <- Enum.with_index(@path) do %>
          <%= if idx > 0 do %>
            <span aria-hidden="true" class="text-base-content/35">/</span>
          <% end %>

          <%= if path_group.id == @group.id do %>
            <span class="font-medium text-base-content">
              {group_identity_name(path_group, @current_profile)}
            </span>
          <% else %>
            <.link
              navigate={~p"/groups/#{path_group.id}/sub_groups"}
              class="transition-colors hover:text-base-content"
            >
              {if path_group.is_root,
                do: "",
                else: group_identity_name(path_group, @current_profile)}
              <.icon :if={path_group.is_root} name="hero-home" class="size-4" />
            </.link>
          <% end %>
        <% end %>
      </nav>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :data, :any, required: true
  attr :label, :string, default: "assigns"
  attr :class, :any, default: nil
  attr :open, :boolean, default: false

  def inspect_tree(assigns) do
    ~H"""
    <div
      id={@id}
      class={[
        "rounded-2xl border border-base-300/80 bg-base-100/80 p-3 font-mono text-xs text-base-content/80 shadow-sm",
        @class
      ]}
    >
      <details open={@open}>
        <summary class="cursor-pointer select-none font-semibold text-base-content">{@label}</summary>

        <div class="mt-3 overflow-auto"><.inspect_tree_node label={@label} value={@data} /></div>
      </details>
    </div>
    """
  end

  attr :profile, :map, required: true
  attr :avatar_size, :string, default: "size-11"
  attr :text_class, :string, default: "text-sm"
  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil
  attr :me, :boolean, default: false
  attr :online?, :boolean, default: false

  attr :presence_profile_id, :integer,
    default: nil,
    doc: "always render the badge and let `presence_css/1` show it while this profile is online"

  attr :presence_badge_id, :string, default: nil
  attr :sharing_badge_text_class, :string, default: "text-xs"
  attr :current_profile, :map, default: nil
  attr :direct_group_link, :boolean, default: false

  def profile_identity(assigns) do
    ~H"""
    <.link
      :if={profile_identity_clickable?(@profile, @current_profile, @direct_group_link)}
      navigate={~p"/profiles/#{@profile.id}/direct"}
      class="block rounded-2xl px-1 py-1 transition-colors hover:bg-base-100/70 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40"
    >
      <.profile_identity_content
        profile={@profile}
        avatar_size={@avatar_size}
        text_class={@text_class}
        title={@title}
        subtitle={@subtitle}
        me={@me}
        online?={@online?}
        presence_profile_id={@presence_profile_id}
        presence_badge_id={@presence_badge_id}
        sharing_badge_text_class={@sharing_badge_text_class}
      />
    </.link>
    <.profile_identity_content
      :if={!profile_identity_clickable?(@profile, @current_profile, @direct_group_link)}
      profile={@profile}
      avatar_size={@avatar_size}
      text_class={@text_class}
      title={@title}
      subtitle={@subtitle}
      me={@me}
      online?={@online?}
      presence_profile_id={@presence_profile_id}
      presence_badge_id={@presence_badge_id}
      sharing_badge_text_class={@sharing_badge_text_class}
    />
    """
  end

  attr :profile, :map, required: true
  attr :avatar_size, :string, default: "size-11"
  attr :text_class, :string, default: "text-sm"
  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil
  attr :me, :boolean, default: false
  attr :online?, :boolean, default: false

  attr :presence_profile_id, :integer,
    default: nil,
    doc: "always render the badge and let `presence_css/1` show it while this profile is online"

  attr :presence_badge_id, :string, default: nil
  attr :sharing_badge_text_class, :string, default: "text-xs"

  defp profile_identity_content(assigns) do
    ~H"""
    <div class="flex min-w-0 items-center gap-3">
      <div class="relative">
        <%!-- @profile: {inspect(@profile)} --%>
        <%= if avatar_url = profile_picture_url(@profile) do %>
          <img
            src={avatar_url}
            alt={@profile.username}
            class={[
              @avatar_size,
              "shrink-0 rounded-full border border-base-300 bg-base-100 object-cover shadow-sm"
            ]}
          />
        <% else %>
          <div class={[
            @avatar_size,
            "flex shrink-0 items-center justify-center rounded-full border border-base-300 bg-base-300 text-xs font-semibold uppercase text-base-content/75 shadow-sm"
          ]}>
            {profile_initials(@profile.username)}
          </div>
        <% end %>

        <div class={[@sharing_badge_text_class, "absolute", "bottom-0", "left-0", "-ml-1", "-mb-1"]}>
          {if @profile.sharing == :shared,
            do: "👨‍👨‍👦‍👦",
            else: ""}
        </div>
      </div>

      <div class="min-w-0">
        <div
          :if={@title}
          class="text-xs font-semibold uppercase tracking-[0.16em] text-base-content/45"
        >
          {@title}
        </div>

        <div class={[
          @text_class,
          "truncate font-semibold text-base-content",
          if(@me, do: "italic text-success", else: "")
        ]}>
          {@profile.username}
        </div>

        <div :if={@subtitle} class="truncate text-xs text-base-content/60">{@subtitle}</div>

        <div
          :if={@online? or @presence_profile_id}
          id={@presence_badge_id}
          class={[
            "mt-1 inline-flex items-center gap-1.5 rounded-full bg-emerald-500/12 px-2 py-0.5 text-[11px] font-medium text-emerald-700",
            @presence_profile_id && "presence-dot presence-p#{@presence_profile_id}"
          ]}
        >
          <span class="size-2 rounded-full bg-emerald-500" /> <span>{gettext("Online")}</span>
        </div>
      </div>
    </div>
    """
  end

  defp profile_identity_clickable?(profile, current_profile, direct_group_link?) do
    direct_group_link? and
      match?(%{id: current_profile_id} when current_profile_id != profile.id, current_profile)
  end

  attr :group, :map, required: true
  attr :avatar_size, :string, default: "size-11"
  attr :text_class, :string, default: "text-sm"
  attr :pending_join_requests_count, :integer, default: 0
  attr :unread_count, :integer, default: 0
  attr :current_profile, :map, default: nil
  attr :highlight_query, :string, default: ""

  def group_identity(assigns) do
    ~H"""
    <.link
      navigate={~p"/groups/#{@group.id}"}
      class="flex justify-start rounded-full w-full justify-items-start active:bg-base-200 hover:bg-base-100 pr-4"
    >
      <div class="flex min-w-0 items-center gap-3">
        <div class="relative shrink-0">
          <%= if avatar_url = group_identity_picture_url(@group, @current_profile) do %>
            <img
              :if={!@group.is_root}
              src={avatar_url}
              alt={@group.name}
              class={[
                @avatar_size,
                "flex shrink-0 rounded-full border border-base-300 object-cover shadow-sm"
              ]}
            />
            <div
              :if={@group.is_root}
              class={[
                @avatar_size,
                "flex shrink-0 items-center justify-center rounded-full border border-base-300 bg-base-300 text-xs font-semibold uppercase text-base-content/75 shadow-sm"
              ]}
            >
              <.icon name="hero-home" class="size-4" />
            </div>
          <% else %>
            <div class={[
              @avatar_size,
              "flex shrink-0 items-center justify-center rounded-full border border-base-300 bg-base-300 text-xs font-semibold uppercase text-base-content/75 shadow-sm"
            ]}>
              <span :if={!@group.is_root}>{group_initials(@group.name)}</span>
              <.icon :if={@group.is_root} name="hero-home" class="size-4" />
            </div>
          <% end %>

          <div
            :if={!@group.is_direct && !@group.is_root}
            class="absolute bottom-0 left-0 -ml-1 -mb-1 text-[0.8rem]"
          >
            {if @group.is_public,
              do: "📢",
              else: "🔐"}
          </div>

          <div
            :if={@group.uses_api && !@group.is_direct && !@group.is_root}
            id={"group-app-badge-#{@group.id}"}
            title={gettext("App")}
            class="absolute bottom-0 right-0 -mr-1 -mb-1 text-[0.8rem]"
          >
            🧩
          </div>

          <span
            :if={!@group.is_root and @pending_join_requests_count > 0}
            id={"group-pending-join-requests-badge-#{@group.id}"}
            class="absolute -left-2 -top-2 inline-flex min-w-5 items-center justify-center rounded-full bg-amber-500 px-1.5 py-0.5 text-[11px] font-semibold leading-none text-amber-950 shadow-sm"
          >
            {unread_badge_label(@pending_join_requests_count)}
          </span>
          <span
            :if={!@group.is_root and @unread_count > 0}
            id={"group-unread-badge-#{@group.id}"}
            class="absolute -right-2 -top-2 inline-flex min-w-5 items-center justify-center rounded-full bg-red-600 px-1.5 py-0.5 text-[11px] font-semibold leading-none text-white shadow-sm"
          >
            {unread_badge_label(@unread_count)}
          </span>
        </div>

        <div
          :if={!@group.is_root}
          class="min-w-0 shrink"
        >
          <div class="flex min-w-0 items-center gap-1.5">
            <div class={[@text_class, "truncate font-semibold text-base-content"]}>
              <.highlighted_text
                text={group_identity_name(@group, @current_profile)}
                query={@highlight_query}
              />
            </div>
            <span
              :if={thread_group?(@group)}
              id={"group-thread-badge-#{@group.id}"}
              title={gettext("Thread")}
              class="inline-flex shrink-0 items-center gap-1 rounded-full bg-primary/10 px-1.5 py-0.5 text-[10px] font-semibold uppercase leading-none tracking-wide text-primary"
            >
              <.icon name="hero-chat-bubble-left-right" class="size-3" />
              <span class="hidden sm:inline">{gettext("Thread")}</span>
            </span>
          </div>

          <div
            :if={false}
            class="mt-1 flex flex-wrap items-center gap-2 text-xs font-medium text-base-content/70"
          >
            <span
              id={"group-visibility-badge-#{@group.id}"}
              class={[
                "inline-flex items-center rounded-full px-2 py-1",
                if(@group.is_public,
                  do: "bg-emerald-100 text-emerald-700",
                  else: "bg-slate-200 text-slate-700"
                )
              ]}
            >
              {if @group.is_public, do: gettext("Public group"), else: gettext("Private group")}
            </span>
          </div>
        </div>
      </div>
    </.link>
    """
  end

  # A thread is the sub-group started from a chat value.
  defp thread_group?(%{parent_value_id: value_id}) when not is_nil(value_id), do: true
  defp thread_group?(_group), do: false

  defp unread_badge_label(count) when count > 999, do: "999+"
  defp unread_badge_label(count), do: Integer.to_string(count)

  attr :content, :string, default: ""
  attr :content_format, :any, default: :markdown
  attr :uses_api, :boolean, default: false
  attr :mentions, :map, default: %{}, doc: "resolved `@` mentions to highlight (`Value.mentions`)"
  attr :class, :any, default: nil

  # The `rich-content` wrapper lives here, not in the rendered HTML: the
  # sanitizer would strip its class.
  def formatted_content(assigns) do
    ~H"""
    <div class={[@class, "rich-content"]}>
      {cached_formatted_content(@content, @content_format, @uses_api, @mentions)}
    </div>
    """
  end

  # Markdown parsing + sanitizing is pure in (content, format, uses_api,
  # mentions) and runs on every render of every streamed value, so the result
  # is memoized. The renderer modules' md5s are part of the key, so a code
  # reload (dev) never serves HTML that the old code rendered.
  @formatted_content_cache_ttl :timer.hours(1)

  defp cached_formatted_content(content, content_format, uses_api, mentions) do
    renderer =
      {__MODULE__.module_info(:md5), PotokIdeWeb.RichContentScrubber.module_info(:md5),
       Mentions.module_info(:md5)}

    key =
      {:formatted_content,
       :crypto.hash(
         :sha256,
         :erlang.term_to_binary({renderer, content, content_format, uses_api, mentions})
       )}

    PotokIde.Cache.fetch(key, @formatted_content_cache_ttl, fn ->
      render_formatted_content(%{
        content: content,
        content_format: content_format,
        uses_api: uses_api,
        mentions: mentions || %{}
      })
    end)
  end

  @doc """
  CSS that reveals the `presence-dot` markers of online profiles. Rendered
  once per page outside of streams, so presence changes never re-render
  streamed values or members. Selectors stay unquoted because EEx escapes
  quotes inside `<style>`.
  """
  def presence_css(online_profile_ids) do
    Enum.map_join(online_profile_ids, fn profile_id ->
      ".presence-dot.presence-p#{profile_id}{display:inline-flex}"
    end)
  end

  attr :id, :string, required: true
  attr :html, :string, required: true, doc: "the app's HTML (the group description)"
  attr :api, :boolean, default: true, doc: "false renders a preview whose API calls are refused"

  attr :storage_key, :string,
    default: nil,
    doc: "page `localStorage` key that keeps the app's `localStorage`; nil keeps it in memory"

  attr :viewer_key, :string,
    default: nil,
    doc: "describes the viewer's access (profile, membership); a new value restarts the app"

  attr :app_id, :string,
    default: "",
    doc: "which of the group's apps this is (`AppApi.app_id/1`); sent with every API call"

  attr :class, :any, default: nil

  @doc """
  Runs an app group's HTML in a sandboxed iframe. Without `allow-same-origin`
  the frame gets an opaque origin: it cannot touch this page, its cookies or
  the LiveSocket, and talks to Potok only through `potok_app_sdk.js` and the
  `GroupAppFrame` hook. The `srcdoc` only changes (and reloads the app) when
  the HTML or `viewer_key` changes: apps load their data once, so one that
  started without access (before its viewer joined) must start again.
  """
  def app_frame(assigns) do
    assigns =
      assign(
        assigns,
        :srcdoc,
        app_frame_srcdoc(assigns.html, assigns.viewer_key, assigns.app_id)
      )

    ~H"""
    <div
      id={@id}
      phx-hook="GroupAppFrame"
      data-api={to_string(@api)}
      data-app-id={@app_id}
      data-storage-key={@storage_key}
      class={["flex min-h-0 flex-1 flex-col", @class]}
    >
      <iframe
        id={"#{@id}-iframe"}
        title={gettext("Group app")}
        sandbox="allow-scripts allow-forms allow-popups allow-popups-to-escape-sandbox allow-modals allow-downloads"
        referrerpolicy="no-referrer"
        srcdoc={@srcdoc}
        class="min-h-0 w-full flex-1 border-0 bg-transparent"
      >
      </iframe>
    </div>
    """
  end

  # Apps written before the sandbox ran inside this page: they use its daisyUI
  # classes and theme, size themselves from the parent of
  # `#group-panel-description` and find the API on its `potok` property (set
  # by the SDK's legacy shim). `potok-app` tells the SDK which app it runs,
  # so it can pick that app's values out of the group's.
  defp app_frame_srcdoc(html, viewer_key, app_id) do
    css_url = ~p"/assets/css/app.css"
    sdk_url = ~p"/assets/js/potok_app_sdk.js"

    viewer_meta =
      if viewer_key do
        ~s(<meta name="potok-viewer" content="#{escape_attr(viewer_key)}">)
      end

    app_meta = ~s(<meta name="potok-app" content="#{escape_attr(app_id || "")}">)

    """
    <!doctype html><html><head><meta charset="utf-8">\
    <meta name="viewport" content="width=device-width, initial-scale=1">#{viewer_meta}#{app_meta}\
    <base target="_blank"><link rel="stylesheet" href="#{css_url}">\
    <style>html,body{height:100%}</style>\
    <script src="#{sdk_url}"></script></head>\
    <body><div id="group-panel-description">\
    #{UTF8.replace_invalid(html || "")}</div></body></html>\
    """
  end

  defp escape_attr(value),
    do: value |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

  @doc "Name of the group's default description next to its alternative ones."
  def default_description_label(%Group{description_name: name})
      when is_binary(name) and name != "",
      do: name

  def default_description_label(%Group{}), do: gettext("Description")

  attr :id_prefix, :string,
    required: true,
    doc: "prefix of the workspace's ids, unique on the page"

  attr :description_field, Phoenix.HTML.FormField, required: true
  attr :format_field, Phoenix.HTML.FormField, required: true
  attr :uses_api, :any, required: true, doc: "the form's `uses_api` value"
  attr :format_options, :list, required: true

  @doc """
  Writes a description (the default one or an alternative): editor,
  side-by-side or preview layout with a live preview, which runs apps with
  their API refused, and the format choice. The layout is remembered for
  the browser session.
  """
  def description_workspace(assigns) do
    assigns = assign(assigns, :app?, assigns.uses_api in [true, "true"])

    ~H"""
    <div>
      <div class="group-description-workspace mt-4">
        <div
          id={"#{@id_prefix}-layout-selector"}
          phx-hook=".PersistDescriptionLayout"
          phx-update="ignore"
          data-storage-key="potok:group-description-layout"
        >
          <input
            :for={layout <- ~w(editor split preview)}
            id={"#{@id_prefix}-layout-#{layout}"}
            type="radio"
            name={"#{@id_prefix}-layout"}
            value={layout}
            class="group-description-layout-input sr-only"
            checked={layout == "split"}
          />
          <div class="group-description-layout-controls mb-4 flex flex-wrap gap-2">
            <label
              for={"#{@id_prefix}-layout-editor"}
              data-layout="editor"
              class="group-description-layout-button"
            >
              {gettext("Editor")}
            </label>
            <label
              for={"#{@id_prefix}-layout-split"}
              data-layout="split"
              class="group-description-layout-button"
            >
              {gettext("Split")}
            </label>
            <label
              for={"#{@id_prefix}-layout-preview"}
              data-layout="preview"
              class="group-description-layout-button"
            >
              {gettext("Preview")}
            </label>
          </div>
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".PersistDescriptionLayout">
          const validLayouts = new Set(["editor", "split", "preview"])

          const storedLayout = el => {
            const storageKey = el.dataset.storageKey
            if (!storageKey) return null

            const value = window.sessionStorage.getItem(storageKey)
            return validLayouts.has(value) ? value : null
          }

          const persistLayout = (el, value) => {
            const storageKey = el.dataset.storageKey
            if (!storageKey || !validLayouts.has(value)) return

            window.sessionStorage.setItem(storageKey, value)
          }

          const applyStoredLayout = el => {
            const value = storedLayout(el)
            if (!value) return

            const input = el.querySelector(`input[type="radio"][value="${value}"]`)
            if (input) input.checked = true
          }

          export default {
            mounted() {
              applyStoredLayout(this.el)

              this.handleChange = event => {
                if (event.target?.type !== "radio") return

                persistLayout(this.el, event.target.value)
              }

              this.el.addEventListener("change", this.handleChange)
            },

            destroyed() {
              this.el.removeEventListener("change", this.handleChange)
            },
          }
        </script>

        <div class="grid group-description-layout min-h-112 gap-4 grid-cols-2 card-body p-0">
          <div class="group-description-pane group-description-pane-editor rounded-2xl border border-base-300/80 bg-base-100/80 p-3 shadow-sm">
            <.input field={@description_field} type="textarea" rows="16" phx-debounce="500" />
          </div>

          <div class="group-description-pane group-description-pane-preview rounded-2xl border border-base-300/80 bg-base-100/80 p-4 shadow-sm">
            <div class="mb-3 text-xs font-semibold uppercase tracking-[0.2em] text-base-content/55">
              {gettext("Live preview")}
            </div>

            <div
              :if={blank_text?(@description_field.value)}
              class="flex min-h-48 items-center justify-center rounded-2xl border border-dashed border-base-300 bg-base-200/50 px-6 text-center text-sm text-base-content/60"
            >
              {gettext("Start typing to preview the description.")}
            </div>

            <.app_frame
              :if={!blank_text?(@description_field.value) and @app?}
              id={"#{@id_prefix}-app-frame-preview"}
              html={@description_field.value}
              api={false}
              class="min-h-96"
            />
            <.formatted_content
              :if={!blank_text?(@description_field.value) and !@app?}
              content={@description_field.value || ""}
              content_format={normalize_description_format(@format_field.value)}
              class="min-h-48"
            />
          </div>
        </div>
      </div>

      <div class="mt-3 flex items-start gap-4 h-3/4 overflow-auto">
        <fieldset class="fieldset">
          <div class="flex flex-wrap gap-3">
            <label :for={{label, value} <- @format_options} class="inline-flex items-center gap-2">
              <input
                type="radio"
                name={@format_field.name}
                value={Atom.to_string(value)}
                checked={description_format_checked?(@format_field.value, value)}
                class="radio radio-sm"
              /> <span>{label}</span>
            </label>
          </div>
        </fieldset>
      </div>
    </div>
    """
  end

  defp description_format_checked?(current_value, option_value)
       when is_atom(current_value) and is_atom(option_value),
       do: current_value == option_value

  defp description_format_checked?(current_value, option_value) when is_binary(current_value),
    do: current_value == Atom.to_string(option_value)

  defp description_format_checked?(_, _), do: false

  defp normalize_description_format(current_value) when current_value in [:markdown, :html],
    do: current_value

  defp normalize_description_format("markdown"), do: :markdown
  defp normalize_description_format("html"), do: :html
  defp normalize_description_format(_), do: :markdown

  defp blank_text?(text), do: is_nil(text) or String.trim(text) == ""

  attr :value, :map, required: true
  attr :dom_id, :string, required: true
  attr :current_profile, :map, default: nil
  attr :editing_value_id, :integer, default: nil
  attr :uses_api, :boolean, default: false
  attr :can_react, :boolean, default: false
  attr :can_reply, :boolean, default: false
  attr :can_thread, :boolean, default: false, doc: "may open a new thread on the value"
  attr :can_join_thread, :boolean, default: false, doc: "may open the value's existing thread"
  attr :can_delete_any, :boolean, default: false, doc: "may delete other members' values"
  attr :can_tag, :boolean, default: false, doc: "may open the value's tags (members)"

  def value_message(assigns) do
    mine? = value_from_current_profile?(assigns.current_profile, assigns.value)
    editing? = assigns.editing_value_id == assigns.value.id

    assigns =
      assigns
      |> assign(:mine?, mine?)
      |> assign(:editing?, editing?)
      |> assign(:can_delete?, (mine? or assigns.can_delete_any) and not editing?)
      |> assign(:mentions_me?, mentions_profile?(assigns.value, assigns.current_profile))
      |> assign(:expandable?, value_expandable?(assigns.value))
      |> assign(:avatar_url, profile_picture_url(assigns.value.creator))
      |> assign(:reactions, reaction_summary(assigns.value.reactions, assigns.current_profile))
      |> assign(:reply_parent, reply_parent(assigns.value))
      |> assign(:thread, value_thread(assigns.value))
      |> assign(:has_text?, String.trim(assigns.value.content || "") != "")
      |> assign(:link_preview, value_link_preview(assigns.value))
      |> assign(:event, value_event(assigns.value))
      |> assign_value_attachments(assigns.value)

    ~H"""
    <div
      id={@dom_id}
      data-mentions-me={@mentions_me? && "true"}
      class={["chat group/value", (@mine? && "chat-end") || "chat-start"]}
    >
      <.inspect_tree
        :if={false}
        id={"value-message-assigns-#{@value.id}"}
        data={@value}
        label={"value#{@value.id}"}
        class="mb-3 w-full"
      />
      <%= if @avatar_url do %>
        <div class="chat-image avatar">
          <div class="relative size-10 rounded-full border border-base-300 shadow-sm">
            <img src={@avatar_url} alt={@value.creator.username} class="object-cover" />
          </div>

          <span
            id={"value-creator-presence-#{@value.id}"}
            class={[
              "presence-dot absolute right-0 bottom-0 size-3 rounded-full border-2 border-base-100 bg-emerald-500",
              "presence-p#{@value.creator_id}"
            ]}
            title={gettext("Online")}
          />
          <%!-- <span
            :if={@value.creator.sharing == :shared}
            class="absolute left-0 bottom-0 size-3 rounded-full border-2 border-base-100 bg-emerald-500"
          >👨‍👨‍👦‍👦</span> --%>
          <div class="absolute bottom-0 left-0 -ml-1 -mb-1">
            {if @value.creator.sharing == :shared,
              do: "👨‍👨‍👦‍👦",
              else: ""}
          </div>
        </div>
      <% else %>
        <div class="chat-image">
          <div class="relative flex size-10 items-center justify-center rounded-full border border-base-300 bg-base-300 text-xs font-semibold uppercase text-base-content/75 shadow-sm">
            {profile_initials(@value.creator.username)}
            <span
              id={"value-creator-presence-#{@value.id}"}
              class={[
                "presence-dot absolute right-0 bottom-0 size-3 rounded-full border-2 border-base-100 bg-emerald-500",
                "presence-p#{@value.creator_id}"
              ]}
              title={gettext("Online")}
            />
          </div>
        </div>
      <% end %>

      <div class="chat-header mb-1 flex items-center gap-2 text-xs text-base-content/65">
        <span class="font-semibold text-base-content">{@value.creator.username}</span>
        <.local_time id={"value-inserted-at-#{@value.id}"} datetime={@value.inserted_at} />
        <span
          :if={@mentions_me?}
          id={"value-mentions-me-#{@value.id}"}
          class="inline-flex items-center gap-0.5 rounded-full bg-amber-500/15 px-1.5 py-0.5 text-[10px] font-semibold uppercase tracking-wide text-amber-700"
        >
          <.icon name="hero-at-symbol" class="size-3" />
          {gettext("Mentioned you")}
        </span>
        <div
          :if={
            @can_react or @can_reply or @can_thread or @can_tag or @can_delete? or
              (@mine? and !@editing?)
          }
          class="ml-auto flex items-center gap-1"
        >
          <button
            :if={@can_reply and !@editing?}
            id={"value-reply-#{@value.id}"}
            type="button"
            phx-click="start_reply_value"
            phx-value-id={@value.id}
            aria-label={gettext("Reply")}
            title={gettext("Reply")}
            class="inline-flex items-center rounded-full p-1 text-base-content/55 transition-colors hover:bg-base-300 hover:text-base-content"
          >
            <.icon name="hero-arrow-uturn-left" class="size-4" />
          </button>
          <%!-- Once the thread exists, the footer pill opens it instead. --%>
          <button
            :if={@can_thread and is_nil(@thread)}
            id={"value-thread-#{@value.id}"}
            type="button"
            phx-click="open_value_thread"
            phx-value-id={@value.id}
            aria-label={gettext("Reply in thread")}
            title={gettext("Reply in thread")}
            class="inline-flex items-center rounded-full p-1 text-base-content/55 transition-colors hover:bg-base-300 hover:text-base-content phx-click-loading:pointer-events-none phx-click-loading:animate-pulse"
          >
            <.icon name="hero-chat-bubble-left-right" class="size-4" />
          </button>
          <%!-- Opens the page's single emoji picker (`ReactionPicker` hook in the values tab). --%>
          <button
            :if={@can_react}
            id={"value-react-#{@value.id}"}
            type="button"
            data-reaction-trigger
            data-value-id={@value.id}
            aria-haspopup="dialog"
            aria-label={gettext("Add reaction")}
            title={gettext("Add reaction")}
            class="inline-flex items-center rounded-full p-1 text-base-content/55 transition-colors hover:bg-base-300 hover:text-base-content"
          >
            <.icon name="hero-face-smile" class="size-4" />
          </button>
          <TagComponents.tag_button
            :if={@can_tag}
            id={"value-tags-#{@value.id}"}
            kind={:value}
            item_id={@value.id}
          />
          <%!-- An event's card is changed in the calendar. --%>
          <button
            :if={@mine? and !@editing? and is_nil(@event)}
            id={"value-edit-#{@value.id}"}
            type="button"
            phx-click="start_edit_value"
            phx-value-id={@value.id}
            aria-label={gettext("Edit value")}
            class="inline-flex items-center rounded-full p-1 text-base-content/55 transition-colors hover:bg-base-300 hover:text-base-content"
          >
            <.icon name="hero-pencil-square" class="size-4" />
          </button>
          <button
            :if={@can_delete?}
            id={"value-delete-#{@value.id}"}
            type="button"
            phx-click="delete_value"
            phx-value-id={@value.id}
            aria-label={gettext("Delete value")}
            data-confirm={gettext("Are you sure you want to delete this value?")}
            class="inline-flex items-center rounded-full p-1 text-base-content/55 transition-colors hover:bg-base-300 hover:text-error"
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </div>
      </div>

      <%!-- `data-highlighted` is set by the `.ValuesFeed` hook after jumping here from a reply quote or a link. --%>
      <div class={[
        "chat-bubble max-w-full rounded-3xl shadow-sm ring-warning/60 transition-shadow duration-500 sm:max-w-[42rem]",
        "group-data-highlighted/value:ring-4",
        @mentions_me? && "ring-2 ring-amber-400/70",
        @mine? && "chat-bubble-primary",
        !@mine? && "border border-base-300 bg-base-100 text-base-content"
      ]}>
        <%!-- `.ValuesFeed` jumps to the replied-to value, or asks the server to load the chat around it. --%>
        <button
          :if={@reply_parent}
          id={"value-reply-quote-#{@value.id}"}
          type="button"
          phx-click={
            JS.dispatch("potok:show-value",
              to: "#group-values-feed",
              detail: %{id: @reply_parent.id}
            )
          }
          title={gettext("Show original value")}
          class={[
            "mb-2 block w-full min-w-0 rounded-xl border-l-4 px-3 py-1.5 text-left text-sm transition-colors",
            @mine? &&
              "border-primary-content/50 bg-primary-content/10 hover:bg-primary-content/15",
            !@mine? && "border-primary/60 bg-base-200 hover:bg-base-300"
          ]}
        >
          <span class={[
            "block text-xs font-semibold",
            if(@mine?, do: "text-primary-content", else: "text-primary")
          ]}>
            {@reply_parent.creator.username}
          </span>
          <span class={[
            "line-clamp-2 wrap-break-word",
            if(@mine?, do: "text-primary-content/80", else: "text-base-content/70")
          ]}>
            {Value.excerpt(@reply_parent, 160)}
          </span>
        </button>
        <EventCard.card :if={@event} value_id={@value.id} event={@event} mine={@mine?} />
        <%!-- Expansion is a client-side attribute toggle: no round trip and no re-render of the stream item. --%>
        <div :if={@has_text? and is_nil(@event)} class="relative">
          <div class={[
            @expandable? &&
              "max-h-[7.5rem] overflow-hidden group-data-expanded/value:max-h-none group-data-expanded/value:overflow-visible"
          ]}>
            <.formatted_content
              content={@value.content}
              content_format={@value.content_format}
              uses_api={@uses_api}
              mentions={@value.mentions}
            />
          </div>

          <div
            :if={@expandable?}
            class={[
              "pointer-events-none absolute inset-x-0 bottom-0 h-12 bg-linear-to-t group-data-expanded/value:hidden",
              @mine? && "from-primary to-transparent",
              !@mine? && "from-base-100 to-transparent"
            ]}
          >
          </div>

          <button
            :if={@expandable?}
            id={"value-toggle-#{@value.id}"}
            type="button"
            phx-click={JS.toggle_attribute({"data-expanded", "true"}, to: "##{@dom_id}")}
            class={[
              "mt-3 text-sm font-semibold transition-opacity hover:opacity-80",
              @mine? && "text-primary-content",
              !@mine? && "text-primary"
            ]}
          >
            <span class="group-data-expanded/value:hidden">{gettext("See more")}</span>
            <span class="hidden group-data-expanded/value:inline">{gettext("See less")}</span>
          </button>
        </div>

        <.link_preview_card
          :if={@link_preview}
          value_id={@value.id}
          preview={@link_preview}
          mine={@mine?}
          can_dismiss={@mine? and !@editing?}
          class={(@has_text? or @reply_parent) && "mt-2.5"}
        />

        <div
          :if={@media != [] or @audios != [] or @files != []}
          id={"value-attachments-#{@value.id}"}
          class={["flex flex-col gap-2", (@has_text? or @link_preview) && "mt-2.5"]}
        >
          <div :if={@media != []} class="flex flex-wrap gap-2">
            <a
              :for={item <- @media}
              id={"value-attachment-#{item.id}"}
              href={~p"/files/#{item.id}"}
              target="_blank"
              rel="noopener"
              title={item.filename}
              {MediaViewer.media_data(item, "value-#{@value.id}")}
              class={[
                "group/image relative block overflow-hidden rounded-2xl border transition duration-150 ease-out hover:-translate-y-px hover:shadow-md",
                if(@mine?, do: "border-primary-content/25", else: "border-base-300")
              ]}
            >
              <%= if ValueAttachment.media_kind(item) == :video do %>
                <%!-- The first frame stands in for a thumbnail; the viewer plays the video. --%>
                <video
                  src={"#{~p"/files/#{item.id}"}#t=0.1"}
                  preload="metadata"
                  muted
                  playsinline
                  disablepictureinpicture
                  tabindex="-1"
                  class="pointer-events-none block h-48 w-auto min-w-36 max-w-full bg-base-300 object-cover transition-transform duration-300 ease-out group-hover/image:scale-[1.02] sm:max-w-80"
                >
                </video>
                <span class="absolute inset-0 flex items-center justify-center bg-black/10 transition-colors duration-150 group-hover/image:bg-black/20">
                  <span class="inline-flex size-12 items-center justify-center rounded-full bg-black/55 text-white shadow-lg backdrop-blur transition-transform duration-200 ease-out group-hover/image:scale-110">
                    <.icon name="hero-play-solid" class="size-6 translate-x-0.5" />
                  </span>
                </span>
              <% else %>
                <img
                  src={~p"/files/#{item.id}"}
                  alt={item.filename}
                  loading="lazy"
                  decoding="async"
                  class="block h-48 w-auto min-w-24 max-w-full bg-base-200 object-cover transition-transform duration-300 ease-out group-hover/image:scale-[1.02] sm:max-w-80"
                />
              <% end %>
            </a>
          </div>
          <.audio_player
            :for={audio <- @audios}
            id={"value-audio-#{audio.id}"}
            file={audio}
            mine={@mine?}
          />
          <a
            :for={file <- @files}
            id={"value-attachment-#{file.id}"}
            href={~p"/files/#{file.id}"}
            download={file.filename}
            title={file.filename}
            class={[
              "group/file flex min-w-0 items-center gap-3 rounded-2xl border py-2 pr-3 pl-2 transition duration-150 ease-out hover:-translate-y-px sm:min-w-64",
              if(@mine?,
                do:
                  "border-primary-content/25 bg-primary-content/10 text-primary-content hover:bg-primary-content/15",
                else: "border-base-300 bg-base-200/60 text-base-content hover:bg-base-200"
              )
            ]}
          >
            <span class={[
              "inline-flex size-9 shrink-0 items-center justify-center rounded-xl",
              if(@mine?, do: "bg-primary-content/15", else: "bg-base-100 text-base-content/60")
            ]}>
              <.icon name={file_icon(file.content_type)} class="size-5" />
            </span>
            <span class="min-w-0 flex-1">
              <span class="block truncate text-sm font-medium">{file.filename}</span>
              <span class={[
                "block text-xs tabular-nums",
                if(@mine?, do: "text-primary-content/70", else: "text-base-content/55")
              ]}>
                {format_bytes(file.byte_size)}
              </span>
            </span>
            <.icon
              name="hero-arrow-down-tray"
              class="size-4 shrink-0 opacity-60 transition-opacity group-hover/file:opacity-100"
            />
          </a>
        </div>
      </div>

      <div
        :if={@reactions != [] or @value.tags != [] or @thread}
        id={"value-footer-#{@value.id}"}
        class={[
          "chat-footer mt-1.5 flex max-w-full flex-wrap items-center gap-1 sm:max-w-[42rem]",
          @mine? && "flex-row-reverse"
        ]}
      >
        <%!-- An event rather than a link: opening the thread also joins members who came later. --%>
        <button
          :if={@thread}
          id={"value-thread-link-#{@value.id}"}
          type="button"
          phx-click="open_value_thread"
          phx-value-id={@value.id}
          disabled={!@can_join_thread}
          title={@thread.name}
          class="inline-flex h-7 items-center gap-1.5 rounded-full border border-primary/30 bg-primary/10 px-2.5 text-xs font-semibold text-primary shadow-xs transition duration-150 ease-out enabled:hover:-translate-y-px enabled:hover:bg-primary/15 enabled:active:scale-95 disabled:cursor-default phx-click-loading:animate-pulse"
        >
          <.icon name="hero-chat-bubble-left-right" class="size-4" />
          {gettext("Thread")}
          <.icon name="hero-chevron-right" class="size-3" />
        </button>
        <div
          :if={@reactions != []}
          id={"value-reactions-#{@value.id}"}
          class={[
            "flex flex-wrap items-center gap-1",
            @mine? && "justify-end"
          ]}
        >
          <button
            :for={reaction <- @reactions}
            id={"value-reaction-#{@value.id}-#{reaction.key}"}
            type="button"
            phx-click="toggle_reaction"
            phx-value-id={@value.id}
            phx-value-emoji={reaction.emoji}
            aria-pressed={to_string(reaction.mine?)}
            title={Enum.join(reaction.names, ", ")}
            disabled={!@can_react}
            class={[
              "inline-flex h-7 items-center gap-1 rounded-full border px-2 leading-none shadow-xs transition duration-150 ease-out",
              "enabled:hover:-translate-y-px enabled:active:scale-95 disabled:cursor-default",
              if(reaction.mine?,
                do: "border-primary/50 bg-primary/10 text-primary",
                else:
                  "border-base-300 bg-base-100 text-base-content/70 enabled:hover:border-base-content/25 enabled:hover:bg-base-200"
              )
            ]}
          >
            <span class="text-base leading-none">{reaction.emoji}</span>
            <span class="text-xs font-semibold tabular-nums">{reaction.count}</span>
          </button>
        </div>
        <TagComponents.tag_chips
          id={"value-tag-list-#{@value.id}"}
          tags={@value.tags}
          class={@mine? && "justify-end"}
        />
      </div>
    </div>
    """
  end

  # A preview fetched by `Social` once the value was posted (`PotokIde.LinkPreviews`).
  defp value_link_preview(%Value{link_preview: %{"url" => url} = preview}) when is_binary(url),
    do: preview

  defp value_link_preview(_value), do: nil

  defp mentions_profile?(%Value{mentioned_profile_ids: [_ | _] = ids}, %{id: profile_id}),
    do: profile_id in ids

  defp mentions_profile?(_value, _profile), do: false

  # Association matches stay defensive: a value that was not loaded with
  # `Social` display preloads renders without its quote or thread link.
  # Images and videos show as tiles that open the viewer, audio as a player,
  # every other file as a download row.
  defp assign_value_attachments(assigns, %Value{attachments: attachments})
       when is_list(attachments) do
    sections = Enum.group_by(attachments, &attachment_section/1)

    assigns
    |> assign(:media, Map.get(sections, :media, []))
    |> assign(:audios, Map.get(sections, :audio, []))
    |> assign(:files, Map.get(sections, :file, []))
  end

  defp assign_value_attachments(assigns, _value),
    do: assigns |> assign(:media, []) |> assign(:audios, []) |> assign(:files, [])

  defp attachment_section(attachment) do
    case ValueAttachment.media_kind(attachment) do
      kind when kind in [:image, :video] -> :media
      :audio -> :audio
      nil -> :file
    end
  end

  attr :value_id, :integer, required: true
  attr :preview, :map, required: true
  attr :mine, :boolean, default: false
  attr :can_dismiss, :boolean, default: false
  attr :class, :any, default: nil

  # The image comes straight from the linked site, without a referrer.
  # `.LinkPreviewImage` hides one that fails to load, fits a banner to the
  # image's own proportions and turns a small or squarish image (a logo)
  # into a thumbnail beside the text; re-renders keep what it set.
  defp link_preview_card(assigns) do
    ~H"""
    <div
      id={"value-link-preview-#{@value_id}"}
      class={["group/preview relative w-80 max-w-full sm:w-96", @class]}
    >
      <a
        id={"value-link-preview-link-#{@value_id}"}
        href={@preview["url"]}
        target="_blank"
        rel="noopener noreferrer nofollow"
        class={[
          "block overflow-hidden rounded-2xl border border-l-4 transition duration-150 ease-out hover:-translate-y-px hover:shadow-md",
          if(@mine,
            do:
              "border-primary-content/25 border-l-primary-content/60 bg-primary-content/10 text-primary-content hover:bg-primary-content/15",
            else:
              "border-base-300 border-l-primary bg-base-200/60 text-base-content hover:bg-base-200"
          )
        ]}
      >
        <img
          :if={@preview["image_url"]}
          id={"value-link-preview-image-#{@value_id}"}
          phx-hook=".LinkPreviewImage"
          phx-mounted={JS.ignore_attributes(["hidden", "data-shape", "style"])}
          src={@preview["image_url"]}
          alt=""
          loading="lazy"
          decoding="async"
          referrerpolicy="no-referrer"
          class="block aspect-[1.91/1] w-full bg-base-300/40 object-cover data-[shape=thumb]:float-left data-[shape=thumb]:m-2.5 data-[shape=thumb]:size-16 data-[shape=thumb]:rounded-xl sm:data-[shape=thumb]:size-20"
        />
        <div class={["px-3 py-2.5", @can_dismiss && "pr-10"]}>
          <p
            :if={@preview["site_name"]}
            class="truncate text-[11px] font-semibold uppercase tracking-wide opacity-60"
          >
            {@preview["site_name"]}
          </p>
          <p :if={@preview["title"]} class="mt-0.5 line-clamp-2 text-sm font-semibold leading-snug">
            {@preview["title"]}
          </p>
          <p
            :if={@preview["description"]}
            class="mt-0.5 line-clamp-2 text-sm leading-snug opacity-75"
          >
            {@preview["description"]}
          </p>
        </div>
      </a>
      <%!-- Outside the link, so removing the preview does not open it. Revealed on hover where there is one. --%>
      <button
        :if={@can_dismiss}
        id={"value-link-preview-dismiss-#{@value_id}"}
        type="button"
        phx-click="dismiss_link_preview"
        phx-value-id={@value_id}
        title={gettext("Remove preview")}
        aria-label={gettext("Remove preview")}
        class="absolute top-2 right-2 inline-flex size-7 items-center justify-center rounded-full bg-base-100/85 text-base-content/70 shadow-sm backdrop-blur transition duration-150 ease-out hover:bg-base-100 hover:text-base-content active:scale-95 focus-visible:opacity-100 pointer-fine:opacity-0 pointer-fine:group-hover/preview:opacity-100 phx-click-loading:pointer-events-none phx-click-loading:animate-pulse"
      >
        <.icon name="hero-x-mark" class="size-4" />
      </button>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".LinkPreviewImage">
      // Open Graph asks for 1.91:1 banners. Wider and slightly narrower ones
      // keep their own proportions; a small or squarish image would be cut
      // or blown up, so it becomes a thumbnail.
      const ratio = img => img.naturalWidth / img.naturalHeight
      const isThumbnail = img => img.naturalWidth < 300 || ratio(img) < 1.3

      export default {
        mounted() {
          this.el.addEventListener("error", () => this.hide())
          this.el.addEventListener("load", () => this.measure())

          if (this.el.complete) {
            if (this.el.naturalWidth === 0) this.hide()
            else this.measure()
          }
        },

        hide() {
          this.el.hidden = true
        },

        measure() {
          if (isThumbnail(this.el)) this.el.dataset.shape = "thumb"
          else this.el.style.aspectRatio = String(Math.min(Math.max(ratio(this.el), 1.5), 2.6))
        },
      }
    </script>
    """
  end

  attr :id, :string, required: true
  attr :file, ValueAttachment, required: true
  attr :mine, :boolean, default: false

  # Ignored by LiveView once mounted, so re-rendering the value (a reaction,
  # an edit) does not stop or rewind what is playing.
  defp audio_player(assigns) do
    ~H"""
    <div
      id={@id}
      phx-hook=".AudioPlayer"
      phx-update="ignore"
      class={[
        "flex min-w-0 items-center gap-3 rounded-2xl border py-2 pr-2 pl-2 sm:min-w-72",
        if(@mine,
          do: "border-primary-content/25 bg-primary-content/10 text-primary-content",
          else: "border-base-300 bg-base-200/60 text-base-content"
        )
      ]}
    >
      <audio src={~p"/files/#{@file.id}"} preload="none"></audio>
      <button
        type="button"
        data-audio-toggle
        aria-pressed="false"
        aria-label={gettext("Play")}
        data-label-play={gettext("Play")}
        data-label-pause={gettext("Pause")}
        class={[
          "group/toggle inline-flex size-9 shrink-0 items-center justify-center rounded-full shadow-sm transition duration-150 ease-out hover:scale-105 active:scale-95 disabled:opacity-50",
          if(@mine,
            do: "bg-primary-content text-primary",
            else: "bg-primary text-primary-content"
          )
        ]}
      >
        <.icon
          name="hero-play-solid"
          class="size-4 translate-x-px group-aria-pressed/toggle:hidden"
        />
        <.icon name="hero-pause-solid" class="hidden size-4 group-aria-pressed/toggle:block" />
      </button>
      <div class="min-w-0 flex-1">
        <div class="flex items-baseline gap-2">
          <span class="min-w-0 flex-1 truncate text-sm font-medium" title={@file.filename}>
            {@file.filename}
          </span>
          <span
            data-audio-time
            class={[
              "shrink-0 text-xs tabular-nums",
              if(@mine, do: "text-primary-content/70", else: "text-base-content/55")
            ]}
          >
            {format_bytes(@file.byte_size)}
          </span>
        </div>
        <input
          type="range"
          data-audio-seek
          min="0"
          max="1000"
          step="1"
          value="0"
          aria-label={gettext("Playback position")}
          class={[
            "audio-seek mt-1.5 block w-full",
            if(@mine, do: "text-primary-content", else: "text-primary")
          ]}
        />
      </div>
      <a
        href={MediaViewer.download_path(@file)}
        title={gettext("Download")}
        aria-label={gettext("Download")}
        class="inline-flex size-8 shrink-0 items-center justify-center rounded-full opacity-60 transition duration-150 ease-out hover:bg-current/10 hover:opacity-100"
      >
        <.icon name="hero-arrow-down-tray" class="size-4" />
      </a>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".AudioPlayer">
      const formatTime = seconds => {
        const total = Math.max(Math.floor(seconds), 0)
        const hours = Math.floor(total / 3600)
        const minutes = Math.floor((total % 3600) / 60)
        const rest = String(total % 60).padStart(2, "0")

        return hours > 0
          ? `${hours}:${String(minutes).padStart(2, "0")}:${rest}`
          : `${minutes}:${rest}`
      }

      export default {
        mounted() {
          const audio = (this.audio = this.el.querySelector("audio"))
          const toggle = this.el.querySelector("[data-audio-toggle]")
          const seek = this.el.querySelector("[data-audio-seek]")
          const time = this.el.querySelector("[data-audio-time]")
          const size = time.textContent.trim()
          let seeking = false
          let pendingSeek = null

          const knownDuration = () => Number.isFinite(audio.duration) && audio.duration > 0

          const showTime = position => {
            time.textContent = knownDuration()
              ? `${formatTime(position)} / ${formatTime(audio.duration)}`
              : size
          }

          const fill = () => seek.style.setProperty("--progress", `${seek.value / 10}%`)

          const render = () => {
            if (seeking) return
            seek.value = knownDuration() ? Math.round((audio.currentTime / audio.duration) * 1000) : 0
            fill()
            showTime(audio.currentTime)
          }

          const renderPlaying = () => {
            const playing = !audio.paused
            toggle.setAttribute("aria-pressed", String(playing))
            toggle.setAttribute(
              "aria-label",
              playing ? toggle.dataset.labelPause : toggle.dataset.labelPlay
            )
          }

          toggle.addEventListener("click", () => {
            if (audio.paused) audio.play()?.catch(() => {})
            else audio.pause()
          })

          seek.addEventListener("input", () => {
            seeking = true
            fill()
            if (knownDuration()) showTime((seek.value / 1000) * audio.duration)
          })

          // Seeking before the first play loads the metadata first.
          seek.addEventListener("change", () => {
            seeking = false

            if (knownDuration()) {
              audio.currentTime = (seek.value / 1000) * audio.duration
            } else {
              pendingSeek = seek.value / 1000
              audio.preload = "metadata"
              audio.load()
            }
          })

          audio.addEventListener("loadedmetadata", () => {
            if (pendingSeek !== null && knownDuration()) {
              audio.currentTime = pendingSeek * audio.duration
              pendingSeek = null
            }

            render()
          })

          audio.addEventListener("timeupdate", render)
          audio.addEventListener("durationchange", render)
          audio.addEventListener("play", renderPlaying)
          audio.addEventListener("pause", renderPlaying)
          audio.addEventListener("ended", renderPlaying)
          audio.addEventListener("error", () => {
            toggle.disabled = true
            seek.disabled = true
            renderPlaying()
          })
        },

        destroyed() {
          this.audio?.pause()
        },
      }
    </script>
    """
  end

  @doc "A heroicon name for a file of the given content type."
  def file_icon(type)
      when type in [
             "application/zip",
             "application/gzip",
             "application/x-7z-compressed",
             "application/x-rar-compressed",
             "application/x-tar",
             "application/vnd.rar"
           ],
      do: "hero-archive-box"

  def file_icon(type)
      when type in [
             "text/csv",
             "application/vnd.ms-excel",
             "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
             "application/vnd.oasis.opendocument.spreadsheet"
           ],
      do: "hero-table-cells"

  def file_icon("image/" <> _subtype), do: "hero-photo"
  def file_icon("video/" <> _subtype), do: "hero-film"
  def file_icon("audio/" <> _subtype), do: "hero-musical-note"
  def file_icon("text/" <> _subtype), do: "hero-document-text"
  def file_icon("application/pdf"), do: "hero-document-text"
  def file_icon(_type), do: "hero-document"

  @doc "A byte count in decimal units: `840 B`, `2.4 MB`, `100 MB`."
  def format_bytes(bytes) when is_integer(bytes) and bytes < 1000, do: "#{bytes} B"

  def format_bytes(bytes) when is_integer(bytes) do
    {size, unit} =
      Enum.find([{1.0e9, "GB"}, {1.0e6, "MB"}, {1.0e3, "kB"}], fn {size, _unit} ->
        bytes >= size
      end)

    value = bytes / size

    number =
      if value < 10,
        do: :erlang.float_to_binary(value, decimals: 1),
        else: Integer.to_string(round(value))

    "#{number} #{unit}"
  end

  def format_bytes(_bytes), do: ""

  defp reply_parent(%Value{parent: %Value{creator: %Profile{}} = parent}), do: parent
  defp reply_parent(_value), do: nil

  defp value_thread(%Value{thread: %Group{} = thread}), do: thread
  defp value_thread(_value), do: nil

  # One pill per emoji, in the order the emoji was first used on the value.
  defp reaction_summary(reactions, current_profile) when is_list(reactions) do
    by_emoji = Enum.group_by(reactions, & &1.emoji)
    current_profile_id = current_profile && current_profile.id

    reactions
    |> Enum.uniq_by(& &1.emoji)
    |> Enum.map(fn %{emoji: emoji} ->
      emoji_reactions = Map.fetch!(by_emoji, emoji)

      %{
        emoji: emoji,
        key: Base.encode16(emoji, case: :lower),
        count: length(emoji_reactions),
        mine?: Enum.any?(emoji_reactions, &(&1.profile_id == current_profile_id)),
        names: for(%{profile: %{username: username}} <- emoji_reactions, do: username)
      }
    end)
  end

  defp reaction_summary(_reactions, _current_profile), do: []

  # App groups get the richer html5 allow-list for chat values; their scripts
  # only ever run inside the sandboxed `app_frame/1`.
  # Mentions are wrapped after sanitizing, which would drop their attributes.
  # The event the value announced, when it was loaded with it.
  defp value_event(%Value{event: %PotokIde.Events.Event{} = event}), do: event
  defp value_event(_value), do: nil

  defp render_formatted_content(
         %{content: content, content_format: :html, uses_api: true} = params
       ) do
    content
    |> UTF8.replace_invalid()
    |> HtmlSanitizeEx.html5()
    |> UTF8.replace_invalid()
    |> Mentions.highlight(params.mentions)
    |> raw()
  end

  defp render_formatted_content(%{content: content, content_format: :html} = params) do
    content
    |> sanitize_html()
    |> UTF8.replace_invalid()
    |> Mentions.highlight(params.mentions)
    |> raw()
  end

  defp render_formatted_content(%{content: content, content_format: :markdown} = params) do
    content
    |> markdown_to_html()
    |> sanitize_html()
    |> UTF8.replace_invalid()
    |> Mentions.highlight(params.mentions)
    |> raw()
  end

  defp render_formatted_content(%{content: content}) when is_binary(content),
    do: UTF8.replace_invalid(content)

  defp sanitize_html(content) when is_binary(content) do
    content
    |> UTF8.replace_invalid()
    |> HtmlSanitizeEx.Scrubber.scrub(PotokIdeWeb.RichContentScrubber)
    |> UTF8.replace_invalid()
  end

  # Compact output: no indentation between tags to show up as stray spaces.
  defp markdown_to_html(content) when is_binary(content) do
    content
    |> UTF8.replace_invalid()
    |> String.trim()
    |> Earmark.as_html!(breaks: true, compact_output: true)
  end

  defp datetime_to_iso8601(datetime) do
    datetime
    |> datetime_to_utc_datetime()
    |> DateTime.to_iso8601()
  end

  defp datetime_to_utc_datetime(%DateTime{} = datetime),
    do: DateTime.shift_zone!(datetime, "Etc/UTC")

  defp datetime_to_utc_datetime(%NaiveDateTime{} = datetime) do
    DateTime.from_naive!(datetime, "Etc/UTC")
  end

  defp value_expandable?(%{content: content}) when is_binary(content) do
    (String.contains?(content, "\n") and length(String.split(content, ~r/\R/, trim: false)) > 5) or
      String.length(content) > 320
  end

  defp value_expandable?(_), do: false

  defp profile_picture_url(profile), do: Avatars.profile_avatar_url(profile)

  defp group_identity_picture_url(%{is_direct: true} = group, current_profile) do
    case direct_group_other_member(group, current_profile) do
      nil -> group_picture_url(group)
      profile -> profile_picture_url(profile) || group_picture_url(group)
    end
  end

  defp group_identity_picture_url(group, _current_profile), do: group_picture_url(group)

  defp group_identity_name(%{is_direct: true} = group, current_profile) do
    case direct_group_other_member(group, current_profile) do
      %{username: username} when is_binary(username) and username != "" -> username
      _ -> group.name
    end
  end

  defp group_identity_name(group, _current_profile), do: group.name

  defp highlighted_text_segments(text, query)

  defp highlighted_text_segments(text, _query) when not is_binary(text),
    do: [%{text: to_string(text), match?: false}]

  defp highlighted_text_segments(text, query) when is_binary(text) and not is_binary(query),
    do: [%{text: text, match?: false}]

  defp highlighted_text_segments(text, query) do
    normalized_query = String.trim(query)

    if normalized_query == "" do
      [%{text: text, match?: false}]
    else
      regex = Regex.compile!(Regex.escape(normalized_query), "iu")

      regex
      |> Regex.split(text, include_captures: true, trim: false)
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(fn segment ->
        %{text: segment, match?: Regex.match?(regex, segment)}
      end)
    end
  end

  # Form preview: the field value is the raw URL/data URL the user entered.
  defp group_picture_url(url) when is_binary(url) do
    case String.trim(url) do
      "" -> nil
      trimmed_url -> trimmed_url
    end
  end

  defp group_picture_url(%{id: _} = group), do: Avatars.group_avatar_url(group)
  defp group_picture_url(_), do: nil

  defp direct_group_other_member(%{members: members}, %{id: current_profile_id}) do
    if Ecto.assoc_loaded?(members) do
      Enum.find(members, &(&1.id != current_profile_id))
    else
      nil
    end
  end

  defp direct_group_other_member(_group, _current_profile), do: nil

  defp profile_initials(username) when is_binary(username) do
    username
    |> String.split(~r/[\s_-]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(fn part ->
      part
      |> String.first()
      |> to_string()
    end)
    |> case do
      "" -> "?"
      initials -> String.upcase(initials)
    end
  end

  defp profile_initials(_), do: "?"

  defp group_initials(name) when is_binary(name) do
    name
    |> String.split(~r/[\s_-]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(fn part ->
      part
      |> String.first()
      |> to_string()
    end)
    |> case do
      "" -> "?"
      initials -> String.upcase(initials)
    end
  end

  defp group_initials(_), do: "?"

  attr :label, :any, required: true
  attr :value, :any, required: true

  defp inspect_tree_node(assigns) do
    case classify_tree_value(assigns.value) do
      {:leaf, rendered_value} ->
        assigns = assign(assigns, :rendered_value, rendered_value)

        ~H"""
        <div class="flex items-start gap-2 leading-5">
          <span class="font-semibold text-primary/80">{format_tree_label(@label)}</span>
          <span class="break-all text-base-content/70">{@rendered_value}</span>
        </div>
        """

      {:container, kind, entries} ->
        assigns = assigns |> assign(:kind, kind) |> assign(:entries, entries)

        ~H"""
        <details open class="tree-node">
          <summary class="cursor-pointer select-none leading-5">
            <span class="font-semibold text-primary/80">{format_tree_label(@label)}</span>
            <span class="ml-2 text-base-content/55">{@kind}</span>
          </summary>

          <ul class="ml-3 mt-2 border-l border-base-300/70 pl-3">
            <li :for={{entry_label, entry_value} <- @entries} class="mt-2">
              <.inspect_tree_node label={entry_label} value={entry_value} />
            </li>
          </ul>
        </details>
        """
    end
  end

  defp classify_tree_value(value) when is_struct(value) do
    struct_name = value.__struct__ |> Module.split() |> List.last()

    {:container, "%#{struct_name}{}", value |> Map.from_struct() |> tree_map_entries()}
  end

  defp classify_tree_value(value) when is_map(value) do
    {:container, "%{}", tree_map_entries(value)}
  end

  defp classify_tree_value(value) when is_list(value) do
    {:container, "list(#{length(value)})",
     Enum.with_index(value) |> Enum.map(fn {item, index} -> {"[#{index}]", item} end)}
  end

  defp classify_tree_value(value) when is_tuple(value) do
    entries =
      value
      |> Tuple.to_list()
      |> Enum.with_index()
      |> Enum.map(fn {item, index} -> {"[#{index}]", item} end)

    {:container, "tuple(#{tuple_size(value)})", entries}
  end

  defp classify_tree_value(value) do
    {:leaf, inspect(value, pretty: true, limit: :infinity, printable_limit: :infinity)}
  end

  defp tree_map_entries(map) do
    map
    |> Enum.map(fn {key, value} -> {format_tree_key(key), value} end)
    |> Enum.sort_by(fn {key, _value} -> key end)
  end

  defp format_tree_key(key) when is_atom(key), do: Atom.to_string(key)
  defp format_tree_key(key) when is_binary(key), do: inspect(key)
  defp format_tree_key(key), do: inspect(key)

  defp format_tree_label(label) when is_binary(label), do: label <> ":"
  defp format_tree_label(label), do: inspect(label) <> ":"

  defp value_from_current_profile?(%{id: current_profile_id}, %{creator_id: creator_id}) do
    current_profile_id == creator_id
  end

  defp value_from_current_profile?(_, _), do: false
end
