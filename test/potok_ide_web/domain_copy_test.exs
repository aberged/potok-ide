defmodule PotokIdeWeb.DomainCopyTest do
  use PotokIde.DataCase, async: true

  alias Expo.Message
  alias Expo.PO
  alias PotokIde.DomainMap
  alias PotokIdeWeb.DomainCopy

  defp in_locale(locale, fun) do
    previous = Gettext.get_locale(PotokIdeWeb.Gettext)
    Gettext.put_locale(PotokIdeWeb.Gettext, locale)

    try do
      fun.()
    after
      Gettext.put_locale(PotokIdeWeb.Gettext, previous)
    end
  end

  test "names and describes every entity and area" do
    map = DomainCopy.map(DomainMap.graph())

    assert map_size(map.entities) == length(DomainMap.modules())

    for {_id, entity} <- map.entities do
      assert entity.name != ""
      assert entity.description != ""
    end

    assert Enum.all?(map.domains, &(&1.name != ""))
  end

  test "counts what the map shows" do
    assert %{entities: 34, domains: 9, soft: 8} = DomainCopy.map(DomainMap.graph()).counts
  end

  test "has a word for every check that is not an enum list" do
    for entity <- DomainMap.graph().entities, check <- entity.checks do
      assert DomainCopy.check_text(check.name), check.name
    end
  end

  test "says in words what every column is" do
    for entity <- DomainMap.graph().entities, field <- entity.fields ++ entity.virtual do
      assert DomainCopy.field_name(entity.id, to_string(field.name)), "#{entity.id}.#{field.name}"
    end
  end

  test "the words for the Serbian password hash are the user's own" do
    in_locale("sr", fn ->
      assert DomainCopy.field_name("Account", "hashed_password") == "heš lozinke"
    end)
  end

  test "the same column can mean different things" do
    assert DomainCopy.field_name("Group", "parent_id") == "parent group"
    assert DomainCopy.field_name("Value", "parent_id") == "replies to"
  end

  test "the words for keys fit on a node of the diagram, in every language" do
    edges = DomainMap.graph().edges

    for locale <- PotokIdeWeb.Locale.supported_locales() do
      in_locale(locale, fn ->
        for edge <- edges, column <- edge.columns do
          name = DomainCopy.field_name(edge.from, column)
          assert String.length(name) <= 27, "#{edge.from}.#{column}: #{name}"
        end
      end)
    end
  end

  test "the names of the columns stay on the server" do
    graph = DomainMap.graph()

    for locale <- PotokIdeWeb.Locale.supported_locales() do
      json = in_locale(locale, fn -> graph |> DomainCopy.map() |> Jason.encode!() end)

      for entity <- graph.entities,
          %{name: name} <- entity.fields ++ entity.virtual,
          name = to_string(name),
          String.contains?(name, "_") do
        refute json =~ ~r/\b#{name}\b/, "#{locale}: #{entity.id}.#{name}"
      end
    end
  end

  test "indexes and their conditions read as words" do
    %{entities: entities} = DomainCopy.map(DomainMap.graph())

    assert %{columns: "group + who is invited", condition: "while this is empty: accepted at"} in entities[
             "GroupInvitation"
           ].unique

    assert %{columns: "name, in any letter case", condition: "while this is empty: owner"} in entities[
             "Tag"
           ].unique
  end

  test "says how many permissions a role has" do
    %{entities: %{"GroupRole" => role}} = DomainCopy.map(DomainMap.graph())

    assert role.description =~ "#{length(PotokIde.Social.GroupRole.permissions())} permissions"
  end

  test "links in the texts lead to entities, in every language" do
    ids = Enum.map(DomainMap.graph().entities, & &1.id)

    for locale <- PotokIdeWeb.Locale.supported_locales() do
      in_locale(locale, fn ->
        links =
          for %{text: text} <- DomainCopy.mechanisms() ++ DomainCopy.apps().capabilities,
              {:entity, id, _label} <- DomainCopy.parts(text),
              do: id

        assert links != []
        assert Enum.uniq(links) -- ids == []
      end)
    end
  end

  test "keeps code and links in Latin in Cyrillic texts" do
    in_locale("sr_Cyrl", fn ->
      parts = DomainCopy.mechanisms() |> Enum.flat_map(&DomainCopy.parts(&1.text))

      assert {:code, "everyone"} in parts
      assert {:entity, "Value", "вредности"} in parts
    end)
  end

  test "the Serbian of the map is complete" do
    %{messages: messages} = PO.parse_file!("priv/gettext/sr/LC_MESSAGES/domain_map.po")

    for message <- messages do
      forms =
        case message do
          %Message.Singular{msgstr: msgstr} -> [msgstr]
          %Message.Plural{msgstr: msgstr} -> Map.values(msgstr)
        end

      assert Enum.all?(forms, &(IO.iodata_to_binary(&1) != "")), inspect(message.msgid)
      refute Message.has_flag?(message, "fuzzy"), inspect(message.msgid)
    end
  end

  describe "parts/1" do
    test "splits text, code and links" do
      assert DomainCopy.parts("A <Group>group</Group> with `parent_value_id` is a thread.") == [
               {:text, "A "},
               {:entity, "Group", "group"},
               {:text, " with "},
               {:code, "parent_value_id"},
               {:text, " is a thread."}
             ]
    end

    test "leaves plain text alone" do
      assert DomainCopy.parts("Nothing here") == [{:text, "Nothing here"}]
    end
  end
end
