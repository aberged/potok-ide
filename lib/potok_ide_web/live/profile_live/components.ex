defmodule PotokIdeWeb.ProfileLive.Components do
  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.Components, as: GroupComponents

  attr :profile, :map, required: true
  attr :title, :string, default: nil
  attr :subtitle, :string, default: nil

  def profile_identity(assigns) do
    ~H"""
    <GroupComponents.profile_identity
      profile={@profile}
      title={@title}
      subtitle={@subtitle}
    />
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
end
