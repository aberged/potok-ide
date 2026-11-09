defmodule PotokIde.Accounts.Password do
  @moduledoc """
  Password hashes in pbkdf2_elixir's format, `$pbkdf2-sha512$<rounds>$<salt>$<hash>`,
  worked out by OpenSSL through `:crypto.pbkdf2_hmac/5`.

  pbkdf2_elixir runs every round as an Elixir call: its 160,000 rounds took
  0.6–1.3 s of CPU per log-in on one core in the load test of 2026-11-09, while
  the same hash takes about 135 ms natively. On a machine whose CPU quota is a
  sixteenth of a core, that is the difference between one log-in holding the
  CPU for ~20 s and for ~2 s. The format stays the same, so hashes stored
  before verify here and these verify with the library.
  """

  alias Pbkdf2.Base64

  @salt_bytes 16

  @doc "Hashes `password` with a new random salt."
  def hash(password) when is_binary(password) do
    rounds = rounds()
    salt = :crypto.strong_rand_bytes(@salt_bytes)
    hash = :crypto.pbkdf2_hmac(:sha512, password, salt, rounds, 64)
    "$pbkdf2-sha512$#{rounds}$#{Base64.encode(salt)}$#{Base64.encode(hash)}"
  end

  @doc """
  Whether `password` matches `stored`. The comparison takes the same time
  however much of the hash matches.
  """
  def verify(password, "$pbkdf2-" <> rest) when is_binary(password) do
    with [alg, rounds, salt, expected] <- String.split(rest, "$"),
         {:ok, digest} <- digest(alg),
         {rounds, ""} when rounds > 0 <- Integer.parse(rounds),
         {:ok, salt} <- decode(salt),
         {:ok, expected} when expected != "" <- decode(expected) do
      password
      |> then(&:crypto.pbkdf2_hmac(digest, &1, salt, rounds, byte_size(expected)))
      |> :crypto.hash_equals(expected)
    else
      _ -> false
    end
  end

  # Any other format the library can read (Django's) is left to it.
  def verify(password, stored) when is_binary(password) and is_binary(stored) do
    Pbkdf2.verify_pass(password, stored)
  rescue
    _ -> false
  end

  @doc """
  Spends the time of one check and returns false, for an email with no
  account or no password, so the answer's timing does not tell them apart.
  """
  def no_user_verify do
    :crypto.pbkdf2_hmac(:sha512, "password", :crypto.strong_rand_bytes(@salt_bytes), rounds(), 64)
    false
  end

  defp digest("sha512"), do: {:ok, :sha512}
  defp digest("sha256"), do: {:ok, :sha256}
  defp digest(_alg), do: :error

  defp decode(text) do
    {:ok, Base64.decode(text)}
  rescue
    _ -> :error
  end

  # Tests set fewer rounds, as for the library.
  defp rounds, do: Application.get_env(:pbkdf2_elixir, :rounds, 160_000)
end
