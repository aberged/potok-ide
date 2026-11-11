defmodule PotokIdeWeb.GroupLive.SubGroupsLastValueTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Value, ValueAttachment}

  setup do
    {owner_account, owner} = account_with_profile!("last-owner")
    {viewer_account, viewer} = account_with_profile!("last-viewer")
    parent = group_with_members!(owner, [viewer])
    child = group_with_members!(owner, [viewer], %{parent: parent})

    %{
      owner_account: owner_account,
      owner: owner,
      viewer_account: viewer_account,
      viewer: viewer,
      parent: parent,
      child: child
    }
  end

  defp live_as(account, path) do
    build_conn()
    |> log_in_account(account)
    |> live(path)
  end

  defp post!(profile, group, content) do
    {:ok, value} = Social.create_value(profile, group, %{"content" => content})
    value
  end

  defp row(id), do: "#child-group-last-value-text-#{id}"

  test "a row shows the group's newest message and who wrote it", ctx do
    post!(ctx.viewer, ctx.child, "older")
    post!(ctx.owner, ctx.child, "**Krećemo** u 8")

    {:ok, lv, _html} = live_as(ctx.viewer_account, ~p"/groups/#{ctx.parent.id}/sub_groups")

    assert has_element?(lv, row(ctx.child.id), "last-owner:")
    assert has_element?(lv, row(ctx.child.id), "Krećemo u 8")
    refute has_element?(lv, row(ctx.child.id), "**")
    refute has_element?(lv, "#{row(ctx.child.id)}[data-mine]")
    assert has_element?(lv, "#child-group-last-value-#{ctx.child.id}[datetime]")
  end

  test "the viewer's own message is marked as theirs", ctx do
    post!(ctx.viewer, ctx.child, "mine")

    {:ok, lv, _html} = live_as(ctx.viewer_account, ~p"/groups/#{ctx.parent.id}/sub_groups")

    assert has_element?(lv, "#{row(ctx.child.id)}[data-mine]", "mine")
    refute has_element?(lv, row(ctx.child.id), "last-viewer")
  end

  test "a public group the viewer is not in shows no message", ctx do
    public =
      group_with_members!(ctx.owner, [], %{:parent => ctx.parent, "is_public" => true})

    post!(ctx.owner, public, "members only")

    {:ok, lv, _html} = live_as(ctx.viewer_account, ~p"/groups/#{ctx.parent.id}/sub_groups")

    assert has_element?(lv, "#child-group-#{public.id}")
    refute has_element?(lv, row(public.id))
  end

  test "a direct conversation shows the other side's message without a name", ctx do
    {:ok, direct} = Social.get_or_create_direct_group(ctx.viewer, ctx.owner)
    post!(ctx.owner, direct, "hello there")

    root = Social.get_root_group!()

    {:ok, lv, _html} =
      live_as(ctx.viewer_account, ~p"/groups/#{root.id}/sub_groups?sub_groups_kind=direct")

    assert has_element?(lv, row(direct.id), "hello there")
    refute has_element?(lv, row(direct.id), "last-owner:")
  end

  test "new, own, edited and deleted messages change the row as they happen", ctx do
    first = post!(ctx.owner, ctx.child, "first")
    {:ok, lv, _html} = live_as(ctx.viewer_account, ~p"/groups/#{ctx.parent.id}/sub_groups")
    assert has_element?(lv, row(ctx.child.id), "first")

    second = post!(ctx.owner, ctx.child, "second")
    assert render(lv) =~ "second"
    assert has_element?(lv, row(ctx.child.id), "second")

    # Written from another page of the viewer's: no unread count, a new row.
    mine = post!(ctx.viewer, ctx.child, "from my phone")
    assert render(lv) =~ "from my phone"
    assert has_element?(lv, "#{row(ctx.child.id)}[data-mine]", "from my phone")

    {:ok, _value} = Social.update_value(ctx.viewer, mine, %{"content" => "from my phone, edited"})
    assert render(lv) =~ "from my phone, edited"

    # Editing an older message leaves the row alone.
    {:ok, _value} = Social.update_value(ctx.owner, second, %{"content" => "second, edited"})
    render(lv)
    assert has_element?(lv, row(ctx.child.id), "from my phone, edited")

    {:ok, _deleted} = Social.delete_value(ctx.viewer, mine)
    assert render(lv) =~ "second, edited"
    assert has_element?(lv, row(ctx.child.id), "second, edited")

    {:ok, _deleted} = Social.delete_value(ctx.owner, Repo.reload!(second))
    {:ok, _deleted} = Social.delete_value(ctx.owner, first)
    render(lv)
    refute has_element?(lv, row(ctx.child.id))
  end

  describe "last_chat_previews/1" do
    test "takes the newest chat value of each group, files when it has no text", ctx do
      other = group_with_members!(ctx.owner, [], %{parent: ctx.parent})
      post!(ctx.owner, ctx.child, "text")

      {:ok, _data} =
        Social.create_data_value(ctx.owner, ctx.child, %{"content" => "data:", "data" => %{}})

      files =
        Repo.insert!(%Value{
          content: "",
          creator_id: ctx.viewer.id,
          group_id: other.id,
          mentions: %{},
          mentioned_profile_ids: []
        })

      for name <- ["report.pdf", "photo.jpg"] do
        Repo.insert!(%ValueAttachment{
          value_id: files.id,
          group_id: other.id,
          profile_id: ctx.viewer.id,
          filename: name,
          content_type: "application/octet-stream",
          byte_size: 1,
          storage_key: "k-#{files.id}-#{name}"
        })
      end

      empty = group_with_members!(ctx.owner, [], %{parent: ctx.parent})
      previews = Social.last_chat_previews([ctx.child.id, other.id, empty.id])

      assert %{author: "last-owner", text: "text"} = previews[ctx.child.id]
      assert %{author: "last-viewer", text: "📎 report.pdf +1"} = previews[other.id]
      refute Map.has_key?(previews, empty.id)
    end
  end
end
