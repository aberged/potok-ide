defmodule PotokIde.Processes.ExprTest do
  use ExUnit.Case, async: true

  alias PotokIde.Processes.Expr

  @entities %{
    "7" => %{
      "name" => "Prijava",
      "attributes" => [
        %{"name" => "naslov", "type" => "text"},
        %{"name" => "sprat", "type" => "number"},
        %{"name" => "hitno", "type" => "boolean"},
        %{"name" => "vrsta", "type" => "choice", "options" => ["voda", "struja"]},
        %{"name" => "prijavljeno", "type" => "date"},
        %{"name" => "stan", "type" => "entity", "entity" => 8},
        %{"name" => "slike", "type" => "text", "list" => true}
      ]
    },
    "8" => %{"name" => "Stan", "attributes" => [%{"name" => "broj", "type" => "number"}]}
  }

  @scope %{
    names: %{
      "start" => {:entity, 7},
      "ukupno" => :number,
      "ime" => :text,
      "kada" => :datetime,
      "stanovi" => {:list, {:entity, 8}},
      "odluka" => {:record, %{"outcome" => :text, "by" => :text}, false},
      "group" => {:record, %{}, true},
      "bilo_sta" => :any
    },
    entities: @entities
  }

  defp d(text), do: Decimal.new(text)

  defp check(text) do
    {:ok, tree} = Expr.parse(text)
    Expr.check(tree, @scope)
  end

  defp eval(text, data \\ %{}, opts \\ %{}) do
    {:ok, tree} = Expr.parse(text)
    Expr.eval(tree, data, opts)
  end

  defp eval!(text, data \\ %{}, opts \\ %{}) do
    {:ok, value} = eval(text, data, opts)
    value
  end

  describe "parse/1" do
    test "reads numbers, texts and words" do
      assert Expr.parse("12.5") == {:ok, {:value, d("12.5")}}
      assert Expr.parse(~s|"Kvar"|) == {:ok, {:value, "Kvar"}}
      assert Expr.parse("'Kvar'") == {:ok, {:value, "Kvar"}}
      assert Expr.parse("true") == {:ok, {:value, true}}
      assert Expr.parse("false") == {:ok, {:value, false}}
      assert Expr.parse("empty") == {:ok, {:value, nil}}
    end

    test "reads the quotes a phone curls" do
      assert Expr.parse("„Kvar“") == {:ok, {:value, "Kvar"}}
      assert Expr.parse("“Kvar”") == {:ok, {:value, "Kvar"}}
      assert Expr.parse("‘Kvar’") == {:ok, {:value, "Kvar"}}
    end

    test "keeps what a backslash guards in a text" do
      assert Expr.parse(~S|"kaže \"da\""|) == {:ok, {:value, ~s|kaže "da"|}}
      assert Expr.parse(~S|"red\ndrugi"|) == {:ok, {:value, "red\ndrugi"}}
    end

    test "reads names, attributes and items" do
      assert Expr.parse("start") == {:ok, {:name, "start"}}
      assert Expr.parse("start.sprat") == {:ok, {:attribute, {:name, "start"}, "sprat"}}
      assert Expr.parse("šifra_1") == {:ok, {:name, "šifra_1"}}
      assert Expr.parse("спрат") == {:ok, {:name, "спрат"}}

      assert Expr.parse("stanovi[0].broj") ==
               {:ok, {:attribute, {:index, {:name, "stanovi"}, {:value, d("0")}}, "broj"}}

      assert Expr.parse(~s|group["broj-kvarova"]|) ==
               {:ok, {:index, {:name, "group"}, {:value, "broj-kvarova"}}}

      # A word of the language may still name an attribute.
      assert Expr.parse("poziv.empty") == {:ok, {:attribute, {:name, "poziv"}, "empty"}}
    end

    test "a minus between two names is a minus" do
      assert Expr.parse("a-b") == {:ok, {:op, :-, {:name, "a"}, {:name, "b"}}}
      assert Expr.parse("call-1") == {:ok, {:op, :-, {:name, "call"}, {:value, d("1")}}}
    end

    test "counts before it joins, joins before it compares, compares before and, or" do
      assert Expr.parse("1 + 2 * 3") ==
               {:ok, {:op, :+, {:value, d("1")}, {:op, :*, {:value, d("2")}, {:value, d("3")}}}}

      assert Expr.parse("(1 + 2) * 3") ==
               {:ok, {:op, :*, {:op, :+, {:value, d("1")}, {:value, d("2")}}, {:value, d("3")}}}

      assert Expr.parse("10 - 2 - 3") ==
               {:ok, {:op, :-, {:op, :-, {:value, d("10")}, {:value, d("2")}}, {:value, d("3")}}}

      assert Expr.parse(~s|"a" & 1 + 2|) ==
               {:ok, {:op, :&, {:value, "a"}, {:op, :+, {:value, d("1")}, {:value, d("2")}}}}

      assert Expr.parse("a > 1 and not b or c") ==
               {:ok,
                {:op, :or,
                 {:op, :and, {:op, :>, {:name, "a"}, {:value, d("1")}}, {:not, {:name, "b"}}},
                 {:name, "c"}}}

      assert Expr.parse("-a * 2") == {:ok, {:op, :*, {:minus, {:name, "a"}}, {:value, d("2")}}}
    end

    test "reads == as =" do
      assert Expr.parse("a == 1") == Expr.parse("a = 1")
    end

    test "reads calls" do
      assert Expr.parse("today()") == {:ok, {:call, "today", []}}

      assert Expr.parse("if(a, 1, 2)") ==
               {:ok, {:call, "if", [{:name, "a"}, {:value, d("1")}, {:value, d("2")}]}}

      assert Expr.parse("empty(a)") == {:ok, {:call, "empty", [{:name, "a"}]}}
    end

    test "says where it stops making sense" do
      assert Expr.parse("") == {:error, {:syntax, 0}}
      assert Expr.parse("1 +") == {:error, {:syntax, 3}}
      assert Expr.parse("1 2") == {:error, {:syntax, 2}}
      assert Expr.parse("a < b < c") == {:error, {:syntax, 6}}
      assert Expr.parse("(1 + 2") == {:error, {:syntax, 6}}
      assert Expr.parse(~s|"otvoren|) == {:error, {:syntax, 0}}
      assert Expr.parse("a # b") == {:error, {:syntax, 2}}
      assert Expr.parse("a.") == {:error, {:syntax, 2}}
      assert Expr.parse("lista[0") == {:error, {:syntax, 7}}
      assert Expr.parse("f(1,") == {:error, {:syntax, 4}}
    end

    test "refuses what is too long or nests too deep" do
      assert {:error, {:syntax, _}} = Expr.parse(String.duplicate("1 + ", 300) <> "1")

      assert {:error, {:syntax, _}} =
               Expr.parse(String.duplicate("(", 60) <> "1" <> String.duplicate(")", 60))

      assert {:ok, _tree} =
               Expr.parse(String.duplicate("(", 20) <> "1" <> String.duplicate(")", 20))
    end
  end

  describe "template/1" do
    test "splits a text at its expressions" do
      assert Expr.template("Kvar: {{start.naslov}}, sprat {{ start.sprat + 1 }}.") ==
               {:ok,
                [
                  "Kvar: ",
                  {:attribute, {:name, "start"}, "naslov"},
                  ", sprat ",
                  {:op, :+, {:attribute, {:name, "start"}, "sprat"}, {:value, d("1")}},
                  "."
                ]}

      assert Expr.template("bez umetaka") == {:ok, ["bez umetaka"]}
      assert Expr.template("") == {:ok, [""]}
    end

    test "names the place of a broken expression in the whole text" do
      assert Expr.template("Kvar: {{start.}}") == {:error, {:syntax, 14}}
      assert Expr.template("{{}}") == {:error, {:syntax, 2}}
    end
  end

  describe "check/2" do
    test "gives the type of names, attributes and items" do
      assert check("ukupno") == {:ok, :number}
      assert check("start.naslov") == {:ok, :text}
      assert check("start.stan.broj") == {:ok, :number}
      assert check("start.slike") == {:ok, {:list, :text}}
      assert check("start.slike[0]") == {:ok, :text}
      assert check("stanovi[1].broj") == {:ok, :number}
      assert check("odluka.outcome") == {:ok, :text}
      assert check("group.kvarova") == {:ok, :any}
      assert check(~s|group["broj-kvarova"]|) == {:ok, :any}
      assert check("bilo_sta.x.y") == {:ok, :any}
    end

    test "names what a process does not have" do
      assert check("nema") == {:error, {:unknown_name, "nema"}}
      assert check("start.nema") == {:error, {:unknown_attribute, "nema"}}
      assert check("odluka.nema") == {:error, {:unknown_attribute, "nema"}}
      assert check("ukupno.x") == {:error, {:mismatch, :record, :number}}
      assert check("ukupno[0]") == {:error, {:mismatch, :list, :number}}
      assert check("nema(1)") == {:error, {:unknown_function, "nema"}}
      assert check("round()") == {:error, {:arguments, "round"}}
    end

    test "counts with numbers only" do
      assert check("ukupno + start.sprat * 2") == {:ok, :number}
      assert check("-ukupno") == {:ok, :number}
      assert check("group.kvarova + 1") == {:ok, :number}
      assert check("ukupno + ime") == {:error, {:mismatch, :number, :text}}
      assert check(~s|1 + "2"|) == {:error, {:mismatch, :number, :text}}
    end

    test "joins what a text can show" do
      assert check(~s|"Sprat " & start.sprat & ", " & start.prijavljeno|) == {:ok, :text}
      assert check(~s|"Stan " & start.stan|) == {:error, {:mismatch, :text, {:entity, 8}}}
    end

    test "compares like with like" do
      assert check("ukupno > 10") == {:ok, :boolean}
      assert check(~s|start.naslov = "Lift"|) == {:ok, :boolean}
      assert check(~s|start.vrsta = "voda"|) == {:ok, :boolean}
      assert check("start.prijavljeno < today()") == {:ok, :boolean}
      assert check("start.naslov = empty") == {:ok, :boolean}
      assert check("group.kvarova > 10") == {:ok, :boolean}
      assert check(~s|group.poslednji = "Lift"|) == {:ok, :boolean}
      assert check(~s|ukupno = "deset"|) == {:error, {:mismatch, :number, :text}}
      assert check("start.prijavljeno < kada") == {:error, {:mismatch, :date, :datetime}}
      assert check("start.hitno > 1") == {:error, {:mismatch, :number, :boolean}}
    end

    test "takes only what is true or false in and, or, not" do
      assert check("start.hitno and ukupno > 1 or not start.hitno") == {:ok, :boolean}
      assert check("ukupno and start.hitno") == {:error, {:mismatch, :boolean, :number}}
      assert check("not ime") == {:error, {:mismatch, :boolean, :text}}
    end

    test "knows what each function takes and gives" do
      assert check(~s|if(start.hitno, "odmah", "sutra")|) == {:ok, :text}
      assert check("if(start.hitno, 1, empty)") == {:ok, :number}
      assert check(~s|if(start.hitno, 1, "dva")|) == {:error, {:mismatch, :number, :text}}
      assert check("empty(start.stan)") == {:ok, :boolean}
      assert check("length(start.slike)") == {:ok, :number}
      assert check("length(ime)") == {:ok, :number}
      assert check("length(ukupno)") == {:error, {:mismatch, :list, :number}}
      assert check(~s|contains(start.slike, "a.png")|) == {:ok, :boolean}
      assert check("contains(start.slike, 1)") == {:error, {:mismatch, :text, :number}}
      assert check(~s|contains(ime, "an")|) == {:ok, :boolean}
      assert check("first(stanovi)") == {:ok, {:entity, 8}}
      assert check("last(stanovi).broj") == {:ok, :number}
      assert check("sum(start.slike)") == {:error, {:mismatch, :number, :text}}
      assert check(~s|join(start.slike, "; ")|) == {:ok, :text}
      assert check("text(ukupno)") == {:ok, :text}
      assert check("number(ime)") == {:ok, :number}
      assert check("number(start.hitno)") == {:error, {:mismatch, :number, :boolean}}
      assert check("round(ukupno / 3, 2)") == {:ok, :number}
      assert check("today()") == {:ok, :date}
      assert check("now()") == {:ok, :datetime}
      assert check("upper(ime)") == {:ok, :text}
      assert check("add_days(start.prijavljeno, 7)") == {:ok, :date}
      assert check("add_days(kada, 1)") == {:ok, :datetime}
      assert check("add_days(ime, 1)") == {:error, {:mismatch, :date, :text}}
    end
  end

  describe "check_template/2" do
    test "checks every expression of a text" do
      {:ok, parts} = Expr.template("Kvar {{start.naslov}} na {{start.sprat}}.")
      assert Expr.check_template(parts, @scope) == :ok

      {:ok, parts} = Expr.template("Kvar {{naslov}}")
      assert Expr.check_template(parts, @scope) == {:error, {:unknown_name, "naslov"}}
    end
  end

  describe "eval/3" do
    test "counts exactly" do
      assert eval!("0.1 + 0.2") == d("0.3")
      assert eval!("10 - 2 - 3") == d("5")
      assert eval!("2 + 3 * 4") == d("14")
      assert eval!("-(2 + 3)") == d("-5")
      assert Decimal.equal?(eval!("1 / 4"), d("0.25"))
      assert eval!("round(10 / 3, 2)") == d("3.33")
      assert eval!("round(2.5)") == d("3")
    end

    test "counts with what it is given, as numbers" do
      data = %{"ukupno" => d("5"), "group" => %{"kvarova" => "7"}, "start" => %{"sprat" => 2}}
      assert eval!("ukupno + 1", data) == d("6")
      assert eval!("group.kvarova + 1", data) == d("8")
      assert eval!("start.sprat * 2.5", data) == d("5.0")
    end

    test "fails where it cannot count" do
      assert eval("1 / 0") == {:error, :division_by_zero}
      assert eval(~s|ime + 1|, %{"ime" => "Mika"}) == {:error, :not_a_number}
      assert eval("nema + 1") == {:error, :not_a_number}
      assert eval(String.duplicate("1000000000 * ", 9) <> "1") == {:error, :number_too_large}
    end

    test "reads attributes and items, and nothing where there is none" do
      data = %{
        "start" => %{"naslov" => "Lift", "stan" => %{"broj" => d("12")}, "broj-prijava" => "3"},
        "stanovi" => [%{"broj" => d("1")}, %{"broj" => d("2")}]
      }

      assert eval!("start.naslov", data) == "Lift"
      assert eval!("start.stan.broj", data) == d("12")
      assert eval!(~s|start["broj-prijava"]|, data) == "3"
      assert eval!("stanovi[1].broj", data) == d("2")
      assert eval!("stanovi[5]", data) == nil
      assert eval!("stanovi[-1]", data) == nil
      assert eval!("start.nema.dalje", data) == nil
      assert eval!("nema", data) == nil
    end

    test "joins texts" do
      data = %{"start" => %{"naslov" => "Lift", "sprat" => d("3.50"), "dan" => ~D[2026-11-16]}}

      assert eval!(~s|"Kvar: " & start.naslov & ", sprat " & start.sprat|, data) ==
               "Kvar: Lift, sprat 3.5"

      assert eval!(~s|"Dan " & start.dan|, data) == "Dan 16. 11. 2026."
      assert eval!(~s|"nema" & start.nema|, data) == "nema"
    end

    test "compares numbers as numbers, days as days and texts as texts" do
      assert eval!("2 < 10")
      assert eval!(~s|"2" < "10"|)
      assert eval!(~s|"b" > "a"|)
      assert eval!(~s|" Lift " = "Lift"|)
      refute eval!(~s|"Lift" = "lift"|)
      assert eval!("1.0 = 1")
      assert eval!("a < b", %{"a" => ~D[2026-11-16], "b" => ~D[2026-12-01]})
      assert eval!("a >= b", %{"a" => ~U[2026-11-16 10:00:00Z], "b" => ~U[2026-11-16 10:00:00Z]})
      assert eval!("a != b", %{"a" => true, "b" => false})
      assert eval!("a = true", %{"a" => "true"})
      refute eval!("a < 5", %{"a" => nil})
      refute eval!(~s|a < 5|, %{"a" => "pet"})
    end

    test "nothing is the same as nothing, in any shape" do
      assert eval!("a = empty", %{"a" => nil})
      assert eval!("a = empty", %{"a" => "  "})
      assert eval!("a = empty", %{"a" => []})
      refute eval!("a = empty", %{"a" => "x"})
      assert eval!("a != empty", %{"a" => d("0")})
      assert eval!("empty(a)", %{"a" => %{}})
    end

    test "joins what is true or false" do
      assert eval!("true and not false")
      assert eval!("false or 1 < 2")
      refute eval!("true and a", %{"a" => nil})
    end

    test "works out only the branch it takes" do
      assert eval!(~s|if(a = 0, "nula", 10 / a)|, %{"a" => d("0")}) == "nula"
      assert eval!(~s|if(a = 0, "nula", 10 / a)|, %{"a" => d("5")}) == d("2")
    end

    test "runs the functions" do
      data = %{"slike" => ["a.png", "b.png"], "brojevi" => [d("1"), "2", 3], "ime" => " Mika "}
      assert eval!("length(slike)", data) == d("2")
      assert eval!("length(ime)", data) == d("6")
      assert eval!("length(nema)", data) == d("0")
      assert eval!(~s|contains(slike, "b.png")|, data)
      refute eval!(~s|contains(slike, "c.png")|, data)
      assert eval!(~s|contains(ime, "ik")|, data)
      assert eval!("first(slike)", data) == "a.png"
      assert eval!("last(slike)", data) == "b.png"
      assert eval!("first(nema)", data) == nil
      assert eval!("sum(brojevi)", data) == d("6")
      assert eval!("join(slike)", data) == "a.png, b.png"
      assert eval!(~s|join(slike, " i ")|, data) == "a.png i b.png"
      assert eval!("text(1.50)", data) == "1.5"
      assert eval!(~s|number("12,5") + 1|, data) == d("13.5")
      assert eval!("upper(trim(ime))", data) == "MIKA"
      assert eval!("lower(ime)", data) == " mika "
      assert eval("first(ime)", data) == {:error, :not_a_list}
    end

    test "knows today and now in the zone of the process" do
      opts = %{now: ~U[2026-11-16 23:30:00Z], zone: "Europe/Belgrade"}
      assert eval!("today()", %{}, opts) == ~D[2026-11-17]
      assert eval!("now()", %{}, opts) == ~U[2026-11-16 23:30:00Z]
      assert eval!("today()", %{}, %{now: ~U[2026-11-16 23:30:00Z]}) == ~D[2026-11-16]
    end

    test "moves days" do
      data = %{
        "dan" => ~D[2026-11-16],
        "kada" => ~U[2026-11-16 10:00:00Z],
        "tekst" => "16. 11. 2026."
      }

      assert eval!("add_days(dan, 7)", data) == ~D[2026-11-23]
      assert eval!("add_days(dan, -16)", data) == ~D[2026-10-31]
      assert eval!("add_days(kada, 1)", data) == ~U[2026-11-17 10:00:00Z]
      assert eval!("add_days(tekst, 1)", data) == ~D[2026-11-17]
      assert eval!("add_days(nema, 1)", data) == nil
      assert eval(~s|add_days("juče", 1)|, data) == {:error, :not_a_date}
    end
  end

  describe "render/3" do
    test "puts values into a text, each as it reads" do
      {:ok, parts} =
        Expr.template(
          "  Kvar {{start.naslov}}, sprat {{start.sprat + 1}}, {{start.kada}}{{start.nema}}.  "
        )

      data = %{
        "start" => %{"naslov" => "Lift", "sprat" => d("2"), "kada" => ~U[2026-11-16 13:05:00Z]}
      }

      assert Expr.render(parts, data, %{zone: "Europe/Belgrade"}) ==
               {:ok, "Kvar Lift, sprat 3, 16. 11. 2026. 14:05."}
    end

    test "fails with the expression that fails" do
      {:ok, parts} = Expr.template("{{1 / start.sprat}}")
      assert Expr.render(parts, %{"start" => %{"sprat" => d("0")}}) == {:error, :division_by_zero}
    end
  end
end
