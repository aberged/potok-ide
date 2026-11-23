defmodule PotokIde.Social.AccessHistory do
  @moduledoc """
  Who changed what of the access to a group, and when: the history every
  member reads on the access overview, so that power has a name and an
  origin. Each change is written in the transaction that makes it, by the
  function that makes it, and only when something really changed.

  What is kept, and what is not:

  - roles given and taken, by an admin, by a decision of a poll or on an
    approved request; the statute (roles, permissions, how a role is had), the
    manifest made or dropped, the settings that let people in (public, open
    chat, the description for guests, inheriting members and by which roles,
    the rule of admission, electing admins), who sees an alternative
    description; members admitted, removed and blocked;
  - not what follows from these by itself, such as members coming into an
    inheriting sub-group or leaving it, nor invitations or members leaving of
    their own accord, which are membership and not power.

  Blocks are read only by those who may lift them, as they see the list of
  blocks; the rest by every member, and by nobody outside the group.
  """

  import Ecto.Query

  alias PotokIde.Repo
  alias PotokIde.Social.{Access, Group, GroupAccessChange}

  @page 30

  @doc "How many changes a page of the history holds."
  def page_size, do: @page

  @doc """
  Writes a change of `group` with `repo`, in the caller's transaction:
  `actor` (a profile id or nil), `subject` (a profile id), `role_key`, `poll`
  (an id) and `data`, each optional.
  """
  def record!(repo, group_or_id, kind, opts \\ []) when is_atom(kind) do
    repo.insert!(%GroupAccessChange{
      group_id: group_id(group_or_id),
      kind: kind,
      actor_id: opts[:actor],
      subject_id: opts[:subject],
      role_key: opts[:role_key],
      poll_id: opts[:poll],
      data: Map.new(opts[:data] || %{}, fn {key, value} -> {to_string(key), value} end)
    })
  end

  @doc """
  The changes of `group` the holder of `access` may read, the newest first, a
  page at a time: nothing for someone outside the group, blocks only for
  those who may remove members. `before: {inserted_at, id}` goes on from where
  a page ended. The actor and the subject come with each row.
  """
  def list(group, access, opts \\ [])

  def list(%Group{id: group_id}, %Access{member?: true} = access, opts) do
    # One query, the profiles joined, however many rows name them.
    from(c in GroupAccessChange,
      left_join: actor in assoc(c, :actor),
      left_join: subject in assoc(c, :subject),
      where: c.group_id == ^group_id,
      order_by: [desc: c.inserted_at, desc: c.id],
      limit: ^Keyword.get(opts, :limit, @page),
      preload: [actor: actor, subject: subject]
    )
    |> without_blocks(Access.can?(access, :remove_members))
    |> before(opts[:before])
    |> Repo.all()
  end

  def list(%Group{}, %Access{}, _opts), do: []

  defp without_blocks(query, true), do: query

  defp without_blocks(query, false),
    do: where(query, [c], c.kind not in ^GroupAccessChange.block_kinds())

  defp before(query, nil), do: query

  defp before(query, {%DateTime{} = at, id}) when is_integer(id),
    do: where(query, [c], c.inserted_at < ^at or (c.inserted_at == ^at and c.id < ^id))

  defp group_id(%Group{id: id}), do: id
  defp group_id(id) when is_integer(id), do: id
end
