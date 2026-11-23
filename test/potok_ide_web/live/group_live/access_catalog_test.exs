defmodule PotokIdeWeb.GroupLive.Show.AccessCatalogTest do
  @moduledoc """
  The access overview says what the page does: a made-up viewer with someone's
  roles gets the same access and the same verdicts as that someone, its
  counts of holders agree with the query that sends things to them, and a
  reason always points the way of its verdict.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Social
  alias PotokIde.Social.{Access, AccessOverview}
  alias PotokIdeWeb.GroupLive.Show.{AccessCatalog, PageRules}

  setup do
    {_, owner} = account_with_profile!("ac-owner")
    {_, savet} = account_with_profile!("ac-savet")
    {_, podstanar} = account_with_profile!("ac-podstanar")
    {_, both} = account_with_profile!("ac-both")
    {_, plain} = account_with_profile!("ac-plain")
    {_, outsider} = account_with_profile!("ac-outsider")

    {:ok, group} =
      Social.create_group(owner, Social.get_root_group!(), %{
        "name" => "ac-group",
        "description" => "",
        "description_format" => :markdown,
        "is_public" => true,
        "has_public_chat" => true
      })

    for member <- [savet, podstanar, both, plain], do: add_member!(owner, group, member)

    {:ok, _} = Social.create_own_group_manifest(owner, group)
    {:ok, r_savet} = Social.create_group_role(owner, group, %{"name" => "savet"})
    {:ok, r_podstanar} = Social.create_group_role(owner, group, %{"name" => "podstanar"})

    for permission <- [:delete_values, :remove_members, :manage_join_requests] do
      {:ok, _} = Social.set_group_role_permission(owner, group, r_savet.key, permission, :allow)
    end

    {:ok, _} =
      Social.set_group_role_permission(owner, group, r_podstanar.key, :post_values, :deny)

    {:ok, _} =
      Social.set_group_role_permission(owner, group, r_podstanar.key, :delete_values, :deny)

    {:ok, _} = Social.assign_group_member_role(owner, group, savet.id, r_savet.key)
    {:ok, _} = Social.assign_group_member_role(owner, group, podstanar.id, r_podstanar.key)
    {:ok, _} = Social.assign_group_member_role(owner, group, both.id, r_savet.key)
    {:ok, _} = Social.assign_group_member_role(owner, group, both.id, r_podstanar.key)

    group = Social.get_group!(group.id)

    %{
      group: group,
      people: [owner, savet, podstanar, both, plain],
      outsider: outsider,
      facts: PageRules.facts(group)
    }
  end

  defp same_access?(a, b) do
    a.member? == b.member? and a.admin? == b.admin? and
      Enum.sort(a.role_keys) == Enum.sort(b.role_keys) and a.permissions == b.permissions
  end

  test "a made-up viewer with someone's roles is that someone", ctx do
    for profile <- ctx.people ++ [ctx.outsider] do
      access = Access.for_profile(profile, ctx.group)
      real = AccessCatalog.real_viewer(access, profile)
      made = AccessCatalog.viewer(access.manifest, AccessCatalog.spec_of(real))

      assert same_access?(real.access, made.access), profile.username

      for capability <- AccessCatalog.capabilities() do
        assert AccessCatalog.check(capability, real, ctx.group, ctx.facts) ==
                 AccessCatalog.check(capability, made, ctx.group, ctx.facts),
               "#{profile.username}: #{capability}"
      end
    end
  end

  test "a denial wins: savet and podstanar together cannot write or delete", ctx do
    [_owner, _savet, _podstanar, both | _] = ctx.people
    access = Access.for_profile(both, ctx.group)
    viewer = AccessCatalog.real_viewer(access, both)

    assert {false, {:explain, {:denied_by, [_], _allow}}} =
             AccessCatalog.check(:post, viewer, ctx.group, ctx.facts)

    assert {false, _} = AccessCatalog.check(:delete_values, viewer, ctx.group, ctx.facts)
    assert {true, _} = AccessCatalog.check(:remove_members, viewer, ctx.group, ctx.facts)
  end

  test "holders are counted as the query that reaches them finds them", ctx do
    manifest = Access.effective_manifest(ctx.group)
    sets = AccessOverview.role_sets(ctx.group)

    for permission <- AccessCatalog.strong_permissions() ++ [:post_values, :react] do
      assert AccessCatalog.holders(manifest, sets, &Access.can?(&1, permission)) ==
               length(Access.profile_ids_with_permission(ctx.group, permission)),
             "#{permission}"
    end

    power = Map.new(AccessCatalog.power(manifest, sets), &{&1.key, &1.count})
    assert power[:admin] == 1
    # The owner and savet; "both" is denied by podstanar.
    assert power[:delete_values] == 2
  end

  test "every reason points the way of its verdict, for every column", ctx do
    groups = [
      ctx.group,
      %{ctx.group | is_public: false, has_public_chat: false},
      %{ctx.group | has_public_chat: false},
      %{ctx.group | elects_admins: true}
    ]

    manifest = Access.effective_manifest(ctx.group)

    for group <- groups,
        column <- AccessCatalog.columns(manifest, group),
        viewer = AccessCatalog.viewer(manifest, column.spec),
        capability <- AccessCatalog.capabilities() do
      {ok, reason} = AccessCatalog.check(capability, viewer, group, ctx.facts)

      assert AccessCatalog.positive?(reason) == ok,
             "#{column.key} #{capability}: #{inspect({ok, reason})}"

      assert is_binary(AccessCatalog.reason_text(reason, manifest))
    end
  end

  test "a guest sees the card of a public group and nothing else", ctx do
    manifest = Access.effective_manifest(ctx.group)
    guest = AccessCatalog.viewer(manifest, :guest)

    assert {true, :guest_preview} = AccessCatalog.check(:see_group, guest, ctx.group, ctx.facts)

    for capability <- AccessCatalog.capabilities() -- [:see_group, :read_description] do
      assert {false, _} = AccessCatalog.check(capability, guest, ctx.group, ctx.facts)
    end
  end
end
