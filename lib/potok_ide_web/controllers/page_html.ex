defmodule PotokIdeWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use PotokIdeWeb, :html

  embed_templates "page_html/*"

  # The cards of the landing page's "what Potok can do" section.
  defp features do
    [
      %{
        id: "groups",
        icon: "hero-user-group",
        title: gettext("Groups and sub-groups"),
        text:
          gettext(
            "Branch out your groups as far as you need. Each one is public or private, a sub-group can inherit members and roles, and unread counts add up through the whole tree."
          )
      },
      %{
        id: "chat",
        icon: "hero-chat-bubble-left-right",
        title: gettext("Chat"),
        text:
          gettext(
            "Replies with a quote, threads for longer conversations, reactions and @mentions of people or whole roles. Links get a preview, and you can edit a message too."
          )
      },
      %{
        id: "calendar",
        icon: "hero-calendar-days",
        title: gettext("Calendar"),
        text:
          gettext(
            "One-off, all-day and repeating events, the answers Going, Maybe or Not going, and reminders. My calendar gathers the events of all your groups, and you can export them to Google, Apple or Outlook."
          )
      },
      %{
        id: "files",
        icon: "hero-paper-clip",
        title: gettext("Files"),
        text:
          gettext(
            "Up to 10 files per message, up to 100 MB each. Pictures, video and sound open right in the conversation, everything stays in the Files tab, and only members can download them."
          )
      },
      %{
        id: "roles",
        icon: "hero-shield-check",
        title: gettext("Roles and permissions"),
        text:
          gettext(
            "Administrator, All members and roles you make yourself, with 15 permissions: from writing and sending files to creating events and editing the group. A sub-group takes over its parent's roles or has its own."
          )
      },
      %{
        id: "apps",
        icon: "hero-squares-plus",
        title: gettext("Apps in a group"),
        text:
          gettext(
            "A group's description doesn't have to be just text. It can also be a small app, say a poll or a task list."
          )
      }
    ]
  end

  # The rows of the landing page's "always with you" section.
  defp perks do
    [
      %{
        id: "notifications",
        icon: "hero-bell",
        title: gettext("Notifications"),
        text: gettext("On your phone and in the browser, for messages, mentions and events.")
      },
      %{
        id: "phone",
        icon: "hero-device-phone-mobile",
        title: gettext("On your phone"),
        text: gettext("An app for your phone, or an install straight from the browser.")
      },
      %{
        id: "profiles",
        icon: "hero-users",
        title: gettext("Several profiles"),
        text: gettext("Personal and shared, say for a family or an association.")
      },
      %{
        id: "theme",
        icon: "hero-moon",
        title: gettext("Light and dark theme"),
        text: gettext("Or the way your system is set.")
      },
      %{
        id: "languages",
        icon: "hero-globe-alt",
        title: gettext("Three languages"),
        text: gettext("Srpski, English and polski.")
      }
    ]
  end
end
