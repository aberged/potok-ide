defmodule PotokIdeWeb.GroupLive.KeyboardMediaTest do
  @moduledoc """
  GIFs and stickers from the keyboard in the Android app: `assets/js/keyboard_media.js`
  puts them into this upload, and each goes out at once as a message of its own.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures, only: [account_with_profile!: 1]

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.Value
  alias PotokIde.Storage

  @gif %{name: "keyboard-1.gif", content: "GIF89a", type: "image/gif"}

  setup %{conn: conn} do
    {account, profile} = account_with_profile!("keyboard-owner")
    group = group!(profile, "keyboard-group")

    %{conn: log_in_account(conn, account), profile: profile, group: group}
  end

  defp group!(profile, name, attrs \\ %{}) do
    {:ok, group} =
      Social.create_group(
        profile,
        Social.get_root_group!(),
        Map.merge(
          %{
            "name" => name,
            "description" => "",
            "description_format" => :markdown,
            "is_public" => false
          },
          attrs
        )
      )

    group
  end

  defp send_from_keyboard(lv, file \\ @gif) do
    lv
    |> file_input("#group-value-keyboard-media-form", :keyboard_media, [file])
    |> render_upload(file.name)
  end

  defp posted_value(group) do
    assert {[attachment], false} = Social.list_group_attachments(group)
    {attachment, Repo.get!(Value, attachment.value_id)}
  end

  describe "a profile that may send files" do
    test "sends a GIF at once, as a message with only the file", %{conn: conn, group: group} do
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group.id}/values")

      assert has_element?(lv, "#group-value-keyboard-media[data-can-send=true]")

      send_from_keyboard(lv)

      {attachment, value} = posted_value(group)

      assert attachment.filename == @gif.name
      assert attachment.content_type == "image/gif"
      assert {:ok, 6} = Storage.stat(attachment.storage_key)
      assert value.content in [nil, ""]

      assert has_element?(lv, "#value-#{value.id} img[src='/files/#{attachment.id}']")
      refute has_element?(lv, "#group-value-keyboard-media-progress")
    end

    test "leaves what is typed in the composer", %{conn: conn, group: group} do
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group.id}/values")

      lv |> form("#group-value-form", value: %{content: "half a sentence"}) |> render_change()

      send_from_keyboard(lv)

      {_attachment, value} = posted_value(group)

      assert value.content in [nil, ""]
      assert has_element?(lv, "#group-value-content", "half a sentence")
    end

    test "leaves files waiting in the composer", %{conn: conn, group: group} do
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group.id}/values")

      lv
      |> file_input("#group-value-form", :attachments, [
        %{name: "notes.txt", content: "hello", type: "text/plain"}
      ])
      |> render_upload("notes.txt")

      send_from_keyboard(lv)

      {attachment, _value} = posted_value(group)

      assert attachment.filename == @gif.name
      assert has_element?(lv, "#group-value-attachments", "notes.txt")
    end

    test "goes out as the reply being written", %{conn: conn, group: group, profile: profile} do
      {:ok, question} = Social.create_value(profile, group, %{"content" => "the question"})
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group.id}/values")

      render_hook(lv, "start_reply_value", %{"id" => question.id})
      assert has_element?(lv, "#group-value-reply-preview")

      send_from_keyboard(lv)

      {_attachment, value} = posted_value(group)

      assert value.parent_id == question.id
      refute has_element?(lv, "#group-value-reply-preview")
    end

    test "sends stickers too", %{conn: conn, group: group} do
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group.id}/values")

      send_from_keyboard(lv, %{name: "keyboard-2.webp", content: "RIFF", type: "image/webp"})

      {attachment, _value} = posted_value(group)

      assert attachment.content_type == "image/webp"
    end

    test "says so when something else comes from the keyboard", %{conn: conn, group: group} do
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group.id}/values")

      file = %{name: "keyboard-3.txt", content: "text", type: "text/plain"}

      assert {:error, _reason} =
               lv
               |> file_input("#group-value-keyboard-media-form", :keyboard_media, [file])
               |> render_upload(file.name)

      lv |> form("#group-value-keyboard-media-form") |> render_change()

      assert has_element?(lv, "#flash-error")
      refute has_element?(lv, "#group-value-keyboard-media-progress")
      assert {[], false} = Social.list_group_attachments(group)
    end

    test "says so when the content came to another field", %{conn: conn, group: group} do
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group.id}/values")

      render_hook(lv, "keyboard_media_refused", %{})

      assert has_element?(lv, "#flash-error", "message field")
      assert {[], false} = Social.list_group_attachments(group)
    end

    test "says so when the device could not read the content", %{conn: conn, group: group} do
      {:ok, lv, _html} = live(conn, ~p"/groups/#{group.id}/values")

      render_hook(lv, "keyboard_media_failed", %{})

      assert has_element?(lv, "#flash-error")
    end
  end

  describe "a profile that may not send files" do
    test "a member without attach_files gets no upload", %{conn: conn, profile: owner} do
      {member_account, member} = account_with_profile!("keyboard-member")
      group = group!(owner, "keyboard-perm-group")

      {:ok, invitation} = Social.invite_profile_to_group(owner, group, member)
      {:ok, _accepted} = Social.accept_group_invitation(invitation, member)
      {:ok, _manifest} = Social.create_own_group_manifest(owner, group)

      {:ok, _role} =
        Social.set_group_role_permission(owner, group, "everyone", :attach_files, :neutral)

      {:ok, lv, _html} =
        conn |> log_in_account(member_account) |> live(~p"/groups/#{group.id}/values")

      assert has_element?(lv, "#group-value-form")
      assert has_element?(lv, "#group-value-keyboard-media[data-can-send=false]")
      refute has_element?(lv, "#group-value-keyboard-media-form")

      render_hook(lv, "keyboard_media_refused", %{})

      assert has_element?(lv, "#flash-error", "cannot send pictures")
    end

    test "a visitor of an open chat gets no upload", %{conn: conn, profile: owner} do
      {visitor_account, _visitor} = account_with_profile!("keyboard-visitor")

      group =
        group!(owner, "keyboard-open-group", %{"is_public" => true, "has_public_chat" => true})

      {:ok, lv, _html} =
        conn |> log_in_account(visitor_account) |> live(~p"/groups/#{group.id}/values")

      assert has_element?(lv, "#group-value-form")
      assert has_element?(lv, "#group-value-keyboard-media[data-can-send=false]")
      refute has_element?(lv, "#group-value-keyboard-media-form")
    end
  end
end
