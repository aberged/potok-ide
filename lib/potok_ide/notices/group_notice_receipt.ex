defmodule PotokIde.Notices.GroupNoticeReceipt do
  @moduledoc """
  A notice that reached one profile: its place in that profile's notices and
  whether it was read. Written for every follower who sees the group when the
  notice is sent, except its author, so it stays after unfollowing. It has no
  time of its own: the notice's is when it arrived.
  """

  use Ecto.Schema

  @primary_key false
  schema "group_notice_receipts" do
    field :read_at, :utc_datetime

    belongs_to :profile, PotokIde.Social.Profile, primary_key: true
    belongs_to :notice, PotokIde.Notices.GroupNotice, primary_key: true
  end
end
