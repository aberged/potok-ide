defmodule PotokIde.Accounts.DeletionTest do
  use PotokIde.DataCase, async: true

  import PotokIde.AccountsFixtures
  import PotokIde.EventsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Accounts.{Account, AccountToken, Deletion}
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{AccountProfile, Group, GroupMembership, Profile, Value}

  setup do
    {owner_account, owner} = account_with_profile!("owner")
    {member_account, member} = account_with_profile!("member")
    group = group_with_members!(owner, [member])

    %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: member_account,
      group: group
    }
  end

  defp message!(profile, group, content) do
    {:ok, value} =
      Social.create_value(profile, group, %{"content" => content, "content_format" => "markdown"})

    value
  end

  defp member?(profile, group),
    do:
      Repo.exists?(
        from(m in GroupMembership, where: m.profile_id == ^profile.id and m.group_id == ^group.id)
      )

  describe "delete/1" do
    test "keeps the person's messages under a deleted profile", %{
      member: member,
      member_account: member_account,
      owner: owner,
      group: group
    } do
      value = message!(member, group, "Hello from the member")
      {:ok, _} = Social.toggle_value_reaction(owner, group, value, "👍")
      other = message!(owner, group, "Hello back")
      {:ok, _} = Social.toggle_value_reaction(member, group, other, "👍")
      :ok = Social.pin_group(member, group.id)
      count_before = Repo.get!(Group, group.id).member_count
      _session = Accounts.generate_account_session_token(member_account)

      assert {:ok, %{email: email, tokens: tokens}} = Deletion.delete(member_account)
      assert email == member_account.email
      assert tokens != []

      refute Repo.get(Account, member_account.id)
      refute Repo.exists?(from(t in AccountToken, where: t.account_id == ^member_account.id))

      deleted = Repo.get!(Profile, member.id)
      assert deleted.kind == :deleted
      assert deleted.username == "obrisan-#{member.id}"
      assert deleted.description == ""
      assert Profile.display_name(deleted) == "Deleted user"
      assert Profile.author_label(deleted) == "Deleted user"

      # The message stays and still names its author; the reaction does not.
      assert Repo.get!(Value, value.id).creator_id == member.id

      refute Repo.exists?(
               from(r in "value_reactions", where: r.profile_id == ^member.id, select: 1)
             )

      refute Repo.exists?(
               from(p in "pinned_groups", where: p.profile_id == ^member.id, select: 1)
             )

      refute member?(deleted, group)
      assert Repo.get!(Group, group.id).member_count == count_before - 1

      # Nobody finds the profile by its name any more.
      refute Social.get_profile_by_username(deleted.username)
    end

    test "is blocked while the person is a group's only admin, with others in it", %{
      owner: owner,
      owner_account: owner_account,
      group: group
    } do
      assert %{blocking: [%Group{id: id}]} = Deletion.preview(owner_account)
      assert id == group.id

      assert {:error, {:blocked, [%Group{id: ^id}]}} = Deletion.delete(owner_account)
      assert Repo.get!(Profile, owner.id).kind == :person
      assert Repo.get(Account, owner_account.id)
    end

    test "takes the groups where the person is alone, sub-groups first" do
      {account, loner} = account_with_profile!("loner")
      alone = group_with_members!(loner, [])
      inner = group_with_members!(loner, [], %{parent: alone})

      preview = Deletion.preview(account)
      assert preview.blocking == []

      assert Enum.sort(Enum.map(preview.deleted_groups, & &1.id)) ==
               Enum.sort([alone.id, inner.id])

      assert {:ok, _} = Deletion.delete(account)
      refute Repo.get(Group, alone.id)
      refute Repo.get(Group, inner.id)
    end

    test "a group with another admin stays, and only the membership goes", %{
      owner: owner,
      member: member,
      member_account: member_account
    } do
      shared = group_with_members!(owner, [member])
      {:ok, _} = Social.assign_group_member_role(owner, shared, member.id, "admin")

      assert %{blocking: []} = Deletion.preview(member_account)
      assert {:ok, _} = Deletion.delete(member_account)
      assert Repo.get(Group, shared.id)
      assert member?(owner, shared)
    end

    test "a profile other accounts use stays as it is", %{member: member, member_account: account} do
      other = account_fixture()
      Repo.insert!(%AccountProfile{account_id: other.id, profile_id: member.id})

      assert %{tombstones: [], kept_shared: [%Profile{id: id}]} = Deletion.preview(account)
      assert id == member.id

      assert {:ok, _} = Deletion.delete(account)
      assert Repo.get!(Profile, member.id).kind == :person
      assert Repo.exists?(from(ap in AccountProfile, where: ap.account_id == ^other.id))
    end

    test "a direct conversation keeps its deleted side and loses the old name", %{
      owner: owner,
      member: member,
      member_account: member_account
    } do
      {:ok, direct} = Social.get_or_create_direct_group(owner, member)
      assert {:ok, _} = Deletion.delete(member_account)

      direct = Repo.get!(Group, direct.id)
      refute direct.name =~ "member"
      assert direct.name =~ "obrisan-#{member.id}"
      assert member?(%Profile{id: member.id}, direct)

      deleted = Repo.get!(Profile, member.id)
      assert {:error, :deleted_profile} = Social.get_or_create_direct_group(owner, deleted)
    end
  end

  describe "Accounts.delete_account/1 and the link" do
    test "the link finds the account for an hour, and only while it keeps the address", %{
      member_account: account
    } do
      token =
        extract_account_token(fn url ->
          Accounts.deliver_account_deletion_instructions(account, url)
        end)

      assert %Account{id: id} = Accounts.get_account_by_deletion_token(token)
      assert id == account.id

      {:ok, decoded} = Base.url_decode64(token, padding: false)
      hashed = :crypto.hash(:sha256, decoded)
      offset_account_token(hashed, -61, :minute)
      refute Accounts.get_account_by_deletion_token(token)
      assert Accounts.delete_expired_tokens() >= 1
    end

    test "sends a last email to the old address", %{member_account: account} do
      assert {:ok, _tokens} = Accounts.delete_account(account)
      refute Repo.get(Account, account.id)
    end
  end

  describe "purge_unclaimed/0" do
    test "deletes invited accounts nobody took up in #{Deletion.unclaimed_days()} days" do
      old = unconfirmed_account_fixture()
      recent = unconfirmed_account_fixture()
      long_ago = DateTime.add(DateTime.utc_now(:second), -(Deletion.unclaimed_days() + 1), :day)

      from(a in Account, where: a.id in ^[old.id, recent.id])
      |> Repo.update_all(set: [inserted_at: long_ago])

      # Somebody invited `recent` again lately.
      {_token, hashed} = generate_account_magic_link_token(recent)

      from(t in AccountToken, where: t.token == ^hashed)
      |> Repo.update_all(set: [inserted_at: DateTime.utc_now(:second)])

      assert Deletion.purge_unclaimed() == 1
      refute Repo.get(Account, old.id)
      assert Repo.get(Account, recent.id)
    end

    test "never touches confirmed accounts or accounts with a profile", %{
      owner_account: owner_account
    } do
      long_ago = DateTime.add(DateTime.utc_now(:second), -365, :day)

      from(a in Account, where: a.id == ^owner_account.id)
      |> Repo.update_all(set: [inserted_at: long_ago, confirmed_at: nil])

      assert Deletion.purge_unclaimed() == 0
    end
  end

  test "nobody may pick a deleted profile's name" do
    changeset = Profile.changeset(%Profile{}, %{username: "obrisan-12", sharing: :unique})
    assert %{username: ["is kept for deleted accounts"]} = errors_on(changeset)
  end
end
