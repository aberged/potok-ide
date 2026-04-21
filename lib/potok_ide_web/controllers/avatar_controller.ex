defmodule PotokIdeWeb.AvatarController do
  use PotokIdeWeb, :controller

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
            send_resp(conn, 404, "")
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
end
