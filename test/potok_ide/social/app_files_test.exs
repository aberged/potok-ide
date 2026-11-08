defmodule PotokIde.Social.AppFilesTest do
  @moduledoc """
  Files sent with an app's values: the two sub-groups that keep them, what a
  sender may send, which value a file belongs to, and who opens it.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{AppData, AppFiles, Group, Value, ValueAttachment}

  defp unique, do: System.unique_integer([:positive])

  setup do
    {owner_account, owner} = account_with_profile!("af#{unique()}")
    {member_account, member} = account_with_profile!("af#{unique()}")

    group =
      group_with_members!(owner, [member], %{
        "uses_api" => true,
        "description" => "<p>app</p>",
        "description_format" => :html,
        "home_page" => :description
      })

    {:ok, _config} =
      AppData.save_config(
        owner,
        group,
        nil,
        %{
          "rules" => %{
            "responses" => %{
              "under" => ["a"],
              "uploads" => %{
                "cv" => %{
                  "target" => "private",
                  "max_files" => 2,
                  "max_bytes" => 1_000,
                  "types" => ["pdf"]
                },
                "photo" => %{"target" => "public"}
              }
            }
          }
        },
        0
      )

    {:ok, files} = AppFiles.ensure_groups(owner, group, nil)

    %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: member_account,
      group: group,
      files: files
    }
  end

  defp file(attrs \\ %{}),
    do: Map.merge(%{name: "cv.pdf", size: 500, type: "application/pdf"}, attrs)

  defp send_file!(ctx, profile, slot \\ "cv", file \\ file()) do
    {:ok, upload} = AppFiles.prepare(profile, ctx.group, nil, "responses", slot, file)

    {:ok, attachment} =
      AppFiles.store(profile, upload, %{
        storage_key: "g#{upload.file_group_id}/#{Ecto.UUID.generate()}",
        filename: file.name,
        content_type: file.type,
        byte_size: file.size
      })

    attachment
  end

  test "makes a closed private group and an inheriting public one, once", ctx do
    private = Repo.get!(Group, ctx.files["private"])
    public = Repo.get!(Group, ctx.files["public"])

    assert private.parent_id == ctx.group.id
    assert Group.closed?(private)
    assert public.inherits_members
    refute Social.member_of_group?(ctx.member, private)
    assert Social.member_of_group?(ctx.member, public)

    assert {:ok, same} = AppFiles.ensure_groups(ctx.owner, ctx.group, nil)
    assert same == ctx.files
    assert AppData.get_config(ctx.group, nil).data["files"] == ctx.files
  end

  test "only editors make them", ctx do
    assert {:error, :not_permitted} = AppFiles.ensure_groups(ctx.member, ctx.group, nil)
  end

  test "a file must fit its slot", ctx do
    assert {:error, :invalid_files} =
             AppFiles.prepare(ctx.member, ctx.group, nil, "responses", "cv", file(%{size: 5_000}))

    assert {:error, :invalid_files} =
             AppFiles.prepare(
               ctx.member,
               ctx.group,
               nil,
               "responses",
               "cv",
               file(%{type: "image/png"})
             )

    assert {:error, :invalid_files} =
             AppFiles.prepare(ctx.member, ctx.group, nil, "responses", "nope", file())
  end

  test "nothing goes into a private group that is no longer closed", ctx do
    private = Repo.get!(Group, ctx.files["private"])
    {:ok, _opened} = Social.update_group(ctx.owner, private, %{"is_public" => true})

    assert {:error, :files_exposed} =
             AppFiles.prepare(ctx.member, ctx.group, nil, "responses", "cv", file())
  end

  test "a value claims its sender's files, which then open for the sender and the group's members only",
       ctx do
    attachment = send_file!(ctx, ctx.member)

    {:ok, value, _rule} =
      AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, "responses", %{
        "a" => %{"cv" => [%{"file" => attachment.id, "name" => "cv.pdf"}]}
      })

    file_value = Repo.get!(Value, attachment.value_id)
    assert file_value.data["response"] == value.id
    assert file_value.group_id == ctx.files["private"]

    # The sender opens it though not a member of the private group.
    assert %ValueAttachment{} = Social.get_attachment_for_download(ctx.member, attachment.id)
    # The owner made the group, so is its member.
    assert %ValueAttachment{} = Social.get_attachment_for_download(ctx.owner, attachment.id)

    {third_account, third} = account_with_profile!("af#{unique()}")
    add_member!(ctx.owner, ctx.group, third)
    assert is_nil(Social.get_attachment_for_download(third, attachment.id))

    # Nobody else's value can claim it.
    assert {:error, :invalid_files} =
             AppData.insert(third, third_account, ctx.group, nil, "responses", %{
               "a" => %{"cv" => [%{"file" => attachment.id}]}
             })
  end

  test "more files than the slot takes are refused", ctx do
    files = for _ <- 1..3, do: %{"file" => send_file!(ctx, ctx.member).id}

    assert {:error, :invalid_files} =
             AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, "responses", %{
               "a" => %{"cv" => files}
             })
  end

  test "deleting a value deletes its files, and the sweep takes the unclaimed ones", ctx do
    claimed = send_file!(ctx, ctx.member)
    unclaimed = send_file!(ctx, ctx.member)

    {:ok, value, _rule} =
      AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, "responses", %{
        "a" => %{"cv" => [%{"file" => claimed.id}]}
      })

    assert AppFiles.sweep(DateTime.utc_now()) == 0
    assert AppFiles.sweep(DateTime.add(DateTime.utc_now(), 2, :day)) == 1
    refute Repo.get(ValueAttachment, unclaimed.id)

    {:ok, _deleted} = AppData.delete(ctx.owner, ctx.group, nil, value.id)
    refute Repo.get(ValueAttachment, claimed.id)
  end

  test "a changed value lets go of the files it no longer names", ctx do
    {:ok, _config} =
      AppData.save_config(
        ctx.owner,
        ctx.group,
        nil,
        %{
          "rules" => %{
            "responses" => %{
              "under" => ["a"],
              "edit_own" => true,
              "uploads" => %{
                "cv" => %{"target" => "private", "max_files" => 2, "types" => ["pdf"]}
              }
            }
          }
        },
        AppData.get_config(ctx.group, nil).lock_version
      )

    first = send_file!(ctx, ctx.member)
    second = send_file!(ctx, ctx.member)

    {:ok, value, _rule} =
      AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, "responses", %{
        "a" => %{"cv" => [%{"file" => first.id}]}
      })

    {:ok, _updated, _rule} =
      AppData.update(
        ctx.member,
        ctx.group,
        nil,
        value.id,
        %{"a" => %{"cv" => [%{"file" => second.id}]}},
        nil
      )

    refute Repo.get(ValueAttachment, first.id)
    assert Repo.get!(Value, second.value_id).data["response"] == value.id
  end

  test "a picture of the app goes to the public group and is kept", ctx do
    {:ok, upload} =
      AppFiles.prepare_image(ctx.owner, ctx.group, nil, %{
        name: "h.png",
        size: 900,
        type: "image/png"
      })

    assert upload.file_group_id == ctx.files["public"]

    assert {:error, :not_permitted} =
             AppFiles.prepare_image(ctx.member, ctx.group, nil, %{
               name: "h.png",
               size: 900,
               type: "image/png"
             })

    {:ok, attachment} =
      AppFiles.store(ctx.owner, upload, %{
        storage_key: "g#{upload.file_group_id}/#{Ecto.UUID.generate()}",
        filename: "h.png",
        content_type: "image/png",
        byte_size: 900
      })

    assert AppFiles.sweep(DateTime.add(DateTime.utc_now(), 2, :day)) == 0
    assert Repo.get(ValueAttachment, attachment.id)
  end
end
