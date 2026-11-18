defmodule PotokIde.CleanupTest do
  @moduledoc """
  What the hourly pass (`Social.AppFileSweeper`) keeps small: runs that ended
  a month ago lose what nothing reads any more, and tokens no check accepts
  go.
  """
  use PotokIde.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import PotokIde.EventsFixtures

  alias PotokIde.Accounts
  alias PotokIde.Accounts.AccountToken
  alias PotokIde.Processes
  alias PotokIde.Processes.{Engine, ValueProcess}
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.DrawnProcesses

  describe "ended runs" do
    setup do
      {_account, owner} = account_with_profile!("slim-owner")
      group = group_with_members!(owner, [], %{})
      {:ok, _manifest} = Social.create_own_group_manifest(owner, group)
      group = Social.get_group!(group.id)

      graph = %{
        "v" => 2,
        "nodes" => [
          %{"id" => "start", "type" => "startEvent"},
          %{"id" => "kraj", "type" => "endEvent"}
        ],
        "flows" => [%{"from" => "start", "to" => "kraj"}]
      }

      {:ok, row} =
        DrawnProcesses.create(owner, group, %{
          "trigger" => "manual",
          "name" => "Proces",
          "graph" => graph
        })

      {:ok, row} = DrawnProcesses.activate(owner, group, row.id)

      runs =
        for title <- ~w(old recent failed) do
          {:ok, instance} = DrawnProcesses.start(owner, group, row.id, %{"title" => title})
          Engine.run(instance.id)
          Repo.get!(ValueProcess, instance.id)
        end

      %{runs: runs}
    end

    test "a month after the end keep status and log, not graph, variables or data", %{
      runs: [old, recent, failed]
    } do
      assert old.status == :done and old.graph != %{}

      age = fn run, days, status ->
        from(i in ValueProcess, where: i.id == ^run.id)
        |> Repo.update_all(
          set: [status: status, updated_at: DateTime.add(DateTime.utc_now(:second), -days, :day)]
        )
      end

      age.(old, 31, :done)
      age.(recent, 29, :done)
      age.(failed, 40, :failed)

      assert Processes.slim_ended() == 1

      slim = Repo.get!(ValueProcess, old.id)
      assert slim.status == :done and slim.log == old.log
      assert {slim.graph, slim.vars, slim.results, slim.data} == {%{}, %{}, %{}, %{}}

      assert Repo.get!(ValueProcess, recent.id).graph == recent.graph
      assert Repo.get!(ValueProcess, failed.id).graph == failed.graph

      # Once slimmed, a run is not taken again.
      assert Processes.slim_ended() == 0
    end
  end

  describe "tokens" do
    test "the expired go, the valid stay" do
      {account, _profile} = account_with_profile!("token-owner")

      fresh = Accounts.generate_account_session_token(account)
      _old_session = Accounts.generate_account_session_token(account)
      {_encoded, login} = AccountToken.build_email_token(account, "login")
      login = Repo.insert!(login)

      age = fn context, days ->
        from(t in AccountToken, where: t.account_id == ^account.id and t.context == ^context)
        |> Repo.update_all(
          set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -days, :day)]
        )
      end

      # The newest session stays young; the other one and the link grow old.
      fresh_id = Repo.get_by!(AccountToken, token: fresh).id

      from(t in AccountToken,
        where: t.account_id == ^account.id and t.context == "session" and t.id != ^fresh_id
      )
      |> Repo.update_all(set: [inserted_at: DateTime.add(DateTime.utc_now(:second), -15, :day)])

      age.("login", 8)

      assert Accounts.delete_expired_tokens() == 2
      assert Repo.get_by(AccountToken, id: fresh_id)
      refute Repo.get_by(AccountToken, id: login.id)
      assert Accounts.get_account_by_session_token(fresh)
    end
  end
end
