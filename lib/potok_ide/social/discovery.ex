defmodule PotokIde.Social.Discovery do
  @moduledoc """
  Who may find a profile, as the profile chooses (`Profile.discovery`):

    * `:everyone`: anyone signed in, also among the suggestions when
      inviting and in the list of profiles with a tag;
    * `:by_username`: anyone who knows its exact username, and whoever
      shares a group with it, who also gets it among the suggestions;
    * `:shared_groups`: only whoever shares a group with it; anyone else
      invites it by email.

  A shared group, or a relation that counts as one, is the one of
  `PotokIde.Social.ProfileFacts`; the profile's own accounts always find it.
  A refusal looks exactly like a profile that is not there, so nobody learns
  that a hidden name exists.

  How the viewer came to the profile (`via`) decides what counts:

    * `:username`: its exact name, typed in to invite it or opened as
      `/u/:username`;
    * `:list`: a list the viewer searches, like the suggestions or a tag's
      profiles;
    * `:id`: an id, as a link carries it (`/profiles/:id/direct`, a tag
      editor), which says nothing of the name, so only `:everyone` or an
      existing direct conversation lets a stranger through.

  On a group's page the group decides instead: whoever it shows there opens
  (`ProfileDetails.card_in_group?/3`).
  """

  import Ecto.Query, warn: false

  alias PotokIde.Social.{Group, GroupBlock, GroupMembership, Profile, ProfileFacts}

  @doc "Whether the viewer of `facts` may find `target` coming `via` (see the moduledoc)."
  def may_find?(%ProfileFacts{} = facts, %Profile{kind: :person} = target, via)
      when via in [:username, :list, :id] do
    facts.holder? or MapSet.size(ProfileFacts.group_ids(facts)) > 0 or
      open_to?(target.discovery, via, facts)
  end

  def may_find?(_facts, _target, _via), do: false

  defp open_to?(:everyone, _via, _facts), do: true
  defp open_to?(:by_username, :username, _facts), do: true
  defp open_to?(_discovery, :id, %ProfileFacts{direct?: true}), do: true
  defp open_to?(_discovery, _via, _facts), do: false

  @doc """
  Whether the viewer of `facts` may open a direct conversation with `target`:
  someone else's person it may find by name, or one it talks to already.
  """
  def may_message?(%ProfileFacts{holder?: true}, _target), do: false

  def may_message?(%ProfileFacts{} = facts, %Profile{kind: :person} = target),
    do: facts.direct? or may_find?(facts, target, :username)

  def may_message?(_facts, _target), do: false

  @doc """
  Keeps the profiles (the query's binding named `:profile`) that `viewer`
  finds in a list: itself, those open to everyone, and those it shares a
  group with.
  """
  def where_listable(query, %Profile{id: viewer_id}) do
    shared =
      from(t in GroupMembership,
        join: v in GroupMembership,
        on: v.group_id == t.group_id and v.profile_id == ^viewer_id,
        join: g in Group,
        on: g.id == t.group_id,
        where: t.profile_id == parent_as(:profile).id,
        where:
          not g.is_root and not g.is_direct and is_nil(g.parent_value_id) and
            is_nil(g.external_key),
        select: 1
      )

    where(
      query,
      [profile: p],
      p.id == ^viewer_id or p.discovery == :everyone or exists(shared)
    )
  end

  @doc "Leaves out the profiles (binding `:profile`) blocked in `group`."
  def where_not_blocked(query, %Group{id: group_id}) do
    blocked =
      from(b in GroupBlock,
        where: b.group_id == ^group_id and b.profile_id == parent_as(:profile).id,
        select: 1
      )

    where(query, not exists(blocked))
  end
end
