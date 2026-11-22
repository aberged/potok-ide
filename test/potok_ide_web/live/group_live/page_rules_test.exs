defmodule PotokIdeWeb.GroupLive.Show.PageRulesTest do
  @moduledoc """
  The rules of what the group page offers a viewer, asked without the
  database: the access overview asks them about made-up viewers.
  """

  use ExUnit.Case, async: true

  alias PotokIde.Social.{Access, Group, GroupManifest, GroupRole}
  alias PotokIdeWeb.GroupLive.Show.PageRules

  @manifest %GroupManifest{
    roles: [
      %GroupRole{key: "admin", name: "admin"},
      %GroupRole{key: "editor", name: "editor", allowed: [:edit_group]},
      %GroupRole{key: "everyone", name: "everyone", allowed: [:post_values]}
    ]
  }

  # Facts no rule here may ask for: a rule that asks fails the test.
  @no_facts %{
    public_events?: &__MODULE__.asked/0,
    public_polls?: &__MODULE__.asked/0,
    any_polls?: &__MODULE__.asked/0,
    apps_or_processes?: &__MODULE__.asked/0
  }

  def asked, do: flunk("a rule asked for a fact it does not need")

  defp member(keys \\ []), do: Access.from_facts(@manifest, {:member, keys})
  defp outsider, do: Access.from_facts(@manifest, {:outsider, false})

  defp group(attrs \\ %{}) do
    struct(%Group{id: 7, parent_id: 1, is_public: true, home_page: :description}, attrs)
  end

  test "the Members and Files tabs are only for members of a group under the root" do
    assert PageRules.tab("members", group(), member(), @no_facts) == "members"
    assert PageRules.tab("members", group(), outsider(), @no_facts) == "group_home"
    assert PageRules.tab("files", group(), member(), @no_facts) == "files"
    assert PageRules.tab("files", group(), outsider(), @no_facts) == "group_home"

    root = group(%{parent_id: nil, is_root: true})
    refute PageRules.members?(root, member())
    assert PageRules.tab("members", root, member(), @no_facts) == "sub_groups"
  end

  test "tabs that take a permission follow the roles" do
    assert PageRules.tab("edit_group", group(), member(["editor"]), @no_facts) == "edit_group"
    assert PageRules.tab("edit_group", group(), member(), @no_facts) == "group_home"
    assert PageRules.tab("edit_group", group(), member(["admin"]), @no_facts) == "edit_group"
    assert PageRules.tab("roles", group(), member(), @no_facts) == "roles"
    assert PageRules.tab("roles", group(), outsider(), @no_facts) == "group_home"
  end

  test "a fact is asked only when the rule needs it, as a boolean or a function" do
    facts = %{@no_facts | public_events?: true, public_polls?: false}

    assert PageRules.calendar?(group(), member(), @no_facts)
    assert PageRules.calendar?(group(), outsider(), facts)
    refute PageRules.calendar?(group(%{is_public: false}), outsider(), @no_facts)
    refute PageRules.polls_tab?(group(), outsider(), facts)
    assert PageRules.polls_section?(group(), member(), %{facts | any_polls?: fn -> true end})
    refute PageRules.processes?(group(), outsider(), @no_facts)
    assert PageRules.processes?(group(), member(["editor"]), @no_facts)
  end

  test "who sees the group at all" do
    assert PageRules.sees_group?(group(), outsider())
    refute PageRules.sees_group?(group(%{is_public: false}), outsider())
    assert PageRules.sees_group?(group(%{is_public: false}), member())
  end
end
