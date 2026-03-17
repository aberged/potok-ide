defmodule PotokIde.Mailer do
  use Swoosh.Mailer, otp_app: :potok_ide

  def from do
    config = Application.fetch_env!(:potok_ide, __MODULE__)
    {Keyword.fetch!(config, :from_name), Keyword.fetch!(config, :from_email)}
  end
end
