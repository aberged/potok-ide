defmodule PotokIde.Social.ProcessActions do
  @moduledoc """
  What an app's process does in Potok, signed by its profile
  (`PotokIde.Social.AppProcesses`). The engine calls these inside the
  transaction of a step (`ProcessStep`), together with the step's change of
  state, so that what they write happens exactly once.

  - Each action returns `{:ok, result, announcement}`. Once the transaction
    commits, the engine passes the announcements to `announce/1`, so no page
    and no device hears of a value or a group that was rolled back.
  - The process writes only in the app's group and in the sub-groups its
    instance made (`ProcessStep.groups`). Being a member is not enough, as an
    open chat takes values from those who are not members.
  - It may do what its profile may do there: the group's roles decide, and
    without the permission the action gives `{:error, :not_permitted}`.
  - A sub-group it makes has people as its admins: by default the process's
    owner, while the owner still edits the app, and whoever started the step.
    When the owner no longer edits the app, whoever started the step takes the
    owner's place.
  - An error in the writes themselves aborts the whole transaction, as Ecto
    does with a nested one; the checks before them leave it alone.
  """

  import Ecto.Query, warn: false

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, AppProcess, AppProcesses, Group, ProcessStep, Profile}

  @value_attrs ~w(content content_format parent_id)
  @group_attrs ~w(name description description_format home_page is_public inherits_members has_public_chat)
  @default_admins ["owner", "triggered_by"]

  @doc "The admins of a sub-group when the step names none: the owner and whoever started it."
  def default_admins, do: @default_admins

  @doc """
  Posts a chat value in `group` as the process, with where it comes from in
  `managed` (`%{"process" => %{"instance", "element", "triggered_by"}}`).
  Of `attrs` only the content, its format and the value replied to count.
  """
  def post_value(%ProcessStep{} = step, %Group{} = group, attrs) do
    with {:ok, row} <- acting_process(step, group) do
      Social.insert_process_value(
        row.profile,
        group,
        attrs |> stringify() |> Map.take(@value_attrs),
        provenance(step)
      )
    end
  end

  @doc """
  Makes a sub-group of `parent` as the process, with no `external_key`: such a
  group is a record, which leaves the unread counts and the map, and its keys
  are the apps' own. `admins` names its admins: `"owner"`, `"triggered_by"`
  and the keys of roles in `parent`, whose people become admins. Naming
  nobody who can be an admin gives `{:error, :no_admin}`.

  The engine keeps the new group's id with the instance (`ProcessStep.groups`).
  """
  def create_subgroup(%ProcessStep{} = step, %Group{} = parent, attrs, admins \\ @default_admins)
      when is_list(admins) do
    with {:ok, row} <- acting_process(step, parent),
         {:ok, admin_ids} <- admin_ids(row, step, parent, admins) do
      Social.insert_process_group(
        row.profile,
        parent,
        attrs |> stringify() |> Map.take(@group_attrs),
        admin_ids
      )
    end
  end

  @doc "Tells what a committed step did, with the announcements of its actions."
  def announce(announcements) when is_list(announcements) do
    Enum.each(announcements, fn announce when is_function(announce, 0) -> announce.() end)
  end

  # The process as it is now, with its profile, while it runs and the group is
  # one it writes in.
  defp acting_process(%ProcessStep{process: %AppProcess{id: id}} = step, %Group{} = group) do
    case Repo.get(AppProcess, id) do
      %AppProcess{active: true} = row -> acting_in(Repo.preload(row, :profile), step, group)
      _stopped_or_gone -> {:error, :process_inactive}
    end
  end

  defp acting_in(%AppProcess{} = row, %ProcessStep{} = step, %Group{} = group) do
    cond do
      group.id != row.group_id and group.id not in step.groups -> {:error, :not_process_group}
      not Social.member_of_group?(row.profile, group) -> {:error, :not_a_member_of_group}
      true -> {:ok, row}
    end
  end

  defp admin_ids(%AppProcess{} = row, %ProcessStep{} = step, %Group{} = parent, admins) do
    ids =
      admins
      |> Enum.flat_map(fn
        "owner" -> [owner_or_trigger(row, step)]
        "triggered_by" -> [step.triggered_by]
        role_key when is_binary(role_key) -> Access.profile_ids_with_role(parent, role_key)
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    # Only people run a group.
    people =
      from(p in Profile, where: p.id in ^ids and p.kind == :person, select: p.id)
      |> Repo.all()
      |> MapSet.new()

    case Enum.filter(ids, &(&1 in people)) do
      [] -> {:error, :no_admin}
      admin_ids -> {:ok, admin_ids}
    end
  end

  defp owner_or_trigger(%AppProcess{owner_profile_id: owner_id, group_id: group_id}, step) do
    if AppProcesses.edits_app?(owner_id, Repo.get!(Group, group_id)),
      do: owner_id,
      else: step.triggered_by
  end

  defp provenance(%ProcessStep{} = step) do
    %{
      "process" => %{
        "instance" => step.instance,
        "element" => step.element,
        "triggered_by" => step.triggered_by
      }
    }
  end

  defp stringify(attrs), do: Map.new(attrs, fn {key, value} -> {to_string(key), value} end)
end
