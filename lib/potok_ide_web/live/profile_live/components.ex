defmodule PotokIdeWeb.ProfileLive.Components do
  use PotokIdeWeb, :html

  alias PotokIde.Initials
  alias PotokIde.Social.Profile
  alias PotokIdeWeb.Avatars
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
      <p class="mb-4 text-sm text-base-content/65">
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

  attr :form, :any, required: true, doc: "from `welcome_form/2`"

  attr :invitation, :any,
    default: nil,
    doc:
      "the account's invitation (`Social.first_pending_account_invitation/1`), with its group and inviter"

  attr :remember_me, :any,
    default: nil,
    doc: "whether the box that keeps the account logged in is ticked; nil leaves the box out"

  attr :button_variant, :string, default: "primary", doc: "`landing` on the guest pages"

  @doc """
  The first profile of an account, in a modal `<dialog>`: a name and a
  picture, and with an invitation, the group the profile goes into. The page
  around it handles `validate_profile`, `create_profile` (with the profile's
  fields under `profile` and the box under `remember_me`) and `welcome_close`.
  The rest of a profile is on the Profiles page.
  """
  def welcome_dialog(assigns) do
    picture_url = profile_picture_url(assigns.form[:profile_picture_url].value)
    username = String.trim(to_string(assigns.form[:username].value))
    invitation = assigns.invitation

    assigns =
      assigns
      |> assign(:picture_url, picture_url)
      |> assign(:username, username)
      |> assign(:initial_colors, Initials.colors(username))
      |> assign(:group, invitation && invitation.group)
      |> assign(:inviter, invitation && invitation.inviter && invitation.inviter.username)
      |> assign(:max_profile_picture_upload_size, @max_profile_picture_upload_size)
      |> assign(:max_profile_picture_dimension, @max_profile_picture_dimension)

    ~H"""
    <dialog
      id="welcome-dialog"
      phx-hook=".WelcomeDialog"
      phx-mounted={JS.ignore_attributes(["open"])}
      aria-labelledby="welcome-dialog-title"
      class="fixed inset-0 m-0 size-full max-h-none max-w-none overflow-hidden bg-transparent p-0 backdrop:bg-transparent"
    >
      <div class="flex size-full items-end justify-center sm:items-center sm:p-4">
        <div
          id="welcome-dialog-backdrop"
          class="absolute inset-0 bg-black/30 backdrop-blur-[2px] dark:bg-black/60"
          phx-click="welcome_close"
          aria-hidden="true"
        >
        </div>
        <section class="relative flex max-h-[92dvh] w-full flex-col overflow-hidden rounded-t-3xl border border-b-0 border-base-300/70 bg-base-100 text-base-content shadow-2xl shadow-base-content/10 sm:max-w-md sm:rounded-3xl sm:border-b">
          <header class="flex items-start gap-3 px-5 pt-5">
            <img
              :if={@group}
              id="welcome-dialog-group"
              src={Avatars.group_avatar_url(@group)}
              alt=""
              class="size-11 shrink-0 rounded-2xl border border-base-300/70 bg-base-200 object-cover"
            />
            <span
              :if={!@group}
              class="inline-flex size-11 shrink-0 items-center justify-center rounded-2xl bg-primary/10 text-primary"
            >
              <.icon name="hero-user-plus" class="size-5" />
            </span>
            <div class="min-w-0 flex-1">
              <h2 id="welcome-dialog-title" class="text-lg font-semibold leading-tight">
                {gettext("Create your profile")}
              </h2>
              <p id="welcome-dialog-lead" class="mt-1 text-sm leading-6 text-base-content/70">
                <%= if @group && @inviter do %>
                  {gettext(
                    "@%{username} invites you to “%{group}”. People there will know you by this name and picture.",
                    username: @inviter,
                    group: @group.name
                  )}
                <% else %>
                  {gettext("People in groups will know you by this name and picture.")}
                <% end %>
              </p>
            </div>
            <.icon_button
              id="welcome-close"
              type="button"
              phx-click="welcome_close"
              icon="hero-x-mark"
              label={gettext("Close")}
              class="-mt-1 -mr-1"
            />
          </header>

          <.form
            for={@form}
            id="welcome-profile-form"
            phx-change="validate_profile"
            phx-submit="create_profile"
            class="min-h-0 flex-1 overflow-y-auto px-5 pt-5 pb-[calc(1.25rem+var(--app-safe-area-bottom))] sm:pb-5"
          >
            <%!-- The picker is ignored by patches, so the preview and the
                 field stand outside it, and the wrapper's `data-picture`
                 tells its "Clear image" when to show. --%>
            <div
              id="welcome-picture"
              data-picture={if @picture_url, do: "set", else: "none"}
              class="group/picture mb-5 flex items-center gap-4"
            >
              <span
                id="welcome-picture-preview"
                class="flex size-16 shrink-0 items-center justify-center overflow-hidden rounded-full border border-base-300/70 bg-base-200 text-base-content/50 shadow-sm"
                style={
                  !@picture_url && @username != "" &&
                    "background-color: #{elem(@initial_colors, 0)}; color: #{elem(@initial_colors, 1)}"
                }
              >
                <img
                  :if={@picture_url}
                  src={@picture_url}
                  alt={gettext("Profile picture preview")}
                  class="size-full object-cover"
                />
                <span :if={!@picture_url && @username != ""} class="text-xl font-semibold">
                  {Initials.of(@username)}
                </span>
                <.icon :if={!@picture_url && @username == ""} name="hero-user" class="size-7" />
              </span>
              <input
                type="hidden"
                id="welcome-picture-url"
                name={@form[:profile_picture_url].name}
                value={@form[:profile_picture_url].value}
              />
              <div
                id="welcome-picture-picker"
                phx-hook=".ProfilePicturePicker"
                phx-update="ignore"
                data-input-id="welcome-picture-url"
                data-max-file-size={@max_profile_picture_upload_size}
                data-max-dimension={@max_profile_picture_dimension}
                data-file-too-large-message={gettext("Choose an image smaller than 5 MB.")}
                data-invalid-image-message={gettext("Choose a valid image file.")}
                data-processing-message={gettext("Could not process that image.")}
                class="min-w-0 flex-1"
              >
                <div class="flex flex-wrap gap-2">
                  <label for="welcome-picture-file" class={button_class("secondary", "sm")}>
                    <.icon name="hero-photo" class="size-4" /> {gettext("Choose image")}
                  </label>
                  <button
                    id="welcome-picture-clear"
                    type="button"
                    data-profile-picture-clear
                    class={[button_class("ghost", "sm"), "group-data-[picture=none]/picture:hidden"]}
                  >
                    <.icon name="hero-x-mark" class="size-4" /> {gettext("Clear image")}
                  </button>
                </div>
                <input
                  id="welcome-picture-file"
                  type="file"
                  accept="image/*"
                  class="sr-only"
                  data-profile-picture-file
                />
                <p
                  data-profile-picture-error
                  class="mt-2 hidden items-center gap-2 text-sm text-error"
                  role="status"
                  aria-live="polite"
                >
                  <.icon name="hero-exclamation-circle" class="size-5 shrink-0" /> <span></span>
                </p>
              </div>
            </div>

            <.input
              field={@form[:username]}
              id="welcome-username"
              label={gettext("Username")}
              maxlength="16"
              autocomplete="nickname"
              autofocus
              required
            />
            <p class="-mt-1 mb-4 text-sm text-base-content/65">
              {gettext("Use 2 to 16 letters or numbers. You can also include _, ., and -.")}
            </p>

            <.input
              :if={!is_nil(@remember_me)}
              type="checkbox"
              id="welcome-remember-me"
              name="remember_me"
              checked={@remember_me}
              label={gettext("Keep me logged in on this device")}
            />

            <.button
              id="welcome-submit"
              type="submit"
              variant={@button_variant}
              phx-disable-with={gettext("Creating...")}
              class="mt-2 w-full"
            >
              {if @group,
                do: gettext("Create profile and join the group"),
                else: gettext("Create profile")}
            </.button>

            <p id="welcome-later" class="mt-4 text-center text-xs leading-5 text-base-content/60">
              {gettext("You can add a description and more profiles later, on the Profiles page.")}
            </p>
          </.form>
        </section>
      </div>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".WelcomeDialog">
      export default {
        mounted() {
          // Escape closes the dialog through the server, which removes it.
          this.el.addEventListener("cancel", event => {
            event.preventDefault()
            this.pushEvent("welcome_close", {})
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

  @doc """
  The form of `welcome_dialog/1`: only a name and a picture, the rest keeps
  its defaults. `action` shows the errors (`:validate`, `:insert`).
  """
  def welcome_form(attrs \\ %{}, action \\ nil) do
    %Profile{}
    |> Profile.changeset(welcome_attrs(attrs))
    |> Map.put(:action, action)
    |> to_form()
  end

  @doc "The fields of a profile `welcome_dialog/1` sends."
  def welcome_attrs(attrs) when is_map(attrs),
    do: Map.take(attrs, ["username", "profile_picture_url"])

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
      {sharing_label(:unique), :unique},
      {sharing_label(:shared), :shared}
    ]
  end

  def sharing_label(:unique), do: gettext("Unique")
  def sharing_label(:shared), do: gettext("Shared")

  def profile_picture_url(url) when is_binary(url) do
    case String.trim(url) do
      "" -> nil
      trimmed_url -> trimmed_url
    end
  end

  def profile_picture_url(%{id: _} = profile), do: PotokIdeWeb.Avatars.profile_avatar_url(profile)

  def profile_picture_url(_), do: nil
end
