defmodule PotokIdeWeb.AvatarControllerTest do
  use PotokIdeWeb.ConnCase, async: true

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIdeWeb.Avatars

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

    test "draws initials as SVG unless PNG is asked for", %{conn: conn, profile: profile} do
      conn = get(conn, ~p"/avatar/profile/#{profile.id}")

      assert response(conn, 200) =~ "<svg"
      assert get_resp_header(conn, "content-type") == ["image/svg+xml"]
      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src 'none'"

      # Push notifications ask for PNG; without ImageMagick it falls back to SVG.
      png_conn = get(build_conn(), ~p"/avatar/profile/#{profile.id}?format=png")
      assert response(png_conn, 200)
      [content_type] = get_resp_header(png_conn, "content-type")
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

    test "never sends a picture that is not an image", %{conn: conn, profile: profile} do
      script = Base.encode64("<script>alert(1)</script>")

      for data_url <- [
            "data:text/html;base64,#{script}",
            "data:TEXT/HTML;base64,#{script}",
            "data:text/html;charset=utf-8;base64,#{script}",
            "data:application/xhtml+xml;base64,#{script}",
            "data:text/html,<script>alert(1)</script>",
            "data:image/png/../html;base64,#{script}"
          ] do
        {:ok, profile} =
          profile
          |> Social.Profile.changeset(%{profile_picture_url: data_url})
          |> Repo.update()

        conn = get(conn, ~p"/avatar/profile/#{profile.id}")

        assert response(conn, 200) =~ "<svg"
        refute conn.resp_body =~ "alert"
        assert get_resp_header(conn, "content-type") == ["image/svg+xml"]
      end
    end

    test "an image's type may be written in any case", %{conn: conn, profile: profile} do
      for {written, sent} <- [{"IMAGE/PNG", "image/png"}, {"image/jpg", "image/jpg"}] do
        data_url = "data:#{written};base64," <> Base.encode64("picture")

        {:ok, profile} =
          profile
          |> Social.Profile.changeset(%{profile_picture_url: data_url})
          |> Repo.update()

        conn = get(conn, ~p"/avatar/profile/#{profile.id}")

        assert response(conn, 200) == "picture"
        assert get_resp_header(conn, "content-type") == [sent]
      end
    end

    test "nothing in a stored SVG runs when it is opened", %{conn: conn, profile: profile} do
      svg = ~s|<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>|

      {:ok, profile} =
        profile
        |> Social.Profile.changeset(%{
          profile_picture_url: "data:image/svg+xml;base64," <> Base.encode64(svg)
        })
        |> Repo.update()

      conn = get(conn, ~p"/avatar/profile/#{profile.id}")

      assert response(conn, 200) == svg
      assert get_resp_header(conn, "content-type") == ["image/svg+xml"]
      assert [csp] = get_resp_header(conn, "content-security-policy")
      assert csp =~ "default-src 'none'"
      assert csp =~ "sandbox"
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

    test "redirects to external picture urls", %{conn: conn, profile: profile} do
      changeset =
        Social.Profile.changeset(profile, %{profile_picture_url: "https://example.com/a.png"})

      {:ok, updated_profile} = Repo.update(changeset)

      conn = get(conn, ~p"/avatar/profile/#{updated_profile.id}")
      assert redirected_to(conn) == "https://example.com/a.png"
      assert get_resp_header(conn, "cache-control") == ["public, max-age=86400"]
    end

    test "returns 404 for a malformed id", %{conn: conn} do
      conn = get(conn, ~p"/avatar/profile/not-a-number")
      assert response(conn, 404)
    end
  end

  describe "GET /avatar/group/:id" do
    setup do
      account = PotokIde.AccountsFixtures.account_fixture()

      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: "avatar-grp-own",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, group} =
        Social.create_group(profile, Social.get_root_group!(), %{
          "name" => "avatar-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      %{group: group}
    end

    test "returns 404 for non-existent group", %{conn: conn} do
      conn = get(conn, ~p"/avatar/group/99999")
      assert response(conn, 404)
    end

    test "a group guests cannot see answers as one that does not exist", %{
      conn: conn,
      group: group
    } do
      missing = conn |> get(~p"/avatar/group/99999") |> response(404)

      assert conn |> get(~p"/avatar/group/#{group.id}") |> response(404) == missing
      assert conn |> get(~p"/avatar/group/#{group.id}?format=png") |> response(404) == missing

      other = Avatars.group_avatar_url(%{id: group.id + 1})
      [_, signature] = Regex.run(~r/[?&]s=([^&]+)/, other)
      assert conn |> get(~p"/avatar/group/#{group.id}?s=#{signature}") |> response(404) == missing
    end

    test "sends it by the address Potok signed, a push notification's too", %{
      conn: conn,
      group: group
    } do
      assert conn |> get(Avatars.group_avatar_url(group)) |> response(200) =~ "<svg"

      badge = get(conn, Avatars.group_badge_url(group))
      assert response(badge, 200)
      assert get_resp_header(badge, "content-type") in [["image/png"], ["image/svg+xml"]]
    end

    test "a group guests see needs no signature", %{conn: conn, group: group} do
      {:ok, group} = group |> Ecto.Changeset.change(is_public: true) |> Repo.update()

      assert conn |> get(~p"/avatar/group/#{group.id}") |> response(200) =~ "<svg"
    end

    test "returns initials avatar when the group has no picture", %{conn: conn, group: group} do
      conn = get(conn, Avatars.group_avatar_url(group))
      assert response(conn, 200)
      [content_type] = get_resp_header(conn, "content-type")
      assert content_type in ["image/png", "image/svg+xml"]
    end

    test "escapes the initials of the group name", %{conn: conn, group: group} do
      {:ok, group} = group |> Ecto.Changeset.change(name: "&co <b>") |> Repo.update()

      body = conn |> get(Avatars.group_avatar_url(group)) |> response(200)

      assert body =~ ">&amp;&lt;</text>"
    end

    test "decodes base64 picture data", %{conn: conn, group: group} do
      data_url = "data:image/png;base64," <> Base.encode64("fake-png")

      {:ok, updated_group} =
        group |> Ecto.Changeset.change(group_picture_url: data_url) |> Repo.update()

      conn = get(conn, Avatars.group_avatar_url(updated_group))
      assert response(conn, 200)
      assert get_resp_header(conn, "content-type") == ["image/png"]
      assert conn.resp_body == "fake-png"
    end

    test "never sends a picture that is not an image", %{conn: conn, group: group} do
      data_url = "data:text/html;base64," <> Base.encode64("<script>alert(1)</script>")

      {:ok, group} =
        group |> Ecto.Changeset.change(group_picture_url: data_url) |> Repo.update()

      conn = get(conn, Avatars.group_avatar_url(group))

      assert response(conn, 200) =~ "<svg"
      refute conn.resp_body =~ "alert"
      assert get_resp_header(conn, "content-type") == ["image/svg+xml"]
    end
  end
end
