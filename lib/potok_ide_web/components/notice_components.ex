defmodule PotokIdeWeb.NoticeComponents do
  @moduledoc """
  Pieces the group's notices tab, the bell in its header, the page of notices
  and the settings share.
  """

  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.Components

  attr :id, :string, required: true
  attr :checked, :boolean, required: true
  attr :label, :string, required: true
  attr :disabled, :boolean, default: false
  attr :class, :any, default: nil
  attr :rest, :global, include: ~w(phx-click phx-value-push phx-value-group-id)

  @doc "A switch that says what it turns on; the click goes to the server."
  def push_switch(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      role="switch"
      aria-checked={to_string(@checked)}
      disabled={@disabled}
      class={[
        "inline-flex min-h-9 items-center gap-2.5 text-left text-sm font-medium text-base-content/80 transition hover:text-base-content disabled:cursor-not-allowed disabled:opacity-60",
        @class
      ]}
      {@rest}
    >
      <span class={[
        "relative inline-flex h-5 w-9 shrink-0 items-center rounded-full transition-colors duration-200",
        if(@checked and !@disabled, do: "bg-primary", else: "bg-base-300")
      ]}>
        <span class={[
          "inline-block size-4 rounded-full bg-base-100 shadow transition-transform duration-200",
          if(@checked and !@disabled, do: "translate-x-4.5", else: "translate-x-0.5")
        ]} />
      </span>
      <span class="min-w-0">{@label}</span>
    </button>
    """
  end

  attr :body, :string, required: true
  attr :class, :any, default: nil

  @doc "A notice's text, formatted as a chat message is, through the same sanitizer."
  def notice_body(assigns) do
    ~H"""
    <Components.formatted_content
      content={@body}
      content_format={:markdown}
      class={["break-words text-sm leading-6 text-base-content", @class]}
    />
    """
  end

  attr :notice, :map, required: true
  attr :can_dismiss, :boolean, default: false
  attr :class, :any, default: nil

  @doc """
  The card of a notice's first link, once it was fetched (`PotokIde.Notices`),
  as a chat message shows one. Its × sends `notice_dismiss_preview`.
  """
  def notice_link_preview(assigns) do
    ~H"""
    <Components.link_preview_card
      :if={link_preview?(@notice)}
      item_id={@notice.id}
      id_prefix="notice-link-preview"
      preview={@notice.link_preview}
      can_dismiss={@can_dismiss}
      dismiss_event="notice_dismiss_preview"
      class={@class}
    />
    """
  end

  defp link_preview?(%{link_preview: %{"url" => url}}) when is_binary(url), do: true
  defp link_preview?(_notice), do: false

  attr :id, :string, required: true

  @doc "The note under a push switch when the profile has turned every notice's push off."
  def push_off_note(assigns) do
    ~H"""
    <p id={@id} class="text-xs text-base-content/65">
      {gettext("Push is off for every notice.")}
      <.link
        navigate={~p"/accounts/settings#notice-push-settings"}
        class="font-medium text-primary hover:underline"
      >
        {gettext("Turn it on in Settings")}
      </.link>
    </p>
    """
  end
end
