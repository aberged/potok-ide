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
end
