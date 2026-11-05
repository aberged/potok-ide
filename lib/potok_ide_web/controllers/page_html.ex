defmodule PotokIdeWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use PotokIdeWeb, :html

  alias PotokIdeWeb.DomainCopy

  embed_templates "page_html/*"

  # A text of the domain map, with its code and its links to entities.
  attr :text, :string, required: true

  defp domain_text(assigns) do
    ~H"""
    <.domain_part :for={part <- DomainCopy.parts(@text)} part={part} />
    """
  end

  # On one line each: whitespace here would show between the parts of a sentence.
  attr :part, :any, required: true

  defp domain_part(%{part: {:text, text}} = assigns) do
    assigns = assign(assigns, :text, text)
    ~H"{@text}"
  end

  defp domain_part(%{part: {:code, name}} = assigns) do
    assigns = assign(assigns, :name, name)
    ~H"<code>{@name}</code>"
  end

  defp domain_part(%{part: {:entity, id, label}} = assigns) do
    assigns = assign(assigns, id: id, label: label)
    ~H|<button type="button" class="dm-ent" data-entity={@id}>{@label}</button>|
  end

  # What a description can do as an app. Plain words, like the rest of the
  # page: this is an overview, so it names no calls of the app API.
  defp domain_apps(assigns) do
    assigns = assign(assigns, :apps, DomainCopy.apps())

    ~H"""
    <section id="domain-apps" class="dm-apps">
      <h2 class="font-brand">{@apps.title}</h2>
      <p class="dm-apps-lead"><.domain_text text={@apps.lead} /></p>

      <ol id="domain-apps-flow" class="dm-flow">
        <%= for {step, link} <- @apps.flow do %>
          <li class="dm-flow-step">{step}</li>
          <li :if={link} class="dm-flow-link" aria-hidden="true">
            <span>{link}</span>
            <.icon name="hero-arrow-right" class="size-4" />
          </li>
        <% end %>
      </ol>

      <div id="domain-apps-capabilities" class="dm-capabilities">
        <article :for={capability <- @apps.capabilities}>
          <span class="lp-icon"><.icon name={capability.icon} class="size-5" /></span>
          <div>
            <h3>{capability.title}</h3>
            <p><.domain_text text={capability.text} /></p>
          </div>
        </article>
      </div>

      <h3 class="dm-limits-title">{@apps.limits_title}</h3>
      <ul id="domain-apps-limits" class="dm-limits">
        <li :for={limit <- @apps.limits}>{limit}</li>
      </ul>
    </section>
    """
  end

  attr :edges, :list, required: true
  attr :entities, :map, required: true

  defp domain_links(assigns) do
    ~H"""
    <ul class="dm-rows">
      <li :for={edge <- @edges} class="dm-row">
        <button type="button" class="dm-ent" data-entity={edge.from}>
          {@entities[edge.from].name}
        </button>
        <span class="dm-field">{Enum.join(edge.columns, " + ")}</span>
        <span>
          →
          <button type="button" class="dm-ent" data-entity={edge.to}>
            {@entities[edge.to].name}
          </button>
        </span>
      </li>
    </ul>
    """
  end

  defp blocking_keys(edges), do: Enum.filter(edges, &(&1[:rule] == :restrict))
  defp soft_links(edges), do: Enum.filter(edges, &(&1.kind == :soft))

  defp composite_keys(edges) do
    Enum.filter(edges, &(&1.kind == :key and length(&1.columns) > 1))
  end

  # The heart of the domain map, on the landing page: a group contains values,
  # and a value opens a thread, which is a group again.
  defp domain_loop(assigns) do
    assigns = assign(assigns, :words, DomainCopy.core_labels())

    ~H"""
    <svg viewBox="0 0 320 124" class="lp-domain-loop" aria-hidden="true">
      <defs>
        <marker
          id="lp-domain-arrow"
          markerUnits="userSpaceOnUse"
          markerWidth="10"
          markerHeight="10"
          refX="9"
          refY="5"
          orient="auto"
        >
          <path d="M0 .8L9 5L0 9.2z" />
        </marker>
      </defs>
      <rect x="2" y="39" width="96" height="46" rx="11" />
      <text x="50" y="67">{DomainCopy.entity_name("Group")}</text>
      <rect x="222" y="39" width="96" height="46" rx="11" />
      <text x="270" y="67">{DomainCopy.entity_name("Value")}</text>
      <path d="M99 51H221" marker-end="url(#lp-domain-arrow)" />
      <text x="160" y="41">{@words.contains}</text>
      <path d="M221 73H99" marker-end="url(#lp-domain-arrow)" />
      <text x="160" y="95">{@words.opens_thread}</text>
    </svg>
    """
  end

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
        title: gettext("Latin and Cyrillic"),
        text: gettext("Serbian in both scripts, and English.")
      }
    ]
  end
end
