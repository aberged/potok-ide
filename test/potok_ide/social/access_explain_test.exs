defmodule PotokIde.Social.AccessExplainTest do
  @moduledoc """
  `Access.explain/2` tells why, by the same rules as `Access.can?/2`: every
  combination of what two roles and Everyone say of a permission, and of which
  roles are held, agrees with the verdict.
  """

  use ExUnit.Case, async: true

  alias PotokIde.Social.{Access, GroupManifest, GroupRole}

  @cells [:allow, :deny, :none]

  defp role(key, cell) do
    case cell do
      :allow -> %GroupRole{key: key, name: key, allowed: [:post_values], denied: []}
      :deny -> %GroupRole{key: key, name: key, allowed: [], denied: [:post_values]}
      :none -> %GroupRole{key: key, name: key, allowed: [], denied: []}
    end
  end

  test "the first element is always can?/2" do
    for a <- @cells,
        b <- @cells,
        everyone <- [:allow, :none],
        held <- [[], ["a"], ["b"], ["a", "b"], ["admin"], ["admin", "b"]] do
      manifest = %GroupManifest{
        roles: [
          %GroupRole{key: "admin", name: "admin"},
          role("a", a),
          role("b", b),
          role("everyone", everyone)
        ]
      }

      access = Access.from_facts(manifest, {:member, held})
      {verdict, _why} = Access.explain(access, :post_values)

      assert verdict == Access.can?(access, :post_values),
             "a=#{a} b=#{b} everyone=#{everyone} held=#{inspect(held)}"
    end
  end

  test "a denial names the roles that deny and those it wins over" do
    manifest = %GroupManifest{
      roles: [role("a", :allow), role("b", :deny), role("everyone", :allow)]
    }

    access = Access.from_facts(manifest, {:member, ["a", "b"]})

    assert Access.explain(access, :post_values) ==
             {false, {:denied_by, ["b"], ["a", "everyone"]}}

    assert Access.explain(Access.from_facts(manifest, {:member, ["a"]}), :post_values) ==
             {true, {:allowed_by, ["a", "everyone"]}}
  end

  test "Everyone cannot deny, admin holds all, and outsiders hold nothing" do
    manifest = %GroupManifest{
      roles: [
        %GroupRole{key: "admin", name: "admin"},
        %GroupRole{key: "everyone", name: "everyone", denied: [:post_values]}
      ]
    }

    assert Access.explain(Access.from_facts(manifest, {:member, []}), :post_values) ==
             {false, :not_allowed}

    assert Access.explain(Access.from_facts(manifest, {:member, ["admin"]}), :post_values) ==
             {true, :admin}

    assert Access.explain(Access.from_facts(manifest, {:outsider, false}), :post_values) ==
             {false, :not_member}
  end
end
