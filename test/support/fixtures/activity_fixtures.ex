defmodule PotokIde.ActivityFixtures do
  @moduledoc """
  What a profile did, at the times a test of the timeline (`PotokIde.Activity`)
  needs, and the timeline as a test reads it.
  """

  alias PotokIde.Activity
  alias PotokIde.Repo
  alias PotokIde.Social.{Value, ValueAttachment, ValueReaction}

  # Long ago, so nothing a fixture does now comes in between.
  @start ~U[2026-03-02 10:00:00Z]

  @doc "The moment `minutes` after the tests' first one."
  def at(minutes), do: DateTime.add(@start, minutes, :minute)

  @doc "A chat message of `profile` in `group`, written at `at`."
  def message!(profile, group, at, attrs \\ %{}) do
    Repo.insert!(
      struct!(
        %Value{
          content: "message #{System.unique_integer([:positive])}",
          creator_id: profile.id,
          group_id: group.id,
          inserted_at: at,
          updated_at: at
        },
        attrs
      )
    )
  end

  @doc "A value of an app of `group`, by `profile`, written at `at`."
  def record!(profile, group, at, attrs \\ %{}) do
    message!(
      profile,
      group,
      at,
      Map.merge(%{content: "", is_data: true, data: %{"n" => 1}, collection: "molbe"}, attrs)
    )
  end

  @doc "A reaction of `profile` to `value`, put at `at`."
  def reaction!(profile, value, at, emoji \\ "👍") do
    Repo.insert!(%ValueReaction{
      profile_id: profile.id,
      value_id: value.id,
      emoji: emoji,
      inserted_at: at
    })
  end

  @doc "A file of `value`, put there by its author."
  def file!(value, filename \\ "zapisnik.pdf") do
    Repo.insert!(%ValueAttachment{
      value_id: value.id,
      group_id: value.group_id,
      profile_id: value.creator_id,
      storage_key: "test/#{System.unique_integer([:positive])}",
      filename: filename,
      content_type: "application/pdf",
      byte_size: 10,
      inserted_at: value.inserted_at
    })
  end

  @doc "The entries of `profile`'s timeline, as `account` reads them."
  def entries(profile, account, opts \\ []) do
    {:ok, %{entries: entries}} = Activity.page(profile, account, opts)
    entries
  end

  @doc "Their keys."
  def keys(profile, account, opts \\ []),
    do: profile |> entries(account, opts) |> Enum.map(& &1.key)

  @doc "The keys of the whole timeline, a page of `limit` at a time."
  def all_keys(profile, account, opts \\ [], cursor \\ nil) do
    {:ok, page} = Activity.page(profile, account, [{:cursor, cursor} | opts])
    keys = Enum.map(page.entries, & &1.key)
    if page.cursor, do: keys ++ all_keys(profile, account, opts, page.cursor), else: keys
  end
end
