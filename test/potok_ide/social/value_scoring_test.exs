defmodule PotokIde.Social.ValueScoringTest do
  use ExUnit.Case, async: true

  alias PotokIde.Social.ValueScoring

  @key %{
    "q1" => %{"points" => 2, "eq" => "o3"},
    "q2" => %{"points" => 3, "set" => ["o1", "o4"]},
    "q3" => %{"points" => 1, "text" => ["Beograd"], "others_wrong" => true},
    "q4" => %{"points" => 1, "rows" => %{"r1" => "c2", "r2" => "c1"}},
    "q5" => %{"points" => 2, "row_sets" => %{"r1" => ["c1", "c3"]}},
    "q6" => %{"points" => 5, "manual" => true},
    "q7" => %{"points" => 1, "text" => ["Dunav"]}
  }

  test "scores every kind of check and leaves manual ones waiting" do
    answers = %{
      "q1" => "o3",
      "q2" => ["o4", "o1"],
      "q3" => "  beograd ",
      "q4" => %{"r1" => "c2", "r2" => "c2"},
      "q5" => %{"r1" => ["c3", "c1"]},
      "q6" => "an essay",
      "q7" => "Sava"
    }

    managed = ValueScoring.score(answers, @key)

    assert managed["items"]["q1"] == %{"ok" => true, "points" => 2}
    assert managed["items"]["q2"] == %{"ok" => true, "points" => 3}
    assert managed["items"]["q3"] == %{"ok" => true, "points" => 1}
    assert managed["items"]["q4"] == %{"ok" => false, "points" => 1}
    assert managed["items"]["q5"] == %{"ok" => true, "points" => 2}
    assert managed["items"]["q6"] == %{"ok" => nil, "points" => nil}
    # Without `others_wrong` an unknown text waits for an editor.
    assert managed["items"]["q7"] == %{"ok" => nil, "points" => nil}

    assert managed["score"] == 9
    assert managed["max"] == 2 + 3 + 1 + 2 + 2 + 5 + 1
    assert managed["pending"] == 2
  end

  test "an unanswered question is wrong" do
    managed = ValueScoring.score(%{}, %{"q1" => %{"points" => 2, "eq" => "o3"}})
    assert managed["items"]["q1"] == %{"ok" => false, "points" => 0}
  end

  test "an editor's grade stays when the key changes, cut to the new worth" do
    key = %{"q6" => %{"points" => 5, "manual" => true}}
    answers = %{"q6" => "an essay"}

    graded =
      ValueScoring.grade(nil, %{"q6" => %{"points" => 4, "feedback" => "Good"}}, answers, key)

    assert graded["items"]["q6"] == %{
             "ok" => false,
             "points" => 4,
             "graded" => true,
             "feedback" => "Good"
           }

    assert graded["score"] == 4
    assert graded["pending"] == 0

    rescored = ValueScoring.score(answers, %{"q6" => %{"points" => 3, "manual" => true}}, graded)
    assert rescored["items"]["q6"]["points"] == 3
    assert rescored["items"]["q6"]["ok"] == true
    assert rescored["items"]["q6"]["feedback"] == "Good"
  end

  test "taking a grade back gives the answer to the key again" do
    key = %{"q1" => %{"points" => 2, "eq" => "o3"}}
    graded = ValueScoring.grade(nil, %{"q1" => %{"points" => 0}}, %{"q1" => "o3"}, key)
    assert graded["items"]["q1"]["points"] == 0

    back = ValueScoring.grade(graded, %{"q1" => %{"points" => nil}}, %{"q1" => "o3"}, key)
    assert back["items"]["q1"] == %{"ok" => true, "points" => 2}
  end
end
