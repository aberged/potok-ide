defmodule PotokIde.Social.ProfileFacts do
  @moduledoc """
  What a viewer is to a profile, read in one query, so that who sees which
  detail (`PotokIde.Social.ProfileDetails`) is a plain function of these
  facts, the way `PotokIde.Social.Access.from_facts/2` is for a group.

    * `holder?`: the viewer's account holds the profile, so it sees all of it;
    * `shared_group_ids`: the shared groups both profiles are members of;
    * `relation_group_ids`: groups the viewer sees the profile in as if both
      were members (none yet);
    * `direct?`: a direct conversation of the two exists.

  A shared group is a group neither of the root (everyone is in it), nor a
  direct conversation (anyone could open one), nor a thread (its members are
  members of its group) nor a record an app made (`plain_group_sql/1`). An
  inherited membership counts like any other.
  """

  alias PotokIde.Accounts.Account
  alias PotokIde.Repo
  alias PotokIde.Social.Profile

  defstruct kind: :person,
            holder?: false,
            shared_group_ids: MapSet.new(),
            relation_group_ids: MapSet.new(),
            direct?: false

  @type t :: %__MODULE__{
          kind: :person | :process | :deleted,
          holder?: boolean(),
          shared_group_ids: MapSet.t(integer()),
          relation_group_ids: MapSet.t(integer()),
          direct?: boolean()
        }

  @doc """
  The SQL condition that `group_alias` is a group shared membership counts in:
  not the root, a direct conversation, a thread or a record.
  """
  def plain_group_sql(group_alias) do
    "NOT #{group_alias}.is_root AND NOT #{group_alias}.is_direct" <>
      " AND #{group_alias}.parent_value_id IS NULL AND #{group_alias}.external_key IS NULL"
  end

  @doc """
  The facts of `viewer` (the current profile of `account`) about `target`.
  With no account or profile (a guest) only the target's kind is known.
  """
  def load(account, viewer, %Profile{} = target) do
    account_id = account_id(account)
    viewer_id = profile_id(viewer)

    if is_nil(account_id) and is_nil(viewer_id) do
      %__MODULE__{kind: target.kind}
    else
      sql = """
      SELECT
        EXISTS(SELECT 1 FROM accounts_profiles ap
               WHERE ap.account_id = $1 AND ap.profile_id = $3),
        ARRAY(SELECT t.group_id
              FROM group_memberships t
              JOIN group_memberships v ON v.group_id = t.group_id AND v.profile_id = $2
              JOIN groups g ON g.id = t.group_id
              WHERE t.profile_id = $3 AND #{plain_group_sql("g")}),
        EXISTS(SELECT 1
               FROM group_memberships t
               JOIN group_memberships v ON v.group_id = t.group_id AND v.profile_id = $2
               JOIN groups g ON g.id = t.group_id AND g.is_direct
               WHERE t.profile_id = $3)
      """

      %{rows: [[holder?, shared_ids, direct?]]} =
        Repo.query!(sql, [account_id, viewer_id, target.id], cache_statement: "profile_facts_v1")

      %__MODULE__{
        kind: target.kind,
        holder?: holder? or viewer_id == target.id,
        shared_group_ids: MapSet.new(shared_ids),
        direct?: direct? and viewer_id != target.id
      }
    end
  end

  @doc "The groups the viewer sees the profile in as a member: shared or related."
  def group_ids(%__MODULE__{shared_group_ids: shared, relation_group_ids: related}),
    do: MapSet.union(shared, related)

  defp account_id(%Account{id: id}), do: id
  defp account_id(_account), do: nil

  defp profile_id(%Profile{id: id}), do: id
  defp profile_id(_profile), do: nil
end
