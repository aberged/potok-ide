defmodule PotokIde.Notices.Notifications do
  @moduledoc """
  The push of a group's notice, built in every language for the language of
  each device. It names the group, not the author: followers hear from the
  group. It opens the notice on the group's page, which works for whichever
  profile the account uses when it is opened, as long as that one sees the
  group.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  import PotokIde.PushNotifications, only: [localized: 1, expires_at: 1, now_ms: 0]

  alias PotokIde.Notices.GroupNotice
  alias PotokIde.PlainText
  alias PotokIde.Social.Group

  @excerpt_length 120

  # As a channel's post in messaging apps: the group's name and picture, its
  # words, and the label "Notice" under the title where the phone shows one.
  def notice(%Group{} = group, %GroupNotice{} = notice) do
    body = PlainText.excerpt(notice.body, :markdown, @excerpt_length)

    base = %{
      kind: "notice",
      # One per notice, so a second one never replaces the first.
      tag: "group-#{group.id}-notice-#{notice.id}",
      url: "/groups/#{group.id}/notices?notice=#{notice.id}",
      group_id: group.id,
      icon: PotokIdeWeb.Avatars.group_badge_url(group),
      timestamp: now_ms(),
      expires_at: expires_at(:week)
    }

    localized(fn ->
      Map.merge(base, %{
        title: group.name,
        body: body || group.name,
        label: dgettext("notifications", "Notice")
      })
    end)
  end
end
