defmodule PotokIde.Social.Identity do
  @moduledoc """
  Who counts as one person where Potok takes one answer per person: a vote in
  a poll, a response to a form.

  One account gives one answer, whichever of its profiles it uses. A profile
  that several accounts really share answers on its own, for all of them. The
  check asks for more than the profile's `sharing` setting, as one account
  alone could turn it on to answer twice.

  A poll may read a shared profile the other way too, as the mask of several
  people, each of whom votes through it as themself, and it may leave out
  either kind of profile (`voter/5`, `counted_voters/5`).
  """

  import Ecto.Query, warn: false

  alias PotokIde.Accounts.Account
  alias PotokIde.Repo
  alias PotokIde.Social.{AccountProfile, Profile}

  @doc "Whether more than one account holds `profile`, which then answers on its own."
  def really_shared?(%Profile{sharing: :shared, id: profile_id}) do
    Repo.aggregate(from(ap in AccountProfile, where: ap.profile_id == ^profile_id), :count) > 1
  end

  def really_shared?(%Profile{}), do: false

  @doc """
  The account an answer of `profile`, used by `account`, counts against: nil
  for a profile that more than one account holds.
  """
  def counted_account_id(%Profile{} = profile, %Account{id: account_id}) do
    if really_shared?(profile), do: nil, else: account_id
  end

  @doc """
  Who a vote of `profile`, used by the account `account_id`, counts as in a
  poll that takes `unique` and `shared` votes (`Poll.unique_votes`,
  `Poll.shared_votes`); `shared?` is `really_shared?/1` of the profile.

  - `{:account, id}`: one vote per account, whichever of its profiles;
  - `{:profile, id}`: a shared profile, once for all its holders;
  - `{:each_holder, account_id}`: one holder of a shared profile, as themself,
    which still counts against that holder's account;
  - `:excluded`: the poll takes no votes of this kind of profile.
  """
  def voter(shared?, profile, account_id, unique, shared)

  def voter(false, %Profile{}, account_id, :yes, _shared), do: {:account, account_id}
  def voter(false, %Profile{}, _account_id, :no, _shared), do: :excluded

  def voter(true, %Profile{id: profile_id}, _account_id, _unique, :as_one),
    do: {:profile, profile_id}

  def voter(true, %Profile{}, account_id, _unique, :each_holder), do: {:each_holder, account_id}
  def voter(true, %Profile{}, _account_id, _unique, :no), do: :excluded

  @doc "The kind of profile a voter is, for the rules: `:unique` or `:shared`."
  def kind(true), do: :shared
  def kind(false), do: :unique

  @doc """
  What a profile with `sharing` and the accounts `holders` counts as among
  those who may vote in a poll that takes `unique` and `shared` votes: keys
  that one person (`{:account, id}`) or one shared profile (`{:profile, id}`)
  has once, none when the poll does not take its kind. A unique profile that
  several accounts still hold votes once, as the ballots allow.
  """
  def counted_voters(profile_id, sharing, holders, unique, shared)

  def counted_voters(profile_id, :shared, [_, _ | _] = holders, _unique, shared) do
    case shared do
      :as_one -> [{:profile, profile_id}]
      :each_holder -> Enum.map(holders, &{:account, &1})
      :no -> []
    end
  end

  def counted_voters(_profile_id, _sharing, _holders, :no, _shared), do: []

  def counted_voters(_profile_id, _sharing, [account_id], :yes, _shared),
    do: [{:account, account_id}]

  def counted_voters(profile_id, _sharing, _holders, :yes, _shared), do: [{:profile, profile_id}]

  @doc """
  A query of the profiles whose answers count as this person's: `profile`
  itself and, for a counted account (`counted_account_id/2`), the profiles that
  account alone holds.
  """
  def counted_profile_ids_query(%Profile{id: profile_id}, nil) do
    from(p in Profile, where: p.id == ^profile_id, select: p.id)
  end

  def counted_profile_ids_query(%Profile{id: profile_id}, account_id)
      when is_integer(account_id) do
    held_alone =
      from(ap in AccountProfile,
        where:
          ap.profile_id in subquery(
            from(own in AccountProfile,
              where: own.account_id == ^account_id,
              select: own.profile_id
            )
          ),
        group_by: ap.profile_id,
        having: count(ap.account_id) == 1,
        select: ap.profile_id
      )

    from(p in Profile,
      where: p.id == ^profile_id or p.id in subquery(held_alone),
      select: p.id
    )
  end
end
