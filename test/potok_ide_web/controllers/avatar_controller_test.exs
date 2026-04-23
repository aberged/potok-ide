defmodule PotokIdeWeb.AvatarControllerTest do
  use PotokIdeWeb.ConnCase, async: true

  alias PotokIde.Social
  alias PotokIde.Repo

  setup do
    {:ok, profile} =
      Repo.insert(%Social.Profile{
        username: "test_avatar_user",
        description: "Test profile for avatar",
        description_format: :markdown,
        sharing: :unique
      })

    %{profile: profile}
  end

  describe "GET /avatar/profile/:id" do
    test "returns 404 for non-existent profile", %{conn: conn} do
      conn = get(conn, ~p"/avatar/profile/99999")
      assert response(conn, 404)
    end

    test "returns initials avatar when profile has no avatar", %{conn: conn, profile: profile} do
      conn = get(conn, ~p"/avatar/profile/#{profile.id}")
      assert response(conn, 200)
      [content_type] = get_resp_header(conn, "content-type")
      assert content_type in ["image/png", "image/svg+xml"]
    end

    test "decodes base64 image data and returns it", %{conn: conn, profile: profile} do
      # Create a small test PNG (1x1 transparent pixel)
      png_bytes =
        <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8,
          6, 0, 0, 0, 31, 21, 196, 137, 0, 0, 0, 10, 73, 68, 65, 84, 8, 29, 1, 0, 0, 255, 255, 0,
          1, 0, 1, 16, 32, 148, 144, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130>>

      base64_data = Base.encode64(png_bytes)
      data_url = "data:image/png;base64," <> base64_data

      changeset = Social.Profile.changeset(profile, %{profile_picture_url: data_url})
      {:ok, updated_profile} = Repo.update(changeset)

      conn = get(conn, ~p"/avatar/profile/#{updated_profile.id}")

      assert response(conn, 200)
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert conn.resp_body == png_bytes
    end

    test "caches avatar for 24 hours", %{conn: conn, profile: profile} do
      # Create a small test JPEG (minimal valid JPEG)
      jpeg_bytes =
        <<255, 216, 255, 224, 0, 16, 74, 70, 73, 70, 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 255, 219, 0,
          67, 0, 8, 6, 6, 7, 6, 5, 8, 7, 7, 7, 9, 9, 8, 10, 12, 20, 13, 12, 11, 11, 12, 25, 18,
          19, 15, 20, 29, 26, 31, 30, 29, 26, 28, 28, 30, 31, 32, 32, 32, 32, 32, 32, 32, 32, 32,
          32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32, 32,
          255, 217>>

      base64_data = Base.encode64(jpeg_bytes)
      data_url = "data:image/jpeg;base64," <> base64_data

      changeset = Social.Profile.changeset(profile, %{profile_picture_url: data_url})
      {:ok, updated_profile} = Repo.update(changeset)

      conn = get(conn, ~p"/avatar/profile/#{updated_profile.id}")

      assert response(conn, 200)
      assert get_resp_header(conn, "cache-control") == ["public, max-age=86400"]
    end

    test "detects mime type from data URL", %{conn: conn, profile: profile} do
      # Small GIF (1x1 transparent pixel)
      gif_bytes =
        <<71, 73, 70, 56, 57, 97, 1, 0, 1, 0, 128, 0, 0, 255, 255, 255, 0, 0, 0, 33, 249, 4, 1, 0,
          0, 0, 0, 44, 0, 0, 0, 0, 1, 0, 1, 0, 0, 2, 1, 68, 0, 59>>

      base64_data = Base.encode64(gif_bytes)
      data_url = "data:image/gif;base64," <> base64_data

      changeset = Social.Profile.changeset(profile, %{profile_picture_url: data_url})
      {:ok, updated_profile} = Repo.update(changeset)

      conn = get(conn, ~p"/avatar/profile/#{updated_profile.id}")

      assert response(conn, 200)
      assert get_resp_header(conn, "content-type") == ["image/gif"]
    end

    test "returns initials avatar for invalid base64 data", %{conn: conn, profile: profile} do
      invalid_data_url = "data:image/jpeg;base64,invalid!!!base64data"

      changeset = Social.Profile.changeset(profile, %{profile_picture_url: invalid_data_url})
      {:ok, updated_profile} = Repo.update(changeset)

      conn = get(conn, ~p"/avatar/profile/#{updated_profile.id}")

      assert response(conn, 200)
      [content_type] = get_resp_header(conn, "content-type")
      assert content_type in ["image/png", "image/svg+xml"]
    end
  end
end
