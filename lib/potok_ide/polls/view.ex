defmodule PotokIde.Polls.View do
  @moduledoc """
  A poll as one viewer may see it, made by `PotokIde.Polls.Rules.view/7`.

  Everything that shows a poll draws from this and never from the poll itself,
  as this holds only what the viewer may see: what is hidden is nil here, so
  nothing can slip out through a card. `scope` is `:teaser` for someone outside
  a poll that is for members, who gets the question and no more.
  """

  defstruct [
    :poll_id,
    :group_id,
    :value_id,
    :question,
    :description,
    :kind,
    :max_choices,
    :closes_at,
    :closed_at,
    :scope,
    :open?,
    :secret?,
    :public?,
    :allow_change?,
    :vote_block,
    :can_vote?,
    :voted?,
    :voted_with_other_profile?,
    :one_tap?,
    :results?,
    :details?,
    :manage?,
    :can_add_option?,
    :voters_count,
    :outcome,
    :winner_option_id,
    :eligible_count,
    :quorum_percent,
    :majority,
    :form_key,
    options: [],
    removable_option_ids: [],
    my_option_ids: [],
    voter_roles: [],
    detail_roles: []
  ]
end
