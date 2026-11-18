defmodule PotokIde.Mailer do
  use Swoosh.Mailer, otp_app: :potok_ide

  alias PotokIde.GmailToken

  def config do
    Application.fetch_env!(:potok_ide, __MODULE__)
  end

  def from do
    config = config()
    {Keyword.fetch!(config, :from_name), Keyword.fetch!(config, :from_email)}
  end

  def delivery_config do
    case Keyword.fetch!(config(), :adapter) do
      Swoosh.Adapters.Gmail -> GmailToken.delivery_config(config(), cache: true)
      _ -> {:ok, []}
    end
  end

  @doc """
  After a failed send: the kept Gmail token may be the reason (revoked
  early), so the next email asks for a new one.
  """
  def delivery_failed do
    GmailToken.forget()
    :ok
  end
end
