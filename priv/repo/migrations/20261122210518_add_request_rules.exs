defmodule PotokIde.Repo.Migrations.AddRequestRules do
  use Ecto.Migration

  # How a role is had and how a request to join is decided, written down
  # beforehand (`PotokIde.Social.GroupRequests`): by the statute for a role,
  # by the group for admission. A mode that votes keeps the vote's rules
  # (`PotokIde.Social.RequestPoll`). The checks that tie the two together
  # spell their modes out, as the domain map reads an `IN` list as an enum.
  def change do
    alter table(:group_roles) do
      add :request_mode, :string, null: false, default: "closed"
      add :request_poll, :map
    end

    create constraint(:group_roles, :group_roles_request_mode_check,
             check: "request_mode IN ('closed', 'approve', 'choose', 'vote')"
           )

    create constraint(:group_roles, :group_roles_request_poll_check,
             check:
               "(request_mode = 'choose' OR request_mode = 'vote') = (request_poll IS NOT NULL) AND (key <> 'everyone' OR request_mode = 'closed')"
           )

    alter table(:groups) do
      add :join_mode, :string, null: false, default: "approve"
      add :join_poll, :map
    end

    create constraint(:groups, :groups_join_mode_check,
             check: "join_mode IN ('approve', 'choose', 'vote')"
           )

    create constraint(:groups, :groups_join_poll_check,
             check: "(join_mode = 'choose' OR join_mode = 'vote') = (join_poll IS NOT NULL)"
           )
  end
end
