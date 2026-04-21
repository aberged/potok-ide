defmodule PotokIdeWeb.AvatarController do
  use PotokIdeWeb, :controller

  require Logger

  alias PotokIde.Social
  alias PotokIde.Repo

  def profile(conn, %{"id" => id}) do
    case Repo.get(Social.Profile, id) do
      nil ->
        send_resp(conn, 404, "")

      profile ->
        case decode_base64_avatar(profile.profile_picture_url) do
          {:ok, image_data, mime_type} ->
            conn
            |> put_resp_header("content-type", mime_type)
            |> put_resp_header("cache-control", "public, max-age=86400")
            |> send_resp(200, image_data)

          :error ->
            {image_data, content_type} = generate_initials_avatar(profile.username)

            conn
            |> put_resp_header("content-type", content_type)
            |> put_resp_header("cache-control", "public, max-age=86400")
            |> send_resp(200, image_data)
        end
    end
  end

  defp decode_base64_avatar(nil), do: :error
  defp decode_base64_avatar(""), do: :error

  defp decode_base64_avatar(url) when is_binary(url) do
    trimmed = String.trim(url)

    if String.starts_with?(trimmed, "data:") do
      parse_data_url(trimmed)
    else
      :error
    end
  end

  defp decode_base64_avatar(_), do: :error

  defp parse_data_url(data_url) do
    case String.split(data_url, ",", parts: 2) do
      [_header, base64_part] ->
        mime_type = extract_mime_type(data_url)
        decode_base64_part(base64_part, mime_type)

      _ ->
        :error
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

  defp generate_initials_avatar(username) do
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

    color_index = :erlang.phash2(username, length(@avatar_colors))
    {bg_color, text_color} = Enum.at(@avatar_colors, color_index)

    svg = """
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 192 192" width="192" height="192">
      <rect width="192" height="192" rx="96" fill="#{bg_color}"/>
      <text x="96" y="96" dominant-baseline="central" text-anchor="middle"
            font-family="sans-serif" font-size="80" font-weight="600"
            fill="#{text_color}">#{initials}</text>
    </svg>
    """

    case svg_to_png(svg) do
      {:ok, png_data} ->
        {png_data, "image/png"}

      :error ->
        case default_avatar_png() do
          {:ok, png_data} -> {png_data, "image/png"}
          :error -> {svg, "image/svg+xml"}
        end
    end
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
           {:ok, _output} <- run_imagemagick_convert(svg_path, png_path),
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

  defp run_imagemagick_convert(svg_path, png_path) do
    case find_imagemagick() do
      {imagemagick, :magick} ->
        run_command(imagemagick, [
          "convert",
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
        ])

      {imagemagick, :convert} ->
        run_command(imagemagick, [
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
        ])

      nil ->
        {:error, :imagemagick_not_found}
    end
  end

  defp run_command(executable, args) do
    case System.cmd(executable, args, stderr_to_stdout: true) do
      {output, 0} -> {:ok, output}
      {output, status} -> {:error, {:command_failed, status, output}}
    end
  end

  defp find_imagemagick do
    # Prefer `magick` because Windows has a built-in `convert.exe` disk utility.
    case :os.type() do
      {:win32, _} ->
        case System.find_executable("magick") || System.find_executable("magick.exe") do
          nil -> nil
          path -> {path, :magick}
        end

      _ ->
        cond do
          magick = System.find_executable("magick") -> {magick, :magick}
          convert = System.find_executable("convert") -> {convert, :convert}
          true -> nil
        end
    end
  end
end
