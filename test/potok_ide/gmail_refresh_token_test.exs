defmodule PotokIde.GmailRefreshTokenTest do
  use PotokIde.DataCase, async: true

  alias PotokIde.GmailRefreshToken

  test "delete_all removes persisted gmail refresh tokens" do
    assert {:ok, %GmailRefreshToken{}} = GmailRefreshToken.upsert("refresh-one")

    assert {1, nil} = GmailRefreshToken.delete_all()
    assert GmailRefreshToken.get() == nil
  end
end
