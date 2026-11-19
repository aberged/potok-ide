defmodule PotokIdeWeb.AppFrameMethodsTest do
  @moduledoc """
  An app calls Potok through its SDK (`potok_app_sdk.js`), and the page lets
  through only the methods it lists (`APP_FRAME_METHODS` in `app.js`): a call
  missing from the list never reaches the server, whatever the server knows,
  and the LiveView tests, which call the server directly, would not tell.
  """

  use ExUnit.Case, async: true

  defp sdk_calls do
    ~r/call\(\s*"([a-z_]+)"/
    |> Regex.scan(File.read!("assets/js/potok_app_sdk.js"), capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end

  defp frame_methods do
    [_, block] =
      Regex.run(
        ~r/const APP_FRAME_METHODS = new Set\(\[(.*?)\]\)/s,
        File.read!("assets/js/app.js")
      )

    ~r/"([a-z_]+)"/
    |> Regex.scan(block, capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end

  test "the page lets through every method the SDK calls, and no other" do
    assert MapSet.difference(sdk_calls(), frame_methods()) == MapSet.new()
    assert MapSet.difference(frame_methods(), sdk_calls()) == MapSet.new()
  end

  test "the calls of processes are among them" do
    for method <- ~w(list_processes complete_task retry_process cancel_process),
        do: assert(method in frame_methods(), method)
  end

  # The SDK names methods in three lists of its own, none of which goes through
  # `call("...")`: a name that is not a method of the page's would do nothing,
  # with no error anywhere.
  defp sdk_list(pattern) do
    [_, block] = Regex.run(pattern, File.read!("assets/js/potok_app_sdk.js"))

    ~r/"([a-z_]+)"/
    |> Regex.scan(block, capture: :all_but_first)
    |> List.flatten()
    |> MapSet.new()
  end

  test "the calls that wait and those that carry a file are methods of the page" do
    waiting = sdk_list(~r/const WAITING_METHODS = new Set\(\[(.*?)\]\)/s)
    files = sdk_list(~r/const FILE_METHODS = new Set\(\[(.*?)\]\)/s)

    assert MapSet.size(waiting) > 0
    assert MapSet.subset?(waiting, frame_methods())
    assert MapSet.size(files) > 0
    assert MapSet.subset?(files, waiting)
  end

  test "a guest's frame answers in the browser exactly what the server leaves to it" do
    [_, block] =
      Regex.run(
        ~r/const APP_FRAME_GUEST_LOCAL = new Set\(\[(.*?)\]\)/s,
        File.read!("assets/js/app.js")
      )

    local =
      ~r/"([a-z_]+)"/
      |> Regex.scan(block, capture: :all_but_first)
      |> List.flatten()
      |> MapSet.new()

    assert local == MapSet.new(PotokIdeWeb.GroupLive.Show.AppApi.local_guest_methods())
    assert MapSet.subset?(local, frame_methods())
  end

  test "what the page pushes goes on to a site in the app's frame only by methods of the page" do
    readers = sdk_list(~r/const SITE_EVENT_READERS = \{(.*?)\n\}/s)

    assert "list_values" in readers
    assert MapSet.subset?(readers, frame_methods())
  end
end
