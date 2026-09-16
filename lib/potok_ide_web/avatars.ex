defmodule PotokIdeWeb.Avatars do
  @moduledoc """
  Builds avatar URLs for profiles and groups.

  Pictures are never inlined into HTML as data URLs; every avatar is served by
  `PotokIdeWeb.AvatarController`, which lets the browser cache them. The
  `updated_at` timestamp is appended as a cache buster so a changed picture
  shows up immediately.
  """

  def profile_avatar_url(%{id: id} = profile) when is_integer(id) do
    "/avatar/profile/#{id}" <> version_query(profile)
  end

  def profile_avatar_url(_), do: nil

  def group_avatar_url(%{id: id} = group) when is_integer(id) do
    "/avatar/group/#{id}" <> version_query(group)
  end

  def group_avatar_url(_), do: nil

  defp version_query(%{updated_at: %DateTime{} = updated_at}),
    do: "?v=#{DateTime.to_unix(updated_at)}"

  defp version_query(%{updated_at: %NaiveDateTime{} = updated_at}),
    do: "?v=#{updated_at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()}"

  defp version_query(_), do: ""
end
