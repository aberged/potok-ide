defmodule PotokIde.Social.AttachmentsTest do
  use PotokIde.DataCase

  import PotokIde.AccountsFixtures

  alias PotokIde.Social
  alias PotokIde.Social.{Value, ValueAttachment}
  alias PotokIde.Storage

  describe "create_value/4" do
    test "a value can carry only files" do
      owner = profile!("att-owner")
      group = group!(owner, "att-group")
      file = stored_file!(group, "notes.txt", "hello")

      assert {:ok, value} = Social.create_value(owner, group, %{"content" => ""}, [file])

      assert value.content == ""
      assert [%ValueAttachment{} = attachment] = value.attachments
      assert attachment.filename == "notes.txt"
      assert attachment.content_type == "text/plain"
      assert attachment.byte_size == 5
      assert attachment.group_id == group.id
      assert attachment.profile_id == owner.id
      assert Value.excerpt(value) == "📎 notes.txt"
    end

    test "a value without text or files is refused" do
      owner = profile!("att-empty-owner")
      group = group!(owner, "att-empty-group")

      assert {:error, %Ecto.Changeset{} = changeset} =
               Social.create_value(owner, group, %{"content" => ""}, [])

      assert %{content: ["can't be blank"]} = errors_on(changeset)
    end

    test "needs the attach_files permission, which admins always hold" do
      owner = profile!("att-perm-owner")
      member = profile!("att-perm-member")
      group = group!(owner, "att-perm-group")
      add_member!(owner, group, member)

      {:ok, _manifest} = Social.create_own_group_manifest(owner, group)

      {:ok, _role} =
        Social.set_group_role_permission(owner, group, "everyone", :attach_files, :neutral)

      assert {:error, :not_permitted} =
               Social.create_value(member, group, %{"content" => "hi"}, [
                 stored_file!(group, "a.txt")
               ])

      assert {:ok, _value} = Social.create_value(member, group, %{"content" => "hi"})

      assert {:ok, %Value{attachments: [_]}} =
               Social.create_value(owner, group, %{"content" => "hi"}, [
                 stored_file!(group, "b.txt")
               ])
    end

    test "refuses more files than the limit" do
      owner = profile!("att-many-owner")
      group = group!(owner, "att-many-group")
      files = for i <- 0..Storage.max_files(), do: stored_file!(group, "f#{i}.txt")

      assert {:error, :too_many_attachments} =
               Social.create_value(owner, group, %{"content" => "many"}, files)
    end

    test "cleans the file name and content type" do
      owner = profile!("att-clean-owner")
      group = group!(owner, "att-clean-group")

      file = %{
        stored_file!(group, "x")
        | filename: "../../etc/pa" <> <<0x202E::utf8>> <> "sswd\n.txt",
          content_type: "Text/HTML; charset=utf-8"
      }

      {:ok, %Value{attachments: [attachment]}} =
        Social.create_value(owner, group, %{"content" => "x"}, [file])

      assert attachment.filename == ".._.._etc_pa_sswd_.txt"
      assert attachment.content_type == "text/html"
    end
  end

  describe "deleting" do
    test "a value removes its files from storage" do
      owner = profile!("att-del-owner")
      group = group!(owner, "att-del-group")
      file = stored_file!(group, "gone.txt")
      {:ok, value} = Social.create_value(owner, group, %{"content" => "bye"}, [file])

      assert {:ok, _} = Storage.stat(file.storage_key)
      assert {:ok, _deleted} = Social.delete_value(owner, value)

      assert {:error, :not_found} = Storage.stat(file.storage_key)
      assert {[], false} = Social.list_group_attachments(group)
    end

    test "a group removes the files of its values" do
      owner = profile!("att-delg-owner")
      group = group!(owner, "att-delg-group")
      file = stored_file!(group, "gone.txt")
      {:ok, _value} = Social.create_value(owner, group, %{"content" => "bye"}, [file])

      assert {:ok, _deleted} = Social.delete_group(owner, group)
      assert {:error, :not_found} = Storage.stat(file.storage_key)
    end

    test "a file-only value keeps its empty text when edited" do
      owner = profile!("att-edit-owner")
      group = group!(owner, "att-edit-group")
      {:ok, value} = Social.create_value(owner, group, %{}, [stored_file!(group, "a.txt")])

      assert {:ok, updated} = Social.update_value(owner, value, %{"content" => "  "})
      assert updated.content == ""
    end
  end

  describe "listing and downloads" do
    test "pages a group's files newest first" do
      owner = profile!("att-list-owner")
      group = group!(owner, "att-list-group")

      for name <- ~w(a b c) do
        {:ok, _} = Social.create_value(owner, group, %{}, [stored_file!(group, "#{name}.txt")])
      end

      assert {[c, b], true} = Social.list_group_attachments(group, limit: 2)
      assert {c.filename, b.filename} == {"c.txt", "b.txt"}
      assert c.profile.id == owner.id

      assert {[a], false} = Social.list_group_attachments(group, limit: 2, before_id: b.id)
      assert a.filename == "a.txt"
    end

    test "narrows the files by name and kind, page by page" do
      owner = profile!("att-find-owner")
      group = group!(owner, "att-find-group")

      files = [
        typed_file!(group, "Ćevapi meni.pdf", "application/pdf"),
        typed_file!(group, "cevapi.png", "image/png"),
        typed_file!(group, "budget_2026.xlsx", "application/vnd.ms-excel"),
        typed_file!(group, "budgetX2026.csv", "text/csv"),
        typed_file!(group, "slides.key", "application/octet-stream")
      ]

      for file <- files, do: {:ok, _} = Social.create_value(owner, group, %{}, [file])

      names = fn opts ->
        {rows, _more?} = Social.list_group_attachments(group, opts)
        Enum.map(rows, & &1.filename)
      end

      # Folded as the other searches: no case, no marks.
      assert names.(search: "CEVAPI") == ["cevapi.png", "Ćevapi meni.pdf"]
      assert names.(search: "ćevapi", kind: :document) == ["Ćevapi meni.pdf"]
      # `_` is only itself, not any one letter.
      assert names.(search: "budget_") == ["budget_2026.xlsx"]
      assert names.(kind: :sheet) == ["budgetX2026.csv", "budget_2026.xlsx"]
      assert names.(kind: :image) == ["cevapi.png"]
      assert names.(kind: :other) == ["slides.key"]
      assert names.(kind: :archive) == []
      assert names.(search: "", kind: nil) |> length() == 5

      assert {[newer], true} = Social.list_group_attachments(group, limit: 1, search: "cevapi")
      assert newer.filename == "cevapi.png"

      assert {[older], false} =
               Social.list_group_attachments(group,
                 limit: 1,
                 search: "cevapi",
                 before_id: newer.id
               )

      assert older.filename == "Ćevapi meni.pdf"

      assert Social.get_group_attachment(group, older.id, kind: :document).id == older.id
      assert Social.get_group_attachment(group, older.id, kind: :image) == nil
    end

    test "only members of the file's group may download it" do
      owner = profile!("att-dl-owner")
      outsider = profile!("att-dl-outsider")
      group = group!(owner, "att-dl-group", %{"is_public" => true})

      {:ok, %Value{attachments: [attachment]}} =
        Social.create_value(owner, group, %{}, [stored_file!(group, "a.txt")])

      assert %ValueAttachment{} = Social.get_attachment_for_download(owner, attachment.id)
      assert Social.get_attachment_for_download(outsider, attachment.id) == nil
    end
  end

  describe "attachment_tree/2" do
    test "walks the visible sub-groups and keeps only folders with files" do
      owner = profile!("tree-owner")
      other = profile!("tree-other")
      group = group!(owner, "tree-root")
      add_member!(owner, group, other)

      {:ok, _} = Social.create_value(owner, group, %{}, [stored_file!(group, "root.txt", "12")])

      # Public, but the owner is not a member: shown as a locked folder only
      # because a sub-group below it has files the owner can read.
      public_child = child!(other, group, "tree-public", %{"is_public" => true})
      {:ok, _} = Social.create_value(other, public_child, %{}, [stored_file!(public_child, "p")])

      nested = child!(other, public_child, "tree-nested")
      add_member!(other, nested, owner)
      {:ok, _} = Social.create_value(other, nested, %{}, [stored_file!(nested, "nested.txt")])

      # Private and the owner is not a member: never shown.
      private_child = child!(other, group, "tree-private")

      {:ok, _} =
        Social.create_value(other, private_child, %{}, [stored_file!(private_child, "s")])

      # A member, but no files: left out.
      _empty_child = child!(owner, group, "tree-empty")

      {:ok, value} = Social.create_value(owner, group, %{"content" => "thread start"})
      {:ok, thread} = Social.get_or_create_value_thread(owner, group, value, %{"name" => "talk"})
      {:ok, _} = Social.create_value(owner, thread, %{}, [stored_file!(thread, "t.txt")])

      assert {tree, false} = Social.attachment_tree(group, owner)

      assert tree.group.id == group.id
      assert Enum.map(tree.files, & &1.filename) == ["root.txt"]
      assert tree.file_count == 3

      assert [talk, public] = tree.children
      assert talk.group.thread? and talk.group.member?
      assert Enum.map(talk.files, & &1.filename) == ["t.txt"]

      assert public.group.id == public_child.id
      refute public.group.member?
      assert public.files == []
      assert [%{group: %{id: nested_id}, files: [%{filename: "nested.txt"}]}] = public.children
      assert nested_id == nested.id
    end

    test "a search keeps only the folders that hold a match" do
      owner = profile!("tree-find-owner")
      group = group!(owner, "tree-find-root")
      {:ok, _} = Social.create_value(owner, group, %{}, [stored_file!(group, "root.txt")])

      found = child!(owner, group, "tree-find-found")
      {:ok, _} = Social.create_value(owner, found, %{}, [stored_file!(found, "Zapisnik.txt")])

      other = child!(owner, group, "tree-find-other")
      {:ok, _} = Social.create_value(owner, other, %{}, [stored_file!(other, "other.txt")])

      assert {tree, false} = Social.attachment_tree(group, owner, search: "zapisnik")

      assert tree.files == []
      assert tree.file_count == 1
      assert [%{group: %{id: found_id}, files: [%{filename: "Zapisnik.txt"}]}] = tree.children
      assert found_id == found.id

      assert {%{file_count: 0, children: []}, false} =
               Social.attachment_tree(group, owner, kind: :image)
    end

    test "an empty group is a tree without files" do
      owner = profile!("tree-empty-owner")
      group = group!(owner, "tree-empty-root")

      assert {%{files: [], children: [], file_count: 0, byte_size: 0}, false} =
               Social.attachment_tree(group, owner)
    end
  end

  describe "Value.excerpt/2" do
    test "falls back to the files of a value without text" do
      value = %Value{
        content: "",
        content_format: :markdown,
        attachments: [%ValueAttachment{filename: "report.pdf"}, %ValueAttachment{filename: "b"}]
      }

      assert Value.excerpt(value) == "📎 report.pdf +1"
      assert Value.excerpt(%{value | content: "**text**"}) == "text"
      assert Value.excerpt(%{value | attachments: []}) == nil
    end
  end

  describe "ValueAttachment.media_kind/1" do
    test "names the files the app previews and nothing else" do
      assert ValueAttachment.media_kind(%ValueAttachment{content_type: "image/webp"}) == :image
      assert ValueAttachment.media_kind("video/mp4") == :video
      assert ValueAttachment.media_kind("video/quicktime") == :video
      assert ValueAttachment.media_kind("audio/mpeg") == :audio
      assert ValueAttachment.media_kind("audio/x-m4a") == :audio

      for type <- ["image/svg+xml", "text/html", "application/pdf", "video/x-msvideo", nil] do
        assert ValueAttachment.media_kind(type) == nil
        refute ValueAttachment.previewable?(%ValueAttachment{content_type: type})
      end
    end
  end

  describe "ValueAttachment.kind/1" do
    test "sorts files as someone looking for them would" do
      kinds = %{
        "image/svg+xml" => :image,
        "image/heic" => :image,
        "video/x-msvideo" => :video,
        "audio/mpeg" => :audio,
        "application/pdf" => :document,
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document" => :document,
        "text/plain" => :document,
        "text/markdown" => :document,
        "text/csv" => :sheet,
        "application/vnd.oasis.opendocument.spreadsheet" => :sheet,
        "application/zip" => :archive,
        "application/octet-stream" => :other,
        "application/json" => :other
      }

      for {type, kind} <- kinds do
        assert ValueAttachment.kind(type) == kind, type
        assert ValueAttachment.kind(%ValueAttachment{content_type: type}) == kind
      end

      assert ValueAttachment.kind(nil) == :other
      assert ValueAttachment.parse_kind("sheet") == :sheet
      assert ValueAttachment.parse_kind("anything") == nil
      assert ValueAttachment.parse_kind(nil) == nil
    end
  end

  describe "Storage.content_disposition/2" do
    test "has an ASCII fallback and the full UTF-8 name" do
      assert Storage.content_disposition(:attachment, ~s(Ćevapi "menu".pdf)) ==
               ~s(attachment; filename="Cevapi menu.pdf"; filename*=UTF-8''%C4%86evapi%20%22menu%22.pdf)
    end
  end

  defp stored_file!(group, name, content \\ "hello") do
    key = Storage.new_key(group.id)
    path = Path.join(System.tmp_dir!(), "potok-upload-#{System.unique_integer([:positive])}")
    File.write!(path, content)
    :ok = Storage.put_file(key, path)
    File.rm!(path)

    %{storage_key: key, filename: name, content_type: "text/plain", byte_size: byte_size(content)}
  end

  defp typed_file!(group, name, content_type),
    do: %{stored_file!(group, name) | content_type: content_type}

  defp profile!(username) do
    {:ok, profile} =
      Social.create_profile_for_account(account_fixture(), %{
        username: username,
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    profile
  end

  defp group_attrs(name, attrs) do
    Map.merge(%{"name" => name, "description" => "", "description_format" => :markdown}, attrs)
  end

  defp group!(owner, name, attrs \\ %{}) do
    {:ok, group} = Social.create_group(owner, Social.get_root_group!(), group_attrs(name, attrs))
    group
  end

  defp child!(owner, parent, name, attrs \\ %{}) do
    {:ok, group} = Social.create_group(owner, parent, group_attrs(name, attrs))
    group
  end

  defp add_member!(owner, group, profile) do
    {:ok, invitation} = Social.invite_profile_to_group(owner, group, profile)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, profile)
    :ok
  end
end
