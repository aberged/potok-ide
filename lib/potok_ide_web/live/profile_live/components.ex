defmodule PotokIdeWeb.ProfileLive.Components do
  use PotokIdeWeb, :html

  attr :profile, :map, required: true
  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil

  def profile_identity(assigns) do
    ~H"""
    <div class="flex min-w-0 items-center gap-3">
      <%= if avatar_url = profile_picture_url(@profile) do %>
        <img
          src={avatar_url}
          alt={@profile.username}
          class="size-11 shrink-0 rounded-full border border-base-300 object-cover shadow-sm"
        />
      <% else %>
        <div class="flex size-11 shrink-0 items-center justify-center rounded-full border border-base-300 bg-base-300 text-sm font-semibold uppercase text-base-content/75 shadow-sm">
          {profile_initials(@profile.username)}
        </div>
      <% end %>

      <div class="min-w-0">
        <div
          :if={@title}
          class="text-xs font-semibold uppercase tracking-[0.16em] text-base-content/45"
        >
          {@title}
        </div>

        <div class="truncate font-semibold text-base-content">{@profile.username}</div>

        <div :if={@subtitle} class="truncate text-xs text-base-content/60">{@subtitle}</div>
      </div>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :description_format_options, :list, required: true
  attr :sharing_options, :list, required: true

  def profile_form_fields(assigns) do
    ~H"""
    <.input field={@form[:username]} id={@form[:username].id} label={gettext("Username")} required />
    <.input
      field={@form[:profile_picture_url]}
      id={@form[:profile_picture_url].id}
      label={gettext("Profile picture URL")}
      type="url"
    />
    <.input
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

  def profile_picture_url(%{profile_picture_url: url}) when is_binary(url) do
    case String.trim(url) do
      "" -> nil
      trimmed_url -> trimmed_url
    end
  end

  def profile_picture_url(_), do: nil

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
end
