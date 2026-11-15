# Script for populating the database. You can run it as:
#
#     mix run priv/repo/seeds.exs
#
# It gives a fresh database an account to log in with, at
# /accounts/log-in/password: dev@example.com with the password "hello world!",
# its profile "dev" and a private group of that profile under the root.
# Running it again keeps what is already there.

import Ecto.Query

alias PotokIde.Accounts
alias PotokIde.Repo
alias PotokIde.Social
alias PotokIde.Social.Group

email = "dev@example.com"
password = "hello world!"
username = "dev"
group_name = "Probna grupa"

{:ok, account} = Accounts.ensure_account_with_password(email, password)

profile =
  case Social.list_profiles_for_account(account) do
    [profile | _] ->
      profile

    [] ->
      {:ok, profile} =
        Social.create_profile_for_account(account, %{
          username: username,
          profile_picture_url: nil,
          description: "",
          description_format: :markdown,
          sharing: :unique
        })

      profile
  end

{:ok, _} = Accounts.set_current_profile(Accounts.get_account!(account.id), profile)

root = Social.get_root_group!()

unless Repo.exists?(from(g in Group, where: g.parent_id == ^root.id and g.name == ^group_name)) do
  {:ok, _} =
    Social.create_group_from_preset(profile, root, "chat", %{
      "name" => group_name,
      "inherits_members" => false
    })
end

IO.puts("Dev account: #{email} / #{password} (profile #{profile.username})")
