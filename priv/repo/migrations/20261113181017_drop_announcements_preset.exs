defmodule PotokIde.Repo.Migrations.DropAnnouncementsPreset do
  use Ecto.Migration

  # Announcements are no longer a kind of group: a group sends notices to those
  # who follow it (`PotokIde.Notices`). The groups made from that preset open on
  # their messages, so they become chats, and keep their roles: there, only
  # administrators still write.
  def up do
    execute "UPDATE groups SET preset = 'chat' WHERE preset = 'announcements'"

    drop constraint(:groups, :groups_preset_check)

    create constraint(:groups, :groups_preset_check,
             check:
               "preset IN ('chat', 'folder', 'feed', 'polls', 'questionnaire', 'page', 'map')"
           )
  end

  # The kind comes back, though not to the groups that had it: they stay chats.
  def down do
    drop constraint(:groups, :groups_preset_check)

    create constraint(:groups, :groups_preset_check,
             check:
               "preset IN ('chat', 'folder', 'announcements', 'feed', 'polls', 'questionnaire', 'page', 'map')"
           )
  end
end
