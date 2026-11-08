defmodule PotokIde.Social.ValueRulesTest do
  use ExUnit.Case, async: true

  alias PotokIde.Social.{Access, Group, Profile, ValueRules}

  @role "0b7c9f0e-6b55-4f0e-9a4b-1f4c2b9d8e71"
  @now ~U[2026-11-08 12:00:00Z]

  defp member(keys \\ [], permissions \\ []),
    do: %Access{
      member?: true,
      role_keys: ["everyone" | keys],
      permissions: MapSet.new(permissions)
    }

  defp editor, do: member([], [:edit_group])
  defp outsider(blocked? \\ false), do: %Access{blocked?: blocked?}

  defp public_group, do: %Group{id: 1, is_public: true, is_root: false, is_direct: false}
  defp closed_group, do: %Group{id: 1, is_public: false, is_root: false, is_direct: false}

  defp rule(raw) do
    {:ok, rules} = ValueRules.normalize(%{"responses" => raw})
    ValueRules.rule(rules, "responses")
  end

  describe "normalize/1" do
    test "fills in defaults and keeps only known keys and role keys" do
      assert {:ok, %{"responses" => rule}} =
               ValueRules.normalize(%{
                 "responses" => %{
                   "write" => ["everyone", "everyone", "nonsense", @role],
                   "read" => [@role],
                   "extra" => true
                 }
               })

      assert rule["write"] == ["everyone", @role]
      assert rule["read"] == [@role]
      assert rule["open"] == true
      assert rule["once"] == false
      refute Map.has_key?(rule, "extra")
    end

    test "a public rule writes for everyone" do
      assert rule(%{"public" => true, "write" => [@role]}).write == ["everyone"]
    end

    test "refuses reserved and malformed collection names" do
      assert {:error, :invalid_collection} = ValueRules.normalize(%{"config" => %{}})
      assert {:error, :invalid_collection} = ValueRules.normalize(%{"Bad Name" => %{}})
    end

    test "an anonymous collection takes no files, whose senders stay on them" do
      assert {:error, :anonymous_uploads} =
               ValueRules.normalize(%{
                 "responses" => %{
                   "anonymous" => true,
                   "under" => ["a"],
                   "uploads" => %{"q1" => %{"target" => "private"}}
                 }
               })
    end

    test "scores released at once cannot go with editing one's own answer" do
      assert {:error, :immediate_release_edit} =
               ValueRules.normalize(%{
                 "responses" => %{
                   "edit_own" => true,
                   "under" => ["a"],
                   "score" => %{"release" => "immediate"}
                 }
               })
    end

    test "files and scores need to know where the answers are" do
      assert {:error, :under_required} =
               ValueRules.normalize(%{"responses" => %{"score" => %{"release" => "manual"}}})
    end

    test "a slot for files is cut to what storage takes" do
      {:ok, %{"responses" => rule}} =
        ValueRules.normalize(%{
          "responses" => %{
            "under" => ["a"],
            "uploads" => %{
              "q9" => %{"target" => "public", "max_bytes" => 10_000_000_000, "types" => ["pdf"]}
            }
          }
        })

      assert rule["uploads"]["q9"]["max_bytes"] <= PotokIde.Storage.max_file_size()
      assert rule["uploads"]["q9"]["max_files"] == 1
    end
  end

  test "a collection without a rule is closed: members write, only author and editors read" do
    rule = ValueRules.rule(%{}, "notes")
    profile = %Profile{id: 7}

    refute rule.ruled?
    assert ValueRules.write_block(rule, closed_group(), member(), profile, @now) == nil
    refute ValueRules.full_reader?(rule, member())
    assert ValueRules.full_reader?(rule, editor())
  end

  describe "write_block/5" do
    test "a member writes with a role on the list" do
      rule = rule(%{"write" => [@role]})
      profile = %Profile{id: 7}

      assert ValueRules.write_block(rule, closed_group(), member([@role]), profile, @now) == nil
      assert ValueRules.write_block(rule, closed_group(), member(), profile, @now) == :role
    end

    test "nothing goes into a closed collection or one past its deadline" do
      profile = %Profile{id: 7}

      assert ValueRules.write_block(
               rule(%{"open" => false}),
               closed_group(),
               member(),
               profile,
               @now
             ) ==
               :closed

      past = rule(%{"closes_at" => "2026-11-08T11:59:59Z"})
      assert ValueRules.write_block(past, closed_group(), member(), profile, @now) == :closed
    end

    test "a non-member writes only into a public rule of a public group, unblocked" do
      profile = %Profile{id: 7}
      public = rule(%{"public" => true})

      assert ValueRules.write_block(public, public_group(), outsider(), profile, @now) == nil

      assert ValueRules.write_block(public, public_group(), outsider(true), profile, @now) ==
               :blocked

      assert ValueRules.write_block(public, closed_group(), outsider(), profile, @now) ==
               :members_only

      assert ValueRules.write_block(rule(%{}), public_group(), outsider(), profile, @now) ==
               :members_only

      assert ValueRules.write_block(public, public_group(), outsider(), nil, @now) ==
               :not_permitted
    end
  end

  test "summary roles see counts; non-members only of a public rule with everyone on it" do
    rule = rule(%{"summary" => ["everyone"], "public" => true})

    assert ValueRules.summary_reader?(rule, public_group(), member())
    assert ValueRules.summary_reader?(rule, public_group(), outsider())
    refute ValueRules.summary_reader?(rule, closed_group(), outsider())
    refute ValueRules.summary_reader?(rule(%{}), public_group(), member())
  end

  describe "edit_block/6" do
    test "an author changes their own value while open and before scores are out" do
      profile = %Profile{id: 7}
      editable = rule(%{"edit_own" => true})

      assert ValueRules.edit_block(editable, 7, closed_group(), member(), profile, @now) == nil

      assert ValueRules.edit_block(editable, 8, closed_group(), member(), profile, @now) ==
               :not_permitted

      assert ValueRules.edit_block(rule(%{}), 7, closed_group(), member(), profile, @now) ==
               :not_permitted

      released =
        rule(%{
          "edit_own" => true,
          "under" => ["a"],
          "score" => %{"release" => "manual", "released" => true}
        })

      assert ValueRules.edit_block(released, 7, closed_group(), member(), profile, @now) ==
               :released
    end
  end

  describe "present/5" do
    defp row(attrs),
      do:
        Map.merge(
          %{id: 1, creator_id: 7, creator_username: "ana", anonymous: false, managed: nil},
          attrs
        )

    test "someone else's anonymous value loses its author, the author keeps it" do
      rule = rule(%{"read" => ["everyone"], "anonymous" => true})
      row = row(%{anonymous: true})

      assert %{creator_id: nil, creator_username: nil} =
               ValueRules.present(row, rule, 8, member())

      assert %{creator_id: 7, creator_username: "ana"} =
               ValueRules.present(row, rule, 7, member())
    end

    test "scores go to full readers, and to the author once released, as shown" do
      managed = %{
        "score" => 2,
        "max" => 3,
        "pending" => 0,
        "items" => %{
          "q1" => %{"ok" => true, "points" => 2},
          "q2" => %{"ok" => false, "points" => 0}
        }
      }

      key = %{
        "q1" => %{"eq" => "o1", "points" => 2},
        "q2" => %{"eq" => "o2", "points" => 1, "bad" => "Look again"}
      }

      manual =
        rule(%{
          "under" => ["a"],
          "score" => %{"release" => "manual", "show" => %{"correct" => false}}
        })

      row = row(%{managed: managed})

      assert ValueRules.present(row, manual, 8, editor(), key).managed == managed
      assert ValueRules.present(row, manual, 7, member(), key).managed == nil

      released =
        rule(%{
          "under" => ["a"],
          "score" => %{"release" => "manual", "released" => true, "show" => %{"correct" => false}}
        })

      seen = ValueRules.present(row, released, 7, member(), key).managed
      assert seen["score"] == 2
      assert seen["items"]["q2"] == %{"ok" => false, "points" => 0, "feedback" => "Look again"}
      refute Map.has_key?(seen["items"]["q2"], "expected")
      assert ValueRules.present(row, released, 9, member(), key).managed == nil
    end
  end

  test "accepts_type?/2 takes any type for an empty list and categories otherwise" do
    assert ValueRules.accepts_type?([], "application/x-anything")
    assert ValueRules.accepts_type?(["pdf"], "application/pdf")
    refute ValueRules.accepts_type?(["image"], "application/pdf")
  end
end
