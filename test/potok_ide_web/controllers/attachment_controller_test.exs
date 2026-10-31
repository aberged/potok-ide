defmodule PotokIdeWeb.AttachmentControllerTest do
  use PotokIdeWeb.ConnCase, async: true

  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social
  alias PotokIde.Social.Value
  alias PotokIde.Storage

  setup do
    {owner_account, owner} = account_with_profile!("dl-owner")
    {outsider_account, _outsider} = account_with_profile!("dl-outsider")

    {:ok, group} =
      Social.create_group(owner, Social.get_root_group!(), %{
        "name" => "dl-group",
        "description" => "",
        "description_format" => :markdown,
        "is_public" => true
      })

    {:ok, %Value{attachments: [document, image, video, audio]}} =
      Social.create_value(owner, group, %{"content" => "files"}, [
        stored_file!(group, "Plan <b>.html", "text/html", "<script>alert(1)</script>"),
        stored_file!(group, "photo.png", "image/png", "png-bytes"),
        stored_file!(group, "clip.mp4", "video/mp4", "0123456789"),
        stored_file!(group, "song.mp3", "audio/mpeg", "mp3-bytes")
      ])

    %{
      owner_account: owner_account,
      outsider_account: outsider_account,
      document: document,
      image: image,
      video: video,
      audio: audio
    }
  end

  test "a member downloads a file as an attachment that cannot run", %{
    conn: conn,
    owner_account: account,
    document: document
  } do
    conn = conn |> log_in_account(account) |> get(~p"/files/#{document.id}")

    assert response(conn, 200) == "<script>alert(1)</script>"
    assert [disposition] = get_resp_header(conn, "content-disposition")
    assert disposition =~ ~s(attachment; filename="Plan <b>.html")
    assert get_resp_header(conn, "content-security-policy") == ["default-src 'none'; sandbox"]
    assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    assert get_resp_header(conn, "cache-control") == ["private, max-age=3600"]
  end

  test "images are shown in place", %{conn: conn, owner_account: account, image: image} do
    conn = conn |> log_in_account(account) |> get(~p"/files/#{image.id}")

    assert response(conn, 200) == "png-bytes"
    assert response_content_type(conn, :png)
    assert [~s(inline; filename="photo.png") <> _] = get_resp_header(conn, "content-disposition")
  end

  test "audio and video play in place", %{
    conn: conn,
    owner_account: account,
    video: video,
    audio: audio
  } do
    for {file, name} <- [{video, "clip.mp4"}, {audio, "song.mp3"}] do
      conn = conn |> log_in_account(account) |> get(~p"/files/#{file.id}")

      assert response(conn, 200)
      assert [disposition] = get_resp_header(conn, "content-disposition")
      assert String.starts_with?(disposition, ~s(inline; filename="#{name}"))
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
    end
  end

  test "?download=1 downloads a file that is otherwise shown in place", %{
    conn: conn,
    owner_account: account,
    image: image
  } do
    conn = conn |> log_in_account(account) |> get(~p"/files/#{image.id}?download=1")

    assert response(conn, 200) == "png-bytes"

    assert [~s(attachment; filename="photo.png") <> _] =
             get_resp_header(conn, "content-disposition")
  end

  describe "byte ranges" do
    setup %{conn: conn, owner_account: account} do
      %{conn: log_in_account(conn, account)}
    end

    test "a range is sent as partial content", %{conn: conn, video: video} do
      conn = conn |> put_req_header("range", "bytes=2-5") |> get(~p"/files/#{video.id}")

      assert response(conn, 206) == "2345"
      assert get_resp_header(conn, "content-range") == ["bytes 2-5/10"]
      assert get_resp_header(conn, "content-type") == ["video/mp4"]
    end

    test "open and suffix ranges stop at the end of the file", %{conn: conn, video: video} do
      for {range, body, content_range} <- [
            {"bytes=7-", "789", "bytes 7-9/10"},
            {"bytes=8-100", "89", "bytes 8-9/10"},
            {"bytes=-4", "6789", "bytes 6-9/10"},
            {"bytes=-50", "0123456789", "bytes 0-9/10"}
          ] do
        conn = conn |> put_req_header("range", range) |> get(~p"/files/#{video.id}")

        assert response(conn, 206) == body
        assert get_resp_header(conn, "content-range") == [content_range]
      end
    end

    test "a range past the end is refused", %{conn: conn, video: video} do
      conn = conn |> put_req_header("range", "bytes=10-") |> get(~p"/files/#{video.id}")

      assert response(conn, 416) == ""
      assert get_resp_header(conn, "content-range") == ["bytes */10"]
    end

    test "other range headers get the whole file", %{conn: conn, video: video} do
      for range <- ["bytes=0-1,4-5", "bytes=5-2", "items=0-1", "bytes=x-"] do
        conn = conn |> put_req_header("range", range) |> get(~p"/files/#{video.id}")

        assert response(conn, 200) == "0123456789"
      end
    end
  end

  test "someone outside the group gets a 404, even for a public group", %{
    conn: conn,
    outsider_account: account,
    document: document
  } do
    conn = conn |> log_in_account(account) |> get(~p"/files/#{document.id}")

    assert response(conn, 404)
  end

  test "unknown ids are a 404", %{conn: conn, owner_account: account} do
    assert conn |> log_in_account(account) |> get(~p"/files/0") |> response(404)
    assert build_conn() |> log_in_account(account) |> get("/files/abc") |> response(404)
  end

  test "logged-out visitors are sent to the login page", %{conn: conn, document: document} do
    conn = get(conn, ~p"/files/#{document.id}")

    assert redirected_to(conn) == ~p"/accounts/log-in"
  end

  defp account_with_profile!(username) do
    account = account_fixture()

    {:ok, profile} =
      Social.create_profile_for_account(account, %{
        username: username,
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    {Accounts.get_account!(account.id), profile}
  end

  defp stored_file!(group, name, content_type, content) do
    key = Storage.new_key(group.id)
    path = Path.join(System.tmp_dir!(), "potok-upload-#{System.unique_integer([:positive])}")
    File.write!(path, content)
    :ok = Storage.put_file(key, path)
    File.rm!(path)

    %{storage_key: key, filename: name, content_type: content_type, byte_size: byte_size(content)}
  end
end
