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
      Swoosh.Adapters.Gmail -> GmailToken.delivery_config(config())
      _ -> {:ok, []}
    end
  end
end
