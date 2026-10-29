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

    {:ok, %Value{attachments: [document, image]}} =
      Social.create_value(owner, group, %{"content" => "files"}, [
        stored_file!(group, "Plan <b>.html", "text/html", "<script>alert(1)</script>"),
        stored_file!(group, "photo.png", "image/png", "png-bytes")
      ])

    %{
      owner_account: owner_account,
      outsider_account: outsider_account,
      document: document,
      image: image
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
