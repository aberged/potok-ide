defmodule PotokIdeWeb.ProfileCard do
  @moduledoc """
  A profile's card as one viewer sees it (`PotokIde.Social.ProfileDetails.card/3`):
  the name and picture, the details and description shown to them, the tags
  they see, the groups both are in and a button to write to it. The page
  `/u/:username` and the dialog of the group page (`dialog/1`) show the same.
  """

  use PotokIdeWeb, :html

  alias PotokIde.Social.ProfileField
  alias PotokIdeWeb.GroupLive.Show.Components, as: GroupComponents
  alias PotokIdeWeb.ProfileLive.Components, as: ProfileComponents
  alias PotokIdeWeb.TagComponents

  attr :id, :string, required: true
  attr :card, :map, required: true

  attr :message_event, :string,
    default: "profile_card_message",
    doc: "the event the button to write sends, with the profile's `id`"

  def profile_card(assigns) do
    {names, others} = Enum.split_with(assigns.card.fields, &(&1.key in [:first_name, :last_name]))

    assigns =
      assigns
      |> assign(:full_name, names |> Enum.map(& &1.value) |> Enum.join(" ") |> blank_to_nil())
      |> assign(:others, others)
      |> assign(
        :empty?,
        assigns.card.fields == [] and not assigns.card.description? and assigns.card.tags == []
      )

    ~H"""
    <div id={@id} class="space-y-5">
      <GroupComponents.profile_identity
        profile={@card.profile}
        avatar_size="size-16"
        text_class="text-lg"
        subtitle={@full_name}
      />

      <dl :if={@others != []} id={"#{@id}-fields"} class="space-y-2">
        <div
          :for={field <- @others}
          id={"#{@id}-field-#{field.key}"}
          class="flex items-start gap-3 rounded-2xl bg-base-200/50 px-3 py-2.5"
        >
          <.icon name={detail_icon(field.key)} class="mt-0.5 size-4 shrink-0 text-base-content/55" />
          <div class="min-w-0 flex-1">
            <dt class="text-xs text-base-content/60">{ProfileComponents.detail_label(field.key)}</dt>
            <dd class="text-sm wrap-break-word">
              <.detail_value field={field} />
            </dd>
          </div>
        </div>
      </dl>

      <section :if={@card.description?} id={"#{@id}-description"}>
        <h3 class="mb-1.5 text-xs font-semibold uppercase tracking-[0.14em] text-base-content/60">
          {gettext("About me")}
        </h3>
        <GroupComponents.formatted_content
          content={@card.profile.description}
          content_format={@card.profile.description_format}
          class="text-sm"
        />
      </section>

      <TagComponents.tag_chips :if={@card.tags != []} id={"#{@id}-tags"} tags={@card.tags} />

      <section :if={@card.shared_groups != []} id={"#{@id}-groups"}>
        <h3 class="mb-1.5 text-xs font-semibold uppercase tracking-[0.14em] text-base-content/60">
          {gettext("Groups you share")}
        </h3>
        <ul class="flex flex-wrap gap-1.5">
          <li :for={group <- @card.shared_groups}>
            <.link
              id={"#{@id}-group-#{group.id}"}
              navigate={~p"/groups/#{group.id}"}
              class="inline-flex max-w-full items-center gap-1.5 rounded-full border border-base-300/80 bg-base-100 px-2.5 py-1 text-xs font-medium transition hover:border-primary/40 hover:text-primary"
            >
              <.icon name="hero-user-group-micro" class="size-3.5 shrink-0" />
              <span class="truncate">{group.name}</span>
            </.link>
          </li>
        </ul>
      </section>

      <p :if={@empty?} id={"#{@id}-empty"} class="text-sm text-base-content/65">
        {gettext("This profile shows you nothing more.")}
      </p>

      <.button
        :if={@card.can_message?}
        id={"#{@id}-message"}
        type="button"
        phx-click={@message_event}
        phx-value-id={@card.profile.id}
        phx-disable-with={gettext("Opening...")}
        variant="primary"
        class="w-full sm:w-auto"
      >
        <.icon name="hero-chat-bubble-left-right" class="size-4" />
        <span>{gettext("Send a message")}</span>
      </.button>
    </div>
    """
  end

  attr :field, :map, required: true

  defp detail_value(%{field: %ProfileField{key: :phone}} = assigns) do
    ~H"""
    <a href={"tel:" <> String.replace(@field.value, ~r/[^\d+]/, "")} class="link link-hover">
      {@field.value}
    </a>
    """
  end

  defp detail_value(%{field: %ProfileField{key: :email}} = assigns) do
    ~H"""
    <a href={"mailto:" <> @field.value} class="link link-hover">{@field.value}</a>
    """
  end

  defp detail_value(%{field: %ProfileField{key: :website}} = assigns) do
    ~H"""
    <span :for={link <- ProfileField.links(@field)} class="block">
      <a
        href={link}
        target="_blank"
        rel="nofollow noopener noreferrer ugc"
        class="link link-hover break-all"
      >
        {String.replace(link, ~r{^https?://}, "")}
      </a>
    </span>
    """
  end

  defp detail_value(assigns) do
    ~H"""
    {@field.value}
    """
  end

  defp detail_icon(:occupation), do: "hero-briefcase"
  defp detail_icon(:place), do: "hero-map-pin"
  defp detail_icon(:phone), do: "hero-phone"
  defp detail_icon(:email), do: "hero-envelope"
  defp detail_icon(:website), do: "hero-link"
  defp detail_icon(_key), do: "hero-identification"

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  attr :card, :map, default: nil, doc: "the card shown, nil when closed"

  @doc """
  The card in a top-layer `<dialog>` of the group page, which handles
  `profile_card_close` and `profile_card_message`.
  """
  def dialog(assigns) do
    ~H"""
    <dialog
      :if={@card}
      id="profile-card-dialog"
      phx-hook=".ProfileCardDialog"
      phx-mounted={JS.ignore_attributes(["open"])}
      aria-label={@card.profile.username}
      class="fixed inset-0 m-0 size-full max-h-none max-w-none overflow-hidden bg-transparent p-0 backdrop:bg-transparent"
    >
      <div class="flex size-full items-end justify-center sm:items-center sm:p-4">
        <div
          id="profile-card-backdrop"
          class="absolute inset-0 bg-black/30 backdrop-blur-[2px] dark:bg-black/60"
          phx-click="profile_card_close"
          aria-hidden="true"
        >
        </div>
        <section class="relative flex max-h-[92dvh] w-full flex-col overflow-hidden rounded-t-3xl border border-b-0 border-base-300/70 bg-base-100 text-base-content shadow-2xl shadow-base-content/10 sm:max-w-md sm:rounded-3xl sm:border-b">
          <div class="flex justify-end px-3 pt-3">
            <.icon_button
              id="profile-card-close"
              type="button"
              phx-click="profile_card_close"
              icon="hero-x-mark"
              label={gettext("Close")}
            />
          </div>
          <div class="min-h-0 flex-1 overflow-y-auto px-5 pb-[calc(1.25rem+var(--app-safe-area-bottom))] sm:pb-5">
            <.profile_card id="profile-card" card={@card} />
          </div>
        </section>
      </div>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".ProfileCardDialog">
      export default {
        mounted() {
          // Escape closes the dialog through the server, which removes it.
          this.el.addEventListener("cancel", event => {
            event.preventDefault()
            this.pushEvent("profile_card_close", {})
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
end
