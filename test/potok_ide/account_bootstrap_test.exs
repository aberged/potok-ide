defmodule PotokIde.AccountBootstrapTest do
  use PotokIde.DataCase

  import Ecto.Query
  import PotokIde.AccountsFixtures

  alias PotokIde.AccountBootstrap
  alias PotokIde.Accounts
  alias PotokIde.Accounts.Account

  describe "ensure_account_with_password/2" do
    test "creates and confirms a missing account" do
      email = unique_account_email()
      password = "bootstrap password"

      assert {:ok, account} = Accounts.ensure_account_with_password(email, password)
      assert account.email == email
      assert account.confirmed_at
      assert Accounts.get_account_by_email_and_password(email, password)
    end

    test "updates an existing account password and confirms it" do
      email = unique_account_email()
      account = unconfirmed_account_fixture(%{email: email})
      password = "bootstrap password"

      assert {:ok, updated_account} = Accounts.ensure_account_with_password(email, password)
      assert updated_account.id == account.id
      assert updated_account.confirmed_at
      assert Accounts.get_account_by_email_and_password(email, password)
    end

    test "does not create a duplicate when the account already matches" do
      email = unique_account_email()
      password = valid_account_password()
      account = account_fixture(%{email: email}) |> set_password()

      assert {:ok, updated_account} = Accounts.ensure_account_with_password(email, password)
      assert updated_account.id == account.id

      assert 1 ==
               Repo.aggregate(
                 from(account in Account, where: account.email == ^email),
                 :count,
                 :id
               )
    end
  end

  describe "startup bootstrap" do
    setup do
      original_config = Application.get_env(:potok_ide, :bootstrap_account)

      on_exit(fn ->
        if is_nil(original_config) do
          Application.delete_env(:potok_ide, :bootstrap_account)
        else
          Application.put_env(:potok_ide, :bootstrap_account, original_config)
        end
      end)

      :ok
    end

    test "ensures the configured account when started" do
      email = unique_account_email()
      password = "bootstrap password"

      Application.put_env(:potok_ide, :bootstrap_account,
        email: email,
        password: password
      )

      pid = start_supervised!(AccountBootstrap)
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
      assert Accounts.get_account_by_email_and_password(email, password)
    end
  end
end
