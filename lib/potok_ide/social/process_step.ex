defmodule PotokIde.Social.ProcessStep do
  @moduledoc """
  One step of an app's process, as the engine hands it to
  `PotokIde.Social.ProcessActions`:

  - `process`: the `AppProcess` whose profile signs what the step does;
  - `instance` and `element`: the instance of the process and the element of
    its graph the step runs, kept with what it writes (`Value.managed`);
  - `triggered_by`: the profile whose action started the step, nil when a
    timer did;
  - `groups`: the ids of the sub-groups the instance has made so far, where
    the process may write besides the app's group.
  """

  @enforce_keys [:process, :instance, :element]
  defstruct [:process, :instance, :element, triggered_by: nil, groups: []]
end
