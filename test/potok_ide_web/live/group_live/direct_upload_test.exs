defmodule PotokIdeWeb.GroupLive.DirectUploadTest do
  # Swaps the storage config to the S3 adapter, so it cannot run next to
  # other tests. Direct uploads never open an upload channel, which also
  # lets one test send several files (LiveViewTest's channel uploads stop
  # once the first file is consumed).
  use PotokIdeWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social
  alias PotokIde.Storage
  alias PotokIde.Storage.S3

  setup %{conn: conn} do
    previous = Application.get_env(:potok_ide, Storage)

    Application.put_env(:potok_ide, Storage,
      adapter: S3,
      bucket: "potok-test",
      endpoint: "https://storage.example.com",
      access_key_id: "test-key",
      secret_access_key: "test-secret",
      req_options: [plug: {Req.Test, S3}, retry: false]
    )

    on_exit(fn -> Application.put_env(:potok_ide, Storage, previous) end)

    # Every uploaded object is reported as the 5 bytes of "hello".
    Req.Test.stub(S3, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-length", "5")
      |> Plug.Conn.send_resp(200, "")
    end)

    account = account_fixture()

    {:ok, profile} =
      Social.create_profile_for_account(account, %{
        username: "direct-owner",
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    {:ok, group} =
      Social.create_group(profile, Social.get_root_group!(), %{
        "name" => "direct-group",
        "description" => "",
        "description_format" => :markdown,
        "is_public" => false
      })

    %{conn: log_in_account(conn, Accounts.get_account!(account.id)), group: group}
  end

  test "a value keeps its files in the order they were picked", %{conn: conn, group: group} do
    {:ok, lv, _html} = live(conn, ~p"/groups/#{group.id}/values")
    Req.Test.allow(S3, self(), lv.pid)

    names = ["first.txt", "second.png", "third.mp3"]
    types = ["text/plain", "image/png", "audio/mpeg"]

    upload =
      file_input(
        lv,
        "#group-value-form",
        :attachments,
        Enum.zip_with(names, types, &%{name: &1, content: "hello", type: &2})
      )

    for name <- names, do: render_upload(upload, name)

    lv |> form("#group-value-form", value: %{content: ""}) |> render_submit()

    # A value shows its files by id, so ids must follow the picked order.
    assert {[_, _, _] = attachments, false} = Social.list_group_attachments(group)
    assert attachments |> Enum.sort_by(& &1.id) |> Enum.map(& &1.filename) == names
  end

  test "a template's picture goes straight to the bucket and to the chat", %{
    conn: conn,
    group: group
  } do
    {:ok, lv, _html} = live(conn, ~p"/groups/#{group.id}/edit_group")
    Req.Test.allow(S3, self(), lv.pid)

    lv
    |> form("#group-edit-form")
    |> render_change(%{"description_template" => %{"pick" => "article"}})

    assert has_element?(lv, "#group-description-template-field-image-device")

    upload =
      file_input(lv, "#description-picture-form", :description_picture, [
        %{name: "most.jpg", content: "hello", type: "image/jpeg"}
      ])

    render_upload(upload, "most.jpg")

    assert_push_event(lv, "description_picture_ready", %{url: _url})

    assert {[attachment], false} = Social.list_group_attachments(group)
    assert attachment.filename == "most.jpg"
    assert attachment.content_type == "image/jpeg"
  end
end
