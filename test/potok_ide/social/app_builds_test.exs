defmodule PotokIde.Social.AppBuildsTest do
  use ExUnit.Case, async: true

  alias PotokIde.Social.AppBuilds

  defp build(app), do: AppBuilds.current_html(app)

  test "knows every build in priv/apps, so a sync that forgot builds.json fails here" do
    for app <- AppBuilds.apps() do
      assert AppBuilds.current(app) in AppBuilds.known(app),
             "#{app}: run mix potok.app_builds (mix potok.sync_apps does) and commit builds.json"
    end
  end

  test "knows each build Potok shipped as the newest of its app" do
    for app <- AppBuilds.apps() do
      assert AppBuilds.status(build(app)) == {:current, app}
    end
  end

  test "a copy that went through a form, with other line endings and space, is the same build" do
    html = build("potok-feed")
    through_a_form = "  " <> String.replace(html, "\n", "\r\n") <> "\r\n\n"

    assert AppBuilds.status(through_a_form) == {:current, "potok-feed"}
  end

  test "the tag alone makes no other build, and names one Potok never saw" do
    html = build("potok-forme")
    tagged = ~s(<meta name="potok-app" content="potok-forme">\n) <> html

    assert AppBuilds.fingerprint(tagged) == AppBuilds.fingerprint(html)
    assert AppBuilds.status(tagged) == {:current, "potok-forme"}

    changed = String.replace(tagged, "</style>", "</style><!-- newer -->", global: false)
    assert AppBuilds.status(changed) == {:outdated, "potok-forme"}
  end

  test "an app of someone's own is none of Potok's" do
    assert AppBuilds.identify("<p>moja aplikacija</p>") == nil
    assert AppBuilds.status("<p>moja aplikacija</p>") == nil
    assert AppBuilds.identify(~s(<meta name="potok-app" content="tudja">)) == nil
    assert AppBuilds.identify(nil) == nil
  end

  test "says which preset each app comes with" do
    assert AppBuilds.preset("potok-feed") == "feed"
    assert AppBuilds.preset("potok-mleko") == "orders"
    assert AppBuilds.preset("potok-feed-creator") == nil
  end
end
