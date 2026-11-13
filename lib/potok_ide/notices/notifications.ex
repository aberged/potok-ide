defmodule PotokIde.Notices.Notifications do
  @moduledoc """
  The push of a group's notice, built in every language for the language of
  each device. It names the group, not the author: followers hear from the
  group. It opens the notice on the group's page, which works for whichever
  profile the account uses when it is opened, as long as that one sees the
  group.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  import PotokIde.PushNotifications, only: [localized: 1]

  alias PotokIde.Notices.GroupNotice
  alias PotokIde.PlainText
  alias PotokIde.Social.Group

  @excerpt_length 120

  def notice(%Group{} = group, %GroupNotice{} = notice) do
    body = PlainText.excerpt(notice.body, :markdown, @excerpt_length)

    localized(fn ->
      %{
        title: dgettext("notifications", "Notice from %{group}", group: group.name),
        body: body || group.name,
        # One per notice, so a second one never replaces the first.
        tag: "group-#{group.id}-notice-#{notice.id}",
        url: "/groups/#{group.id}/notices?notice=#{notice.id}",
        badge: PotokIdeWeb.Avatars.group_badge_url(group)
      }
    end)
  end
end
