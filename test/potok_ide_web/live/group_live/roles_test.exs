defmodule PotokIdeWeb.GroupLive.RolesTest do
  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.AccountsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Social
  alias PotokIde.Social.Access

  setup do
    {owner_account, owner} = account_with_profile!("rl-owner")
    {member_account, member} = account_with_profile!("rl-member")

    {:ok, group} =
      Social.create_group(owner, Social.get_root_group!(), %{
        "name" => "roles-group",
        "description" => "",
        "description_format" => :markdown,
        "home_page" => :chat
      })

    {:ok, invitation} = Social.invite_profile_to_group(owner, group, member)
    {:ok, _accepted} = Social.accept_group_invitation(invitation, member)

    %{
      owner_account: owner_account,
      owner: owner,
      member_account: member_account,
      member: member,
      group: group
    }
  end

  describe "roles tab" do
    test "an admin creates an own manifest, adds a role and denies a permission", ctx do
      {:ok, lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/roles")

      assert has_element?(lv, "#group-manifest-source")
      refute has_element?(lv, "#new-role-form")

      lv |> element("#create-own-manifest-button") |> render_click()
      assert has_element?(lv, "#revert-manifest-button")

      lv
      |> form("#new-role-form", group_role: %{name: "muted"})
      |> render_submit()

      role = role_named(ctx.group, "muted")
      assert has_element?(lv, "#role-#{role.key}")

      lv |> element("#role-#{role.key}-post_values-deny") |> render_click()
      assert has_element?(lv, ~s(#role-#{role.key}-post_values-deny[aria-checked="true"]))
      assert :post_values in role_named(ctx.group, "muted").denied
    end

    test "members see the roles without controls", ctx do
      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/roles")

      assert has_element?(lv, "#role-everyone")
      assert has_element?(lv, ~s(#role-everyone-post_values-state[data-state="allow"]))
      refute has_element?(lv, "#create-own-manifest-button")
      refute has_element?(lv, "#role-everyone-post_values-allow")
    end

    test "direct groups have no roles tab", ctx do
      {:ok, direct} = Social.get_or_create_direct_group(ctx.owner, ctx.member)
      {:ok, lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{direct.id}/roles")

      refute has_element?(lv, "#group-panel-roles")
      refute has_element?(lv, "#group-tab-roles")
    end
  end

  describe "members tab" do
    test "an admin assigns a role, which takes effect for the member", ctx do
      {:ok, _manifest} = Social.create_own_group_manifest(ctx.owner, ctx.group)
      {:ok, muted} = Social.create_group_role(ctx.owner, ctx.group, %{"name" => "muted"})

      {:ok, _role} =
        Social.set_group_role_permission(ctx.owner, ctx.group, muted.key, :post_values, :deny)

      {:ok, member_lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")
      assert has_element?(member_lv, "#group-value-form")

      {:ok, lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/members")
      assert has_element?(lv, "#member-#{ctx.owner.id}-role-badge-admin")

      lv |> element("#member-#{ctx.member.id}-role-#{muted.key}") |> render_click()

      assert has_element?(lv, "#member-#{ctx.member.id}-role-badge-#{muted.key}")
      assert muted.key in Access.for_profile(ctx.member, ctx.group).role_keys

      assert eventually(fn -> has_element?(member_lv, "#group-value-composer-disabled") end)
      refute has_element?(member_lv, "#group-value-form")
    end

    test "members cannot assign roles or remove admins", ctx do
      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/members")

      refute has_element?(lv, "#member-#{ctx.owner.id}-roles-toggle")
      refute has_element?(lv, "#group-remove-member-#{ctx.owner.id}")
    end
  end

  describe "mentions" do
    test "the composer suggests members and roles", ctx do
      {:ok, lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/values")
      assert has_element?(lv, "#group-value-mentions")

      render_hook(lv, "suggest_mentions", %{"query" => "rl-m"})
      assert_reply(lv, %{items: [%{kind: "profile", name: "rl-member"}]})

      render_hook(lv, "suggest_mentions", %{"query" => "ev"})
      assert_reply(lv, %{items: [%{kind: "role", name: "everyone", everyone: true}]})
    end

    test "values highlight mentions and mark the ones that mention the viewer", ctx do
      {:ok, value} =
        Social.create_value(ctx.owner, ctx.group, %{"content" => "hi @rl-member and @everyone"})

      {:ok, lv, _html} = live_as(ctx.member_account, ~p"/groups/#{ctx.group.id}/values")

      assert has_element?(lv, ~s(#value-#{value.id}[data-mentions-me="true"]))
      assert has_element?(lv, "#value-mentions-me-#{value.id}")
      assert has_element?(lv, ~s(#value-#{value.id} .mention-profile[data-mention="rl-member"]))
      assert has_element?(lv, ~s(#value-#{value.id} .mention-role[data-mention="everyone"]))

      {:ok, owner_lv, _html} = live_as(ctx.owner_account, ~p"/groups/#{ctx.group.id}/values")
      refute has_element?(owner_lv, "#value-mentions-me-#{value.id}")
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

  defp live_as(account, path) do
    build_conn()
    |> log_in_account(account)
    |> live(path)
  end

  defp role_named(group, name) do
    group
    |> Access.effective_manifest()
    |> Map.fetch!(:roles)
    |> Enum.find(&(&1.name == name))
  end

  defp eventually(fun, attempts \\ 20)
  defp eventually(fun, attempts) when attempts <= 1, do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      receive do
      after
        25 -> eventually(fun, attempts - 1)
      end
    end
  end
end
