defmodule PotokIde.Social.AppProcesses do
  @moduledoc """
  The processes of apps and the profiles they sign with.

  A collection whose rule has a `process` (`ValueRules`) gets a profile of its
  own the first time an editor saves that rule: every value and every group
  but the root needs a creator, and what a process does is signed by it, not
  by one of the people. In the same transaction it becomes a member of the
  app's group, and the editor who saved the rule owns it (`AppProcess`).

  - A process profile has no account (`Profile.kind` `:process`): nobody logs
    in as it or picks it, and where people are listed, mentioned or invited
    it is left out. Members do not pass to it through inheritance.
  - It holds what `everyone` holds in the app's group, like any member, so the
    editors see what is missing (`warnings/2`).
  - Removing the rule deactivates the process and takes it out of the group;
    the profile stays as the author of what it wrote, and the rule coming back
    brings the same profile back.
  - A profile left without its process (the app or its group was deleted) and
    without anything it wrote is deleted (`sweep/0`).
  """

  import Ecto.Query, warn: false

  alias PotokIde.Processes.Graph
  alias PotokIde.Repo

  alias PotokIde.Social.{
    Access,
    AppData,
    AppProcess,
    Group,
    GroupMembership,
    GroupValueRead,
    Profile,
    ValueRules
  }

  @username_prefix "proces."
  @username_alphabet ~c"abcdefghijkmnpqrstuvwxyz23456789"
  @username_suffix_length 6
  @username_attempts 5

  @doc """
  Brings the processes of an app in line with its normalized `rules`, as
  `editor` saves them. Runs inside the transaction of `AppData.save_config/5`,
  which holds the app's lock, so two saves never make two profiles.

  A new process, or one that comes back, is owned by `editor`; so is one whose
  owner no longer edits the app. Returns `:ok`; a profile that cannot be made
  rolls the save back with `:process_profile`.
  """
  def sync(%Profile{} = editor, %Group{} = group, alt, rules) when is_map(rules) do
    alt_id = AppData.alt_id(alt)

    wanted =
      for {collection, %{"process" => %{"name" => name}}} <- rules,
          into: %{},
          do: {collection, name}

    rows = group.id |> app_query(alt_id) |> lock("FOR UPDATE") |> Repo.all()
    by_collection = Map.new(rows, &{&1.collection, &1})

    Enum.each(wanted, fn {collection, name} ->
      case Map.get(by_collection, collection) do
        nil -> start!(editor, group, alt_id, collection, name)
        %AppProcess{active: false} = row -> resume!(editor, group, row, name)
        %AppProcess{} = row -> keep!(editor, group, row, name)
      end
    end)

    for %AppProcess{active: true} = row <- rows, not Map.has_key?(wanted, row.collection) do
      stop!(group, row)
    end

    :ok
  end

  defp start!(editor, group, alt_id, collection, name) do
    profile = create_process_profile!()

    %AppProcess{
      profile_id: profile.id,
      group_id: group.id,
      alt_description_id: alt_id,
      collection: collection,
      name: name,
      owner_profile_id: editor.id,
      active: true
    }
    |> Repo.insert!()

    join!(group, profile.id)
  end

  defp resume!(editor, group, %AppProcess{} = row, name) do
    row
    |> Ecto.Changeset.change(active: true, owner_profile_id: editor.id, name: name)
    |> Repo.update!()

    join!(group, row.profile_id)
  end

  # The owner stays while they edit the app; otherwise the editor saving the
  # rule takes it over. The name follows the rule.
  defp keep!(editor, group, %AppProcess{owner_profile_id: owner_id} = row, name) do
    owner_id =
      if owner_id != editor.id and not edits_app?(owner_id, group), do: editor.id, else: owner_id

    changeset = Ecto.Changeset.change(row, owner_profile_id: owner_id, name: name)
    if changeset.changes != %{}, do: Repo.update!(changeset)

    :ok
  end

  defp stop!(%Group{id: group_id}, %AppProcess{profile_id: profile_id} = row) do
    row |> Ecto.Changeset.change(active: false) |> Repo.update!()

    # Its roles go with the membership (composite foreign key).
    Repo.delete_all(
      from(gm in GroupMembership,
        where: gm.group_id == ^group_id and gm.profile_id == ^profile_id
      )
    )

    Repo.delete_all(
      from(r in GroupValueRead, where: r.group_id == ^group_id and r.profile_id == ^profile_id)
    )
  end

  # A direct member, never inherited, and never one that inheriting groups
  # below take in (`MemberInheritance`).
  defp join!(%Group{id: group_id}, profile_id) do
    %GroupMembership{}
    |> GroupMembership.changeset(%{group_id: group_id, profile_id: profile_id})
    |> Repo.insert!(on_conflict: :nothing, conflict_target: [:group_id, :profile_id])

    :ok
  end

  @doc "Whether the profile still edits the app of `group`: an owner who no longer does gives way."
  def edits_app?(nil, _group), do: false

  def edits_app?(profile_id, %Group{} = group),
    do: ValueRules.manage?(Access.for_profile(%Profile{id: profile_id}, group))

  @doc """
  A new process profile with a username of its own, such as `proces.4f2kx9`:
  usernames are unique across Potok and the process has no name of its own
  there, as its rule names it. Raises, or rolls back the transaction it runs
  in, when no free username turns up.
  """
  def create_process_profile! do
    changeset = free_username_changeset(@username_attempts)

    case Repo.insert(changeset) do
      {:ok, profile} -> profile
      {:error, _changeset} -> rollback_or_raise(:process_profile)
    end
  end

  defp free_username_changeset(0), do: rollback_or_raise(:process_profile)

  defp free_username_changeset(attempts) do
    changeset =
      %Profile{kind: :process}
      |> Profile.changeset(%{
        username: random_username(),
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    if changeset.valid?, do: changeset, else: free_username_changeset(attempts - 1)
  end

  defp random_username do
    suffix =
      for _ <- 1..@username_suffix_length, into: "", do: <<Enum.random(@username_alphabet)>>

    @username_prefix <> suffix
  end

  defp rollback_or_raise(reason) do
    if Repo.in_transaction?(),
      do: Repo.rollback(reason),
      else: raise("could not make a process profile: #{reason}")
  end

  @doc """
  What the editors of an app should know about its active processes, by
  collection: the permissions the actions of its graph need that the process
  profile lacks in the app's group (`"missing"`, `Graph.permissions/1`), and
  whether its owner no longer edits the app (`"owner_left"`). Collections
  with nothing to say are left out.
  """
  def warnings(%Group{} = group, alt) do
    manifest = Access.effective_manifest(group)
    rules = group |> AppData.get_config(alt) |> AppData.rules()

    group.id
    |> app_query(AppData.alt_id(alt))
    |> where([p], p.active)
    |> Repo.all()
    |> Enum.flat_map(fn row ->
      case warning(row, group, manifest: manifest, graph: graph(rules, row)) do
        nil -> []
        warning -> [{row.collection, warning}]
      end
    end)
    |> Map.new()
  end

  @doc """
  What `warnings/2` says about one process, or nil when there is nothing to
  say. `opts` may carry the group's `:manifest` and the process's `:graph`,
  read from the app's rules otherwise.
  """
  def warning(%AppProcess{} = row, %Group{} = group, opts \\ []) do
    graph =
      Keyword.get_lazy(opts, :graph, fn ->
        group |> AppData.get_config(row.alt_description_id) |> AppData.rules() |> graph(row)
      end)

    access =
      Access.for_profile(%Profile{id: row.profile_id}, group, Keyword.take(opts, [:manifest]))

    missing =
      for permission <- Graph.permissions(graph),
          not Access.can?(access, permission),
          do: permission

    owner_left? = not edits_app?(row.owner_profile_id, group)

    if missing != [] or owner_left?,
      do: %{"missing" => Enum.map(missing, &to_string/1), "owner_left" => owner_left?}
  end

  @doc """
  The active processes of the group's apps, those of other descriptions
  included, with their profiles, owners and descriptions, by name.
  """
  def list_active(%Group{id: group_id}) do
    from(p in AppProcess,
      where: p.group_id == ^group_id and p.active,
      order_by: [asc: p.name, asc: p.id],
      preload: [:profile, :owner_profile, :alt_description]
    )
    |> Repo.all()
  end

  @doc """
  Whether `profile` signs for a process of `group`'s apps, running or stopped:
  there its rule, not a person, takes it in and out, so nobody removes or
  blocks it by hand. In the sub-groups it makes, people may.
  """
  def app_process_of?(%Profile{kind: :process, id: profile_id}, %Group{id: group_id}) do
    Repo.exists?(
      from(p in AppProcess, where: p.profile_id == ^profile_id and p.group_id == ^group_id)
    )
  end

  def app_process_of?(_profile, _group), do: false

  defp graph(rules, %AppProcess{collection: collection}),
    do: get_in(rules, [collection, "process", "graph"])

  @doc "The process a process profile signs for, or nil."
  def get_by_profile(%Profile{id: profile_id}),
    do: Repo.get_by(AppProcess, profile_id: profile_id)

  @doc """
  Deletes the process profiles that lost their process, when the app or its
  group was deleted, and have nothing left that they wrote. A deactivated
  process keeps its profile. Returns how many went.
  """
  def sweep do
    %{num_rows: count} =
      Repo.query!("""
      DELETE FROM profiles p
      WHERE p.kind = 'process'
        AND NOT EXISTS (SELECT 1 FROM app_processes a WHERE a.profile_id = p.id)
        AND NOT EXISTS (SELECT 1 FROM "values" v WHERE v.creator_id = p.id)
        AND NOT EXISTS (SELECT 1 FROM groups g WHERE g.creator_id = p.id)
        AND NOT EXISTS (SELECT 1 FROM value_attachments f WHERE f.profile_id = p.id)
      """)

    count
  end

  defp app_query(group_id, nil),
    do: from(p in AppProcess, where: p.group_id == ^group_id and is_nil(p.alt_description_id))

  defp app_query(group_id, alt_id),
    do: from(p in AppProcess, where: p.group_id == ^group_id and p.alt_description_id == ^alt_id)
end
