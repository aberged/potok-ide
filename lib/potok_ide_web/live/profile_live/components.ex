defmodule PotokIdeWeb.ProfileLive.Components do
  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.Components, as: GroupComponents

  @max_profile_picture_upload_size 5 * 1024 * 1024
  @max_profile_picture_dimension 200

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
  attr :description_format_options, :list, required: true
  attr :sharing_options, :list, required: true

  def profile_form_fields(assigns) do
    assigns =
      assigns
      |> assign(:max_profile_picture_upload_size, @max_profile_picture_upload_size)
      |> assign(:max_profile_picture_dimension, @max_profile_picture_dimension)

    ~H"""
    <.input field={@form[:username]} id={@form[:username].id} label={gettext("Username")} required />
    <.input
      field={@form[:profile_picture_url]}
      id={@form[:profile_picture_url].id}
      label={gettext("Profile picture URL")}
      type="text"
      placeholder={gettext("https://example.com/avatar.png or data:image/...")}
    />
    <div
      id={"#{@form[:profile_picture_url].id}-picker"}
      phx-hook=".ProfilePicturePicker"
      phx-update="ignore"
      data-input-id={@form[:profile_picture_url].id}
      data-max-file-size={@max_profile_picture_upload_size}
      data-max-dimension={@max_profile_picture_dimension}
      data-file-too-large-message={gettext("Choose an image smaller than 5 MB.")}
      data-invalid-image-message={gettext("Choose a valid image file.")}
      data-processing-message={gettext("Could not process that image.")}
      class="mb-4 rounded-3xl border border-base-300/70 bg-base-200/40 p-4"
    >
      <div class="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
        <div class="space-y-1">
          <p class="text-sm font-semibold text-base-content">
            {gettext("Upload from your device")}
          </p>
          <p class="text-xs leading-5 text-base-content/70">
            {gettext("Images are resized to fit within 200 x 200 and files over 5 MB are rejected.")}
          </p>
        </div>
        <div class="flex flex-wrap gap-2">
          <label
            for={"#{@form[:profile_picture_url].id}-file"}
            class="inline-flex cursor-pointer items-center gap-2 rounded-full bg-base-content px-4 py-2 text-sm font-medium text-base-100 transition hover:opacity-90"
          >
            <.icon name="hero-photo" class="size-5" />
            {gettext("Choose image")}
          </label>
          <button
            type="button"
            data-profile-picture-clear
            class="inline-flex items-center gap-2 rounded-full border border-base-300 bg-base-100 px-4 py-2 text-sm font-medium text-base-content transition hover:border-base-content/30 hover:bg-base-100/80"
          >
            <.icon name="hero-x-mark" class="size-5" />
            {gettext("Clear image")}
          </button>
        </div>
      </div>
      <input
        id={"#{@form[:profile_picture_url].id}-file"}
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
        <.icon name="hero-exclamation-circle" class="size-5 shrink-0" />
        <span></span>
      </p>
    </div>
    <%= if preview_url = profile_picture_url(@form[:profile_picture_url].value) do %>
      <div class="mb-4 flex items-center gap-4 rounded-3xl border border-base-300/70 bg-base-100 p-4 shadow-sm">
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
    <.input
      field={@form[:sharing]}
      id={@form[:sharing].id}
      label={gettext("Sharing")}
      type="select"
      options={@sharing_options}
    />
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

  def profile_picture_url(%{profile_picture_url: url}) when is_binary(url),
    do: profile_picture_url(url)

  def profile_picture_url(_), do: nil
end
