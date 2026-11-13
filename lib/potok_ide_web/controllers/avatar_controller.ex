defmodule PotokIdeWeb.AvatarController do
  use PotokIdeWeb, :controller

  require Logger

  alias PotokIde.ImageMagick
  alias PotokIde.{RenderCache, Renderers}
  alias PotokIde.Social
  alias PotokIdeWeb.Avatars

  @cache_control "public, max-age=86400"
  # Initials PNGs are drawn once per name and kept on disk (PotokIde.RenderCache).
  @initials_max_age :timer.hours(24 * 7)
  # A small drawing: ImageMagick stops it rather than let it grow.
  @png_limits ~w(-limit memory 32MiB -limit map 64MiB -limit disk 64MiB -limit time 10)
  # A picture is only ever shown as an image: opened on its own, on Potok's
  # address, nothing in it may run or load. SVG is the one that could.
  @image_csp "default-src 'none'; style-src 'unsafe-inline'; sandbox"
  @image_type ~r/\Aimage\/[a-z0-9.+-]+\z/

  def profile(conn, %{"id" => id}) do
    id
    |> parse_id()
    |> case do
      {:ok, id} -> Social.get_profile_avatar_source(id)
      :error -> nil
    end
    |> serve_avatar(conn)
  end

  # A group guests cannot see is answered as one that does not exist, unless
  # the address is one Potok signed for someone who sees it (`Avatars`).
  def group(conn, %{"id" => id} = params) do
    id
    |> parse_id()
    |> case do
      {:ok, id} -> Social.get_group_avatar_source(id)
      :error -> nil
    end
    |> case do
      %{guest_preview?: true} = source -> source
      %{id: id} = source -> if Avatars.group_signature?(id, params["s"]), do: source
      nil -> nil
    end
    |> serve_avatar(conn)
  end

  defp serve_avatar(nil, conn), do: send_resp(conn, 404, "")

  defp serve_avatar(%{name: name, picture_url: picture_url}, conn) do
    trimmed = picture_url && String.trim(picture_url)

    cond do
      is_binary(trimmed) and String.starts_with?(trimmed, "data:") ->
        case parse_data_url(trimmed) do
          {:ok, image_data, mime_type} -> send_image(conn, image_data, mime_type)
          :error -> send_initials(conn, name)
        end

      is_binary(trimmed) and String.starts_with?(trimmed, ["http://", "https://"]) ->
        conn
        |> put_resp_header("cache-control", @cache_control)
        |> redirect(external: trimmed)

      true ->
        send_initials(conn, name)
    end
  end

  # Initials are drawn as an SVG, which costs nothing to make. Push
  # notifications cannot show SVG, so their URLs ask for `?format=png`, which
  # ImageMagick renders (60–125 ms of CPU) once per name, one drawing at a
  # time with the link cards (PotokIde.Renderers): the address is public, and
  # a page of new names must not start an ImageMagick process for each.
  defp send_initials(%{params: %{"format" => "png"}} = conn, name) do
    {image_data, content_type} =
      case RenderCache.fetch({:initials_avatar, name}, @initials_max_age, fn ->
             svg = initials_svg(name)
             Renderers.run(fn -> svg_to_png(svg) end)
           end) do
        {:ok, png_data} -> {png_data, "image/png"}
        _error -> fallback_png(name)
      end

    send_image(conn, image_data, content_type)
  end

  defp send_initials(conn, name), do: send_image(conn, initials_svg(name), "image/svg+xml")

  defp send_image(conn, image_data, mime_type) do
    conn
    |> put_resp_header("content-type", mime_type)
    |> put_resp_header("content-security-policy", @image_csp)
    |> put_resp_header("cache-control", @cache_control)
    |> send_resp(200, image_data)
  end

  defp parse_id(id) when is_integer(id), do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, ""} -> {:ok, int}
      _ -> :error
    end
  end

  defp parse_id(_), do: :error

  # The address is whatever someone typed into the picture field, so it says
  # what the response will be sent as: only images are let through.
  defp parse_data_url(data_url) do
    with [_header, base64_part] <- String.split(data_url, ",", parts: 2),
         mime_type = data_url |> extract_mime_type() |> String.downcase(),
         true <- Regex.match?(@image_type, mime_type) do
      decode_base64_part(base64_part, mime_type)
    else
      _ -> :error
    end
  end

  defp extract_mime_type(data_url) do
    case Regex.run(~r/data:([^;]+)/, data_url) do
      [_full, mime] -> mime
      _ -> "image/jpeg"
    end
  end

  defp decode_base64_part(base64_string, mime_type) do
    trimmed = String.trim(base64_string)

    case Base.decode64(trimmed) do
      {:ok, decoded} -> {:ok, decoded, mime_type}
      :error -> :error
    end
  rescue
    _ -> :error
  end

  @avatar_colors [
    {"#4f46e5", "#e0e7ff"},
    {"#0891b2", "#cffafe"},
    {"#059669", "#d1fae5"},
    {"#d97706", "#fef3c7"},
    {"#dc2626", "#fee2e2"},
    {"#7c3aed", "#ede9fe"},
    {"#db2777", "#fce7f3"},
    {"#ea580c", "#ffedd5"}
  ]

  # When no PNG could be drawn: Potok's icon, which every push service shows.
  defp fallback_png(username) do
    case default_avatar_png() do
      {:ok, png_data} -> {png_data, "image/png"}
      :error -> {initials_svg(username), "image/svg+xml"}
    end
  end

  defp initials_svg(username) do
    initials =
      username
      |> to_string()
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
      # Group names may hold any character.
      |> Phoenix.HTML.html_escape()
      |> Phoenix.HTML.safe_to_string()

    color_index = :erlang.phash2(username, length(@avatar_colors))
    {bg_color, text_color} = Enum.at(@avatar_colors, color_index)

    """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 192 192" width="192" height="192">
      <rect width="192" height="192" rx="96" fill="#{bg_color}"/>
      <text x="96" y="96" dominant-baseline="central" text-anchor="middle"
            font-family="sans-serif" font-size="80" font-weight="600"
            fill="#{text_color}">#{initials}</text>
    </svg>
    """
  end

  defp default_avatar_png do
    path = Application.app_dir(:potok_ide, "priv/static/images/pwa/icon-192.png")

    case File.read(path) do
      {:ok, binary} -> {:ok, binary}
      _ -> :error
    end
  end

  defp svg_to_png(svg) do
    unique = :erlang.unique_integer([:positive])
    svg_path = Path.join(System.tmp_dir!(), "avatar_#{unique}.svg")
    png_path = Path.join(System.tmp_dir!(), "avatar_#{unique}.png")

    try do
      with :ok <- File.write(svg_path, svg),
           {:ok, _output} <- convert_svg(svg_path, png_path),
           {:ok, png_binary} <- File.read(png_path) do
        {:ok, png_binary}
      else
        {:error, reason} ->
          Logger.warning("avatar png conversion failed: #{inspect(reason)}")
          :error

        _ ->
          :error
      end
    after
      File.rm(svg_path)
      File.rm(png_path)
    end
  end

  defp convert_svg(svg_path, png_path) do
    ImageMagick.convert(
      @png_limits ++
        [
          "-background",
          "none",
          "-gravity",
          "center",
          "-extent",
          "192x192",
          "-resize",
          "192x192",
          svg_path,
          png_path
        ]
    )
  end
end
