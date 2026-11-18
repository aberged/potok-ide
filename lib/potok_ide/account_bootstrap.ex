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

  # Machines start together: one that loses the race to create the account
  # finds it made by another and takes it from there.
  defp ensure_account(email, password, tries \\ 2) do
    case Accounts.ensure_account_with_password(email, password) do
      {:ok, account} ->
        Logger.info("Ensured bootstrap account for #{account.email}")

      {:error, %Ecto.Changeset{} = changeset} when tries > 1 ->
        if taken_email?(changeset),
          do: ensure_account(email, password, tries - 1),
          else: log_failure(email, changeset)

      {:error, %Ecto.Changeset{} = changeset} ->
        log_failure(email, changeset)

      {:error, reason} ->
        Logger.error("Failed to ensure bootstrap account for #{email}: #{inspect(reason)}")
    end
  end

  defp taken_email?(%Ecto.Changeset{errors: errors}) do
    case Keyword.get(errors, :email) do
      {_message, opts} -> opts[:constraint] == :unique or opts[:validation] == :unsafe_unique
      nil -> false
    end
  end

  defp log_failure(email, changeset) do
    Logger.error("Failed to ensure bootstrap account for #{email}: #{inspect(changeset.errors)}")
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
