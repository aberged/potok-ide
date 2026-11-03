defmodule PotokIdeWeb.ProfileLive.Components do
  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.Components, as: GroupComponents

  @max_profile_picture_upload_size 5 * 1024 * 1024
  @max_profile_picture_dimension 200

  # The cards of the profile form and the fields of each, so a save that fails
  # opens the card with the error.
  @form_section_fields [
    {"basics", [:username, :profile_picture_url]},
    {"description", [:description, :description_format]},
    {"sharing", [:sharing]}
  ]

  attr :profile, :map, required: true
  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil
  attr :current_profile, :map, default: nil
  attr :direct_group_link, :boolean, default: false

  def profile_identity(assigns) do
    ~H"""
    <GroupComponents.profile_identity
      profile={@profile}
      title={@title}
      subtitle={@subtitle}
      current_profile={@current_profile}
      direct_group_link={@direct_group_link}
    />
    """
  end

  attr :form, :any, required: true
  attr :section, :string, required: true, doc: "the card on screen (see `form_sections/1`)"
  attr :id_prefix, :string, required: true, doc: "starts the ids of the cards and of their tabs"
  attr :description_format_options, :list, required: true
  attr :sharing_options, :list, required: true

  @doc """
  The cards of the new and edit pages' form, laid out like a group's. A card
  not on screen is only hidden, so the form still sends every field.
  """
  def profile_form_cards(assigns) do
    ~H"""
    <GroupComponents.settings_card
      id={"#{@id_prefix}-basics"}
      tab_id={"#{@id_prefix}-tab-basics"}
      active={@section == "basics"}
      icon="hero-identification"
      title={gettext("Basics")}
      subtitle={gettext("The name and picture others see.")}
    >
      <.input
        field={@form[:username]}
        id={@form[:username].id}
        label={gettext("Username")}
        maxlength="16"
        required
      />
      <p class="mb-4 text-sm text-base-content/60">
        {gettext("Use 2 to 16 letters or numbers. You can also include _, ., and -.")}
      </p>
      <.profile_picture_field field={@form[:profile_picture_url]} />
    </GroupComponents.settings_card>

    <GroupComponents.settings_card
      id={"#{@id_prefix}-description"}
      tab_id={"#{@id_prefix}-tab-description"}
      active={@section == "description"}
      icon="hero-document-text"
      title={gettext("Description")}
      subtitle={gettext("What others read about this profile.")}
    >
      <.input
        :if={false}
        field={@form[:description_format]}
        id={@form[:description_format].id}
        label={gettext("Description format")}
        type="select"
        options={@description_format_options}
      />
      <.input
        field={@form[:description]}
        id={@form[:description].id}
        label={gettext("Description")}
        type="textarea"
      />
    </GroupComponents.settings_card>

    <GroupComponents.settings_card
      id={"#{@id_prefix}-sharing"}
      tab_id={"#{@id_prefix}-tab-sharing"}
      active={@section == "sharing"}
      icon="hero-share"
      title={gettext("Sharing")}
      subtitle={gettext("Whether one account uses the profile, or several.")}
    >
      <.input
        field={@form[:sharing]}
        id={@form[:sharing].id}
        label={gettext("Sharing")}
        type="select"
        options={@sharing_options}
      />
    </GroupComponents.settings_card>
    """
  end

  attr :field, :any, required: true

  defp profile_picture_field(assigns) do
    assigns =
      assigns
      |> assign(:max_profile_picture_upload_size, @max_profile_picture_upload_size)
      |> assign(:max_profile_picture_dimension, @max_profile_picture_dimension)

    ~H"""
    <.input
      field={@field}
      id={@field.id}
      label={gettext("Profile picture URL")}
      type="text"
      placeholder={gettext("https://example.com/avatar.png or data:image/...")}
    />
    <div
      id={"#{@field.id}-picker"}
      phx-hook=".ProfilePicturePicker"
      phx-update="ignore"
      data-input-id={@field.id}
      data-max-file-size={@max_profile_picture_upload_size}
      data-max-dimension={@max_profile_picture_dimension}
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
            class={button_class("secondary", "sm")}
          >
            <.icon name="hero-photo" class="size-4" /> {gettext("Choose image")}
          </label>
          <button
            type="button"
            data-profile-picture-clear
            class={button_class("ghost", "sm")}
          >
            <.icon name="hero-x-mark" class="size-4" /> {gettext("Clear image")}
          </button>
        </div>
      </div>

      <input
        id={"#{@field.id}-file"}
        type="file"
        accept="image/*"
        class="sr-only"
        data-profile-picture-file
      />
      <p
        data-profile-picture-error
        class="mt-3 hidden items-center gap-2 text-sm text-error"
        role="status"
        aria-live="polite"
      >
        <.icon name="hero-exclamation-circle" class="size-5 shrink-0" /> <span></span>
      </p>
    </div>

    <%= if preview_url = profile_picture_url(@field.value) do %>
      <div class="flex items-center gap-4 rounded-3xl border border-base-300/70 bg-base-100 p-4 shadow-sm">
        <div class="flex size-[72px] items-center justify-center overflow-hidden rounded-2xl border border-base-300/70 bg-base-200">
          <img
            src={preview_url}
            alt={gettext("Profile picture preview")}
            class="h-full w-full object-cover"
          />
        </div>

        <p class="text-sm text-base-content/70">
          {gettext("Preview of the current profile picture value.")}
        </p>
      </div>
    <% end %>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ProfilePicturePicker">
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
          this.fileInput = this.el.querySelector("[data-profile-picture-file]")
          this.errorContainer = this.el.querySelector("[data-profile-picture-error]")
          this.errorText = this.errorContainer?.querySelector("span")
          this.clearButton = this.el.querySelector("[data-profile-picture-clear]")
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
              console.error("Unable to process selected profile image", error)
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

  @doc "The tabs of `profile_form_cards/1`: `{key, panel id, label, danger?}`, in order."
  def form_sections(id_prefix) do
    [
      {"basics", "#{id_prefix}-basics", gettext("Basics"), false},
      {"description", "#{id_prefix}-description", gettext("Description"), false},
      {"sharing", "#{id_prefix}-sharing", gettext("Sharing"), false}
    ]
  end

  @doc "The first card, in bar order, holding a field with an error."
  def error_section(%Ecto.Changeset{errors: errors}) do
    fields = Keyword.keys(errors)

    Enum.find_value(@form_section_fields, fn {section, section_fields} ->
      if Enum.any?(fields, &(&1 in section_fields)), do: section
    end)
  end

  def description_format_options do
    [
      {gettext("Markdown"), :markdown},
      {gettext("HTML"), :html}
    ]
  end

  def sharing_options do
    [
      {gettext("Unique"), :unique},
      {gettext("Shared"), :shared}
    ]
  end

  def profile_picture_url(url) when is_binary(url) do
    case String.trim(url) do
      "" -> nil
      trimmed_url -> trimmed_url
    end
  end

  def profile_picture_url(%{id: _} = profile), do: PotokIdeWeb.Avatars.profile_avatar_url(profile)

  def profile_picture_url(_), do: nil
end
