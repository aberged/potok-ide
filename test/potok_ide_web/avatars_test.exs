defmodule PotokIdeWeb.AvatarsTest do
  use ExUnit.Case, async: true

  alias PotokIde.Social.Group
  alias PotokIdeWeb.Avatars
  alias PotokIdeWeb.GroupLive.Show.Components

  defp signature(url) do
    [_, signature] = Regex.run(~r/[?&]s=([^&]+)/, url)
    signature
  end

  test "a group's address carries its version and a signature of its own" do
    url = Avatars.group_avatar_url(%{id: 12, updated_at: ~U[2026-11-12 10:00:00Z]})

    v = DateTime.to_unix(~U[2026-11-12 10:00:00Z])
    assert url =~ ~r"\A/avatar/group/12\?v=#{v}&s=[\w-]{16}\z"
    assert Avatars.group_signature?(12, signature(url))
    refute Avatars.group_signature?(13, signature(url))
    refute Avatars.group_signature?(12, nil)
    assert signature(Avatars.group_badge_url(%{id: 12})) == signature(url)
  end

  test "signs only the pictures of the groups it is given" do
    signed = signature(Avatars.group_avatar_url(%{id: 12}))

    html =
      ~s|<img src="/avatar/group/12?p=170"><img src="/avatar/group/12">| <>
        ~s|<img src="/avatar/group/123"><img src="/avatar/group/7">|

    assert Avatars.sign_group_pictures(html, 12) ==
             ~s|<img src="/avatar/group/12?p=170&amp;s=#{signed}">| <>
               ~s|<img src="/avatar/group/12?s=#{signed}">| <>
               ~s|<img src="/avatar/group/123"><img src="/avatar/group/7">|

    assert Avatars.sign_group_pictures(html, nil) == html
    assert Avatars.sign_group_pictures(html, []) == html
  end

  test "leaves an address that is signed already" do
    html = ~s|<img src="/avatar/group/12?p=1&amp;s=abc">|
    assert Avatars.sign_group_pictures(html, [12]) == html
  end

  test "a group's description shows its own picture by a signed address" do
    group = %Group{
      id: 12,
      uses_api: false,
      description: ~s|<p><img src="/avatar/group/12?p=170"></p>|,
      description_format: :html
    }

    assert Components.description_html(group) =~
             ~s|src="/avatar/group/12?p=170&amp;s=#{signature(Avatars.group_avatar_url(group))}"|
  end
end
