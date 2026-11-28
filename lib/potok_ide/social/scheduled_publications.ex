defmodule PotokIde.Social.ScheduledPublications do
  @moduledoc """
  Drafts that open by themselves at a time their editor picked, as a site's
  article that goes out on Monday morning (`AppApi`, `publishAt` of
  `createChild` and `updateChild`; `ScheduledPublications.Scheduler` calls
  `run_due/1`).

  Until then the group stays the draft it is. At its time it gets the
  audience the editor chose through `Social.update_group/3`, in the name of
  whoever scheduled it, so `published_at`, history and every check are those
  of a publication by hand: one who may no longer edit the group publishes
  nothing, and the row stays with the reason for the editors to see. However
  late it comes (a deploy, a stopped server), a publication still goes out:
  an article loses nothing by waiting.

  Publishing or withdrawing by hand takes the row away; a new time replaces it.
  """

  import Ecto.Query

  require Logger

  alias PotokIde.History
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, Group, Profile, ScheduledPublication}
  alias PotokIde.Social.ScheduledPublications.Scheduler

  @max_days_ahead 366

  # Publications in one pass; the scheduler comes back for the rest.
  @batch 100

  def max_days_ahead, do: @max_days_ahead

  @doc """
  Schedules `group` to open at `publish_at` to `audience`
  (`%{is_public: boolean, inherits_members: boolean}`, at least one true), in
  `profile`'s name, replacing any time it had. The group must be a draft that
  `profile` may edit, and the time ahead, within a year.
  """
  def schedule(%Profile{} = profile, %Group{} = group, %DateTime{} = publish_at, audience) do
    now = DateTime.utc_now(:second)
    publish_at = DateTime.truncate(publish_at, :second)
    is_public = Map.get(audience, :is_public) == true
    inherits = Map.get(audience, :inherits_members) == true

    cond do
      not Access.can?(profile, group, :edit_group) ->
        {:error, :not_permitted}

      not Group.draft?(group) ->
        {:error, :published}

      DateTime.compare(publish_at, now) != :gt or
          DateTime.diff(publish_at, now, :day) > @max_days_ahead ->
        {:error, :invalid_time}

      not (is_public or inherits) ->
        {:error, :invalid_audience}

      true ->
        result =
          Repo.insert(
            %ScheduledPublication{
              group_id: group.id,
              profile_id: profile.id,
              publish_at: publish_at,
              is_public: is_public,
              inherits_members: inherits
            },
            on_conflict: [
              set: [
                profile_id: profile.id,
                publish_at: publish_at,
                is_public: is_public,
                inherits_members: inherits,
                failure: nil,
                updated_at: now
              ]
            ],
            conflict_target: :group_id,
            returning: true
          )

        Scheduler.nudge()
        result
    end
  end

  @doc "Takes away the time `group` would open at, if it had one."
  def cancel(%Group{id: group_id}) do
    Repo.delete_all(from(s in ScheduledPublication, where: s.group_id == ^group_id))
    :ok
  end

  @doc "The publications waiting for `group_ids`, by group id."
  def for_groups([]), do: %{}

  def for_groups(group_ids) when is_list(group_ids) do
    from(s in ScheduledPublication, where: s.group_id in ^group_ids)
    |> Repo.all()
    |> Map.new(&{&1.group_id, &1})
  end

  @doc "When the next publication is due, or nil."
  def next_at do
    Repo.one(from(s in ScheduledPublication, where: is_nil(s.failure), select: min(s.publish_at)))
  end

  @doc """
  Publishes what is due at `now`, the longest due first. Returns how many it
  published.
  """
  def run_due(now \\ DateTime.utc_now(:second)) do
    from(s in ScheduledPublication,
      where: is_nil(s.failure) and s.publish_at <= ^now,
      order_by: [asc: s.publish_at, asc: s.id],
      limit: @batch,
      select: s.id
    )
    |> Repo.all()
    |> Enum.count(&(publish_due(&1, now) == :published))
  end

  defp publish_due(id, now) do
    case attempt(id, now) do
      {:ok, result} ->
        result

      {:error, reason} ->
        fail(id, now, reason)
        :failed
    end
  end

  # The failure goes in by a transaction of its own (`fail/3`): one that
  # failed inside this one leaves nothing more to write in it.
  defp attempt(id, now) do
    Repo.transaction(fn ->
      case lock_due(id, now) do
        nil -> :skip
        scheduled -> publish(scheduled)
      end
    end)
  rescue
    # The database's trouble, not the article's: the next pass tries again.
    exception in DBConnection.ConnectionError ->
      Logger.error("Scheduled publication #{id} failed: #{Exception.message(exception)}")
      {:ok, :skip}

    exception ->
      Logger.error(
        "Scheduled publication #{id} failed: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      {:error, :error}
  end

  # The row, unless another node is publishing it, it is gone, or its editor
  # gave it another time meanwhile.
  defp lock_due(id, now) do
    from(s in ScheduledPublication,
      where: s.id == ^id and is_nil(s.failure) and s.publish_at <= ^now,
      lock: "FOR UPDATE SKIP LOCKED"
    )
    |> Repo.one()
  end

  defp publish(%ScheduledPublication{} = scheduled) do
    profile = Repo.get!(Profile, scheduled.profile_id)
    group = Repo.get!(Group, scheduled.group_id)

    cond do
      # Published by hand meanwhile: nothing is left to do.
      not Group.draft?(group) ->
        Repo.delete!(scheduled)
        :gone

      not Access.can?(profile, group, :edit_group) ->
        Repo.rollback(:not_permitted)

      true ->
        attrs = %{
          "is_public" => scheduled.is_public,
          "inherits_members" => scheduled.inherits_members,
          "inherit_role_keys" => []
        }

        # `update_group/3` signs with the editor; this says how it came about.
        case History.also([via: :scheduled], fn ->
               Social.update_group(profile, group, attrs)
             end) do
          {:ok, _published} ->
            Repo.delete!(scheduled)
            :published

          {:error, :not_permitted} ->
            Repo.rollback(:not_permitted)

          other ->
            Logger.error("Scheduled publication #{scheduled.id} was refused: #{inspect(other)}")
            Repo.rollback(:error)
        end
    end
  end

  defp fail(id, now, reason) do
    from(s in ScheduledPublication,
      where: s.id == ^id and is_nil(s.failure) and s.publish_at <= ^now
    )
    |> Repo.update_all(set: [failure: reason, updated_at: DateTime.utc_now(:second)])

    :ok
  end

  @doc "Deletes what the profiles of a deleted account scheduled (`PotokIde.Accounts.Deletion`)."
  def forget_profiles(profile_ids) when is_list(profile_ids) do
    Repo.delete_all(from(s in ScheduledPublication, where: s.profile_id in ^profile_ids))
    :ok
  end
end
