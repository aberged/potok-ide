defmodule PotokIdeWeb.GuestDescriptions do
  @moduledoc """
  What a guest reads at the link of a public group that opened its description
  to guests (`Group.guest_description?/1`): the default description, unless it
  is empty, and the alternative descriptions marked for guests
  (`Social.list_guest_alt_descriptions/1`), in the group's order.

  An entry is `%{id: nil | alt_id, name: label, uses_api: boolean}`. Its text
  is read only for the one on screen (`source/2`): an app's can run to
  hundreds of kilobytes. `PotokIdeWeb.PublicPreview` shows text on a plain
  page, and an app in a small LiveView of its own
  (`PotokIdeWeb.GroupLive.GuestApp`).
  """

  use PotokIdeWeb, :verified_routes

  alias PotokIde.Social
  alias PotokIde.Social.{Group, GroupAltDescription}
  alias PotokIdeWeb.GroupLive.Show.Components

  @doc "The descriptions guests read, the default first; [] while the group keeps them closed."
  def entries(%Group{} = group) do
    if Group.guest_description?(group) do
      default =
        if blank?(group.description),
          do: [],
          else: [
            %{
              id: nil,
              name: Components.default_description_label(group),
              uses_api: group.uses_api
            }
          ]

      default ++
        Enum.map(
          Social.list_guest_alt_descriptions(group),
          &%{id: &1.id, name: &1.name, uses_api: &1.uses_api}
        )
    else
      []
    end
  end

  @doc """
  The entry a guest opens, by the `d` of the link, as on a member's page:
  `"default"`, an alternative's id, or nothing for the one the group opens on
  (`Group.home_alt_description_id` when guests read it). One they cannot read
  gives that one too. Nil when there is no entry.
  """
  def pick([], _group, _param), do: nil

  def pick(entries, group, "default"),
    do: Enum.find(entries, &is_nil(&1.id)) || home(entries, group)

  def pick(entries, group, param) when is_binary(param) do
    with {id, ""} <- Integer.parse(param),
         %{} = entry <- Enum.find(entries, &(&1.id == id)) do
      entry
    else
      _ -> home(entries, group)
    end
  end

  def pick(entries, group, _none), do: home(entries, group)

  defp home(entries, %Group{home_alt_description_id: home_id}) do
    (home_id && Enum.find(entries, &(&1.id == home_id))) ||
      Enum.find(entries, &is_nil(&1.id)) || hd(entries)
  end

  @doc """
  What `entry` shows, with its text: the group itself for the default
  description, or the alternative description. Nil when that one is gone.
  """
  def source(%Group{} = group, %{id: nil}), do: group

  def source(%Group{} = group, %{id: id}) do
    case Social.get_alt_description(group, id) do
      %GroupAltDescription{} = alt -> alt
      nil -> nil
    end
  end

  @doc "The link of `entry` on the group's page, the same for guests and members."
  def path(%Group{id: group_id}, %{id: id}),
    do: ~p"/groups/#{group_id}/group_home?#{[d: id || "default"]}"

  defp blank?(description), do: is_nil(description) or String.trim(description) == ""
end
