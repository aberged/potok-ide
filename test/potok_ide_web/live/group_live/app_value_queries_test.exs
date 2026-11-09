defmodule PotokIdeWeb.GroupLive.AppValueQueriesTest do
  @moduledoc """
  Listing, counting and adding up an app's values outside collections through
  the App API: newest first, pages next to a cursor, `match`, `total` and
  `aggregate_values`.
  """

  use PotokIdeWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import PotokIde.EventsFixtures

  alias PotokIde.Social

  defp unique, do: System.unique_integer([:positive])

  setup do
    {_owner_account, owner} = account_with_profile!("vq#{unique()}")
    {member_account, member} = account_with_profile!("vq#{unique()}")
    {visitor_account, _visitor} = account_with_profile!("vq#{unique()}")

    group =
      group_with_members!(owner, [member], %{
        "uses_api" => true,
        "is_public" => true,
        "description" => "<p>app</p>",
        "description_format" => :html,
        "home_page" => :description
      })

    values =
      for {status, amount} <- [{"open", 10}, {"done", "2.5"}, {"open", 4}] do
        {:ok, value} =
          Social.create_data_value(owner, group, %{
            "content" => "data:",
            "data" => %{"status" => status, "amount" => amount}
          })

        value
      end

    %{
      member_account: member_account,
      visitor_account: visitor_account,
      group: group,
      values: values
    }
  end

  defp open_app(account, group) do
    {:ok, lv, _html} =
      build_conn()
      |> log_in_account(account)
      |> live(~p"/groups/#{group.id}/group_home")

    lv
  end

  defp call(lv, method, params) do
    render_hook(lv, "app_api", %{method: method, params: params, app_id: ""})
    assert_reply(lv, reply)
    reply
  end

  defp ids(%{values: values}), do: Enum.map(values, & &1.id)

  test "a member lists newest first, next to a cursor, by match and with a total", ctx do
    lv = open_app(ctx.member_account, ctx.group)
    [first, second, third] = Enum.map(ctx.values, & &1.id)

    reply = call(lv, "list_values", %{order_dir: "desc", limit: 2})
    assert %{ok: true, has_more: true, total: nil} = reply
    assert ids(reply) == [third, second]

    reply = call(lv, "list_values", %{before_id: third, limit: 1})
    assert %{ok: true, has_more: true} = reply
    assert ids(reply) == [second]

    reply = call(lv, "list_values", %{match: %{status: "open"}, total: true})
    assert %{ok: true, has_more: false, total: 2} = reply
    assert ids(reply) == [first, third]

    assert %{ok: true, total: 3} = call(lv, "list_values", %{match: %{}, total: true})
  end

  test "a broken match is refused, not read as everything", ctx do
    lv = open_app(ctx.member_account, ctx.group)
    too_big = %{"text" => String.duplicate("x", 5_000)}

    assert %{ok: false, error: "invalid_match"} = call(lv, "list_values", %{match: "open"})
    assert %{ok: false, error: "invalid_match"} = call(lv, "list_values", %{match: too_big})
    assert %{ok: false, error: "invalid_match"} = call(lv, "aggregate_values", %{match: [1]})
  end

  test "a member adds up numbers, in all and per group", ctx do
    lv = open_app(ctx.member_account, ctx.group)

    assert %{
             ok: true,
             total: 3,
             fields: %{"amount" => %{count: 3, sum: 16.5, avg: 5.5, min: 2.5, max: 10.0}},
             buckets: [
               %{value: "open", count: 2, fields: %{"amount" => %{sum: 14.0}}},
               %{value: "done", count: 1}
             ],
             other: nil
           } = call(lv, "aggregate_values", %{group_by: "status", fields: ["amount"]})

    assert %{ok: true, total: 1, buckets: nil} =
             call(lv, "aggregate_values", %{match: %{status: "done"}})

    assert %{ok: false, error: "invalid_aggregate"} =
             call(lv, "aggregate_values", %{fields: ~w(a b c d e f)})
  end

  test "a visitor of the public group may not list or add up its values", ctx do
    lv = open_app(ctx.visitor_account, ctx.group)

    assert %{ok: false, error: "not_a_member"} = call(lv, "list_values", %{})
    assert %{ok: false, error: "not_a_member"} = call(lv, "aggregate_values", %{})
  end

  test "counts and sums are limited per viewer", ctx do
    lv = open_app(ctx.member_account, ctx.group)
    {max, _window} = PotokIde.RateLimit.limit(:app_heavy_read)

    # A window may end during the loop, so allow for two of them.
    replies =
      Stream.repeatedly(fn -> call(lv, "aggregate_values", %{}) end)
      |> Stream.take(2 * max + 1)
      |> Enum.find(&(&1[:error] == "rate_limited"))

    assert %{ok: false, error: "rate_limited", message: _} = replies

    # Plain lists stay free.
    assert %{ok: true} = call(lv, "list_values", %{limit: 1})
  end
end
