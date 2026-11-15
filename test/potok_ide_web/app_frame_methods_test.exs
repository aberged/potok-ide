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
end
