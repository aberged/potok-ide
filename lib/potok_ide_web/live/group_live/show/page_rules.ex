defmodule PotokIdeWeb.GroupLive.Show.PageRules do
  @moduledoc """
  What the group page offers a viewer: which tabs open for them, and what its
  composer takes. Each rule is a pure function of the viewer's `%Access{}` and
  the group, so the access overview asks these same rules about a made-up
  viewer (roles picked by hand, a non-member, a guest) and cannot say anything
  the page does not do.

  A few rules need a fact about the group that takes a query, such as whether
  it has public events. `facts` holds each one as a boolean or as a function of
  no arguments. The page passes `lazy_facts/1`, which asks the database only
  when a rule needs the answer; the overview works them out once with
  `facts/1` and asks the rules many times.
  """

  alias PotokIde.{Events, Notices, Polls, Storage}
  alias PotokIde.Social.{Access, AppProcesses, Group, ValueRules}

  @type facts :: %{optional(atom()) => boolean() | (-> boolean())}

  @doc "The facts as the page asks for them: each one only when a rule needs it."
  @spec lazy_facts(Group.t()) :: facts()
  def lazy_facts(%Group{} = group) do
    %{
      public_events?: fn -> Events.public_events?(group) end,
      public_polls?: fn -> Polls.public_polls?(group) end,
      any_polls?: fn -> Polls.any?(group) end,
      apps_or_processes?: fn -> AppProcesses.any_app_or_process?(group) end
    }
  end

  @doc "The facts worked out at once, for asking the rules about many viewers."
  @spec facts(Group.t()) :: facts()
  def facts(%Group{} = group), do: Map.new(lazy_facts(group), fn {key, fun} -> {key, fun.()} end)

  defp fact(facts, key) do
    case Map.fetch!(facts, key) do
      fun when is_function(fun, 0) -> fun.()
      value when is_boolean(value) -> value
    end
  end

  @doc "The tab a group opens on when no other is asked for, or when the one asked for is not the viewer's."
  def default_tab(%Group{is_root: true}), do: "sub_groups"
  def default_tab(%Group{is_direct: true}), do: "values"
  def default_tab(%Group{home_page: :chat}), do: "values"
  def default_tab(%Group{home_page: :subgroups}), do: "sub_groups"
  def default_tab(%Group{}), do: "group_home"

  @doc """
  The tab a request for `tab` opens: `tab` itself when the viewer may have it,
  the group's first tab otherwise.
  """
  def tab(tab, _group, _access, _facts) when tab in ["values", "sub_groups", "group_home"],
    do: tab

  def tab("members", group, access, _facts),
    do: if(members?(group, access), do: "members", else: default_tab(group))

  def tab("roles", %Group{is_direct: false}, %Access{member?: true}, _facts), do: "roles"

  # In the root group, the events of every group the profile is in.
  def tab("calendar", group, access, facts),
    do: if(calendar?(group, access, facts), do: "calendar", else: default_tab(group))

  # In the root group, every group with a place the profile sees.
  def tab("map", %Group{is_root: true}, _access, _facts), do: "map"

  def tab("polls", group, access, facts),
    do: if(polls_tab?(group, access, facts), do: "polls", else: default_tab(group))

  def tab("processes", group, access, facts),
    do: if(processes?(group, access, facts), do: "processes", else: default_tab(group))

  def tab("files", group, access, _facts),
    do: if(files?(group, access), do: "files", else: default_tab(group))

  def tab(tab, group, access, _facts)
      when tab in ["create_group", "invite_profile", "edit_group"],
      do: if(Access.can?(access, tab_permission(tab)), do: tab, else: default_tab(group))

  # Everyone who sees a group reads its notices; the page only mounts such groups.
  def tab("notices", group, _access, _facts),
    do: if(Notices.followable?(group), do: "notices", else: default_tab(group))

  def tab(_tab, group, _access, _facts), do: default_tab(group)

  defp tab_permission("create_group"), do: :create_subgroups
  defp tab_permission("invite_profile"), do: :invite_members
  defp tab_permission("edit_group"), do: :edit_group

  @doc "Whether the viewer sees the group at all: any public one, and those they are in."
  def sees_group?(%Group{} = group, %Access{member?: member?}), do: group.is_public or member?

  @doc "Whether the viewer has the Members tab: members of a group under the root."
  def members?(%Group{parent_id: parent_id}, %Access{member?: member?}),
    do: member? and not is_nil(parent_id)

  @doc "Whether the viewer has the Files tab: members of a group under the root."
  def files?(%Group{parent_id: parent_id}, %Access{member?: member?}),
    do: member? and not is_nil(parent_id)

  @doc """
  Whether the viewer has the calendar: members, and those who are not see the
  public events of a public group in it, when it has some.
  """
  def calendar?(_group, %Access{member?: true}, _facts), do: true

  def calendar?(%Group{is_public: true, is_root: false}, _access, facts),
    do: fact(facts, :public_events?)

  def calendar?(_group, _access, _facts), do: false

  @doc """
  Whether the viewer has the polls: members, in the root those of all their
  groups; those who are not see the public polls of a public group, when it
  has some. Direct conversations have no roles to give a poll its rules.
  """
  def polls_tab?(%Group{is_direct: true}, _access, _facts), do: false
  def polls_tab?(_group, %Access{member?: true}, _facts), do: true
  def polls_tab?(_group, _access, facts), do: fact(facts, :public_polls?)

  @doc """
  Whether the polls stand on the bar of sections. A sixth section does not fit
  every phone, so a group has it once it has a poll; until then the group's
  menu leads there. The root has no bar.
  """
  def polls_section?(%Group{is_root: true}, _access, _facts), do: false
  def polls_section?(%Group{is_direct: true}, _access, _facts), do: false
  def polls_section?(_group, %Access{member?: true}, facts), do: fact(facts, :any_polls?)
  def polls_section?(_group, _access, facts), do: fact(facts, :public_polls?)

  @doc """
  Whether the group has the Processes tab for the viewer: for its members, in a
  group that is neither the root nor a conversation, with an app or a process,
  or for whoever may draw one.
  """
  def processes?(%Group{is_root: true}, _access, _facts), do: false
  def processes?(%Group{is_direct: true}, _access, _facts), do: false

  def processes?(%Group{}, %Access{member?: true} = access, facts),
    do: ValueRules.manage?(access) or fact(facts, :apps_or_processes?)

  def processes?(_group, _access, _facts), do: false

  @doc "Whether the viewer may send files with a message."
  def can_attach?(%Access{} = access),
    do: Storage.enabled?() and access.member? and Access.can?(access, :attach_files)

  @doc """
  Whether the viewer may put a picture from the device into the description. It
  is a message with a file, in the group's chat, so it takes what such a message
  takes. It also takes editing the group, as the address it gives opens with no
  session. The root has no chat, though its settings can be reached by address.
  """
  def can_post_description_picture?(%Group{} = group, %Access{} = access) do
    not group.is_root and Access.can?(access, :edit_group) and can_attach?(access) and
      Access.can?(access, :post_values)
  end

  @doc """
  Whether the viewer may send a GIF or a sticker from the keyboard. It is a file
  in a message of its own, so it takes what both of those take.
  """
  def can_send_keyboard_media?(profile, %Group{} = group, %Access{} = access),
    do: can_attach?(access) and Access.can_post_in_chat?(profile, access, group)
end
