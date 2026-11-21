defmodule PotokIde.Social.GroupTemplatesTest do
  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Social
  alias PotokIde.Social.{GroupTemplate, GroupTemplates}

  @attrs %{
    "name" => "Utakmica",
    "purpose" => "Rezultat i strelci.",
    "fields" => [
      %{"label" => "Domaćin", "kind" => "text", "required" => "true"},
      %{"label" => "Strelci", "kind" => "items"},
      %{"label" => "Ishod", "kind" => "choice", "options" => "pobeda\nnerešeno\nporaz"}
    ],
    "html" => "<h2>{{domacin}}</h2>{{#strelci}}<p>{{.}}</p>{{/strelci}}<p>{{ishod}}</p>"
  }

  setup do
    {_account, owner} = account_with_profile!("tpl-owner")
    {_account, member} = account_with_profile!("tpl-member")
    top = group_with_members!(owner, [member])
    middle = group_with_members!(owner, [], %{parent: top})
    bottom = group_with_members!(owner, [], %{parent: middle})
    %{owner: owner, member: member, top: top, middle: middle, bottom: bottom}
  end

  test "a template keeps its fields in shape, keys from their labels", ctx do
    assert {:ok, template} = GroupTemplates.create(ctx.owner, ctx.top, @attrs)

    assert [%{"key" => "domacin", "required" => true}, %{"key" => "strelci"}, ishod] =
             template.fields

    assert ishod["options"] == ["pobeda", "nerešeno", "poraz"]
    assert template.rev == 1
    assert template.creator_id == ctx.owner.id
  end

  test "serves its group and every group below, nearest first", ctx do
    {:ok, top} = GroupTemplates.create(ctx.owner, ctx.top, @attrs)
    {:ok, middle} = GroupTemplates.create(ctx.owner, ctx.middle, %{@attrs | "name" => "Sredina"})

    catalog = GroupTemplates.catalog(ctx.bottom, ctx.owner)
    assert Enum.map(catalog, & &1.template.id) == [middle.id, top.id]
    assert Enum.all?(catalog, &(not &1.own?))
    assert hd(catalog).owner == ctx.middle.name

    assert [%{own?: true}] = GroupTemplates.catalog(ctx.top, ctx.owner)
    assert GroupTemplates.get_for(ctx.bottom, top.id).id == top.id
    assert GroupTemplates.get_for(ctx.top, middle.id) == nil
  end

  test "a group above the viewer does not see is not named", ctx do
    {:ok, _template} = GroupTemplates.create(ctx.owner, ctx.top, @attrs)
    {_account, stranger} = account_with_profile!("tpl-stranger")
    assert [%{owner: nil}] = GroupTemplates.catalog(ctx.bottom, stranger)
  end

  test "a new version counts up, and its name stays its own in the group", ctx do
    {:ok, template} = GroupTemplates.create(ctx.owner, ctx.top, @attrs)

    assert {:ok, updated} =
             GroupTemplates.update(ctx.owner, ctx.top, template, %{"name" => "Meč"})

    assert updated.rev == 2

    {:ok, _other} = GroupTemplates.create(ctx.owner, ctx.top, %{@attrs | "name" => "Drugi"})

    assert {:error, changeset} =
             GroupTemplates.create(ctx.owner, ctx.top, %{@attrs | "name" => "meč"})

    assert "is already used by another template" in errors_on(changeset).name
  end

  test "the template must name only its fields, in tags it knows", ctx do
    assert {:error, changeset} =
             GroupTemplates.create(ctx.owner, ctx.top, %{@attrs | "html" => "{{autor}}"})

    assert [message] = errors_on(changeset).html
    assert message =~ "autor"

    two_keys = %{
      @attrs
      | "fields" => [%{"label" => "A", "kind" => "text"}, %{"label" => "a", "kind" => "url"}]
    }

    assert {:error, changeset} = GroupTemplates.create(ctx.owner, ctx.top, two_keys)
    assert errors_on(changeset).fields != []

    no_options = %{@attrs | "fields" => [%{"label" => "Ishod", "kind" => "choice"}], "html" => ""}
    assert {:error, _changeset} = GroupTemplates.create(ctx.owner, ctx.top, no_options)
  end

  test "only an editor makes, changes and moves them, not in a direct conversation", ctx do
    assert {:error, :not_permitted} = GroupTemplates.create(ctx.member, ctx.top, @attrs)

    {:ok, first} = GroupTemplates.create(ctx.owner, ctx.top, @attrs)
    {:ok, second} = GroupTemplates.create(ctx.owner, ctx.top, %{@attrs | "name" => "Drugi"})

    assert {:ok, :moved} = GroupTemplates.move(ctx.owner, ctx.top, second, :up)
    assert Enum.map(GroupTemplates.list_own(ctx.top), & &1.id) == [second.id, first.id]

    assert {:error, :not_found} = GroupTemplates.update(ctx.owner, ctx.middle, first, %{})
    assert {:ok, _deleted} = GroupTemplates.delete(ctx.owner, ctx.top, first)
    assert GroupTemplates.list_own(ctx.top) |> length() == 1

    {:ok, direct} = Social.get_or_create_direct_group(ctx.owner, ctx.member)
    assert {:error, :not_permitted} = GroupTemplates.create(ctx.owner, direct, @attrs)
  end

  test "a group holds a limited number", ctx do
    for n <- 1..GroupTemplates.max_per_group() do
      {:ok, _template} = GroupTemplates.create(ctx.owner, ctx.top, %{@attrs | "name" => "T#{n}"})
    end

    assert {:error, :too_many_templates} =
             GroupTemplates.create(ctx.owner, ctx.top, %{@attrs | "name" => "Previše"})
  end

  test "a key out of a label with letters of its own" do
    assert GroupTemplate.slug("Naslov vesti") == "naslov_vesti"
    assert GroupTemplate.slug("Đačka žurka č") == "djacka_zurka_c"
    assert GroupTemplate.slug("1. mesto") == "polje_1_mesto"
  end
end
