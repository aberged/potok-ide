defmodule PotokIdeWeb.PushChannels do
  @moduledoc """
  The Android notification channels, one per kind of push
  (`PotokIde.PushNotifications.FCM.channel_for/1`), named in the page's
  language. The root layout carries them, and the app creates or renames
  them each time it starts (`NativePushManager` in `assets/js/app.js`), so
  each kind can be silenced or given its own sound in the phone's settings,
  as in other messaging apps.

  Android keeps a channel's importance once it exists; only its name and
  description follow the language.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  def list do
    [
      %{
        id: "potok-messages",
        name: dgettext("notifications", "Messages"),
        description: dgettext("notifications", "New messages in your groups and conversations"),
        importance: 4
      },
      %{
        id: "potok-mentions",
        name: dgettext("notifications", "Mentions and replies"),
        description:
          dgettext(
            "notifications",
            "When someone mentions you, replies to you or reacts to your message"
          ),
        importance: 5
      },
      %{
        id: "potok-calendar",
        name: dgettext("notifications", "Calendar"),
        description: dgettext("notifications", "New events, changes and reminders"),
        importance: 4
      },
      %{
        id: "potok-polls",
        name: dgettext("notifications", "Polls"),
        description: dgettext("notifications", "New polls, reminders to vote and their end"),
        importance: 3
      },
      %{
        id: "potok-notices",
        name: dgettext("notifications", "Group notices"),
        description: dgettext("notifications", "Notices of the groups you follow"),
        importance: 3
      },
      %{
        id: "potok-invitations",
        name: dgettext("notifications", "Invitations and requests"),
        description: dgettext("notifications", "Invitations, your requests and your roles"),
        importance: 4
      },
      %{
        id: "potok-apps",
        name: dgettext("notifications", "Apps and processes"),
        description:
          dgettext("notifications", "Form responses and what processes send to your role"),
        importance: 4
      },
      %{
        id: "potok-default",
        name: dgettext("notifications", "Other"),
        description: dgettext("notifications", "Everything else from Potok"),
        importance: 3
      }
    ]
  end

  def json, do: Jason.encode!(list())
end
