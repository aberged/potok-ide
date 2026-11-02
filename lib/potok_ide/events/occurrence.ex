defmodule PotokIde.Events.Occurrence do
  @moduledoc """
  One occurrence of an event: its local start date in the event's zone, which
  names it, and its UTC start and end.
  """

  @enforce_keys [:event, :date, :starts_at, :ends_at]
  defstruct [:event, :date, :starts_at, :ends_at]
end
