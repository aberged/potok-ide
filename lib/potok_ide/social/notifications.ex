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
              name: creator.username,
              group: group.name
            )
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
      title: dgettext("notifications", "%{name} sent a new message", name: creator.username),
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
end
