defmodule PotokIde.Repo.Migrations.AddPollPermissions do
  use Ecto.Migration

  # Every member may start polls and vote, so the "everyone" role of every
  # manifest gets `create_polls` and `vote_polls`. `manage_polls` and
  # `publish_polls` are given by admins, who hold every permission without it
  # being stored.
  #
  # A role saved by a group made from the announcements preset keeps the right
  # to vote there and loses the right to start polls, as the preset would have
  # it: such a role does not hold `post_values`, which a poll in the chat needs.
  def up do
    execute """
    UPDATE group_roles
    SET allowed = array_append(allowed, 'vote_polls')
    WHERE key = 'everyone' AND NOT ('vote_polls' = ANY(allowed))
    """

    execute """
    UPDATE group_roles
    SET allowed = array_append(allowed, 'create_polls')
    WHERE key = 'everyone' AND 'post_values' = ANY(allowed) AND NOT ('create_polls' = ANY(allowed))
    """
  end

  def down do
    for permission <- ~w(create_polls vote_polls manage_polls publish_polls) do
      execute """
      UPDATE group_roles
      SET allowed = array_remove(allowed, '#{permission}'),
          denied = array_remove(denied, '#{permission}')
      """
    end
  end
end
