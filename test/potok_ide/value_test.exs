defmodule PotokIde.ValueTest do
  use PotokIde.DataCase, async: true

  alias PotokIde.Social.Value

  test "value changeset normalizes malformed utf-8 content" do
    malformed = <<240, 159, 141, 60>>

    changeset =
      Value.changeset(%Value{}, %{
        content: malformed,
        content_format: :markdown,
        creator_id: 1,
        group_id: 1
      })

    assert Ecto.Changeset.get_field(changeset, :content) == "�<"
  end

  describe "excerpt/2" do
    test "strips markdown syntax into one line" do
      value = %Value{
        content:
          "# Title\n\n**bold** and `code` [a link](http://x) ![img](http://y)\n- item\n> quote",
        content_format: :markdown
      }

      assert Value.excerpt(value) == "Title bold and code a link img item quote"
    end

    test "strips html tags, scripts and entities" do
      value = %Value{
        content: "<p>Fish &amp; <b>chips</b></p><p>tonight</p><script>alert(1)</script>",
        content_format: :html
      }

      assert Value.excerpt(value) == "Fish & chips tonight"
    end

    test "truncates to the given length with an ellipsis" do
      value = %Value{content: String.duplicate("word ", 40), content_format: :markdown}

      excerpt = Value.excerpt(value, 20)

      assert String.length(excerpt) <= 20
      assert String.ends_with?(excerpt, "…")
    end

    test "returns nil when nothing readable is left" do
      assert Value.excerpt(%Value{content: "![](http://x)", content_format: :markdown}) == nil
      assert Value.excerpt(%Value{content: nil, content_format: :markdown}) == nil
    end
  end
end
