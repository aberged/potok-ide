defmodule PotokIde.Social.EmailInvitations do
  @moduledoc """
  Invitations into a group by email, which go to the account behind the
  address and never to one of its profiles (`GroupAccountInvitation`).

  Whoever invites gets the same answer whether the address has an account,
  an account without a profile, or none: an address tells nothing of who is
  behind it. An address with no account gets one and a link to log in; any
  other account gets a push. The person then picks on Invitations which of
  their profiles accepts it, or makes a new one, and only then does the
  inviter learn that profile, as an accepted invitation naming it, the
  record of who brought whom in. No direct conversation opens before that,
  nor after: the two share the group, so either may write from the card.
  """

  import Ecto.Query, warn: false

  alias PotokIde.Accounts
  alias PotokIde.Accounts.Account
  alias PotokIde.RateLimit
  alias PotokIde.Repo
  alias PotokIde.Social

  alias PotokIde.Social.{
    GroupAccountInvitation,
    GroupBlock,
    GroupInvitation,
    GroupMembership,
    Notifications,
    Profile
  }

  @doc """
  `inviter`, the current profile of the account `inviter_account_id`,
  invites the address `email` into `group`. `login_url` makes the link of a
  new account's email from its token.

  Returns `:ok` whatever is behind the address, or an error about the
  inviter itself: no right to invite here (`Social.invitation_refusal/2`) or
  too many invitations lately (`{:error, :rate_limited, retry_after_ms}`).
  """
  def invite(%Profile{} = inviter, inviter_account_id, group, email, login_url)
      when is_binary(email) and is_function(login_url, 1) do
    email = String.trim(email)

    with nil <- Social.invitation_refusal(inviter, group),
         :ok <- RateLimit.hit(:invitation_email, inviter_account_id),
         {:ok, account} <- find_or_register(email),
         {:ok, _invitation} <- Social.invite_account_to_group(inviter, group, account, email) do
      if never_logged_in?(account), do: send_login_link(account, inviter, group, login_url)
      :ok
    else
      {:error, :rate_limited, _retry_after} = limited -> limited
      {:error, %Ecto.Changeset{}} -> {:error, :invalid_email}
      {:error, reason} -> {:error, reason}
      reason when is_atom(reason) -> {:error, reason}
    end
  end

  # Two people may invite the same new address at once: the one that comes
  # second finds the account the first one made.
  defp find_or_register(email) do
    case Accounts.get_account_by_email(email) do
      %Account{} = account ->
        {:ok, account}

      nil ->
        with {:error, changeset} <- Accounts.register_account(%{email: email}) do
          case Accounts.get_account_by_email(email) do
            %Account{} = account -> {:ok, account}
            nil -> {:error, changeset}
          end
        end
    end
  end

  # An account that never logged in has no device to push to, so it is told
  # by email, as often as links to log in are sent to one address.
  defp never_logged_in?(%Account{} = account) do
    is_nil(account.confirmed_at) and not Social.account_has_profiles?(account) and
      RateLimit.hit(:magic_link_email, RateLimit.email_key(account.email)) == :ok
  end

  # Sent apart from the answer, so how long it takes tells nothing either.
  defp send_login_link(account, inviter, group, login_url) do
    PotokIde.PushNotifications.Dispatch.run(fn ->
      Accounts.deliver_login_instructions(account, login_url, invited_by: inviter, group: group)
    end)
  end

  @doc """
  The account's invitations that still hold, the oldest first, with their
  groups and inviters.
  """
  def list(%Account{id: account_id}) do
    from(i in GroupAccountInvitation,
      where: i.account_id == ^account_id and i.inserted_at > ^GroupInvitation.cutoff(),
      order_by: [asc: i.inserted_at, asc: i.id],
      preload: [:group, :inviter]
    )
    |> Repo.all()
  end

  @doc "How many invitations the account has that still hold."
  def count(%Account{id: account_id}) do
    from(i in GroupAccountInvitation,
      where: i.account_id == ^account_id and i.inserted_at > ^GroupInvitation.cutoff(),
      select: count(i.id)
    )
    |> Repo.one()
  end

  @doc "One of the account's invitations, with its group and inviter, or nil."
  def get(%Account{id: account_id}, id) when is_integer(id) do
    from(i in GroupAccountInvitation,
      where: i.id == ^id and i.account_id == ^account_id,
      preload: [:group, :inviter]
    )
    |> Repo.one()
  end

  def get(_account, _id), do: nil

  @doc """
  The invitations `inviter` sent by email that wait still, the newest first,
  with their groups: the inviter sees the address, not who is behind it.
  """
  def list_sent(%Profile{id: inviter_id}) do
    from(i in GroupAccountInvitation,
      where: i.inviter_id == ^inviter_id and i.inserted_at > ^GroupInvitation.cutoff(),
      order_by: [desc: i.inserted_at, desc: i.id],
      limit: 100,
      preload: [:group]
    )
    |> Repo.all()
  end

  @doc """
  The account's profiles that may accept `invitation`, each with why it
  cannot, if it cannot: `:member` already, or `:blocked` in the group.
  """
  def choices(%Account{} = account, %GroupAccountInvitation{group_id: group_id}) do
    profiles = account |> Social.list_profiles_for_account() |> Enum.filter(&(&1.kind == :person))
    ids = Enum.map(profiles, & &1.id)
    members = ids_in(GroupMembership, group_id, ids)
    blocked = ids_in(GroupBlock, group_id, ids)

    Enum.map(profiles, fn profile ->
      cond do
        MapSet.member?(members, profile.id) -> {profile, :member}
        MapSet.member?(blocked, profile.id) -> {profile, :blocked}
        true -> {profile, nil}
      end
    end)
  end

  defp ids_in(schema, group_id, ids) do
    from(r in schema,
      where: r.group_id == ^group_id and r.profile_id in ^ids,
      select: r.profile_id
    )
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Accepts `invitation`, one of `account`'s, with `profile`, one of its
  people. The invitation holds 30 days and while its inviter may still
  invite into the group; the profile is no member there yet and not blocked.
  It becomes an accepted group invitation naming the profile, dated as the
  invitation was sent, and the account's other invitations to the group go.
  Where the profile has an invitation to the group of its own already, that
  one is accepted instead.

  Returns `{:ok, group}` or `{:error, reason}`: `:not_found`, `:expired`
  (the invitation goes), `:lapsed` (its inviter may no longer invite; it
  goes), `:not_held`, `:member` or `:blocked`.
  """
  def accept(%Account{} = account, %GroupAccountInvitation{} = invitation, %Profile{} = profile) do
    invitation = Repo.preload(invitation, [:group, :inviter])

    with :ok <- own(account, invitation),
         :ok <- holds(invitation),
         :ok <- may_join(account, invitation, profile),
         {:ok, group_invitation, made} <- group_invitation_for(invitation, profile) do
      case Social.accept_group_invitation(group_invitation, profile) do
        {:ok, _accepted} ->
          drop_for_group(account, invitation.group_id)
          {:ok, invitation.group}

        {:error, reason} ->
          # One left behind would show the inviter the profile, though it
          # never came in.
          if made == :new, do: forget(group_invitation)
          {:error, reason}
      end
    end
  end

  defp forget(%GroupInvitation{id: id}) do
    Repo.delete_all(from(i in GroupInvitation, where: i.id == ^id and is_nil(i.accepted_at)))
  end

  defp own(%Account{id: id}, %GroupAccountInvitation{account_id: id}), do: :ok
  defp own(_account, _invitation), do: {:error, :not_found}

  defp holds(%GroupAccountInvitation{} = invitation) do
    cond do
      DateTime.compare(invitation.inserted_at, GroupInvitation.cutoff()) != :gt ->
        drop(invitation)
        {:error, :expired}

      Social.invitation_refusal(invitation.inviter, invitation.group) ->
        drop(invitation)
        {:error, :lapsed}

      true ->
        :ok
    end
  end

  defp may_join(account, invitation, %Profile{} = profile) do
    case Enum.find(choices(account, invitation), fn {held, _reason} -> held.id == profile.id end) do
      nil -> {:error, :not_held}
      {_profile, nil} -> :ok
      {_profile, reason} -> {:error, reason}
    end
  end

  # The profile's own waiting invitation to the group (it has one at most),
  # or a new one dated as the invitation by email was sent. One that lapsed
  # and was not swept yet makes way.
  defp group_invitation_for(%GroupAccountInvitation{} = invitation, %Profile{} = profile) do
    own =
      from(i in GroupInvitation,
        where:
          i.group_id == ^invitation.group_id and i.invitee_id == ^profile.id and
            is_nil(i.accepted_at)
      )

    Repo.delete_all(from(i in own, where: i.inserted_at <= ^GroupInvitation.cutoff()))

    case Repo.one(own) do
      %GroupInvitation{} = group_invitation ->
        {:ok, group_invitation, :waiting}

      nil ->
        %GroupInvitation{
          inserted_at: invitation.inserted_at,
          updated_at: invitation.inserted_at
        }
        |> GroupInvitation.changeset(%{
          group_id: invitation.group_id,
          inviter_id: invitation.inviter_id,
          invitee_id: profile.id
        })
        |> Repo.insert()
        |> case do
          {:ok, group_invitation} -> {:ok, group_invitation, :new}
          {:error, %Ecto.Changeset{}} -> {:error, :already_accepted}
        end
    end
  end

  @doc """
  Makes a new profile of `account` from the welcome window's fields and
  accepts `invitation` with it. Returns `{:ok, profile, group}`, where the
  group is nil when the invitation failed after the profile was made, or
  `{:error, changeset | reason}`.
  """
  def create_profile_and_accept(
        %Account{} = account,
        %GroupAccountInvitation{} = invitation,
        attrs
      ) do
    invitation = Repo.preload(invitation, [:group, :inviter])

    with :ok <- own(account, invitation),
         :ok <- holds(invitation),
         {:ok, profile} <- Social.create_profile_for_account(account, attrs) do
      case accept(account, invitation, profile) do
        {:ok, group} -> {:ok, profile, group}
        {:error, _reason} -> {:ok, profile, nil}
      end
    end
  end

  @doc "Deletes one of the account's invitations. Returns `:ok` or `{:error, :not_found}`."
  def delete(%Account{} = account, %GroupAccountInvitation{} = invitation) do
    with :ok <- own(account, invitation) do
      drop(invitation)
    end
  end

  defp drop(%GroupAccountInvitation{id: id, account_id: account_id}),
    do: drop_all(from(i in GroupAccountInvitation, where: i.id == ^id), account_id)

  defp drop_for_group(%Account{id: account_id}, group_id) do
    drop_all(
      from(i in GroupAccountInvitation,
        where: i.account_id == ^account_id and i.group_id == ^group_id
      ),
      account_id
    )
  end

  # The pages of the account and of whoever sent them.
  defp drop_all(query, account_id) do
    {_count, inviter_ids} = Repo.delete_all(select(query, [i], i.inviter_id))
    Social.broadcast_account_invitations_updated(account_id)
    inviter_ids |> Enum.uniq() |> Enum.each(&Social.broadcast_invitations_updated/1)
    :ok
  end

  @doc "The push an account gets for a new invitation."
  def notify(%Account{} = account, %Profile{} = inviter, group) do
    Social.notify_account(
      account,
      Notifications.group_invitation(inviter, group),
      "group invitation"
    )
  end
end
