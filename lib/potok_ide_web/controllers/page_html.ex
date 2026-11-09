defmodule PotokIdeWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use PotokIdeWeb, :html

  alias PotokIdeWeb.DomainCopy
  alias PotokIdeWeb.StackCopy

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
            "Branch out your groups as far as you need. Each one is public or private, a sub-group can inherit members and roles, and unread counts add up through the whole tree. You can react to a group just as you do to a message. You start a new group from a ready setup: chat, folder, announcements, feed, polls, form or page. You can then narrow the list of sub-groups by kind, to the groups you are in, or to those you created. You can put a group on a map, with a pin you pick for it."
          )
      },
      %{
        id: "chat",
        icon: "hero-chat-bubble-left-right",
        title: gettext("Chat"),
        text:
          gettext(
            "Replies with a quote, threads for longer conversations, reactions and @mentions of people or whole roles. Links get a preview, and you can edit a message too. You can open the chat of a public group, so that those who are not members write there too. You can start a poll right in the chat, and everyone votes from there."
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
            "Up to 10 files per message, up to 100 MB each. Pictures, video and sound open right in the conversation, everything stays in the Files tab, and only members can download them, apart from the pictures you put in a group's description and the files of an open chat. In the Android app you send a GIF or a sticker straight from the keyboard."
          )
      },
      %{
        id: "roles",
        icon: "hero-shield-check",
        title: gettext("Roles and permissions"),
        text:
          gettext(
            "Administrator, All members and roles you make yourself, with 19 permissions: from writing and sending files to creating events and editing the group. A sub-group takes over its parent's roles or has its own."
          )
      },
      %{
        id: "apps",
        icon: "hero-squares-plus",
        title: gettext("Apps in a group"),
        text:
          gettext(
            "A group's description doesn't have to be just text. It can also be a small app, say a form, a poll or a task list. Or pick a template, say news or an event, and fill in the fields."
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
        text:
          gettext(
            "On your phone and in the browser, for messages, mentions, events, polls and form responses."
          )
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

  # A tool's logo in its own hue (`--st-<tool>` in app.css). It always sits beside
  # the tool's name, so screen readers skip it. From Simple Icons (CC0). BEAM has
  # no logo of its own and takes Erlang's, which the page says.
  attr :tool, :string, required: true

  defp stack_logo(assigns) do
    assigns = assign(assigns, :path, logo_path(assigns.tool))

    ~H"""
    <span class="st-logo" style={"--tc:var(--st-#{@tool})"} aria-hidden="true">
      <svg viewBox="0 0 24 24"><path d={@path} /></svg>
    </span>
    """
  end

  defp logo_path("beam") do
    "M8.859 7.889c.154-1.863 1.623-3.115 3.344-3.119 1.734.004 2.986 1.256 3.029 3.119zm12.11 11.707c.802-.86 1.52-1.872 2.172-3.03l-3.616-1.807c-1.27 2.064-3.127 3.965-5.694 3.977-3.738-.012-5.206-3.208-5.198-7.322h13.966c.019-.464.019-.68 0-.904.091-2.447-.558-4.504-1.737-6.106l-.007.005H24v15.186h-3.039zm-17.206-.001C1.901 17.62.811 14.894.813 11.64c-.002-2.877.902-5.35 2.456-7.232H0v15.187h3.761Z"
  end

  defp logo_path("elixir") do
    "M19.793 16.575c0 3.752-2.927 7.426-7.743 7.426-5.249 0-7.843-3.71-7.843-8.29 0-5.21 3.892-12.952 8-15.647a.397.397 0 0 1 .61.371 9.716 9.716 0 0 0 1.694 6.518c.522.795 1.092 1.478 1.763 2.352.94 1.227 1.637 1.906 2.644 3.842l.015.028a7.107 7.107 0 0 1 .86 3.4z"
  end

  defp logo_path("phoenix") do
    "m9.012 15.241-.188-.036c-1.34-.248-2.186-1.06-2.588-2.334-.25-.794.204-1.38 1.038-1.416.682-.032 1.15.36 1.562.816.532.588 1.02 1.216 1.542 1.814.754.86 1.64 1.412 2.854 1.24a5.404 5.404 0 0 0 2.86-1.308c.124-.108.26-.2.392-.302l-.084-.098a6.034 6.034 0 0 1-2.12.252c-1.092-.054-2.132-.282-3.064-.882-.848-.548-1.476-1.28-1.774-2.26-.24-.79.252-1.344 1.072-1.23.313.049.606.187.842.398.2.168.39.346.594.51.958.77 2.294.812 3.508-.022-1.996-.01-3.354-1.108-4.548-2.5-.466-.544-.922-1.1-1.4-1.636-.92-1.038-1.944-1.952-3.346-2.264-1.79-.398-3.518-.136-5.176.622A4.214 4.214 0 0 0 0 5.217h.352c.836-.022 1.464.35 1.916 1.034.328.498.482 1.06.6 1.64.176.86.086 1.734.188 2.598.26 2.22 1.394 3.768 3.506 4.56.774.292 1.568.39 2.45.19v.002zM3.674 5.113c-.334.084-.6-.05-.874-.328.47-.118.886-.164 1.332-.18a.562.562 0 0 1-.458.508zm10.938 12.96c-.03-.212-.212-.306-.356-.42-.634-.492-1.378-.668-2.164-.682a4.08 4.08 0 0 1-1.378-.208c-.204-.076-.43-.174-.426-.436.006-.266.238-.34.448-.404.174-.052.352-.084.548-.13-.5-.32-.988-.364-1.636-.102-1.024.41-2.032.36-3.052-.006-.574-.208-1.086-.534-1.618-.824l-.026.02c.44.722 1.038 1.304 1.71 1.8 1.296.96 2.712 1.53 4.37 1.276a22.8 22.8 0 0 1 1.614-.19c.676-.054 1.32.136 1.966.308v-.002zm-3.124-10.37c-.036-.026-.07-.09-.144-.024a5.258 5.258 0 0 0 2.284 1.776c1.488.604 3 .708 4.544.174 1.2-.414 2.06-.01 2.508 1.156.066-1.352-.73-2.338-1.996-2.53-.712-.11-1.37.128-2.038.32-1.856.54-3.584.274-5.16-.872h.002zm9.256 5.272.726.064c-.546-.48-1.212-.52-1.888-.48-1.026.058-1.766.65-2.44 1.356-.594.624-1.13 1.324-2.016 1.574l.02.04c.12.002.24.008.36.002 1.288-.058 2.5-.33 3.464-1.264.306-.294.576-.62.87-.926.226-.258.562-.394.904-.366zm-2.992-1.596c-.96.084-1.794.48-2.58 1.006-.602.404-1.248.594-1.972.468-.128-.022-.258-.04-.384-.058l-.006.054c.046.024.092.05.14.07.12.048.24.106.364.136 1.396.33 2.732.16 3.936-.618.76-.49 1.546-.582 2.398-.456.086.014.172.028.258.036.08.008.164.088.272 0a3.454 3.454 0 0 0-2.426-.638zm-3.434-3.26a2.68 2.68 0 0 0 1.534-.364c-.154.014-.22.014-.282.026a2.296 2.296 0 0 1-1.96-.472l-.646-.5c-.856-.652-1.836-.872-2.91-.852.018.052.02.088.038.106 1.168 1.18 2.52 1.996 4.226 2.054v.002zm8.452 6.06c-.724-.72-1.694-.81-2.59-.186.594.028 1.04.216 1.4.592.128.134.262.26.404.378.548.44 1.474.46 2.016.052-.636-.248-.636-.248-1.23-.838v.002zm-7.198 5.486c-.634-1.18-1.7-1.448-2.936-1.368.364.1.708.26 1.02.474.286.2.526.448.764.702.472.504 1.208.812 1.696.708-.224-.14-.546-.514-.546-.514h-.012l.008.006.004.018c.004-.02.006-.016.008-.01h.02l-.028-.012v.01l.01.004s.114.208-.008-.018z"
  end

  defp logo_path("tailwind") do
    "M12.001,4.8c-3.2,0-5.2,1.6-6,4.8c1.2-1.6,2.6-2.2,4.2-1.8c0.913,0.228,1.565,0.89,2.288,1.624 C13.666,10.618,15.027,12,18.001,12c3.2,0,5.2-1.6,6-4.8c-1.2,1.6-2.6,2.2-4.2,1.8c-0.913-0.228-1.565-0.89-2.288-1.624 C16.337,6.182,14.976,4.8,12.001,4.8z M6.001,12c-3.2,0-5.2,1.6-6,4.8c1.2-1.6,2.6-2.2,4.2-1.8c0.913,0.228,1.565,0.89,2.288,1.624 c1.177,1.194,2.538,2.576,5.512,2.576c3.2,0,5.2-1.6,6-4.8c-1.2,1.6-2.6,2.2-4.2,1.8c-0.913-0.228-1.565-0.89-2.288-1.624 C10.337,13.382,8.976,12,6.001,12z"
  end

  defp logo_path("daisyui") do
    "M12 0C7.828.001 4.396 3.433 4.395 7.605c.001 4.172 3.433 7.604 7.605 7.605 4.172-.001 7.604-3.433 7.605-7.605C19.604 3.433 16.172.001 12 0Zm0 .286c4.016 0 7.32 3.304 7.32 7.32-.001 4.015-3.305 7.318-7.32 7.318-4.015 0-7.319-3.304-7.32-7.319 0-4.016 3.304-7.32 7.32-7.32zm0 4.04a3.294 3.294 0 0 0-3.279 3.279v.001A3.296 3.296 0 0 0 12 10.884a3.294 3.294 0 0 0 3.279-3.279A3.294 3.294 0 0 0 12 4.326ZM8.34 16.681h-.008a3.67 3.67 0 0 0-3.652 3.652v.015A3.67 3.67 0 0 0 8.332 24h7.336a3.67 3.67 0 0 0 3.652-3.652v-.016a3.67 3.67 0 0 0-3.652-3.652h-.008Z"
  end
end
