defmodule PotokIde.Social.Notifications do
  @moduledoc """
  Push payloads about values, reactions, invitations and requests. Like
  `PotokIde.Events.Notifications`, each is built in every supported language
  (`PotokIde.PushNotifications.localized/1`).

  They look as in messaging apps: the title is the conversation (the group,
  the other person of a direct conversation, "Group › thread"), the body
  "name: text", the picture the group's, or the person's in a direct
  conversation (`PotokIde.PushNotifications.Conversation`). The messages of
  one conversation share a tag, so a newer one replaces the older, and the
  Android app stacks them in one notification from `sender`, `sender_icon`
  and `text`.

  Every payload says its `kind`, which picks the Android channel and the Web
  Push urgency, its `group_id`, by which a device clears a conversation's
  notifications once it is read, and its `expires_at`.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  import PotokIde.PushNotifications, only: [localized: 1, expires_at: 1, now_ms: 0]

  alias PotokIde.PushNotifications.Conversation
  alias PotokIde.Social.{Group, Profile, ScheduledValue, Value}
  alias PotokIdeWeb.Avatars

  @excerpt_length 120

  def value_created(%Profile{} = creator, %Group{} = group, %Value{} = value),
    do: chat(:message, creator, group, value)

  def value_mention(%Profile{} = creator, %Group{} = group, %Value{} = value),
    do: chat(:mention, creator, group, value)

  def value_reply(%Profile{} = creator, %Group{} = group, %Value{} = value),
    do: chat(:reply, creator, group, value)

  @doc """
  The tag of a conversation's messages: one per group, so the newest message
  replaces the notification of the one before.
  """
  def chat_tag(group_id), do: "group-#{group_id}-chat"

  defp chat(kind, %Profile{} = creator, %Group{} = group, %Value{} = value) do
    look = Conversation.of(group, creator)
    name = Profile.display_name(creator)
    text = Value.excerpt(value, @excerpt_length)

    url =
      if kind == :reply,
        do: "/groups/#{group.id}/values?value=#{value.id}",
        else: "/groups/#{group.id}/values"

    base = %{
      kind: Atom.to_string(kind),
      tag: chat_tag(group.id),
      url: url,
      group_id: group.id,
      icon: look.icon,
      sender: name,
      sender_icon: avatar_url(creator),
      # The Android app stacks a direct conversation without a group title.
      direct: look.direct?,
      timestamp: now_ms(),
      expires_at: expires_at(:week)
    }

    localized(fn ->
      text = text || dgettext("notifications", "New message")

      Map.merge(base, %{
        title: look.title,
        body: chat_body(kind, name, text, look.direct?),
        text: text
      })
    end)
  end

  defp chat_body(:message, _name, text, true = _direct?), do: text

  defp chat_body(:message, name, text, false),
    do: dgettext("notifications", "%{name}: %{text}", name: name, text: text)

  defp chat_body(:mention, name, text, _direct?),
    do: dgettext("notifications", "%{name} mentioned you: %{text}", name: name, text: text)

  defp chat_body(:reply, name, text, _direct?),
    do: dgettext("notifications", "%{name} replied to you: %{text}", name: name, text: text)

  @doc """
  What an app's process pushes to the people of a role, under its name; `tag`
  lets a step that runs again replace its push rather than add one.
  """
  def process_push(%Profile{} = process, %Group{} = group, text, tag, url \\ nil) do
    look = Conversation.of(group, process)
    name = Profile.display_name(process)

    base = %{
      kind: "process",
      tag: tag,
      url: url || "/groups/#{group.id}",
      group_id: group.id,
      icon: look.icon,
      sender: name,
      sender_icon: avatar_url(process),
      text: text,
      timestamp: now_ms(),
      expires_at: expires_at(:day)
    }

    localized(fn ->
      Map.merge(base, %{
        title: look.title,
        body: dgettext("notifications", "%{name}: %{text}", name: name, text: text)
      })
    end)
  end

  @doc "For the accounts of whoever scheduled a message that could not be sent."
  def scheduled_value_failed(%Group{} = group, %ScheduledValue{} = scheduled) do
    look = Conversation.of(group, nil)

    base = %{
      kind: "scheduled",
      tag: "group-#{group.id}-scheduled-#{scheduled.id}",
      url: "/groups/#{group.id}/values",
      group_id: group.id,
      icon: look.icon,
      timestamp: now_ms(),
      expires_at: expires_at(:day)
    }

    localized(fn ->
      Map.merge(base, %{
        title: look.title,
        body:
          dgettext("notifications", "A scheduled message was not sent: %{excerpt}",
            excerpt: ScheduledValue.excerpt(scheduled)
          )
      })
    end)
  end

  @doc """
  To the author of a value when someone reacts to it. One tag per value, so
  later reactions replace the earlier notification.
  """
  def value_reaction(%Profile{} = reactor, %Group{} = group, %Value{} = value, emoji) do
    look = Conversation.of(group, reactor)
    name = Profile.display_name(reactor)
    snippet = Value.excerpt(value, 80)

    base = %{
      kind: "reaction",
      tag: "group-#{group.id}-value-#{value.id}-reactions",
      url: "/groups/#{group.id}/values",
      group_id: group.id,
      icon: look.icon,
      sender: name,
      sender_icon: avatar_url(reactor),
      timestamp: now_ms(),
      expires_at: expires_at(:day)
    }

    localized(fn ->
      body =
        case snippet do
          nil ->
            dgettext("notifications", "%{name} reacted %{emoji} to your message",
              name: name,
              emoji: emoji
            )

          snippet ->
            dgettext("notifications", "%{name}: %{emoji} to “%{excerpt}”",
              name: name,
              emoji: emoji,
              excerpt: snippet
            )
        end

      Map.merge(base, %{title: look.title, body: body})
    end)
  end

  def group_invitation(%Profile{} = inviter, %Group{} = group) do
    base = %{
      kind: "invitation",
      tag: "group-#{group.id}-invitation-#{inviter.id}",
      url: "/invitations",
      group_id: group.id,
      icon: avatar_url(inviter),
      timestamp: now_ms(),
      expires_at: expires_at(:week)
    }

    localized(fn ->
      Map.merge(base, %{
        title:
          dgettext("notifications", "%{name} invited you to %{group}",
            name: inviter.username,
            group: group.name
          ),
        body: dgettext("notifications", "Tap to accept or decline.")
      })
    end)
  end

  def group_invitation_accepted(%Group{} = group, %Profile{} = invitee) do
    base = %{
      kind: "invitation",
      tag: "group-#{group.id}-invitation-accepted",
      url: "/groups/#{group.id}",
      group_id: group.id,
      icon: avatar_url(invitee),
      timestamp: now_ms(),
      expires_at: expires_at(:week)
    }

    localized(fn ->
      Map.merge(base, %{
        title: group.name,
        body:
          dgettext("notifications", "%{name} accepted your invitation", name: invitee.username)
      })
    end)
  end

  def shared_profile_invitation(%Profile{} = inviter, %Profile{} = shared_profile) do
    base = %{
      kind: "invitation",
      tag: "profile-#{shared_profile.id}-invitation",
      url: "/profiles",
      icon: avatar_url(shared_profile),
      timestamp: now_ms(),
      expires_at: expires_at(:week)
    }

    localized(fn ->
      Map.merge(base, %{
        title:
          dgettext("notifications", "%{name} shared %{profile}",
            name: inviter.username,
            profile: shared_profile.username
          ),
        body: dgettext("notifications", "Open Potok to review this shared profile invitation.")
      })
    end)
  end

  def shared_profile_invitation_accepted(%Profile{} = shared_profile, %Profile{} = invitee) do
    base = %{
      kind: "invitation",
      tag: "profile-#{shared_profile.id}-invitation-accepted",
      url: "/profiles",
      icon: avatar_url(shared_profile),
      timestamp: now_ms(),
      expires_at: expires_at(:week)
    }

    localized(fn ->
      Map.merge(base, %{
        title:
          dgettext("notifications", "%{name} accepted your shared profile invitation",
            name: invitee.username
          ),
        body:
          dgettext("notifications", "%{name} now has access to %{profile}.",
            name: invitee.username,
            profile: shared_profile.username
          )
      })
    end)
  end

  @doc """
  A new value in a collection of an app, for those of its readers who asked to
  hear of them: a response to a form. `author` is nil for an anonymous one.
  One tag per app, so a busy form keeps one notification on the phone.
  """
  def app_value_created(%Group{} = group, alt, author) do
    query = if alt, do: "?d=#{alt.id}", else: ""
    look = Conversation.of(group, author)

    base =
      %{
        kind: "app",
        tag: "group-#{group.id}-app-#{if(alt, do: alt.id, else: 0)}-values",
        url: "/groups/#{group.id}/group_home#{query}",
        group_id: group.id,
        icon: look.icon,
        timestamp: now_ms(),
        expires_at: expires_at(:day)
      }
      |> then(fn base ->
        case author do
          %Profile{} ->
            Map.merge(base, %{sender: author.username, sender_icon: avatar_url(author)})

          nil ->
            base
        end
      end)

    localized(fn ->
      Map.merge(base, %{
        title: look.title,
        body:
          case author do
            %Profile{username: name} ->
              dgettext("notifications", "%{name} sent a response.", name: name)

            nil ->
              dgettext("notifications", "Someone sent a response.")
          end
      })
    end)
  end

  # Notification pictures cannot be SVG, which the avatar URL serves by
  # default.
  defp avatar_url(%Profile{} = profile), do: Avatars.profile_badge_url(profile)

  @doc """
  What became of a request in `group`, for whoever asked, in one push:
  `parts` holds `:admitted` (true, false when refused, or nil), whether
  admission went to a vote (`:admission_vote`), the roles `:granted`,
  `:declined` and put to a vote (`:voted`), and the `:url` it opens;
  `reason` is what the one who decided said.
  """
  def request_decided(%Group{} = group, parts, reason) do
    base = request_base(group, parts[:url] || "/requests")

    localized(fn ->
      lines =
        [
          parts[:admitted] == true && dgettext("notifications", "You are a member now."),
          parts[:admitted] == false &&
            dgettext("notifications", "Your request to join was refused."),
          parts[:admission_vote] &&
            dgettext("notifications", "The group votes on admitting you."),
          roles_line(:granted, parts[:granted]),
          roles_line(:declined, parts[:declined]),
          roles_line(:voted, parts[:voted]),
          reason not in [nil, ""] && "„#{reason}“"
        ]
        |> Enum.filter(&is_binary/1)

      Map.merge(base, %{
        title: group.name,
        body: Enum.join(lines, " "),
        label: dgettext("notifications", "Request")
      })
    end)
  end

  @doc """
  How a vote on a request in `group` ended, for whoever asked: `:admitted`,
  `:not_admitted` or `{:not_granted, role}`.
  """
  def request_vote_ended(%Group{} = group, outcome) do
    url = if outcome == :not_admitted, do: "/requests", else: "/groups/#{group.id}"
    base = request_base(group, url)

    localized(fn ->
      body =
        case outcome do
          :admitted ->
            dgettext("notifications", "The group admitted you by a vote.")

          :not_admitted ->
            dgettext("notifications", "The vote did not admit you.")

          {:not_granted, role} ->
            dgettext("notifications", "The vote did not give you the role %{role}.",
              role: role_name(role)
            )
        end

      Map.merge(base, %{
        title: group.name,
        body: body,
        label: dgettext("notifications", "Request")
      })
    end)
  end

  @doc """
  For the admins of `group`: someone reported a message (`ValueReports`). It
  says why and what the message says, never who reported it; the Requests
  page lists it.
  """
  def value_reported(%Group{} = group, %Value{} = value, reason) do
    base = request_base(group, "/requests?section=reports")
    excerpt = Value.excerpt(value, @excerpt_length)

    localized(fn ->
      reason = PotokIde.Social.ValueReports.reason_label(reason)

      body =
        if excerpt,
          do:
            dgettext("notifications", "A message was reported (%{reason}): %{text}",
              reason: reason,
              text: excerpt
            ),
          else: dgettext("notifications", "A message was reported (%{reason}).", reason: reason)

      Map.merge(base, %{
        tag: "group-#{group.id}-report",
        title: group.name,
        body: body,
        label: dgettext("notifications", "Report")
      })
    end)
  end

  defp request_base(%Group{} = group, url) do
    %{
      kind: "request",
      tag: "group-#{group.id}-request",
      url: url,
      group_id: group.id,
      icon: Avatars.group_badge_url(group),
      timestamp: now_ms(),
      expires_at: expires_at(:week)
    }
  end

  defp roles_line(_kind, empty) when empty in [nil, []], do: nil

  defp roles_line(:granted, roles),
    do: dgettext("notifications", "Given: %{roles}.", roles: role_names(roles))

  defp roles_line(:declined, roles),
    do: dgettext("notifications", "Refused: %{roles}.", roles: role_names(roles))

  defp roles_line(:voted, roles),
    do: dgettext("notifications", "Put to a vote: %{roles}.", roles: role_names(roles))

  defp role_names(roles), do: Enum.map_join(roles, ", ", &role_name/1)

  defp role_name(%{key: "admin"}), do: dgettext("notifications", "Admin")
  defp role_name(%{name: name}), do: name
end
