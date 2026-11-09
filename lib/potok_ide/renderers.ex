defmodule PotokIde.Renderers do
  @moduledoc """
  Runs ImageMagick drawings one at a time, under the `PotokIde.Renderers`
  task supervisor (one child). ImageMagick runs outside the BEAM, so its
  memory, up to 150 MB for a link card with a big picture, is not counted
  or limited by the VM, and several at once could exhaust a small machine.
  Link cards and PNG avatars both come here; both URLs are public.
  """

  # How long a caller waits for its turn, and how long a drawing may take.
  @turn_timeout 8_000
  @turn_poll 50
  @draw_timeout 15_000

  @doc """
  Runs `fun` once no other drawing runs, returning what it returned, or
  `:error` when no turn came in time, the drawing crashed or took too long.
  """
  def run(fun) when is_function(fun, 0) do
    run(fun, System.monotonic_time(:millisecond) + @turn_timeout)
  end

  defp run(fun, deadline) do
    caller = self()
    ref = make_ref()

    case Task.Supervisor.start_child(__MODULE__, fn -> send(caller, {ref, fun.()}) end) do
      {:ok, pid} ->
        await(pid, ref)

      {:error, :max_children} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@turn_poll)
          run(fun, deadline)
        else
          :error
        end
    end
  end

  defp await(pid, ref) do
    monitor = Process.monitor(pid)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, _reason} ->
        :error
    after
      @draw_timeout ->
        Process.demonitor(monitor, [:flush])
        Task.Supervisor.terminate_child(__MODULE__, pid)
        :error
    end
  end
end
