defmodule PotokIde.Operators do
  @moduledoc """
  The people who run Potok itself, named by the emails of their accounts in
  `OPERATOR_EMAILS` (comma separated). For now they only copy Fly's invoices
  onto `/troskovi` (`PotokIde.HostingCosts`); in groups they are like anyone.
  """

  alias PotokIde.Accounts.Scope

  # Only once the email is confirmed: whoever holds the address is the operator.
  def operator?(%Scope{account: %{email: email, confirmed_at: %DateTime{}}})
      when is_binary(email) do
    email = String.downcase(email)
    Enum.any?(emails(), &(&1 == email))
  end

  def operator?(_scope), do: false

  defp emails do
    :potok_ide
    |> Application.get_env(:operator_emails, [])
    |> Enum.map(&String.downcase/1)
  end
end
