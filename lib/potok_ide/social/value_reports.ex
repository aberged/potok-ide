defmodule PotokIde.Social.ValueReports do
  @moduledoc """
  Messages reported to the admins of their group (`PotokIde.Social.ValueReport`).

  Whoever reads a chat may report a message in it that someone else wrote,
  once, with a reason and a note. It goes to the admins of the group: for a
  message in a thread, those of the group the thread hangs from, and when a
  group has no admin, those of the nearest group above it that has one
  (`handling_group/1`). They hear of it by push and find it under Requests,
  and they delete the message, which takes its reports with it, or dismiss
  the report. Who reported is seen by the admins only.

  A direct conversation has no reports: a profile blocks the other one there
  (`PotokIde.Social.ProfileBlocks`).
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  import Ecto.Query, warn: false

  alias PotokIde.PushNotifications.Dispatch
  alias PotokIde.Repo
  alias PotokIde.Social

  alias PotokIde.Social.{
    Access,
    AccountProfile,
    Group,
    GroupMemberRole,
    GroupRole,
    Notifications,
    Profile,
    Value,
    ValueReport
  }

  @list_limit 200

  @doc "The reasons a report gives, in the order the dialog offers them."
  def reasons, do: ValueReport.reasons()

  @doc "A reason as people read it."
  def reason_label(:spam), do: gettext("Spam or advertising")
  def reason_label(:abuse), do: gettext("Insult, threat or harassment")
  def reason_label(:inappropriate), do: gettext("Violence, hate or sexual content")
  def reason_label(:other), do: gettext("Something else")

  @doc """
  Whether `profile`, with `access` to `group`, may report `value`: a person
  who reads the chat, a message someone else wrote, and no direct
  conversation.
  """
  def can_report?(profile, %Access{} = access, %Group{} = group, %Value{} = value) do
    match?(%Profile{kind: :person}, profile) and not group.is_direct and not value.is_data and
      value.creator_id != profile.id and Access.can_read_chat?(access, group)
  end

  @doc "A blank report for the dialog's form."
  def change_report(attrs \\ %{}), do: ValueReport.changeset(%ValueReport{}, attrs)

  @doc """
  `reporter` reports `value` with `attrs` (`"reason"`, `"note"`). The admins
  who handle it are told at once.
  """
  def report(%Profile{} = reporter, %Value{} = value, attrs) do
    group = Repo.get!(Group, value.group_id)

    if can_report?(reporter, Access.for_profile(reporter, group), group, value) do
      handler = handling_group(group)

      %ValueReport{group_id: handler.id, value_id: value.id, reporter_id: reporter.id}
      |> ValueReport.changeset(attrs)
      |> Repo.insert()
      |> case do
        {:ok, report} ->
          tell_admins(handler, value, report.reason, except: reporter.id)
          {:ok, report}

        {:error, %Ecto.Changeset{} = changeset} ->
          if Keyword.has_key?(changeset.errors, :value_id),
            do: {:error, :already_reported},
            else: {:error, changeset}
      end
    else
      {:error, :not_permitted}
    end
  end

  @doc "Whether `profile` already reported `value_id`."
  def reported?(%Profile{id: profile_id}, value_id) when is_integer(value_id) do
    Repo.exists?(
      from(r in ValueReport, where: r.value_id == ^value_id and r.reporter_id == ^profile_id)
    )
  end

  def reported?(_profile, _value_id), do: false

  @doc """
  The group whose admins handle a report of a message in `group`: the group
  a thread hangs from, or the nearest one above it with an admin.
  """
  def handling_group(%Group{parent_value_id: nil} = group), do: with_admins(group, group)

  def handling_group(%Group{parent_id: parent_id}),
    do: parent_id |> Social.get_group!() |> handling_group()

  defp with_admins(%Group{} = group, %Group{} = first) do
    cond do
      Access.count_admins(group) > 0 -> group
      group.parent_id -> with_admins(Social.get_group!(group.parent_id), first)
      true -> first
    end
  end

  @doc """
  The open reports of the groups `profile` is an admin of, newest first, by
  group: `[%{group: group, reports: reports}]`, each report with its message
  (author and files) and reporter.
  """
  def list_open(%Profile{} = profile) do
    profile
    |> open_query()
    |> order_by([r], desc: r.id)
    |> limit(@list_limit)
    |> preload([:reporter, :group, value: [:creator, :attachments]])
    |> Repo.all()
    |> Enum.group_by(& &1.group)
    |> Enum.map(fn {group, reports} -> %{group: group, reports: reports} end)
    |> Enum.sort_by(fn %{reports: [newest | _]} -> -newest.id end)
  end

  @doc "How many open reports wait for `profile` as an admin (the hand on the header counts them)."
  def open_count(nil), do: 0

  def open_count(%Profile{} = profile),
    do: profile |> open_query() |> select([r], count(r.id)) |> Repo.one()

  defp open_query(%Profile{id: profile_id}) do
    admin_key = GroupRole.admin_key()

    from(r in ValueReport,
      join: role in GroupMemberRole,
      on: role.group_id == r.group_id and role.profile_id == ^profile_id,
      where: role.role_key == ^admin_key and is_nil(r.dismissed_at)
    )
  end

  @doc "An admin of its group dismisses the report: the message stays."
  def dismiss(%Profile{} = admin, report_id) when is_integer(report_id) do
    with {:ok, report, group} <- open_report_for_admin(admin, report_id) do
      report
      |> Ecto.Changeset.change(
        dismissed_at: DateTime.utc_now(:second),
        dismissed_by_id: admin.id
      )
      |> Repo.update!()

      reports_changed([group.id])
      :ok
    end
  end

  @doc """
  An admin of its group deletes the reported message, also when it is in a
  thread where they hold no role: handling reports is what admins are for.
  The message's reports go with it (`Social.moderate_value/2`).
  """
  def delete_value(%Profile{} = admin, report_id) when is_integer(report_id) do
    with {:ok, report, _group} <- open_report_for_admin(admin, report_id),
         %Value{} = value <- Repo.get(Value, report.value_id),
         {:ok, _value} <- Social.moderate_value(admin, value) do
      :ok
    else
      nil -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp open_report_for_admin(%Profile{} = admin, report_id) do
    with %ValueReport{dismissed_at: nil} = report <- Repo.get(ValueReport, report_id),
         %Group{} = group <- Repo.get(Group, report.group_id),
         true <- Access.admin?(admin, group) do
      {:ok, report, group}
    else
      false -> {:error, :not_permitted}
      _gone -> {:error, :not_found}
    end
  end

  @doc """
  The groups whose admins have open reports of `value_id`: read before the
  message is deleted, which takes them with it, to tell those admins after.
  """
  def open_group_ids(value_id) when is_integer(value_id) do
    from(r in ValueReport,
      where: r.value_id == ^value_id and is_nil(r.dismissed_at),
      distinct: true,
      select: r.group_id
    )
    |> Repo.all()
  end

  @doc "The admins of `group_ids` count their open reports again (the hand and the Requests page)."
  def reports_changed([]), do: :ok

  def reports_changed(group_ids) when is_list(group_ids) do
    group_ids
    |> Enum.flat_map(&Access.profile_ids_with_role(%Group{id: &1}, GroupRole.admin_key()))
    |> Enum.uniq()
    |> Enum.each(&broadcast_waiting/1)
  end

  defp tell_admins(%Group{} = group, %Value{} = value, reason, except: reporter_id) do
    admin_ids = Access.profile_ids_with_role(group, GroupRole.admin_key()) -- [reporter_id]
    Enum.each(admin_ids, &broadcast_waiting/1)

    if admin_ids != [] do
      payload = Notifications.value_reported(group, Repo.preload(value, :attachments), reason)

      Dispatch.run(fn ->
        from(ap in AccountProfile, where: ap.profile_id in ^admin_ids, select: ap.account_id)
        |> Dispatch.subscriptions_by_account()
        |> Dispatch.deliver_localized("value report", group.id, payload)
      end)
    end

    :ok
  end

  # What waits for the profile changed: the hand counts again
  # (`PotokIdeWeb.ProfileAuth`), and the Requests page reads its lists.
  defp broadcast_waiting(profile_id) do
    Phoenix.PubSub.broadcast(
      PotokIde.PubSub,
      "profiles:#{profile_id}",
      {:profile_waiting_updated, profile_id}
    )
  end
end
