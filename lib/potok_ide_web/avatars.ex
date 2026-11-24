defmodule PotokIdeWeb.Avatars do
  @moduledoc """
  Builds avatar URLs for profiles and groups.

  Pictures are never inlined into HTML as data URLs; every avatar is served by
  `PotokIdeWeb.AvatarController`, which lets the browser cache them. The
  `updated_at` timestamp is appended as a cache buster so a changed picture
  shows up immediately.

  Every address also carries a signature (`s`). The controller sends the
  picture of a group guests cannot see only with it, and of a profile always,
  so that an id alone tells nobody whether a private group or a profile
  exists, what it is called or what its picture is. Potok signs the addresses
  it shows to those who see the group or the profile, and a push
  notification's, which a phone fetches with no session.
  """

  @group_salt "group avatar"
  @profile_salt "profile avatar"

  def profile_avatar_url(%{id: id} = profile) when is_integer(id) do
    "/avatar/profile/#{id}?" <>
      URI.encode_query(version(profile) ++ [s: signature(@profile_salt, id)])
  end

  def profile_avatar_url(_), do: nil

  @doc "The profile's picture as a PNG, for push notifications, which cannot show SVG."
  def profile_badge_url(%{id: id}) when is_integer(id) do
    "/avatar/profile/#{id}?" <>
      URI.encode_query(format: "png", s: signature(@profile_salt, id))
  end

  @doc "Whether `signature` is the one Potok gives out with the profile's picture."
  def profile_signature?(id, signature) when is_integer(id) and is_binary(signature),
    do: Plug.Crypto.secure_compare(signature(@profile_salt, id), signature)

  def profile_signature?(_id, _signature), do: false

  def group_avatar_url(%{id: id} = group) when is_integer(id) do
    "/avatar/group/#{id}?" <> URI.encode_query(version(group) ++ [s: group_signature(id)])
  end

  def group_avatar_url(_), do: nil

  @doc "The group's picture as a PNG, for push notifications, which cannot show SVG."
  def group_badge_url(%{id: id}) when is_integer(id),
    do: "/avatar/group/#{id}?" <> URI.encode_query(format: "png", s: group_signature(id))

  @doc "Whether `signature` is the one Potok gives out with the group's picture."
  def group_signature?(id, signature) when is_integer(id) and is_binary(signature),
    do: Plug.Crypto.secure_compare(group_signature(id), signature)

  def group_signature?(_id, _signature), do: false

  @doc """
  Signs the addresses of the pictures of `group_ids` in `html`. An app writes
  a group's picture into a description without the signature (FeedCreator's
  stories show their own), so a description is shown with its own group's
  signed, as whoever reads it sees that group.
  """
  def sign_group_pictures(html, group_ids) when is_binary(html) do
    ids = for id <- List.wrap(group_ids), is_integer(id), into: MapSet.new(), do: id

    if MapSet.size(ids) == 0 or not String.contains?(html, "/avatar/group/") do
      html
    else
      Regex.replace(~r{(src=")(/avatar/group/(\d+))(\?[^"]*)?"}, html, fn whole,
                                                                          open,
                                                                          path,
                                                                          id,
                                                                          query ->
        id = String.to_integer(id)

        cond do
          id not in ids -> whole
          query == "" -> ~s(#{open}#{path}?s=#{group_signature(id)}")
          query =~ ~r/[?&;]s=/ -> whole
          true -> ~s(#{open}#{path}#{query}&amp;s=#{group_signature(id)}")
        end
      end)
    end
  end

  defp group_signature(id), do: signature(@group_salt, id)

  # Not secret enough to expire: the address of a picture someone was shown
  # once keeps working, as a copy of the picture would.
  defp signature(salt, id) do
    PotokIdeWeb.Endpoint.config(:secret_key_base)
    |> Plug.Crypto.KeyGenerator.generate(salt, cache: Plug.Crypto.Keys)
    |> then(&:crypto.mac(:hmac, :sha256, &1, Integer.to_string(id)))
    |> binary_part(0, 12)
    |> Base.url_encode64(padding: false)
  end

  defp version(%{updated_at: %DateTime{} = updated_at}), do: [v: DateTime.to_unix(updated_at)]

  defp version(%{updated_at: %NaiveDateTime{} = updated_at}),
    do: [v: updated_at |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_unix()]

  defp version(_), do: []
end
