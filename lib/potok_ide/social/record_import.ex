defmodule PotokIde.Social.RecordImport do
  @moduledoc """
  Takes away the records an app brought in under a group (`Social.create_children/3`,
  groups with an `external_key`), such as a trial import of an open dataset:
  each through `Social.delete_group/2`, in the name of the profile that
  imported them, who is their admin. A record that has got groups below it
  stays.

  Run it on a release over `bin/potok_ide rpc` with `start_remove/2`, so that
  a dropped connection does not stop it:

      PotokIde.Social.RecordImport.start_remove(parent_id, profile_id)
  """

  import Ecto.Query

  require Logger

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Group, Profile}

  # Records read at a time, so that a year of them is not held at once.
  @page 500

  @doc """
  Deletes the records under the group `parent_id` that `profile_id` made.
  `{:ok, deleted, kept}`.
  """
  def remove(parent_id, profile_id) when is_integer(parent_id) and is_integer(profile_id) do
    profile = Repo.get!(Profile, profile_id)
    remove_after(parent_id, profile, 0, {0, 0})
  end

  @doc "`remove/2` in a task of the app's own, logging what it did."
  def start_remove(parent_id, profile_id) do
    Task.Supervisor.start_child(PotokIde.TaskSupervisor, fn ->
      {:ok, deleted, kept} = remove(parent_id, profile_id)
      Logger.info("Records under #{parent_id} removed: #{deleted} deleted, #{kept} kept")
    end)
  end

  defp remove_after(parent_id, %Profile{} = profile, after_id, counts) do
    case records(parent_id, profile.id, after_id) do
      [] ->
        {deleted, kept} = counts
        {:ok, deleted, kept}

      groups ->
        counts = Enum.reduce(groups, counts, &delete(profile, &1, &2))
        remove_after(parent_id, profile, List.last(groups).id, counts)
    end
  end

  defp records(parent_id, profile_id, after_id) do
    from(g in Group,
      where:
        g.parent_id == ^parent_id and g.creator_id == ^profile_id and
          not is_nil(g.external_key) and g.id > ^after_id,
      order_by: g.id,
      limit: @page
    )
    |> Repo.all()
  end

  defp delete(profile, group, {deleted, kept}) do
    case Social.delete_group(profile, group) do
      {:ok, _group} -> {deleted + 1, kept}
      {:error, _reason} -> {deleted, kept + 1}
    end
  end
end
