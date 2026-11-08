defmodule PotokIde.Social.ValueRules do
  @moduledoc """
  The rules an app sets on the collections of its data values, and what they
  let a viewer do. The app's editors write them into the app's config (the
  collection `config`, see `PotokIde.Social.AppData`) under `rules`, one rule
  per collection. Potok normalizes them on the way in and holds to them on every
  call, whatever the app asks for.

  | Who | Writes | Reads |
  |---|---|---|
  | A member with a role on `write` | while the collection is open | their own values |
  | A member with a role on `read` | as their roles allow | every value |
  | An editor of the app (`edit_group`) | as their roles allow | every value |
  | A signed-in non-member of a public group | when the rule is `public`, unless blocked | their own values |
  | A role on `summary` | | only counts (`summarize`) |

  A collection without a rule is closed: members write, and only the author
  and the editors read. Editors always read, as they could change the rules,
  just as the organizer of a poll and those who manage polls always see it.

  A value written while its collection is `anonymous` carries that for good
  (`Value.anonymous`): its author shows to nobody but the author, whatever the
  rule says later.

  Plain functions over what the caller has read, like `PotokIde.Polls.Rules`.
  """

  alias PotokIde.Social.{Access, Group, GroupRole, Profile}
  alias PotokIde.Storage

  # Collections Potok keeps itself: the app's config, the notification
  # subscriptions of its readers and the files sent with its values.
  @reserved ~w(config notify files)
  @collection_format ~r/\A[a-z][a-z0-9_-]{0,39}\z/
  @key_format ~r/\A[A-Za-z0-9_-]{1,40}\z/
  @uuid_format ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  @max_collections 20
  @max_role_keys 50
  @max_upload_slots 30
  @max_files_per_slot 10
  @max_path_depth 3
  @default_max_upload_bytes 10 * 1024 * 1024

  # What a slot for files may take. A browser reports the type, so this keeps
  # out mistakes, not attacks: downloads are what keep a file from running.
  @upload_types %{
    "document" => ~w(application/pdf application/msword application/rtf text/plain
                     application/vnd.openxmlformats-officedocument.wordprocessingml.document
                     application/vnd.oasis.opendocument.text),
    "presentation" => ~w(application/vnd.ms-powerpoint
                         application/vnd.openxmlformats-officedocument.presentationml.presentation
                         application/vnd.oasis.opendocument.presentation),
    "spreadsheet" => ~w(application/vnd.ms-excel text/csv
                        application/vnd.openxmlformats-officedocument.spreadsheetml.sheet
                        application/vnd.oasis.opendocument.spreadsheet),
    "drawing" => ~w(image/svg+xml application/vnd.oasis.opendocument.graphics),
    "pdf" => ~w(application/pdf),
    "image" => ~w(image/png image/jpeg image/gif image/webp image/avif image/heic image/heif),
    "video" => ~w(video/mp4 video/webm video/ogg video/quicktime),
    "audio" =>
      ~w(audio/mpeg audio/mp3 audio/mp4 audio/x-m4a audio/aac audio/ogg audio/opus audio/wav
         audio/x-wav audio/wave audio/webm audio/flac audio/x-flac)
  }

  @closed_default %{
    ruled?: false,
    write: ["everyone"],
    read: [],
    summary: [],
    once: false,
    edit_own: false,
    anonymous: false,
    public: false,
    open: true,
    closes_at: nil,
    under: nil,
    uploads: %{},
    score: nil
  }

  @doc "The collections Potok keeps itself."
  def reserved, do: @reserved

  @doc "Whether an app may name a collection of its own so."
  def app_collection?(name) when is_binary(name),
    do: name not in @reserved and Regex.match?(@collection_format, name)

  def app_collection?(_name), do: false

  @doc "The categories a slot for files can take, as the app offers them."
  def upload_types, do: Map.keys(@upload_types)

  @doc """
  The rules as Potok keeps them: known keys only, role keys checked, defaults
  filled in, `public` writing for everyone. `{:error, reason}` for rules that
  cannot hold, such as an anonymous collection that takes files, whose senders
  stay on the files.
  """
  def normalize(nil), do: {:ok, %{}}

  def normalize(rules) when is_map(rules) and map_size(rules) <= @max_collections do
    Enum.reduce_while(rules, {:ok, %{}}, fn {collection, rule}, {:ok, acc} ->
      with true <- app_collection?(collection) || {:error, :invalid_collection},
           {:ok, normalized} <- normalize_rule(rule) do
        {:cont, {:ok, Map.put(acc, collection, normalized)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def normalize(_rules), do: {:error, :invalid_rules}

  defp normalize_rule(rule) when is_map(rule) do
    with {:ok, write} <- role_keys(rule, "write", ["everyone"]),
         {:ok, read} <- role_keys(rule, "read", []),
         {:ok, summary} <- role_keys(rule, "summary", []),
         {:ok, once} <- boolean(rule, "once", false),
         {:ok, edit_own} <- boolean(rule, "edit_own", false),
         {:ok, anonymous} <- boolean(rule, "anonymous", false),
         {:ok, public} <- boolean(rule, "public", false),
         {:ok, open} <- boolean(rule, "open", true),
         {:ok, closes_at} <- moment(rule["closes_at"]),
         {:ok, under} <- path(rule["under"]),
         {:ok, uploads} <- uploads(rule["uploads"]),
         {:ok, score} <- score(rule["score"]),
         :ok <- consistent(anonymous, uploads, score, edit_own, under) do
      {:ok,
       %{
         "write" => if(public, do: ["everyone"], else: write),
         "read" => read,
         "summary" => summary,
         "once" => once,
         "edit_own" => edit_own,
         "anonymous" => anonymous,
         "public" => public,
         "open" => open,
         "closes_at" => closes_at,
         "under" => under,
         "uploads" => uploads,
         "score" => score
       }}
    end
  end

  defp normalize_rule(_rule), do: {:error, :invalid_rules}

  defp consistent(true, uploads, _score, _edit_own, _under) when map_size(uploads) > 0,
    do: {:error, :anonymous_uploads}

  defp consistent(_anonymous, _uploads, %{"release" => "immediate"}, true, _under),
    do: {:error, :immediate_release_edit}

  defp consistent(_anonymous, uploads, score, _edit_own, nil)
       when map_size(uploads) > 0 or not is_nil(score),
       do: {:error, :under_required}

  defp consistent(_anonymous, _uploads, _score, _edit_own, _under), do: :ok

  # Built-in roles and custom ones (UUIDs); anything else is dropped, as a poll
  # does. A role deleted later is held by nobody.
  defp role_keys(rule, field, default) do
    case Map.get(rule, field, default) do
      keys when is_list(keys) ->
        keys =
          keys
          |> Enum.filter(&is_binary/1)
          |> Enum.map(&String.trim/1)
          |> Enum.filter(&role_key?/1)
          |> Enum.uniq()
          |> Enum.take(@max_role_keys)

        {:ok, keys}

      nil ->
        {:ok, default}

      _other ->
        {:error, :invalid_rules}
    end
  end

  defp role_key?(key),
    do:
      key in [GroupRole.admin_key(), GroupRole.everyone_key()] or
        Regex.match?(@uuid_format, key)

  defp boolean(rule, field, default) do
    case Map.get(rule, field, default) do
      value when is_boolean(value) -> {:ok, value}
      nil -> {:ok, default}
      _other -> {:error, :invalid_rules}
    end
  end

  defp moment(nil), do: {:ok, nil}

  defp moment(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, moment, _offset} ->
        {:ok, moment |> DateTime.truncate(:second) |> DateTime.to_iso8601()}

      {:error, _reason} ->
        {:error, :invalid_rules}
    end
  end

  defp moment(_value), do: {:error, :invalid_rules}

  defp path(nil), do: {:ok, nil}

  defp path(segments)
       when is_list(segments) and segments != [] and length(segments) <= @max_path_depth do
    if Enum.all?(segments, &key?/1), do: {:ok, segments}, else: {:error, :invalid_rules}
  end

  defp path(_segments), do: {:error, :invalid_rules}

  defp key?(value), do: is_binary(value) and Regex.match?(@key_format, value)

  defp uploads(nil), do: {:ok, %{}}

  defp uploads(slots) when is_map(slots) and map_size(slots) <= @max_upload_slots do
    Enum.reduce_while(slots, {:ok, %{}}, fn {slot, spec}, {:ok, acc} ->
      case upload_slot(slot, spec) do
        {:ok, normalized} -> {:cont, {:ok, Map.put(acc, slot, normalized)}}
        error -> {:halt, error}
      end
    end)
  end

  defp uploads(_slots), do: {:error, :invalid_rules}

  defp upload_slot(slot, %{"target" => target} = spec)
       when target in ["private", "public"] do
    max_bytes = Map.get(spec, "max_bytes", @default_max_upload_bytes)
    max_files = Map.get(spec, "max_files", 1)
    types = Map.get(spec, "types", [])

    cond do
      not key?(slot) ->
        {:error, :invalid_rules}

      not (is_integer(max_files) and max_files in 1..@max_files_per_slot) ->
        {:error, :invalid_rules}

      not (is_integer(max_bytes) and max_bytes > 0) ->
        {:error, :invalid_rules}

      not (is_list(types) and Enum.all?(types, &Map.has_key?(@upload_types, &1))) ->
        {:error, :invalid_rules}

      true ->
        {:ok,
         %{
           "target" => target,
           "max_files" => max_files,
           "max_bytes" => min(max_bytes, Storage.max_file_size()),
           "types" => Enum.uniq(types)
         }}
    end
  end

  defp upload_slot(_slot, _spec), do: {:error, :invalid_rules}

  defp score(nil), do: {:ok, nil}

  defp score(score) when is_map(score) do
    show = Map.get(score, "show") || %{}

    with release when release in ["immediate", "manual"] <-
           Map.get(score, "release", "immediate"),
         {:ok, released} <- boolean(score, "released", false),
         true <- is_map(show),
         {:ok, missed} <- boolean(show, "missed", true),
         {:ok, correct} <- boolean(show, "correct", true),
         {:ok, points} <- boolean(show, "points", true) do
      {:ok,
       %{
         "release" => release,
         "released" => released,
         "show" => %{"missed" => missed, "correct" => correct, "points" => points}
       }}
    else
      _invalid -> {:error, :invalid_rules}
    end
  end

  defp score(_score), do: {:error, :invalid_rules}

  @doc """
  The rule of `collection` among normalized `rules`, as a map with atom keys
  and `closes_at` as a `DateTime`. A collection without one gets the closed
  default (`ruled?: false`).
  """
  def rule(rules, collection) when is_map(rules) do
    case Map.get(rules, collection) do
      %{} = rule ->
        %{
          ruled?: true,
          write: rule["write"] || [],
          read: rule["read"] || [],
          summary: rule["summary"] || [],
          once: rule["once"] == true,
          edit_own: rule["edit_own"] == true,
          anonymous: rule["anonymous"] == true,
          public: rule["public"] == true,
          open: rule["open"] != false,
          closes_at: parse_moment(rule["closes_at"]),
          under: rule["under"],
          uploads: rule["uploads"] || %{},
          score: rule["score"]
        }

      _none ->
        @closed_default
    end
  end

  def rule(_rules, _collection), do: @closed_default

  defp parse_moment(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, moment, _offset} -> moment
      _error -> nil
    end
  end

  defp parse_moment(_value), do: nil

  @doc "Whether the collection takes values at `now`."
  def open?(%{open: open, closes_at: closes_at}, %DateTime{} = now),
    do: open and (is_nil(closes_at) or DateTime.compare(now, closes_at) == :lt)

  @doc "Whether the collection takes non-members now: a group that stopped being public closes it to them."
  def public?(%{public: true}, %Group{} = group), do: Group.guest_preview?(group)
  def public?(_rule, %Group{}), do: false

  @doc "Whether the holder of `access` edits the app, and with that its config and rules."
  def manage?(%Access{} = access), do: access.member? and Access.can?(access, :edit_group)

  @doc """
  Why `profile` cannot write to the collection at `now`, or nil when it can.
  `:closed`, `:role`, `:blocked`, `:members_only`, or `:not_permitted` for a
  guest.
  """
  def write_block(rule, %Group{} = group, %Access{} = access, profile, %DateTime{} = now) do
    cond do
      not match?(%Profile{}, profile) -> :not_permitted
      not open?(rule, now) -> :closed
      access.member? -> if on_list?(rule.write, access), do: nil, else: :role
      access.blocked? -> :blocked
      not public?(rule, group) -> :members_only
      true -> nil
    end
  end

  @doc "Whether the holder of `access` reads every value of the collection, not just their own."
  def full_reader?(rule, %Access{} = access),
    do: manage?(access) or (access.member? and on_list?(rule.read, access))

  @doc """
  Whether the holder of `access` sees the collection's counts. Past the members
  that takes a public collection with "everyone" on `summary`.
  """
  def summary_reader?(rule, %Group{} = group, %Access{} = access) do
    cond do
      full_reader?(rule, access) -> true
      access.member? -> on_list?(rule.summary, access)
      access.blocked? -> false
      true -> public?(rule, group) and GroupRole.everyone_key() in rule.summary
    end
  end

  @doc "Whether the collection's scores have been released to their authors."
  def released?(%{score: %{"release" => "immediate"}}), do: true
  def released?(%{score: %{"released" => true}}), do: true
  def released?(_rule), do: false

  @doc """
  Why `profile` cannot change its own value `creator_id` in the collection at
  `now`, or nil when it can.
  """
  def edit_block(rule, creator_id, %Group{} = group, %Access{} = access, profile, now) do
    cond do
      not match?(%Profile{}, profile) or creator_id != profile.id -> :not_permitted
      not rule.edit_own -> :not_permitted
      not open?(rule, now) -> :closed
      released?(rule) -> :released
      access.member? -> nil
      access.blocked? or not public?(rule, group) -> :not_permitted
      true -> nil
    end
  end

  defp on_list?(keys, %Access{role_keys: role_keys}), do: Enum.any?(keys, &(&1 in role_keys))

  @doc """
  A value as the viewer may see it. `row` is a map or a `Value` with
  `creator_id`, `creator_username`, `anonymous` and `managed`. Someone else's
  anonymous value loses its author. `managed` goes in full to full readers, and
  to the author once released, as far as `score.show` allows, with the answers
  from the current `key`.
  """
  def present(row, rule, viewer_id, %Access{} = access, key \\ %{}) do
    own? = not is_nil(viewer_id) and row.creator_id == viewer_id

    row
    |> hide_author(own?)
    |> Map.put(:managed, managed_for(row.managed, rule, own?, access, key))
  end

  defp hide_author(%{anonymous: true} = row, false = _own?),
    do: %{row | creator_id: nil} |> Map.put(:creator_username, nil)

  defp hide_author(row, _own?), do: row

  defp managed_for(nil, _rule, _own?, _access, _key), do: nil

  defp managed_for(managed, rule, own?, access, key) do
    cond do
      full_reader?(rule, access) -> managed
      own? and is_map(rule.score) and released?(rule) -> author_view(managed, rule.score, key)
      true -> nil
    end
  end

  # What an author sees of their graded value: whether each answer was right,
  # the points, and the right answers, as the editors chose.
  defp author_view(managed, %{"show" => show}, key) do
    key = if is_map(key), do: key, else: %{}

    items =
      Map.new(managed["items"] || %{}, fn {question, item} ->
        {question, author_item(item, Map.get(key, question), show)}
      end)

    if show["points"] do
      %{
        "score" => managed["score"],
        "max" => managed["max"],
        "pending" => managed["pending"],
        "items" => items
      }
    else
      %{"items" => items}
    end
  end

  defp author_item(item, check, show) do
    feedback = feedback(item, check)

    %{}
    |> put_if(show["missed"], "ok", item["ok"])
    |> put_if(show["points"], "points", item["points"])
    |> put_if(show["correct"] and is_map(check), "expected", expected(check))
    |> put_if(feedback != nil, "feedback", feedback)
  end

  defp put_if(map, true, key, value), do: Map.put(map, key, value)
  defp put_if(map, _condition, _key, _value), do: map

  defp expected(check) do
    Map.take(check, ~w(eq set text rows row_sets))
  end

  # The editor's own words win over the prepared ones.
  defp feedback(%{"feedback" => feedback}, _check) when is_binary(feedback) and feedback != "",
    do: feedback

  defp feedback(%{"ok" => true}, %{"ok" => text}) when is_binary(text) and text != "", do: text
  defp feedback(%{"ok" => false}, %{"bad" => text}) when is_binary(text) and text != "", do: text
  defp feedback(_item, _check), do: nil

  @doc """
  What the viewer may do in the collection, for the app to choose its screens.
  `written?` says whether this person already has a value there.
  """
  def caps(rule, %Group{} = group, %Access{} = access, profile, %DateTime{} = now, opts \\ []) do
    write_block = write_block(rule, group, access, profile, now)

    %{
      ruled: rule.ruled?,
      write: is_nil(write_block),
      write_block: write_block && Atom.to_string(write_block),
      read: if(full_reader?(rule, access), do: "all", else: "own"),
      summary: summary_reader?(rule, group, access),
      edit_own: rule.edit_own and open?(rule, now) and not released?(rule),
      manage: manage?(access),
      open: open?(rule, now),
      once: rule.once,
      anonymous: rule.anonymous,
      public: public?(rule, group),
      released: released?(rule),
      written: Keyword.get(opts, :written?, false),
      notify: Keyword.get(opts, :notify?, false)
    }
  end

  @doc "Whether `content_type` fits a slot that takes `types` (any when empty)."
  def accepts_type?([], _content_type), do: true

  def accepts_type?(types, content_type) when is_list(types) and is_binary(content_type) do
    Enum.any?(types, fn type -> content_type in Map.get(@upload_types, type, []) end)
  end

  def accepts_type?(_types, _content_type), do: false
end
