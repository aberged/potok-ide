defmodule PotokIde.Polls.Deadlines do
  @moduledoc """
  What falls due on its own: polls past their deadline get closed and reminders
  go out. `PotokIde.Polls.Scheduler` calls `run/1`.

  A vote checks the time itself (`Poll.open?/2`), so a deadline holds to the
  second whatever this does. This only writes the end and tells people. It is
  safe on every node: a row one of them is working on is skipped by the others.
  """

  import Ecto.Query

  alias PotokIde.Polls
  alias PotokIde.Polls.{Notifications, Poll}
  alias PotokIde.Repo
  alias PotokIde.Social.Group

  @batch 200

  @doc "Handles what is due at `now`."
  def run(now \\ DateTime.utc_now(:second)) do
    close_due(now)
    send_due_reminders(now)
  end

  @doc "Closes the polls past their deadline, and returns them."
  def close_due(%DateTime{} = now) do
    {:ok, closed} =
      Repo.transaction(fn ->
        from(p in Poll,
          where: is_nil(p.closed_at) and not is_nil(p.closes_at) and p.closes_at <= ^now,
          order_by: [asc: p.closes_at],
          limit: @batch,
          lock: "FOR UPDATE SKIP LOCKED"
        )
        |> Repo.all()
        |> Enum.map(&Polls.close_locked(&1, Repo.get!(Group, &1.group_id), &1.closes_at))
      end)

    Enum.each(closed, fn poll ->
      Notifications.deliver_closed(poll, nil)
      Polls.refresh(poll)
    end)

    closed
  end

  @doc "Sends the reminders that are due, each once."
  def send_due_reminders(%DateTime{} = now) do
    {:ok, due} =
      Repo.transaction(fn ->
        polls =
          from(p in Poll,
            where: not is_nil(p.remind_at) and p.remind_at <= ^now and is_nil(p.closed_at),
            limit: @batch,
            lock: "FOR UPDATE SKIP LOCKED"
          )
          |> Repo.all()

        ids = Enum.map(polls, & &1.id)
        Repo.update_all(from(p in Poll, where: p.id in ^ids), set: [remind_at: nil])
        polls
      end)

    Enum.each(due, fn poll ->
      Notifications.deliver_reminder(poll, Repo.get!(Group, poll.group_id))
    end)

    due
  end
end
