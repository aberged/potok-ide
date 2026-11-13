defmodule PotokIde.NoticesTest do
  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.CountMark
  alias PotokIde.Notices
  alias PotokIde.Notices.{GroupFollow, GroupNotice, GroupNoticeReceipt, Notifications}
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.Group

  setup do
    {owner_account, owner} = account_with_profile!("owner")
    {member_account, member} = account_with_profile!("member")
    {outsider_account, outsider} = account_with_profile!("outsider")

    %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: member_account,
      outsider: outsider,
      outsider_account: outsider_account,
      public: group_with_members!(owner, [member], %{"is_public" => true}),
      private: group_with_members!(owner, [member])
    }
  end

  defp access(profile, group), do: Social.get_group_access(profile, group)

  defp send!(author, group, body \\ "There is no water in Main Street tomorrow.") do
    {:ok, notice} = Notices.send_notice(author, group, access(author, group), %{"body" => body})
    notice
  end

  defp receipt_profile_ids(notice) do
    from(r in GroupNoticeReceipt, where: r.notice_id == ^notice.id, select: r.profile_id)
    |> Repo.all()
    |> Enum.sort()
  end

  # Past the group's limit, for the lists' pages: the rows a sent notice leaves.
  defp insert_notice!(author, group, body, recipients) do
    notice = Repo.insert!(%GroupNotice{group_id: group.id, creator_id: author.id, body: body})

    for profile <- recipients do
      Repo.insert!(%GroupNoticeReceipt{notice_id: notice.id, profile_id: profile.id})
    end

    notice
  end

  defp give_send_role!(owner, group, member) do
    {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
    {:ok, role} = Social.create_group_role(owner, group, %{"name" => "editors"})
    {:ok, _role} = Social.set_group_role_permission(owner, group, role.key, :send_notices, :allow)
    {:ok, _member_role} = Social.assign_group_member_role(owner, group, member.id, role.key)
    role
  end

  describe "following" do
    test "anyone who sees a group follows it", ctx do
      assert {:ok, %GroupFollow{push: true}} = Notices.follow(ctx.outsider, ctx.public)
      assert {:error, :not_allowed} = Notices.follow(ctx.outsider, ctx.private)
      assert {:ok, %GroupFollow{}} = Notices.follow(ctx.member, ctx.private)

      assert Notices.can_follow?(ctx.outsider, ctx.public, access(ctx.outsider, ctx.public))
      refute Notices.can_follow?(ctx.outsider, ctx.private, access(ctx.outsider, ctx.private))
      refute Notices.can_follow?(nil, ctx.public, access(nil, ctx.public))
    end

    test "not the root, a direct conversation or a thread", ctx do
      root = Social.get_root_group!()
      {:ok, direct} = Social.get_or_create_direct_group(ctx.owner, ctx.member)

      assert {:error, :not_allowed} = Notices.follow(ctx.owner, root)
      assert {:error, :not_allowed} = Notices.follow(ctx.owner, direct)
      refute Notices.followable?(%Group{ctx.public | parent_value_id: 1})
    end

    test "following again keeps the push as it was set", ctx do
      {:ok, _follow} = Notices.follow(ctx.outsider, ctx.public)
      assert :ok = Notices.set_follow_push(ctx.outsider, ctx.public.id, false)
      assert {:ok, %GroupFollow{push: false}} = Notices.follow(ctx.outsider, ctx.public)
      assert Repo.aggregate(GroupFollow, :count) == 1
    end

    test "a push switch needs a follow", ctx do
      assert {:error, :not_following} =
               Notices.set_follow_push(ctx.outsider, ctx.public.id, false)
    end

    test "the group's state counts the followers who still see it", ctx do
      {:ok, _follow} = Notices.follow(ctx.outsider, ctx.public)
      {:ok, _follow} = Notices.follow(ctx.member, ctx.private)

      assert %{notices?: false, following?: true, push?: true, followers: 1} =
               Notices.group_state(ctx.public, ctx.outsider)

      assert %{following?: false, followers: 1} = Notices.group_state(ctx.private, ctx.owner)

      {:ok, _removed} = Social.remove_group_member(ctx.owner, ctx.private, ctx.member.id)
      assert %{followers: 0} = Notices.group_state(ctx.private, nil)
    end

    test "the list of followed groups holds only those the profile still sees", ctx do
      {:ok, _follow} = Notices.follow(ctx.member, ctx.public)
      {:ok, _follow} = Notices.follow(ctx.member, ctx.private)
      :ok = Notices.set_follow_push(ctx.member, ctx.private.id, false)

      followed = Notices.list_followed_groups(ctx.member)

      assert Enum.sort(Enum.map(followed, fn {group, _push?} -> group.id end)) ==
               Enum.sort([ctx.public.id, ctx.private.id])

      assert {_group, false} =
               Enum.find(followed, fn {group, _} -> group.id == ctx.private.id end)

      {:ok, _removed} = Social.remove_group_member(ctx.owner, ctx.private, ctx.member.id)
      assert [{%Group{id: id}, true}] = Notices.list_followed_groups(ctx.member)
      assert id == ctx.public.id
    end

    test "unfollowing tells the profile's pages", ctx do
      Notices.subscribe(ctx.outsider)
      {:ok, _follow} = Notices.follow(ctx.outsider, ctx.public)
      assert_receive {:notices, {:follow_changed, profile_id, group_id}}
      assert {profile_id, group_id} == {ctx.outsider.id, ctx.public.id}

      :ok = Notices.unfollow(ctx.outsider, ctx.public.id)
      assert_receive {:notices, {:follow_changed, _profile_id, _group_id}}
      assert Repo.aggregate(GroupFollow, :count) == 0
    end
  end

  describe "sending" do
    test "needs the permission, which admins hold", ctx do
      assert {:error, :not_allowed} =
               Notices.send_notice(ctx.member, ctx.public, access(ctx.member, ctx.public), %{
                 "body" => "Hello"
               })

      assert %GroupNotice{body: "Hello"} = send!(ctx.owner, ctx.public, "Hello")
    end

    test "a role can be given the permission, and a denial takes it away", ctx do
      role = give_send_role!(ctx.owner, ctx.public, ctx.member)
      assert %GroupNotice{} = send!(ctx.member, ctx.public)

      {:ok, _role} =
        Social.set_group_role_permission(ctx.owner, ctx.public, role.key, :send_notices, :deny)

      assert {:error, :not_allowed} =
               Notices.send_notice(ctx.member, ctx.public, access(ctx.member, ctx.public), %{
                 "body" => "Again"
               })
    end

    test "is not for the root or a direct conversation", ctx do
      root = Social.get_root_group!()
      {:ok, direct} = Social.get_or_create_direct_group(ctx.owner, ctx.member)

      for group <- [root, direct] do
        assert {:error, :not_allowed} =
                 Notices.send_notice(ctx.owner, group, access(ctx.owner, group), %{"body" => "Hi"})
      end
    end

    test "the text has 1 to 2,000 characters, counting an emoji once", ctx do
      access = access(ctx.owner, ctx.public)

      for body <- ["", "   \n  ", String.duplicate("a", 2_001)] do
        assert {:error, %Ecto.Changeset{} = changeset} =
                 Notices.send_notice(ctx.owner, ctx.public, access, %{"body" => body})

        assert %{body: [_error]} = errors_on(changeset)
      end

      emoji = String.duplicate("🙂", 2_000)

      assert {:ok, %GroupNotice{body: ^emoji}} =
               Notices.send_notice(ctx.owner, ctx.public, access, %{"body" => emoji})
    end

    test "a group sends at most 10 an hour, and a text that fails costs nothing", ctx do
      access = access(ctx.owner, ctx.public)

      {:error, %Ecto.Changeset{}} =
        Notices.send_notice(ctx.owner, ctx.public, access, %{"body" => ""})

      for n <- 1..10, do: send!(ctx.owner, ctx.public, "Notice #{n}")

      assert {:error, {:rate_limited, retry_after}} =
               Notices.send_notice(ctx.owner, ctx.public, access, %{"body" => "Eleven"})

      assert retry_after > 0
    end

    test "reaches the followers who see the group, never its author", ctx do
      {:ok, _follow} = Notices.follow(ctx.outsider, ctx.public)
      {:ok, _follow} = Notices.follow(ctx.member, ctx.public)
      {:ok, _follow} = Notices.follow(ctx.owner, ctx.public)

      notice = send!(ctx.owner, ctx.public)

      assert notice.recipients_count == 2
      assert receipt_profile_ids(notice) == Enum.sort([ctx.outsider.id, ctx.member.id])
    end

    test "a private group's notice skips a follower who left it", ctx do
      {_account, other} = account_with_profile!("other")
      add_member!(ctx.owner, ctx.private, other)
      {:ok, _follow} = Notices.follow(ctx.member, ctx.private)
      {:ok, _follow} = Notices.follow(other, ctx.private)
      {:ok, _removed} = Social.remove_group_member(ctx.owner, ctx.private, ctx.member.id)

      notice = send!(ctx.owner, ctx.private)

      assert receipt_profile_ids(notice) == [other.id]
    end

    test "what was received stays after unfollowing", ctx do
      {:ok, _follow} = Notices.follow(ctx.outsider, ctx.public)
      notice = send!(ctx.owner, ctx.public)
      :ok = Notices.unfollow(ctx.outsider, ctx.public.id)

      assert %{entries: [%{notice: %GroupNotice{id: id}, unread?: true}], more?: false} =
               Notices.list_received(ctx.outsider)

      assert id == notice.id
    end

    test "tells each follower's pages, then the group's", ctx do
      {:ok, _follow} = Notices.follow(ctx.outsider, ctx.public)
      Notices.subscribe(ctx.outsider)
      Notices.subscribe_group(ctx.public)

      notice = send!(ctx.owner, ctx.public)
      outsider_id = ctx.outsider.id
      public_id = ctx.public.id
      notice_id = notice.id

      assert_receive {:notices, {:received, ^outsider_id, ^notice_id, ^public_id}}
      assert_receive {:group_notices, {:posted, ^notice_id}}
    end
  end

  describe "deleting" do
    test "the author or a sender deletes a notice for everyone who received it", ctx do
      {:ok, _follow} = Notices.follow(ctx.outsider, ctx.public)
      notice = send!(ctx.owner, ctx.public)
      Notices.subscribe(ctx.outsider)

      assert {:error, :not_allowed} =
               Notices.delete_notice(
                 ctx.member,
                 ctx.public,
                 access(ctx.member, ctx.public),
                 notice.id
               )

      assert {:ok, _notice} =
               Notices.delete_notice(
                 ctx.owner,
                 ctx.public,
                 access(ctx.owner, ctx.public),
                 notice.id
               )

      notice_id = notice.id
      assert_receive {:notices, {:deleted, _profile_id, ^notice_id, _group_id, true}}
      assert Repo.aggregate(GroupNoticeReceipt, :count) == 0
      assert %{entries: []} = Notices.list_received(ctx.outsider)
    end

    test "its author deletes it after losing the permission", ctx do
      role = give_send_role!(ctx.owner, ctx.public, ctx.member)
      notice = send!(ctx.member, ctx.public)

      {:ok, _role} =
        Social.set_group_role_permission(ctx.owner, ctx.public, role.key, :send_notices, :neutral)

      assert {:ok, _notice} =
               Notices.delete_notice(
                 ctx.member,
                 ctx.public,
                 access(ctx.member, ctx.public),
                 notice.id
               )
    end

    test "a notice of another group is not found", ctx do
      notice = send!(ctx.owner, ctx.public)

      assert {:error, :not_found} =
               Notices.delete_notice(
                 ctx.owner,
                 ctx.private,
                 access(ctx.owner, ctx.private),
                 notice.id
               )
    end

    test "deleting the group deletes its follows and notices", ctx do
      {:ok, _follow} = Notices.follow(ctx.outsider, ctx.public)
      send!(ctx.owner, ctx.public)

      {:ok, _deleted} = Social.delete_group(ctx.owner, ctx.public)

      assert Repo.aggregate(GroupFollow, :count) == 0
      assert Repo.aggregate(GroupNotice, :count) == 0
      assert Repo.aggregate(GroupNoticeReceipt, :count) == 0
    end
  end

  describe "reading" do
    test "a notice still being sent when the counter counted is not taken as counted", ctx do
      {:ok, _follow} = Notices.follow(ctx.outsider, ctx.public)

      # The id a notice takes before its transaction commits: a later notice
      # commits first, and the count sees only that one.
      %{rows: [[on_its_way]]} = Repo.query!("SELECT nextval('group_notices_id_seq')")
      sent = send!(ctx.owner, ctx.public)

      assert %{count: 1, as_of: as_of} = Notices.unread_snapshot(ctx.outsider)
      assert CountMark.counted?(as_of, sent.id)
      refute CountMark.counted?(as_of, on_its_way)
      refute CountMark.counted?(Social.nav_counts(ctx.outsider).unread_notices_as_of, on_its_way)
    end

    test "the counter counts unread notices, and reading clears it", ctx do
      {:ok, _follow} = Notices.follow(ctx.outsider, ctx.public)
      {:ok, _follow} = Notices.follow(ctx.member, ctx.private)

      first = send!(ctx.owner, ctx.public)
      second = send!(ctx.owner, ctx.public)

      assert %{count: 2, as_of: as_of} = Notices.unread_snapshot(ctx.outsider)
      assert CountMark.counted?(as_of, second.id)
      assert Social.nav_counts(ctx.outsider).unread_notices == 2

      Notices.subscribe(ctx.outsider)
      assert Notices.mark_read(ctx.outsider, first.id) == 1
      outsider_id = ctx.outsider.id
      assert_receive {:notices, {:read, ^outsider_id}}
      assert %{count: 1} = Notices.unread_snapshot(ctx.outsider)

      assert Notices.mark_group_read(ctx.outsider, ctx.public) == 1
      assert_receive {:notices, {:read, ^outsider_id}}
      assert Notices.mark_all_read(ctx.outsider) == 0
      refute_receive {:notices, {:read, _profile_id}}, 50
      assert Social.nav_counts(ctx.outsider).unread_notices == 0
    end

    test "a group's notices come newest first, 20 at a time", ctx do
      ids = for n <- 1..21, do: insert_notice!(ctx.owner, ctx.public, "Notice #{n}", []).id

      assert %{entries: entries, more?: true} = Notices.list_group_notices(ctx.public)
      assert Enum.map(entries, & &1.id) == ids |> Enum.reverse() |> Enum.take(20)
      assert Enum.all?(entries, &(&1.creator.id == ctx.owner.id))

      assert %{entries: [last], more?: false} =
               Notices.list_group_notices(ctx.public, before_id: List.last(entries).id)

      assert last.id == hd(ids)
    end

    test "received notices page by the oldest one shown", ctx do
      ids =
        for n <- 1..21 do
          group = if rem(n, 2) == 0, do: ctx.public, else: ctx.private
          insert_notice!(ctx.owner, group, "Notice #{n}", [ctx.member]).id
        end

      assert %{entries: first, more?: true} = Notices.list_received(ctx.member)
      assert Enum.map(first, & &1.notice.id) == ids |> Enum.reverse() |> Enum.take(20)
      oldest = List.last(first).notice.id

      assert %{entries: [last], more?: false} =
               Notices.list_received(ctx.member, before_id: oldest)

      assert last.notice.id == hd(ids)
      assert last.group.id == ctx.private.id
    end
  end

  describe "push" do
    setup do
      capture_push_requests!()
      :ok
    end

    test "goes to the followers' devices while both switches allow it", ctx do
      outsider_device = push_device!(ctx.outsider_account)
      _member_device = push_device!(ctx.member_account)
      _owner_device = push_device!(ctx.owner_account)

      {:ok, _follow} = Notices.follow(ctx.outsider, ctx.public)
      {:ok, _follow} = Notices.follow(ctx.member, ctx.public)
      :ok = Notices.set_follow_push(ctx.member, ctx.public.id, false)

      send!(ctx.owner, ctx.public)
      assert pushed_endpoints() == [outsider_device]

      {:ok, _profile} = Notices.set_notice_push(ctx.outsider, false)
      send!(ctx.owner, ctx.public)
      assert pushed_endpoints() == []
    end

    test "never to an account of the author's profile, though it follows with another", ctx do
      _owner_device = push_device!(ctx.owner_account)

      {:ok, second} =
        Social.create_profile_for_account(ctx.owner_account, %{
          username: "second",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, _follow} = Notices.follow(second, ctx.public)

      notice = send!(ctx.owner, ctx.public)

      assert receipt_profile_ids(notice) == [second.id]
      assert pushed_endpoints() == []
    end

    test "one push per account, however many of its profiles follow", ctx do
      device = push_device!(ctx.outsider_account)

      {:ok, second} =
        Social.create_profile_for_account(ctx.outsider_account, %{
          username: "outsider2",
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      {:ok, _follow} = Notices.follow(ctx.outsider, ctx.public)
      {:ok, _follow} = Notices.follow(second, ctx.public)

      send!(ctx.owner, ctx.public)
      assert pushed_endpoints() == [device]
    end

    test "names the group and opens the notice on its page", ctx do
      notice = send!(ctx.owner, ctx.public, "**Water** is off from 8 to 12.")
      payload_for = Notifications.notice(ctx.public, notice)

      assert %{
               title: title,
               body: "Water is off from 8 to 12.",
               tag: tag,
               url: url,
               badge: badge
             } = payload_for.("en")

      assert title == "Notice from #{ctx.public.name}"
      assert tag == "group-#{ctx.public.id}-notice-#{notice.id}"
      assert url == "/groups/#{ctx.public.id}/notices?notice=#{notice.id}"
      assert badge == "/avatar/group/#{ctx.public.id}?format=png"
      assert payload_for.("sr").title =~ ctx.public.name
    end
  end
end
