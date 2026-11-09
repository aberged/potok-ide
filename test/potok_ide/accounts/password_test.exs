defmodule PotokIde.Accounts.PasswordTest do
  use ExUnit.Case, async: true

  alias PotokIde.Accounts.Password

  test "a hash verifies its own password and no other" do
    hash = Password.hash("tajna lozinka")

    assert Password.verify("tajna lozinka", hash)
    refute Password.verify("tajna lozinkA", hash)
    refute Password.verify("", hash)
  end

  test "hashes keep pbkdf2_elixir's format, with the configured rounds and a fresh salt" do
    rounds = Integer.to_string(Application.get_env(:pbkdf2_elixir, :rounds, 160_000))
    hash = Password.hash("lozinka")

    assert ["", "pbkdf2-sha512", ^rounds, salt, digest] = String.split(hash, "$")
    assert byte_size(Pbkdf2.Base64.decode(salt)) == 16
    assert byte_size(Pbkdf2.Base64.decode(digest)) == 64
    refute Password.hash("lozinka") == hash
  end

  test "the library and this module verify each other's hashes" do
    assert Password.verify("stara", Pbkdf2.hash_pwd_salt("stara"))
    refute Password.verify("nova", Pbkdf2.hash_pwd_salt("stara"))
    assert Pbkdf2.verify_pass("nova", Password.hash("nova"))
  end

  test "a hash made with many rounds, as in production, verifies" do
    hash = Pbkdf2.hash_pwd_salt("lozinka", rounds: 1_000)

    assert hash =~ "$1000$"
    assert Password.verify("lozinka", hash)
    refute Password.verify("lozinka2", hash)
  end

  test "sha256 and Django-style hashes still verify" do
    assert Password.verify("p", Pbkdf2.hash_pwd_salt("p", digest: :sha256))
    assert Password.verify("p", Pbkdf2.hash_pwd_salt("p", format: :django))
    refute Password.verify("q", Pbkdf2.hash_pwd_salt("p", format: :django))
  end

  test "a malformed hash is a mismatch, not a crash" do
    for stored <- [
          "",
          "garbage",
          "$pbkdf2-sha512$abc$c2FsdA$aGFzaA",
          "$pbkdf2-sha512$0$c2FsdA$aGFzaA",
          "$pbkdf2-md5$1$c2FsdA$aGFzaA",
          "$pbkdf2-sha512$1$!!!$aGFzaA",
          "$pbkdf2-sha512$1$c2FsdA$",
          "$pbkdf2-sha512$1$c2FsdA"
        ] do
      refute Password.verify("lozinka", stored), "expected no match for #{inspect(stored)}"
    end
  end

  test "an account with no password takes a check's time and fails" do
    refute Password.no_user_verify()
  end
end
