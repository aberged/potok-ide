defmodule PotokIdeWeb.Locale do
  @moduledoc "Locale resolution and LiveView locale mounting helpers."

  import Plug.Conn, except: [assign: 3]
  import Phoenix.Component, only: [assign: 3]

  @default_locale "en"
  @supported_locales ~w(en pl)
  @locale_names %{
    "en" => "English",
    "pl" => "Polski"
  }

  def default_locale, do: @default_locale

  def supported_locales, do: @supported_locales

  def locale_name(locale), do: Map.get(@locale_names, locale, locale)

  def init(opts), do: opts

  def call(conn, opts), do: put_locale(conn, opts)

  def put_locale(conn, _opts) do
    conn = fetch_query_params(conn)
    locale = resolve_locale(conn)

    Gettext.put_locale(PotokIdeWeb.Gettext, locale)

    conn
    |> put_session(:locale, locale)
    |> Plug.Conn.assign(:current_locale, locale)
    |> Plug.Conn.assign(:available_locales, @supported_locales)
  end

  def on_mount(:mount_locale, _params, session, socket) do
    locale = normalize_locale(session["locale"]) || @default_locale

    Gettext.put_locale(PotokIdeWeb.Gettext, locale)

    {:cont,
     socket
     |> assign(:current_locale, locale)
     |> assign(:available_locales, @supported_locales)}
  end

  def normalize_locale(locale) when is_binary(locale) do
    locale
    |> String.downcase()
    |> String.replace("_", "-")
    |> String.split("-", parts: 2)
    |> List.first()
    |> case do
      locale when locale in @supported_locales -> locale
      _ -> nil
    end
  end

  def normalize_locale(_), do: nil

  defp resolve_locale(conn) do
    normalize_locale(conn.params["locale"]) ||
      normalize_locale(get_session(conn, :locale)) ||
      locale_from_accept_language(get_req_header(conn, "accept-language")) ||
      @default_locale
  end

  defp locale_from_accept_language([header | _]) do
    header
    |> String.split(",")
    |> Enum.find_value(fn entry ->
      entry
      |> String.split(";", parts: 2)
      |> List.first()
      |> String.trim()
      |> normalize_locale()
    end)
  end

  defp locale_from_accept_language(_), do: nil
end
