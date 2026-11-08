defmodule PotokIde.Social.Identity do
  @moduledoc """
  Who counts as one person where Potok takes one answer per person: a vote in
  a poll, a response to a form.

  One account gives one answer, whichever of its profiles it uses. A profile
  that several accounts really share answers on its own, for all of them. The
  check asks for more than the profile's `sharing` setting, as one account
  alone could turn it on to answer twice.
  """

  import Ecto.Query, warn: false

  alias PotokIde.Accounts.Account
  alias PotokIde.Repo
  alias PotokIde.Social.{AccountProfile, Profile}

  @doc """
  The account an answer of `profile`, used by `account`, counts against: nil
  for a profile that more than one account holds.
  """
  def counted_account_id(%Profile{sharing: :shared, id: profile_id}, %Account{id: account_id}) do
    holders =
      Repo.aggregate(from(ap in AccountProfile, where: ap.profile_id == ^profile_id), :count)

    if holders > 1, do: nil, else: account_id
  end

  def counted_account_id(%Profile{}, %Account{id: account_id}), do: account_id

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
