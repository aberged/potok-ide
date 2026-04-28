defmodule PotokIde.AccountBootstrap do
  use GenServer, restart: :temporary

  require Logger

  alias PotokIde.Accounts

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    {:ok, opts, {:continue, :ensure_account}}
  end

  @impl true
  def handle_continue(:ensure_account, state) do
    case configured_account_credentials() do
      {:ok, email, password} ->
        ensure_account(email, password)

      :skip ->
        :ok

      {:error, :incomplete_config} ->
        Logger.warning(
          "Skipping bootstrap account setup because BOOTSTRAP_ACCOUNT_EMAIL and BOOTSTRAP_ACCOUNT_PASSWORD must both be set."
        )
    end

    {:stop, :normal, state}
  end

  defp ensure_account(email, password) do
    case Accounts.ensure_account_with_password(email, password) do
      {:ok, account} ->
        Logger.info("Ensured bootstrap account for #{account.email}")

      {:error, %Ecto.Changeset{} = changeset} ->
        Logger.error(
          "Failed to ensure bootstrap account for #{email}: #{inspect(changeset.errors)}"
        )

      {:error, reason} ->
        Logger.error("Failed to ensure bootstrap account for #{email}: #{inspect(reason)}")
    end
  end

  defp configured_account_credentials do
    config = Application.get_env(:potok_ide, :bootstrap_account, [])
    email = Keyword.get(config, :email)
    password = Keyword.get(config, :password)

    cond do
      present?(email) and present?(password) ->
        {:ok, String.trim(email), password}

      present?(email) or present?(password) ->
        {:error, :incomplete_config}

      true ->
        :skip
    end
  end

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false
end
