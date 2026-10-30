defmodule PotokIde.Social.Access do
  @moduledoc """
  What a profile may do in a group, derived from the group's effective
  manifest and the roles the profile holds there.

  - The effective manifest is the group's own, or that of its nearest ancestor
    that has one. The root group always has one.
  - Every member holds "everyone"; other roles are assigned per group.
  - "admin" holds every permission. For the other roles a permission is granted
    when one of them allows it and none of them denies it. "everyone" can only
    allow.

  Pure reads: changes and broadcasts live in `PotokIde.Social`.
  """

  import Ecto.Query, warn: false

  alias PotokIde.Cache
  alias PotokIde.Repo

  alias PotokIde.Social.{
    Group,
    GroupManifest,
    GroupMemberRole,
    GroupMembership,
    GroupRole,
    Profile
  }

  # Manifests change rarely and every page mount needs one; see `forget_manifests/1`.
  @manifest_ttl :timer.minutes(1)

  defstruct member?: false,
            admin?: false,
            role_keys: [],
            permissions: MapSet.new(),
            manifest: nil

  @type t :: %__MODULE__{
          member?: boolean(),
          admin?: boolean(),
          role_keys: [String.t()],
          permissions: MapSet.t(atom()),
          manifest: %GroupManifest{} | nil
        }

  @doc """
  The manifest a group uses, with its roles in display order (admin, custom
  roles, everyone). `manifest.group_id` is the group that owns it, which
  differs from `group.id` when the manifest is inherited.
  """
  def effective_manifest(%Group{id: group_id}), do: effective_manifest(group_id)

  def effective_manifest(group_id) when is_integer(group_id) do
    Cache.fetch({:effective_manifest, group_id}, @manifest_ttl, fn ->
      load_effective_manifest(group_id)
    end)
  end

  @doc """
  Forgets the cached manifests of `group_ids`, on this node and the others.
  Called after any change to a manifest or its roles, before telling the
  pages; the TTL bounds an entry that a load racing with the change stored.
  """
  def forget_manifests(group_ids) when is_list(group_ids) do
    keys = Enum.map(group_ids, &{:effective_manifest, &1})
    Cache.delete_many(keys)
    :erpc.multicast(Node.list(), Cache, :delete_many, [keys])
    :ok
  end

  @doc """
  `effective_manifest/1` read from the database, past the cache: for a
  transaction that changes manifests and must see its own writes.
  """
  def load_effective_manifest(%Group{id: group_id}), do: load_effective_manifest(group_id)

  def load_effective_manifest(group_id) when is_integer(group_id) do
    sql = """
    WITH RECURSIVE path AS (
      SELECT g.id, g.parent_id, 0 AS depth
      FROM groups g
      WHERE g.id = $1
      UNION ALL
      SELECT parent.id, parent.parent_id, path.depth + 1
      FROM groups parent
      JOIN path ON parent.id = path.parent_id
    )
    SELECT m.id, m.group_id
    FROM path
    JOIN group_manifests m ON m.group_id = path.id
    ORDER BY path.depth
    LIMIT 1
    """

    case Repo.query(sql, [group_id], cache_statement: "access_effective_manifest") do
      {:ok, %{rows: [[manifest_id, owner_group_id]]}} ->
        roles =
          from(r in GroupRole, where: r.manifest_id == ^manifest_id)
          |> Repo.all()
          |> sort_roles()

        %GroupManifest{id: manifest_id, group_id: owner_group_id, roles: roles}

      {:ok, %{rows: []}} ->
        nil
    end
  end

  @doc "Admin first, then custom roles by position, then everyone."
  def sort_roles(roles) do
    Enum.sort_by(roles, fn role -> {role_rank(role.key), role.position, role.id} end)
  end

  defp role_rank("admin"), do: 0
  defp role_rank("everyone"), do: 2
  defp role_rank(_key), do: 1

  @doc "Whether the group has its own manifest instead of inheriting one."
  def own_manifest?(%Group{id: group_id}, %GroupManifest{group_id: group_id}), do: true
  def own_manifest?(%Group{}, _manifest), do: false

  @doc """
  The profile's access to the group. Pass `manifest:` when it is already
  loaded (e.g. when computing access for several profiles of one group).
  """
  def for_profile(profile, group, opts \\ [])

  def for_profile(nil, %Group{} = group, opts) do
    %__MODULE__{manifest: Keyword.get_lazy(opts, :manifest, fn -> effective_manifest(group) end)}
  end

  def for_profile(%Profile{id: profile_id}, %Group{id: group_id} = group, opts) do
    manifest = Keyword.get_lazy(opts, :manifest, fn -> effective_manifest(group) end)

    # [] = not a member, [nil] = a member with no assigned roles.
    assigned =
      from(gm in GroupMembership,
        left_join: r in GroupMemberRole,
        on: r.group_id == gm.group_id and r.profile_id == gm.profile_id,
        where: gm.group_id == ^group_id and gm.profile_id == ^profile_id,
        select: r.role_key
      )
      |> Repo.all()

    case assigned do
      [] -> %__MODULE__{manifest: manifest}
      keys -> build(manifest, Enum.reject(keys, &is_nil/1))
    end
  end

  # A member's access from the role keys assigned to them in the group.
  defp build(manifest, assigned_keys) do
    roles = if manifest, do: manifest.roles, else: []
    known_keys = MapSet.new(roles, & &1.key)
    admin_key = GroupRole.admin_key()
    everyone_key = GroupRole.everyone_key()

    role_keys =
      [everyone_key | Enum.filter(assigned_keys, &MapSet.member?(known_keys, &1))]
      |> Enum.uniq()

    admin? = admin_key in role_keys

    %__MODULE__{
      member?: true,
      admin?: admin?,
      role_keys: role_keys,
      permissions: permissions_for(roles, role_keys, admin?),
      manifest: manifest
    }
  end

  defp permissions_for(_roles, _role_keys, true = _admin?),
    do: MapSet.new(GroupRole.permissions())

  defp permissions_for(roles, role_keys, false = _admin?) do
    held = Enum.filter(roles, &(&1.key in role_keys))
    allowed = held |> Enum.flat_map(& &1.allowed) |> MapSet.new()

    denied =
      held
      |> Enum.reject(&(&1.key == GroupRole.everyone_key()))
      |> Enum.flat_map(& &1.denied)
      |> MapSet.new()

    MapSet.difference(allowed, denied)
  end

  def can?(%__MODULE__{permissions: permissions}, permission) when is_atom(permission),
    do: MapSet.member?(permissions, permission)

  def can?(profile, %Group{} = group, permission) when is_atom(permission),
    do: profile |> for_profile(group) |> can?(permission)

  def admin?(%Profile{} = profile, %Group{} = group), do: for_profile(profile, group).admin?

  @doc """
  The access of every member of the group, as `%{profile_id => %Access{}}`.
  """
  def for_members(%Group{id: group_id} = group, opts \\ []) do
    manifest = Keyword.get_lazy(opts, :manifest, fn -> effective_manifest(group) end)

    from(gm in GroupMembership,
      left_join: r in GroupMemberRole,
      on: r.group_id == gm.group_id and r.profile_id == gm.profile_id,
      where: gm.group_id == ^group_id,
      select: {gm.profile_id, r.role_key}
    )
    |> Repo.all()
    |> Enum.group_by(fn {profile_id, _key} -> profile_id end, fn {_id, key} -> key end)
    |> Map.new(fn {profile_id, keys} ->
      {profile_id, build(manifest, Enum.reject(keys, &is_nil/1))}
    end)
  end

  def profile_ids_with_permission(%Group{} = group, permission) when is_atom(permission) do
    group
    |> for_members()
    |> Enum.filter(fn {_profile_id, access} -> can?(access, permission) end)
    |> Enum.map(fn {profile_id, _access} -> profile_id end)
    |> Enum.sort()
  end

  @doc """
  Members of the group holding the role (every member for "everyone"). Stale
  assignments of roles missing from the effective manifest are not counted.
  """
  def profile_ids_with_role(%Group{id: group_id}, "everyone") do
    from(gm in GroupMembership, where: gm.group_id == ^group_id, select: gm.profile_id)
    |> Repo.all()
  end

  def profile_ids_with_role(%Group{id: group_id}, role_key) when is_binary(role_key) do
    from(r in GroupMemberRole,
      where: r.group_id == ^group_id and r.role_key == ^role_key,
      select: r.profile_id
    )
    |> Repo.all()
  end

  def count_admins(%Group{id: group_id}) do
    admin_key = GroupRole.admin_key()

    from(r in GroupMemberRole,
      where: r.group_id == ^group_id and r.role_key == ^admin_key,
      select: count()
    )
    |> Repo.one()
  end

  @doc "Assigned role keys of the given members: `%{profile_id => [key]}`."
  def role_keys_by_profile(%Group{id: group_id}, profile_ids) when is_list(profile_ids) do
    from(r in GroupMemberRole,
      where: r.group_id == ^group_id and r.profile_id in ^profile_ids,
      order_by: [asc: r.inserted_at],
      select: {r.profile_id, r.role_key}
    )
    |> Repo.all()
    |> Enum.group_by(fn {profile_id, _key} -> profile_id end, fn {_id, key} -> key end)
  end

  @doc "How many members of the group hold each assigned role: `%{key => count}`."
  def role_member_counts(%Group{id: group_id}) do
    from(r in GroupMemberRole,
      where: r.group_id == ^group_id,
      group_by: r.role_key,
      select: {r.role_key, count()}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Ids of the groups that use the manifest: its owner and every descendant
  reached without passing a group that has its own manifest.
  """
  def group_ids_using_manifest(%GroupManifest{group_id: owner_group_id}) do
    sql = """
    WITH RECURSIVE sub AS (
      SELECT g.id FROM groups g WHERE g.id = $1
      UNION ALL
      SELECT child.id
      FROM groups child
      JOIN sub ON child.parent_id = sub.id
      WHERE NOT EXISTS (SELECT 1 FROM group_manifests m WHERE m.group_id = child.id)
    )
    SELECT id FROM sub
    """

    {:ok, %{rows: rows}} =
      Repo.query(sql, [owner_group_id], cache_statement: "access_groups_using_manifest")

    Enum.map(rows, fn [id] -> id end)
  end
end
