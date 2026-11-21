defmodule PotokIde.Social.AppRefreshTest do
  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{AppBuilds, AppData, Group, GroupPresets, Value}

  setup do
    {_account, owner} = account_with_profile!("refresh-owner")
    {_account, member} = account_with_profile!("refresh-member")
    parent = group_with_members!(owner, [member])
    %{owner: owner, member: member, parent: parent}
  end

  defp create(ctx, preset) do
    {:ok, made} =
      Social.create_group_from_preset(
        ctx.owner,
        ctx.parent,
        preset,
        Map.merge(GroupPresets.defaults(preset, ctx.parent), %{"name" => "Grupa #{preset}"})
      )

    made
  end

  # An earlier build of `app`, as Potok knows it: another text with its tag.
  defp older(app) do
    ~s(<meta name="potok-app" content="#{app}">\n<!-- earlier -->\n) <>
      AppBuilds.current_html(app)
  end

  defp put_older(ctx, group, app) do
    {:ok, group} = Social.update_group(ctx.owner, group, %{"description" => older(app)})
    group
  end

  test "an older Feed becomes the newest, and its .feed's FeedCreator goes along", ctx do
    %{group: feed, feed: desk} = create(ctx, "feed")
    feed = put_older(ctx, feed, "potok-feed")
    desk = put_older(ctx, desk, "potok-feed-creator")
    Social.subscribe_group(feed)

    assert {:ok, %{group: refreshed, app: "potok-feed", along: [along]}} =
             Social.refresh_app(ctx.owner, feed)

    assert refreshed.description == AppBuilds.current_html("potok-feed")
    assert refreshed.preset == :feed
    assert refreshed.uses_api
    assert along.id == desk.id
    assert Repo.get!(Group, desk.id).description == AppBuilds.current_html("potok-feed-creator")

    feed_id = feed.id
    assert_receive {:group_updated, ^feed_id}
  end

  test "a Feed whose FeedCreator is new already refreshes alone", ctx do
    %{group: feed} = create(ctx, "feed")
    feed = put_older(ctx, feed, "potok-feed")

    assert {:ok, %{along: []}} = Social.refresh_app(ctx.owner, feed)
  end

  test "the app's data stay where they are", ctx do
    %{group: form} = create(ctx, "questionnaire")
    {:ok, _config} = AppData.save_config(ctx.owner, form, nil, %{"rules" => %{}}, 0)

    {:ok, answer} =
      Social.create_data_value(ctx.owner, form, %{"content" => "data:", "data" => %{"a" => 1}})

    form = put_older(ctx, form, "potok-forme")

    assert {:ok, %{group: refreshed}} = Social.refresh_app(ctx.owner, form)

    assert AppData.get_config(refreshed, nil) != nil
    assert Repo.get!(Value, answer.id).alt_description_id == nil
  end

  test "an app in an alternative description too", ctx do
    group = group_with_members!(ctx.owner, [], %{parent: ctx.parent})

    {:ok, alt} =
      Social.create_alt_description(ctx.owner, group, %{
        "name" => "Glasanja",
        "uses_api" => "true",
        "description" => older("potok-glasanje")
      })

    Social.subscribe_group(group)

    assert {:ok, %{alt: refreshed, app: "potok-glasanje", along: []}} =
             Social.refresh_app(ctx.owner, group, alt)

    assert refreshed.description == AppBuilds.current_html("potok-glasanje")
    group_id = group.id
    assert_receive {:alt_descriptions_updated, ^group_id}
  end

  test "what stands in the way", ctx do
    %{group: map} = create(ctx, "map")
    assert {:error, :up_to_date} = Social.refresh_app(ctx.owner, map)

    own =
      group_with_members!(ctx.owner, [], %{"uses_api" => true, "description" => "<p>moja</p>"})

    assert {:error, :not_ours} = Social.refresh_app(ctx.owner, own)

    text = group_with_members!(ctx.owner, [], %{"description" => older("potok-mapa")})
    assert {:error, :not_ours} = Social.refresh_app(ctx.owner, text)

    map = put_older(ctx, map, "potok-mapa")
    assert {:error, :not_permitted} = Social.refresh_app(ctx.member, map)
    assert Repo.get!(Group, map.id).description == older("potok-mapa")
  end
end
