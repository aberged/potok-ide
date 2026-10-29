defmodule PotokIdeWeb.GroupLive.FilesTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social
  alias PotokIde.Storage

  setup %{conn: conn} do
    {account, profile} = account_with_profile!("files-owner")

    {:ok, group} =
      Social.create_group(profile, Social.get_root_group!(), %{
        "name" => "files-group",
        "description" => "",
        "description_format" => :markdown,
        "is_public" => false
      })

    %{conn: log_in_account(conn, account), profile: profile, group: group}
  end

  describe "composer" do
    test "posts a value that is only a file", %{conn: conn, group: group} do
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group.id}/values")

      assert has_element?(lv, "#group-value-attach")

      upload =
        file_input(lv, "#group-value-form", :attachments, [
          %{name: "notes.txt", content: "hello", type: "text/plain"}
        ])

      assert render_upload(upload, "notes.txt") =~ "notes.txt"
      assert has_element?(lv, "#group-value-attachments", "notes.txt")
      assert has_element?(lv, "#group-value-submit[data-has-attachments=true]")

      lv |> form("#group-value-form", value: %{content: ""}) |> render_submit()

      assert {[attachment], false} = Social.list_group_attachments(group)
      assert attachment.filename == "notes.txt"
      assert attachment.byte_size == 5
      assert {:ok, 5} = Storage.stat(attachment.storage_key)

      assert has_element?(
               lv,
               "a#value-attachment-#{attachment.id}[href='/files/#{attachment.id}']"
             )

      refute has_element?(lv, "#group-value-attachments")
    end

    test "a picked file can be removed before sending", %{conn: conn, group: group} do
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group.id}/values")

      upload =
        file_input(lv, "#group-value-form", :attachments, [
          %{name: "draft.txt", content: "draft", type: "text/plain"}
        ])

      render_upload(upload, "draft.txt")
      [%{"ref" => ref}] = upload.entries

      lv |> element("#group-value-attachment-cancel-#{ref}") |> render_click()

      refute has_element?(lv, "#group-value-attachments")
    end

    test "has no file button without the attach_files permission", %{conn: conn} do
      {owner_account, owner} = account_with_profile!("fperm-owner")
      {member_account, member} = account_with_profile!("fperm-member")

      {:ok, group} =
        Social.create_group(owner, Social.get_root_group!(), %{
          "name" => "files-perm-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, invitation} = Social.invite_profile_to_group(owner, group, member)
      {:ok, _accepted} = Social.accept_group_invitation(invitation, member)
      {:ok, _manifest} = Social.create_own_group_manifest(owner, group)

      {:ok, _role} =
        Social.set_group_role_permission(owner, group, "everyone", :attach_files, :neutral)

      {:ok, member_lv, _html} =
        conn |> log_in_account(member_account) |> live(~p"/groups/#{group.id}/values")

      assert has_element?(member_lv, "#group-value-form")
      refute has_element?(member_lv, "#group-value-attach")

      {:ok, owner_lv, _html} =
        conn |> log_in_account(owner_account) |> live(~p"/groups/#{group.id}/values")

      assert has_element?(owner_lv, "#group-value-attach")
    end
  end

  describe "files tab" do
    test "lists the group's files and switches to the folder tree", %{
      conn: conn,
      profile: profile,
      group: group
    } do
      {:ok, child} =
        Social.create_group(profile, group, %{
          "name" => "files-child",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => false
        })

      {:ok, %{attachments: [own]}} =
        Social.create_value(profile, group, %{"content" => "here"}, [
          stored_file!(group, "own.pdf")
        ])

      {:ok, %{attachments: [nested]}} =
        Social.create_value(profile, child, %{}, [stored_file!(child, "nested.txt")])

      {:ok, lv, _html} = live(conn, ~p"/groups/#{group.id}")

      lv |> element("#group-tab-files") |> render_click()
      assert_patch(lv, ~p"/groups/#{group.id}/files")

      assert has_element?(lv, "#group-files-list #file-#{own.id}", "own.pdf")
      refute has_element?(lv, "#file-#{nested.id}")

      lv |> element("#group-files-view-tree") |> render_click()

      assert has_element?(lv, "#group-files-tree #files-folder-#{group.id}")
      assert has_element?(lv, "#files-folder-#{child.id} #files-tree-file-#{nested.id}")
      assert has_element?(lv, "#files-tree-file-#{own.id}")
    end

    test "the header button opens the files tab", %{conn: conn, group: group} do
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group.id}/values")

      assert has_element?(lv, ~s(#group-values-summary[aria-current="true"]))
      refute has_element?(lv, ~s(#group-files-summary[aria-current="true"]))

      lv |> element("#group-files-summary") |> render_click()
      assert_patch(lv, ~p"/groups/#{group.id}/files")

      assert has_element?(lv, "#group-files-empty")
      assert has_element?(lv, ~s(#group-files-summary[aria-current="true"]))
      refute has_element?(lv, ~s(#group-values-summary[aria-current="true"]))
    end

    test "has no header button for visitors who are not members", %{conn: conn} do
      {_owner_account, owner} = account_with_profile!("fhead-owner")
      {visitor_account, _visitor} = account_with_profile!("fhead-visitor")

      {:ok, public_group} =
        Social.create_group(owner, Social.get_root_group!(), %{
          "name" => "files-public-group",
          "description" => "",
          "description_format" => :markdown,
          "is_public" => true
        })

      {:ok, lv, _html} =
        conn |> log_in_account(visitor_account) |> live(~p"/groups/#{public_group.id}")

      assert has_element?(lv, "#group-subgroups-summary")
      refute has_element?(lv, "#group-files-summary")
    end

    test "shows a new file while the list is open", %{conn: conn, profile: profile, group: group} do
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group.id}/files")

      assert has_element?(lv, "#group-files-empty")

      {:ok, %{attachments: [attachment]}} =
        Social.create_value(profile, group, %{}, [stored_file!(group, "live.txt")])

      assert has_element?(lv, "#file-#{attachment.id}", "live.txt")
    end
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

  defp stored_file!(group, name) do
    key = Storage.new_key(group.id)
    path = Path.join(System.tmp_dir!(), "potok-upload-#{System.unique_integer([:positive])}")
    File.write!(path, "hello")
    :ok = Storage.put_file(key, path)
    File.rm!(path)

    %{storage_key: key, filename: name, content_type: "text/plain", byte_size: 5}
  end
end
