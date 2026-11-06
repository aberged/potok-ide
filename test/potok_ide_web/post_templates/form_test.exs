defmodule PotokIdeWeb.PostTemplates.FormTest do
  use ExUnit.Case, async: true

  alias PotokIdeWeb.PostTemplates.{Form, Post}

  setup do
    Gettext.put_locale(PotokIdeWeb.Gettext, "sr")
    :ok
  end

  defp prepare(params, saved \\ nil, attrs \\ %{}), do: Form.prepare(attrs, params, saved)

  defp fields_of(attrs) do
    {:post, %{fields: fields}} = Post.decode(attrs["description"])
    fields
  end

  test "leaves a form without a template alone" do
    attrs = %{"description" => "tekst", "description_format" => "markdown"}

    assert Form.prepare(attrs, nil, "staro") == {attrs, []}
  end

  describe "an open form" do
    test "writes the description as HTML" do
      {attrs, []} = prepare(%{"id" => "quote", "fields" => %{"quote" => "Citat"}})

      assert attrs["description_format"] == "html"
      assert {:post, %{template: "quote"}} = Post.decode(attrs["description"])
      assert attrs["description"] =~ "Citat"
    end

    test "does not store what the browser adds to mark untouched inputs" do
      {attrs, []} =
        prepare(%{
          "id" => "quote",
          "fields" => %{"quote" => "Citat", "author" => "", "_unused_author" => ""}
        })

      assert fields_of(attrs) == %{"quote" => "Citat"}
    end

    test "gives back the saved description when nothing changed" do
      saved = Post.encode("quote", %{"quote" => "Citat"})

      {attrs, []} =
        prepare(
          %{
            "id" => "quote",
            "fields" => %{"quote" => "Citat", "author" => "", "_unused_quote" => ""}
          },
          saved
        )

      assert attrs["description"] == saved
    end

    test "does not rewrite a description in the words of another language" do
      saved = Post.encode("link", %{"address" => "https://a.rs", "title" => "Naslov"})
      params = %{"id" => "link", "fields" => %{"address" => "https://a.rs", "title" => "Naslov"}}

      Gettext.put_locale(PotokIdeWeb.Gettext, "en")
      {attrs, []} = prepare(params, saved)

      assert attrs["description"] == saved
      assert attrs["description"] =~ "Pročitaj više"
    end

    test "comes back to the saved description when a change is undone" do
      saved = Post.encode("link", %{"address" => "https://a.rs", "title" => "Naslov"})

      Gettext.put_locale(PotokIdeWeb.Gettext, "en")

      {changed, []} =
        prepare(
          %{"id" => "link", "fields" => %{"address" => "https://a.rs", "title" => "Novo"}},
          saved
        )

      assert changed["description"] =~ "Read more"

      {back, []} =
        prepare(
          %{"id" => "link", "fields" => %{"address" => "https://a.rs", "title" => "Naslov"}},
          saved
        )

      assert back["description"] == saved
    end

    test "is not fooled by a level FeedCreator left out or by a form's line endings" do
      saved = Post.encode("notice", %{"title" => "Naslov", "body" => "a\n\nb"})

      {attrs, []} =
        prepare(
          %{
            "id" => "notice",
            "fields" => %{"level" => "info", "title" => "Naslov", "body" => "a\r\n\r\nb"}
          },
          saved
        )

      assert attrs["description"] == saved
    end

    test "is not fooled by empty rows of a list" do
      saved = Post.encode("list", %{"title" => "Naslov", "items" => ["a"]})

      {attrs, []} =
        prepare(
          %{"id" => "list", "fields" => %{"title" => "Naslov", "items" => ["a", " "]}},
          saved
        )

      assert attrs["description"] == saved
    end

    test "stores text with a description's line endings" do
      {attrs, []} =
        prepare(%{"id" => "quote", "fields" => %{"quote" => "a\r\nb"}})

      assert fields_of(attrs) == %{"quote" => "a\nb"}
      assert attrs["description"] =~ "a<br>b"
    end

    test "ignores a template that does not exist" do
      assert prepare(%{"id" => "nepoznat", "fields" => %{}}, nil, %{"a" => 1}) ==
               {%{"a" => 1}, []}
    end
  end

  describe "required fields" do
    test "are named when a new description lacks them" do
      {_attrs, missing} = prepare(%{"id" => "photo", "fields" => %{"title" => "Naslov"}})

      assert missing == ["Slika"]
    end

    test "stop no one while the description is not being changed" do
      saved = Post.encode("photo", %{"title" => "Naslov"})

      assert {_attrs, []} = prepare(%{"id" => "photo", "fields" => %{"title" => "Naslov"}}, saved)
    end

    test "take a list with something in it" do
      params = fn items -> %{"id" => "list", "fields" => %{"title" => "N", "items" => items}} end

      assert {_attrs, ["Stavke"]} = prepare(params.([""]))
      assert {_attrs, []} = prepare(params.(["", "a"]))
    end
  end

  describe "the buttons" do
    test "add_item adds a row that survives, though it is empty" do
      saved = Post.encode("list", %{"title" => "Naslov", "items" => ["a"]})

      {attrs, []} =
        prepare(
          %{
            "id" => "list",
            "add_item" => "1",
            "fields" => %{"title" => "Naslov", "items" => ["a"]}
          },
          saved
        )

      assert fields_of(attrs)["items"] == ["a", ""]
    end

    test "add_item stops at ten rows" do
      items = Enum.map(1..10, &"stavka #{&1}")

      {attrs, []} =
        prepare(%{
          "id" => "list",
          "add_item" => "1",
          "fields" => %{"title" => "Naslov", "items" => items}
        })

      assert fields_of(attrs)["items"] == items
    end

    test "remove_item removes that row" do
      {attrs, []} =
        prepare(%{
          "id" => "list",
          "remove_item" => "1",
          "fields" => %{"title" => "Naslov", "items" => ["a", "b", "c"]}
        })

      assert fields_of(attrs)["items"] == ["a", "c"]
    end

    test "clear_image takes the picture out" do
      {attrs, []} =
        prepare(%{
          "id" => "article",
          "clear_image" => "1",
          "fields" => %{"title" => "Naslov", "image" => "https://a.rs/b.png"}
        })

      assert fields_of(attrs) == %{"title" => "Naslov"}
      refute attrs["description"] =~ "<img"
    end

    test "restore brings the form back over a text changed by hand" do
      description = Post.encode("quote", %{"quote" => "Citat"}) <> "<p>rukom</p>"

      {attrs, []} = prepare(%{"restore" => "1"}, description, %{"description" => description})

      assert {:post, %{fields: %{"quote" => "Citat"}}} = Post.decode(attrs["description"])
      refute attrs["description"] =~ "rukom"
    end
  end

  describe "picking a template" do
    test "keeps the fields both templates have, and drops the rest" do
      {attrs, ["Adresa"]} =
        prepare(%{
          "id" => "article",
          "pick" => "link",
          "fields" => %{"title" => "Naslov", "image" => "https://a.rs/b.png", "kicker" => "K"}
        })

      assert {:post, %{template: "link"}} = Post.decode(attrs["description"])
      assert fields_of(attrs) == %{"title" => "Naslov", "image" => "https://a.rs/b.png"}
    end

    test "starts from an empty form over free text" do
      {attrs, ["Naslov"]} =
        prepare(%{"pick" => "article"}, nil, %{
          "description" => "tekst",
          "description_format" => "markdown"
        })

      assert attrs["description_format"] == "html"
      assert fields_of(attrs) == %{}
    end

    test "takes the fields of a text changed by hand along" do
      description = Post.encode("article", %{"title" => "Naslov"}) <> "<p>rukom</p>"

      {attrs, _missing} = prepare(%{"pick" => "link"}, nil, %{"description" => description})

      assert fields_of(attrs) == %{"title" => "Naslov"}
    end

    test "the same template changes nothing" do
      saved = Post.encode("quote", %{"quote" => "Citat"})

      {attrs, []} =
        prepare(%{"id" => "quote", "pick" => "quote", "fields" => %{"quote" => "Citat"}}, saved)

      assert attrs["description"] == saved
    end

    test "free text keeps the HTML, without the way back to the form" do
      {attrs, []} =
        prepare(%{"id" => "quote", "pick" => "text", "fields" => %{"quote" => "Citat"}})

      assert attrs["description_format"] == "html"
      assert attrs["description"] =~ "<blockquote"
      assert Post.decode(attrs["description"]) == :free
    end

    test "free text over free text changes nothing" do
      attrs = %{"description" => "tekst", "description_format" => "markdown"}

      assert prepare(%{"pick" => "text"}, nil, attrs) == {attrs, []}
    end

    test "ignores a template that does not exist" do
      attrs = %{"description" => "tekst"}

      assert prepare(%{"pick" => "nepoznat"}, nil, attrs) == {attrs, []}
    end
  end
end
