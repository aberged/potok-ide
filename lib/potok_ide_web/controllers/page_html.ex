defmodule PotokIdeWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use PotokIdeWeb, :html

  embed_templates "page_html/*"

  # The steps of the landing page's "how it flows" section, from the spring
  # (an account) to the mouth (what a group does with what it agreed on).
  defp flow_steps do
    [
      %{
        id: "identity",
        icon: "hero-finger-print",
        title: pgettext("landing step", "Identity"),
        tagline: gettext("You, once."),
        text:
          gettext(
            "One account and one email address. That's all Potok needs to know to recognize you."
          )
      },
      %{
        id: "profile",
        icon: "hero-user-circle",
        title: pgettext("landing step", "Profile"),
        tagline: gettext("How you show up."),
        text:
          gettext(
            "You can have several: a personal one, or a shared one, like an assembly's profile run by a few people."
          )
      },
      %{
        id: "group",
        icon: "hero-user-group",
        title: pgettext("landing step", "Group"),
        tagline: gettext("Where you gather."),
        text:
          gettext(
            "A plenum, an assembly, a working group. A subgroup can take over its parent's members and roles, so it doesn't start from scratch."
          )
      },
      %{
        id: "values",
        icon: "hero-chat-bubble-left-right",
        title: pgettext("landing step", "Values"),
        tagline: gettext("What comes out of it."),
        text:
          gettext(
            "Messages, decisions, events and files stay on record, so tomorrow everyone still knows what was agreed yesterday."
          )
      },
      %{
        id: "application",
        icon: "hero-sparkles",
        title: pgettext("landing step", "Application"),
        tagline: gettext("What gets done."),
        text:
          gettext(
            "Polls, task lists, the calendar and small apps inside the group turn an agreement into action."
          )
      }
    ]
  end

  defp why_points do
    [
      %{
        id: "data",
        icon: "hero-shield-check",
        title: gettext("Data belongs to the community"),
        text:
          gettext(
            "What a group writes stays with the group. We don't sell it and we don't turn it into a profile for advertisers."
          )
      },
      %{
        id: "order",
        icon: "hero-clock",
        title: gettext("In order, without an algorithm"),
        text:
          gettext(
            "Messages arrive in the order they were written. Nobody decides for you what matters today."
          )
      },
      %{
        id: "riverbed",
        icon: "hero-rectangle-group",
        title: gettext("One riverbed"),
        text:
          gettext(
            "Chat, calendar, files, roles and small apps in one place, connected on purpose rather than by the habit of everyone using the same thing."
          )
      }
    ]
  end
end
