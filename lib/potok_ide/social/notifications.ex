defmodule PotokIde.Social.Notifications do
  @moduledoc """
  Push payloads about values, reactions and invitations. Like
  `PotokIde.Events.Notifications`, each is built in every supported language
  and returned as a function from a device's locale to the payload.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  import PotokIde.PushNotifications, only: [localized: 1]

  alias PotokIde.Social.{Group, Profile, Value}

  def value_created(%Profile{} = creator, %Group{} = group, %Value{} = value) do
    localized(fn -> value_payload(creator, group, value) end)
  end

  def value_mention(%Profile{} = creator, %Group{} = group, %Value{} = value) do
    localized(fn ->
      %{
        value_payload(creator, group, value)
        | title:
            dgettext("notifications", "%{name} mentioned you in %{group}",
              name: Profile.display_name(creator),
              group: group.name
            )
      }
    end)
  end

  def value_reply(%Profile{} = creator, %Group{} = group, %Value{} = value) do
    localized(fn ->
      %{
        value_payload(creator, group, value)
        | title:
            dgettext("notifications", "%{name} replied to you in %{group}",
              name: Profile.display_name(creator),
              group: group.name
            ),
          url: "/groups/#{group.id}/values?value=#{value.id}"
      }
    end)
  end

  @doc """
  What an app's process pushes to the people of a role, under its name; `tag`
  lets a step that runs again replace its push rather than add one.
  """
  def process_push(%Profile{} = process, %Group{} = group, text, tag, url \\ nil) do
    localized(fn ->
      %{
        title:
          dgettext("notifications", "%{name} in %{group}",
            name: Profile.display_name(process),
            group: group.name
          ),
        body: text,
        tag: tag,
        url: url || "/groups/#{group.id}",
        badge: avatar_url(process)
      }
    end)
  end

  # One tag per value, so later reactions replace the earlier notification.
  def value_reaction(%Profile{} = reactor, %Group{} = group, %Value{} = value, emoji) do
    body =
      case excerpt(value) do
        nil -> group.name
        snippet -> "#{group.name}: #{snippet}"
      end

    localized(fn ->
      %{
        title:
          dgettext("notifications", "%{name} reacted %{emoji} to your message",
            name: reactor.username,
            emoji: emoji
          ),
        body: body,
        tag: "group-#{group.id}-value-#{value.id}-reactions",
        url: "/groups/#{group.id}/values",
        badge: avatar_url(reactor)
      }
    end)
  end

  def group_invitation(%Profile{} = inviter, %Group{} = group) do
    localized(fn ->
      %{
        title:
          dgettext("notifications", "%{name} invited you to %{group}",
            name: inviter.username,
            group: group.name
          ),
        body: dgettext("notifications", "Open Potok to review this group invitation."),
        tag: "group-#{group.id}-invitation-#{inviter.id}",
        url: "/invitations",
        badge: avatar_url(inviter)
      }
    end)
  end

  def group_invitation_accepted(%Group{} = group, %Profile{} = invitee) do
    localized(fn ->
      %{
        title:
          dgettext("notifications", "%{name} accepted your invitation", name: invitee.username),
        body:
          dgettext("notifications", "%{name} joined %{group}.",
            name: invitee.username,
            group: group.name
          ),
        tag: "group-#{group.id}-invitation-accepted",
        url: "/groups/#{group.id}",
        badge: avatar_url(invitee)
      }
    end)
  end

  def shared_profile_invitation(%Profile{} = inviter, %Profile{} = shared_profile) do
    localized(fn ->
      %{
        title:
          dgettext("notifications", "%{name} shared %{profile}",
            name: inviter.username,
            profile: shared_profile.username
          ),
        body: dgettext("notifications", "Open Potok to review this shared profile invitation."),
        tag: "profile-#{shared_profile.id}-invitation",
        url: "/profiles",
        badge: avatar_url(shared_profile)
      }
    end)
  end

  def shared_profile_invitation_accepted(%Profile{} = shared_profile, %Profile{} = invitee) do
    localized(fn ->
      %{
        title:
          dgettext("notifications", "%{name} accepted your shared profile invitation",
            name: invitee.username
          ),
        body:
          dgettext("notifications", "%{name} now has access to %{profile}.",
            name: invitee.username,
            profile: shared_profile.username
          ),
        tag: "profile-#{shared_profile.id}-invitation-accepted",
        url: "/profiles",
        badge: avatar_url(shared_profile)
      }
    end)
  end

  @doc """
  A new value in a collection of an app, for those of its readers who asked to
  hear of them: a response to a form. `author` is nil for an anonymous one.
  One tag per app, so a busy form keeps one notification on the phone.
  """
  def app_value_created(%Group{} = group, alt, author) do
    query = if alt, do: "?d=#{alt.id}", else: ""

    localized(fn ->
      %{
        title: dgettext("notifications", "New response in %{group}", group: group.name),
        body:
          case author do
            %Profile{username: name} ->
              dgettext("notifications", "%{name} sent a response.", name: name)

            nil ->
              dgettext("notifications", "Someone sent a response.")
          end,
        tag: "group-#{group.id}-app-#{if(alt, do: alt.id, else: 0)}-values",
        url: "/groups/#{group.id}/group_home#{query}"
      }
      |> then(fn payload ->
        if author, do: Map.put(payload, :badge, avatar_url(author)), else: payload
      end)
    end)
  end

  defp value_payload(%Profile{} = creator, %Group{} = group, %Value{} = value) do
    body =
      case excerpt(value) do
        nil ->
          dgettext("notifications", "New message in %{group}", group: group.name)

        snippet ->
          dgettext("notifications", "New message in %{group}: %{excerpt}",
            group: group.name,
            excerpt: snippet
          )
      end

    %{
      title:
        dgettext("notifications", "%{name} sent a new message",
          name: Profile.display_name(creator)
        ),
      body: body,
      tag: "group-#{group.id}-value-#{value.id}-created",
      url: "/groups/#{group.id}/values",
      badge: avatar_url(creator)
    }
  end

  defp excerpt(%Value{content: content} = value),
    do: excerpt(content) || Value.attachment_summary(value, 120)

  defp excerpt(content) when is_binary(content) do
    trimmed = String.trim(content)

    cond do
      trimmed == "" -> nil
      String.length(trimmed) <= 120 -> trimmed
      true -> String.slice(trimmed, 0, 117) <> "..."
    end
  end

  defp excerpt(_content), do: nil

  # Notification badges and icons cannot be SVG, which the avatar URL serves
  # by default.
  defp avatar_url(%Profile{id: profile_id}), do: "/avatar/profile/#{profile_id}?format=png"

  @doc """
  What became of a request in `group`, for whoever asked, in one push:
  `parts` holds `:admitted` (true, false when refused, or nil), whether
  admission went to a vote (`:admission_vote`), the roles `:granted`,
  `:declined` and put to a vote (`:voted`), and the `:url` it opens;
  `reason` is what the one who decided said.
  """
  def request_decided(%Group{} = group, parts, reason) do
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

      %{
        title: dgettext("notifications", "Your request in %{group}", group: group.name),
        body: Enum.join(lines, " "),
        tag: "group-#{group.id}-request",
        url: parts[:url] || "/requests"
      }
    end)
  end

  @doc """
  How a vote on a request in `group` ended, for whoever asked: `:admitted`,
  `:not_admitted` or `{:not_granted, role}`.
  """
  def request_vote_ended(%Group{} = group, outcome) do
    localized(fn ->
      {body, url} =
        case outcome do
          :admitted ->
            {dgettext("notifications", "The group admitted you by a vote."),
             "/groups/#{group.id}"}

          :not_admitted ->
            {dgettext("notifications", "The vote did not admit you."), "/requests"}

          {:not_granted, role} ->
            {dgettext("notifications", "The vote did not give you the role %{role}.",
               role: role_name(role)
             ), "/groups/#{group.id}"}
        end

      %{
        title: dgettext("notifications", "Your request in %{group}", group: group.name),
        body: body,
        tag: "group-#{group.id}-request",
        url: url
      }
    end)
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
