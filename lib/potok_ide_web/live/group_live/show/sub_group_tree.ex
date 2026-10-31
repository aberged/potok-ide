defmodule PotokIdeWeb.GroupLive.Show.SubGroupTree do
  @moduledoc """
  The folder view of the sub-groups tab, loaded a level at a time: the
  folders directly below the group first, then those below a folder once it
  is opened, a page per level (see `Social.list_sub_group_folders/3`). A
  search shows its matches and the folders on the way to them instead.

  The tree is a map with the top level as `nodes` and whether it has another
  page as `more?`, the `ids` of every folder loaded, the `thread_count` for
  the threads switch and whether the search left matches out (`truncated?`).
  A node is `%{group, child_count, thread_child_count, children, more?,
  open?, unread_count}`; `children` stays nil until the folder is opened,
  and the page keeps `unread_count` up to date.
  """

  alias PotokIde.Social
  alias PotokIde.Social.Group

  @page_size 50

  @doc """
  The tree of `group`. Options: `threads?: false` leaves out threads,
  `search:` shows the matches of a term, and `thread_count:` is the number of
  threads directly below the group.

  Without a search, the folders open in `previous` (the tree this one
  replaces) are loaded again as far as they were and stay open, so a reload
  keeps the view as it was. A search opens the folders on the way to its
  matches, and the tree after it starts closed again.
  """
  def load(%Group{} = group, profile, previous, opts \\ []) do
    search = if opts[:search] in [nil, ""], do: nil, else: opts[:search]

    tree = %{
      group_id: group.id,
      threads?: Keyword.get(opts, :threads?, true),
      search: search,
      base_thread_count: Keyword.get(opts, :thread_count, 0),
      thread_count_floor: 0,
      nodes: [],
      more?: false,
      truncated?: false,
      ids: [],
      thread_count: 0
    }

    previous = if previous && previous.group_id == group.id, do: previous

    tree
    |> load_nodes(group, profile, previous)
    |> refresh()
  end

  @doc """
  Opens or closes the folder `group_id`. Opening one for the first time
  loads its first page.
  """
  def toggle(tree, group_id, profile) do
    tree
    |> update_node(group_id, fn
      %{open?: true} = node ->
        %{node | open?: false}

      %{children: nil} = node ->
        {children, more?} = load_page(tree, group_id, profile, nil, [])
        %{node | children: children, more?: more?, open?: true}

      node ->
        %{node | open?: true}
    end)
    |> refresh()
  end

  @doc "Loads the next page of the top level (nil) or of the folder `group_id`."
  def load_more(%{more?: true} = tree, nil, profile) do
    {nodes, more?} = load_page(tree, tree.group_id, profile, List.last(tree.nodes), tree.nodes)
    refresh(%{tree | nodes: tree.nodes ++ nodes, more?: more?})
  end

  def load_more(tree, nil, _profile), do: tree

  def load_more(tree, group_id, profile) do
    tree
    |> update_node(group_id, fn
      %{more?: true, children: [_ | _] = children} = node ->
        {nodes, more?} = load_page(tree, group_id, profile, List.last(children), children)
        %{node | children: children ++ nodes, more?: more?}

      node ->
        node
    end)
    |> refresh()
  end

  defp load_nodes(%{search: nil} = tree, group, profile, previous) do
    {top_limit, open} =
      case previous do
        %{search: nil, nodes: nodes} -> {max(length(nodes), @page_size), open_folders(nodes)}
        _after_search -> {@page_size, []}
      end

    pages =
      Social.list_sub_group_folders(
        profile,
        [{group.id, top_limit, nil} | Enum.map(open, &{&1.group.id, page_limit(&1), nil})],
        threads?: tree.threads?
      )

    {nodes, more?} = build_level(group.id, pages)
    %{tree | nodes: nodes, more?: more?}
  end

  defp load_nodes(tree, group, profile, previous) do
    {folders, truncated?} =
      Social.search_sub_group_folders(group, profile, tree.search, threads?: tree.threads?)

    %{
      tree
      | nodes: search_level(group.id, Enum.group_by(folders, & &1.parent_id)),
        truncated?: truncated?,
        # The threads switch stays put while searching.
        thread_count_floor: (previous && previous.thread_count) || 0
    }
  end

  # The open folders, and those open below them; a closed folder's children
  # are loaded again once it is opened.
  defp open_folders(nodes) do
    Enum.flat_map(nodes, fn
      %{open?: true, children: [_ | _] = children} = node -> [node | open_folders(children)]
      _node -> []
    end)
  end

  defp page_limit(node), do: max(length(node.children), @page_size)

  # Every folder with a page in `pages` comes back open with its children.
  defp build_level(parent_id, pages) do
    {folders, more?} = Map.get(pages, parent_id, {[], false})

    nodes =
      Enum.map(folders, fn folder ->
        if Map.has_key?(pages, folder.id) do
          {children, more?} = build_level(folder.id, pages)
          %{new_node(folder) | children: children, more?: more?, open?: true}
        else
          new_node(folder)
        end
      end)

    {nodes, more?}
  end

  # A folder on the way to a match comes open with just that way below it; a
  # match loads its own sub-groups once opened.
  defp search_level(parent_id, folders_by_parent) do
    folders_by_parent
    |> Map.get(parent_id, [])
    |> Enum.map(fn folder ->
      node = new_node(folder)

      if Map.has_key?(folders_by_parent, folder.id) do
        %{node | children: search_level(folder.id, folders_by_parent), open?: true}
      else
        node
      end
    end)
  end

  # Folders already in the tree are skipped: a group renamed between two
  # pages sorts again further on.
  defp load_page(tree, parent_id, profile, last_node, loaded) do
    after_folder = last_node && %{id: last_node.group.id, name: last_node.group.name}

    %{^parent_id => {folders, more?}} =
      Social.list_sub_group_folders(profile, [{parent_id, @page_size, after_folder}],
        threads?: tree.threads?
      )

    loaded_ids = MapSet.new(loaded, & &1.group.id)

    nodes =
      for folder <- folders, not MapSet.member?(loaded_ids, folder.id), do: new_node(folder)

    {nodes, more?}
  end

  defp new_node(folder) do
    %{
      group: Map.take(folder, [:id, :name, :thread?, :public?, :member?]),
      child_count: folder.child_count,
      thread_child_count: folder.thread_child_count,
      children: nil,
      more?: false,
      open?: false,
      unread_count: 0
    }
  end

  defp update_node(tree, group_id, fun),
    do: %{tree | nodes: update_nodes(tree.nodes, group_id, fun)}

  defp update_nodes(nodes, group_id, fun) do
    Enum.map(nodes, fn
      %{group: %{id: ^group_id}} = node ->
        fun.(node)

      %{children: [_ | _] = children} = node ->
        %{node | children: update_nodes(children, group_id, fun)}

      node ->
        node
    end)
  end

  # Threads are counted by the folder they sit in, loaded or not.
  defp refresh(tree) do
    nodes = all_nodes(tree.nodes)
    thread_count = tree.base_thread_count + Enum.sum_by(nodes, & &1.thread_child_count)

    %{
      tree
      | ids: Enum.map(nodes, & &1.group.id),
        thread_count: max(thread_count, tree.thread_count_floor)
    }
  end

  defp all_nodes(nodes), do: Enum.flat_map(nodes, &[&1 | all_nodes(&1.children || [])])
end
