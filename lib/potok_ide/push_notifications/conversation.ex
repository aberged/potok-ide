defmodule PotokIde.PushNotifications.Conversation do
  @moduledoc """
  Where a notification seems to come from, as messaging apps show it: its
  title and its picture. A group's notification carries the group's name and
  picture, a direct conversation's the other person (who is the one that
  wrote), a thread's "Group › thread" and its group's picture.

  The pictures are PNG addresses that work without a session
  (`PotokIdeWeb.Avatars`), since the browser and the phone fetch them
  outside the page.
  """

  alias PotokIde.Repo
  alias PotokIde.Social.{Group, Profile}
  alias PotokIdeWeb.Avatars

  @doc """
  `%{title:, icon:, direct?:}` of `group`'s notifications written by `sender`
  (nil for nobody, as an anonymous response to a form).
  """
  def of(%Group{is_direct: true}, %Profile{} = sender) do
    %{title: Profile.display_name(sender), icon: Avatars.profile_badge_url(sender), direct?: true}
  end

  def of(%Group{parent_value_id: value_id, parent_id: parent_id} = group, _sender)
      when is_integer(value_id) and is_integer(parent_id) do
    case Repo.get(Group, parent_id) do
      %Group{} = parent ->
        %{
          title: parent.name <> " › " <> group.name,
          icon: Avatars.group_badge_url(parent),
          direct?: false
        }

      nil ->
        of_group(group)
    end
  end

  def of(%Group{} = group, _sender), do: of_group(group)

  defp of_group(%Group{} = group),
    do: %{title: group.name, icon: Avatars.group_badge_url(group), direct?: false}
end
