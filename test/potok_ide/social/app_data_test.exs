defmodule PotokIde.Social.AppDataTest do
  @moduledoc """
  An app's collections under the rules its editors keep in its config: who
  writes, who reads everything and who only their own, and what Potok adds.
  """

  use PotokIde.DataCase, async: true

  import PotokIde.EventsFixtures
  import PotokIde.PollsFixtures, only: [share_profile!: 2]

  alias PotokIde.Social
  alias PotokIde.Social.{Access, AppData, Value}

  defp unique, do: System.unique_integer([:positive])

  defp profile!(account) do
    {:ok, profile} =
      Social.create_profile_for_account(account, %{
        username: "ad#{unique()}",
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    profile
  end

  setup do
    {owner_account, owner} = account_with_profile!("ad#{unique()}")
    {member_account, member} = account_with_profile!("ad#{unique()}")
    {reader_account, reader} = account_with_profile!("ad#{unique()}")

    group =
      group_with_members!(owner, [member, reader], %{
        "uses_api" => true,
        "description" => "<p>app</p>",
        "description_format" => :html,
        "home_page" => :description
      })

    {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
    {:ok, role} = Social.create_group_role(owner, group, %{"name" => "pregled"})
    {:ok, _assigned} = Social.assign_group_member_role(owner, group, reader.id, role.key)

    %{
      owner: owner,
      owner_account: owner_account,
      member: member,
      member_account: member_account,
      reader: reader,
      reader_account: reader_account,
      role: role.key,
      group: Social.get_group!(group.id)
    }
  end

  defp config!(ctx, rules, extra \\ %{}) do
    revision =
      case AppData.get_config(ctx.group, nil) do
        nil -> 0
        config -> config.lock_version
      end

    {:ok, config} =
      AppData.save_config(
        ctx.owner,
        ctx.group,
        nil,
        Map.merge(%{"rules" => rules, "form" => %{"title" => "T"}}, extra),
        revision
      )

    config
  end

  defp access(profile, group), do: Access.for_profile(profile, group)

  defp answer!(profile, account, group, answers, collection \\ "responses") do
    {:ok, value, _rule} =
      AppData.insert(profile, account, group, nil, collection, %{"a" => answers})

    value
  end

  defp list!(profile, group, opts \\ [], collection \\ "responses") do
    {:ok, rows, _more?, total} =
      AppData.list(profile, group, nil, access(profile, group), collection, opts)

    {rows, total}
  end

  describe "the config" do
    test "is one value, changed in place with its revision", ctx do
      first = config!(ctx, %{})
      assert first.lock_version == 0
      assert first.collection == "config"

      {:ok, second} = AppData.save_config(ctx.owner, ctx.group, nil, %{"form" => %{}}, 0)
      assert second.id == first.id
      assert second.lock_version == 1

      assert {:error, {:conflict, %Value{lock_version: 1}}} =
               AppData.save_config(ctx.owner, ctx.group, nil, %{"form" => %{}}, 0)
    end

    test "only those who edit the app save it", ctx do
      assert {:error, :not_permitted} = AppData.save_config(ctx.member, ctx.group, nil, %{}, 0)
    end

    test "its secret part goes only to editors, and Potok keeps its files", ctx do
      config = config!(ctx, %{}, %{"secret" => %{"x" => 1}})
      AppData.put_files(config, %{"public" => 123})

      config = config!(ctx, %{}, %{"secret" => %{"x" => 1}, "files" => %{"public" => 999}})
      assert config.data["files"] == %{"public" => 123}

      refute Map.has_key?(
               AppData.config_payload(config, access(ctx.member, ctx.group)).data,
               "secret"
             )

      assert AppData.config_payload(config, access(ctx.owner, ctx.group)).data["secret"] == %{
               "x" => 1
             }
    end

    test "refuses rules that cannot hold", ctx do
      assert {:error, :anonymous_uploads} =
               AppData.save_config(
                 ctx.owner,
                 ctx.group,
                 nil,
                 %{
                   "rules" => %{
                     "responses" => %{
                       "anonymous" => true,
                       "under" => ["a"],
                       "uploads" => %{"q1" => %{"target" => "private"}}
                     }
                   }
                 },
                 0
               )
    end
  end

  describe "writing" do
    test "takes a member with a role on the list", ctx do
      config!(ctx, %{"responses" => %{"write" => [ctx.role]}})

      assert {:error, :role} =
               AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, "responses", %{
                 "a" => %{}
               })

      assert {:ok, %Value{collection: "responses"}, _rule} =
               AppData.insert(ctx.reader, ctx.reader_account, ctx.group, nil, "responses", %{
                 "a" => %{}
               })
    end

    test "refuses a closed collection", ctx do
      config!(ctx, %{"responses" => %{"open" => false}})

      assert {:error, :closed} =
               AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, "responses", %{
                 "a" => %{}
               })
    end

    test "refuses what is too big and names Potok keeps", ctx do
      config!(ctx, %{"responses" => %{}})
      big = %{"a" => %{"q1" => String.duplicate("x", 70_000)}}

      assert {:error, :too_large} =
               AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, "responses", big)

      assert {:error, :invalid_collection} =
               AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, "config", %{})
    end

    test "once takes one answer per account, whichever profile, but a really shared profile answers on its own",
         ctx do
      config!(ctx, %{"responses" => %{"once" => true}})
      second = profile!(ctx.member_account)
      add_member!(ctx.owner, ctx.group, second)

      answer!(ctx.member, ctx.member_account, ctx.group, %{})

      assert {:error, :already_answered} =
               AppData.insert(ctx.member, ctx.member_account, ctx.group, nil, "responses", %{
                 "a" => %{}
               })

      assert {:error, :already_answered} =
               AppData.insert(second, ctx.member_account, ctx.group, nil, "responses", %{
                 "a" => %{}
               })

      {:ok, shared} =
        Social.update_profile_for_account(ctx.member_account, second.id, %{sharing: :shared})

      share_profile!(shared, ctx.owner_account)

      assert {:ok, _value, _rule} =
               AppData.insert(shared, ctx.member_account, ctx.group, nil, "responses", %{
                 "a" => %{}
               })

      assert AppData.answered?(ctx.member, ctx.member_account, ctx.group, nil, "responses")
    end

    test "a public rule takes signed-in non-members of a public group, unless blocked", ctx do
      {outsider_account, outsider} = account_with_profile!("ad#{unique()}")
      {:ok, group} = Social.update_group(ctx.owner, ctx.group, %{"is_public" => true})
      ctx = %{ctx | group: group}
      config!(ctx, %{"responses" => %{"public" => true}})

      assert {:ok, value, _rule} =
               AppData.insert(outsider, outsider_account, group, nil, "responses", %{
                 "a" => %{"q" => 1}
               })

      assert {[%{id: id}], _} = list!(outsider, group)
      assert id == value.id

      {:ok, _block} = Social.block_from_group(ctx.owner, group, outsider)

      assert {:error, :blocked} =
               AppData.insert(outsider, outsider_account, group, nil, "responses", %{"a" => %{}})
    end

    test "a rule that is not public keeps non-members out", ctx do
      {outsider_account, outsider} = account_with_profile!("ad#{unique()}")
      {:ok, group} = Social.update_group(ctx.owner, ctx.group, %{"is_public" => true})
      config!(%{ctx | group: group}, %{"responses" => %{}})

      assert {:error, :members_only} =
               AppData.insert(outsider, outsider_account, group, nil, "responses", %{"a" => %{}})

      assert {:error, :not_a_member} =
               AppData.list(outsider, group, nil, access(outsider, group), "responses")
    end
  end

  describe "reading" do
    setup ctx do
      config!(ctx, %{"responses" => %{"read" => [ctx.role]}})

      first = answer!(ctx.member, ctx.member_account, ctx.group, %{"q1" => "o1"})
      second = answer!(ctx.owner, ctx.owner_account, ctx.group, %{"q1" => "o2"})
      %{first: first, second: second}
    end

    test "a member reads only their own", ctx do
      assert {[%{id: id}], 1} = list!(ctx.member, ctx.group, total: true)
      assert id == ctx.first.id
    end

    test "a reader and an editor read everything, newest first when asked", ctx do
      assert {[%{id: newest}, %{id: oldest}], 2} =
               list!(ctx.reader, ctx.group, total: true, order_dir: "desc")

      assert {newest, oldest} == {ctx.second.id, ctx.first.id}
      assert {[_, _], _} = list!(ctx.owner, ctx.group)
    end

    test "match and mine narrow a reader's page", ctx do
      assert {[%{id: id}], 1} =
               list!(ctx.reader, ctx.group, match: %{"a" => %{"q1" => "o2"}}, total: true)

      assert id == ctx.second.id
      assert {[], 0} = list!(ctx.reader, ctx.group, mine: true, total: true)
    end

    test "a page lies right next to its cursor, oldest first too", ctx do
      third = answer!(ctx.reader, ctx.reader_account, ctx.group, %{"q1" => "o3"})

      assert {:ok, [%{id: id}], true, nil} =
               AppData.list(
                 ctx.reader,
                 ctx.group,
                 nil,
                 access(ctx.reader, ctx.group),
                 "responses",
                 before_id: third.id,
                 limit: 1
               )

      assert id == ctx.second.id
    end

    test "a full reader adds up a collection; others may not", ctx do
      assert {:ok, %{total: 2, buckets: buckets}} =
               AppData.aggregate(ctx.group, nil, access(ctx.reader, ctx.group), "responses",
                 under: ["a"],
                 group_by: "q1"
               )

      assert Enum.map(buckets, &{&1.value, &1.count}) == [{"o1", 1}, {"o2", 1}]

      assert {:error, :not_permitted} =
               AppData.aggregate(ctx.group, nil, access(ctx.member, ctx.group), "responses", [])

      {_outsider_account, outsider} = account_with_profile!("ad#{unique()}")

      assert {:error, :not_a_member} =
               AppData.aggregate(ctx.group, nil, access(outsider, ctx.group), "responses", [])

      assert {:error, :invalid_collection} =
               AppData.aggregate(ctx.group, nil, access(ctx.owner, ctx.group), "config", [])
    end

    test "a member's match is ignored, as it could find others' values", ctx do
      assert {[%{id: id}], _} = list!(ctx.member, ctx.group, match: %{"a" => %{"q1" => "o2"}})
      assert id == ctx.first.id
    end

    test "values in collections stay out of the lists of apps that use none", ctx do
      {:ok, _legacy} =
        Social.create_data_value(ctx.member, ctx.group, %{
          "content" => "data:",
          "data" => %{"x" => 1}
        })

      {rows, false} = Social.list_group_data_value_rows(ctx.group)
      assert Enum.map(rows, & &1.data) == [%{"x" => 1}]
    end

    test "a collection without a rule is closed", ctx do
      answer!(ctx.member, ctx.member_account, ctx.group, %{}, "notes")
      answer!(ctx.reader, ctx.reader_account, ctx.group, %{}, "notes")

      assert {[_mine], _} = list!(ctx.member, ctx.group, [], "notes")
      assert {[_, _], _} = list!(ctx.owner, ctx.group, [], "notes")
    end
  end

  test "an anonymous value never shows its author to others, even after the rule changes", ctx do
    config!(ctx, %{"responses" => %{"read" => ["everyone"], "anonymous" => true}})
    value = answer!(ctx.member, ctx.member_account, ctx.group, %{})
    assert value.anonymous

    config!(ctx, %{"responses" => %{"read" => ["everyone"], "anonymous" => false}})

    assert {[%{creator_id: nil, creator_username: nil}], _} = list!(ctx.reader, ctx.group)
    assert {[%{creator_id: creator_id}], _} = list!(ctx.member, ctx.group)
    assert creator_id == ctx.member.id
  end

  describe "changing and deleting" do
    test "an author changes their own value where the rule allows, with its revision", ctx do
      config!(ctx, %{"responses" => %{"edit_own" => true}})
      value = answer!(ctx.member, ctx.member_account, ctx.group, %{"q1" => "o1"})

      assert {:ok, updated, _rule} =
               AppData.update(ctx.member, ctx.group, nil, value.id, %{"a" => %{"q1" => "o2"}}, 0)

      assert updated.lock_version == 1
      assert updated.data == %{"a" => %{"q1" => "o2"}}

      assert {:error, {:conflict, %Value{}}} =
               AppData.update(ctx.member, ctx.group, nil, value.id, %{"a" => %{}}, 0)

      assert {:error, :not_permitted} =
               AppData.update(ctx.reader, ctx.group, nil, value.id, %{"a" => %{}}, nil)
    end

    test "nobody changes a value where the rule does not say so", ctx do
      config!(ctx, %{"responses" => %{}})
      value = answer!(ctx.member, ctx.member_account, ctx.group, %{})

      assert {:error, :not_permitted} =
               AppData.update(ctx.member, ctx.group, nil, value.id, %{"a" => %{}}, nil)
    end

    test "editors delete one value or the whole collection", ctx do
      config!(ctx, %{"responses" => %{}})
      value = answer!(ctx.member, ctx.member_account, ctx.group, %{})
      answer!(ctx.reader, ctx.reader_account, ctx.group, %{})

      assert {:error, :not_permitted} = AppData.delete(ctx.member, ctx.group, nil, value.id)
      assert {:ok, _deleted} = AppData.delete(ctx.owner, ctx.group, nil, value.id)
      assert {:ok, 1} = AppData.delete_collection(ctx.owner, ctx.group, nil, "responses")
      assert AppData.get_config(ctx.group, nil)
    end
  end

  describe "summaries" do
    setup ctx do
      config!(ctx, %{
        "responses" => %{"read" => [ctx.role], "summary" => ["everyone"], "under" => ["a"]}
      })

      answer!(ctx.member, ctx.member_account, ctx.group, %{
        "q1" => "o1",
        "q2" => ["o1", "o2"],
        "q4" => %{"r1" => "c1", "r2" => ["c1", "c2"]}
      })

      answer!(ctx.owner, ctx.owner_account, ctx.group, %{
        "q1" => "o1",
        "q2" => ["o2"],
        "q4" => %{"r1" => "c2"}
      })

      answer!(ctx.reader, ctx.reader_account, ctx.group, %{"q1" => "o2", "q3" => "free text"})
      :ok
    end

    test "count choices, list elements and grid rows in the database", ctx do
      {:ok, summary} =
        AppData.summarize(ctx.group, nil, access(ctx.reader, ctx.group), "responses",
          keys: ["q1", "q2", "q4"]
        )

      assert summary.total == 3
      assert summary.keys["q1"].answered == 3
      assert summary.keys["q1"].rows[nil].buckets == [{"o1", 2}, {"o2", 1}]
      assert summary.keys["q2"].rows[nil].buckets == [{"o2", 2}, {"o1", 1}]
      assert summary.keys["q4"].rows["r1"].buckets == [{"c1", 1}, {"c2", 1}]
      assert summary.keys["q4"].rows["r2"].buckets == [{"c1", 1}, {"c2", 1}]
      refute Map.has_key?(summary.keys, "q3")
    end

    test "summary roles see counts, others do not", ctx do
      assert {:ok, _summary} =
               AppData.summarize(ctx.group, nil, access(ctx.member, ctx.group), "responses",
                 keys: ["q1"]
               )

      config!(ctx, %{"responses" => %{"read" => [ctx.role], "under" => ["a"]}})

      assert {:error, :not_permitted} =
               AppData.summarize(ctx.group, nil, access(ctx.member, ctx.group), "responses",
                 keys: ["q1"]
               )
    end
  end

  describe "scores" do
    setup ctx do
      config!(
        ctx,
        %{
          "responses" => %{
            "read" => [ctx.role],
            "under" => ["a"],
            "score" => %{"release" => "manual"}
          }
        },
        %{
          "secret" => %{
            "score" => %{
              "responses" => %{
                "q1" => %{"points" => 2, "eq" => "o1"},
                "q2" => %{"points" => 3, "manual" => true}
              }
            }
          }
        }
      )

      :ok
    end

    test "Potok scores an answer by the hidden key, and again when the key changes", ctx do
      value = answer!(ctx.member, ctx.member_account, ctx.group, %{"q1" => "o1", "q2" => "essay"})
      assert value.managed["score"] == 2
      assert value.managed["pending"] == 1

      config!(
        ctx,
        %{
          "responses" => %{
            "read" => [ctx.role],
            "under" => ["a"],
            "score" => %{"release" => "manual"}
          }
        },
        %{
          "secret" => %{
            "score" => %{
              "responses" => %{
                "q1" => %{"points" => 2, "eq" => "o2"},
                "q2" => %{"points" => 3, "manual" => true}
              }
            }
          }
        }
      )

      assert Repo.get!(Value, value.id).managed["score"] == 0
    end

    test "an editor grades by hand, and the author sees it once released", ctx do
      value = answer!(ctx.member, ctx.member_account, ctx.group, %{"q1" => "o1", "q2" => "essay"})

      assert {:error, :not_permitted} =
               AppData.grade(ctx.reader, ctx.group, nil, value.id, %{"q2" => %{"points" => 3}})

      assert {:ok, graded, _rule} =
               AppData.grade(ctx.owner, ctx.group, nil, value.id, %{"q2" => %{"points" => 3}})

      assert graded.managed["score"] == 5
      assert {[%{managed: nil}], _} = list!(ctx.member, ctx.group)

      config!(
        ctx,
        %{
          "responses" => %{
            "read" => [ctx.role],
            "under" => ["a"],
            "score" => %{"release" => "manual", "released" => true}
          }
        },
        %{
          "secret" => %{
            "score" => %{
              "responses" => %{
                "q1" => %{"points" => 2, "eq" => "o1"},
                "q2" => %{"points" => 3, "manual" => true}
              }
            }
          }
        }
      )

      assert {[%{managed: %{"score" => 5, "items" => items}}], _} = list!(ctx.member, ctx.group)
      assert items["q1"]["expected"] == %{"eq" => "o1"}
    end

    test "score stats go to full readers", ctx do
      answer!(ctx.member, ctx.member_account, ctx.group, %{"q1" => "o1"})
      answer!(ctx.owner, ctx.owner_account, ctx.group, %{"q1" => "o2"})

      {:ok, summary} =
        AppData.summarize(ctx.group, nil, access(ctx.reader, ctx.group), "responses",
          keys: [],
          score: true
        )

      assert summary.score.count == 2
      assert summary.score.average == 1.0
      assert summary.score.items["q1"] == %{"ok" => 1, "bad" => 1}
    end
  end

  describe "notifications" do
    test "full readers turn their push on and off; others may not", ctx do
      config!(ctx, %{"responses" => %{"read" => [ctx.role]}})

      assert {:ok, true} =
               AppData.set_notifications(ctx.reader, ctx.group, nil, "responses", true)

      assert AppData.notifications?(ctx.reader, ctx.group, nil, "responses")

      assert {:ok, false} =
               AppData.set_notifications(ctx.reader, ctx.group, nil, "responses", false)

      refute AppData.notifications?(ctx.reader, ctx.group, nil, "responses")

      assert {:error, :not_permitted} =
               AppData.set_notifications(ctx.member, ctx.group, nil, "responses", true)
    end

    test "a new value goes to subscribers without error", ctx do
      config!(ctx, %{"responses" => %{"read" => [ctx.role]}})
      {:ok, true} = AppData.set_notifications(ctx.reader, ctx.group, nil, "responses", true)

      assert %Value{} = answer!(ctx.member, ctx.member_account, ctx.group, %{})
    end
  end

  test "changes go to the app topic with the rule they were written under", ctx do
    config!(ctx, %{"responses" => %{"read" => [ctx.role]}})
    AppData.subscribe(ctx.group)
    group_id = ctx.group.id
    role = ctx.role

    value = answer!(ctx.member, ctx.member_account, ctx.group, %{})

    assert_receive {:app_value, ^group_id, :created, %{value: %Value{id: id}, read: [^role]}}
    assert id == value.id

    config!(ctx, %{"responses" => %{}})
    assert_receive {:app_value, ^group_id, :config, %{revision: 1}}
  end
end
