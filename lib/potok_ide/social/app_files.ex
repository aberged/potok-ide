defmodule PotokIde.Social.AppFiles do
  @moduledoc """
  Files sent with an app's values (a form's file questions) and the app's own
  pictures. They live in two sub-groups of the app's group, made the first time
  the app needs one:

  - **private** ("Privatni fajlovi"): closed and inheriting no members. Only its
    members open its files: at first the editor who made it, then whoever is
    invited, as into any group.
  - **public** ("Fajlovi"): inherits the members of the app's group, so all of
    them open its files. An app's pictures go there, with a signed address
    anyone who sees the app can open (`PostTemplates.Picture`).

  Their ids are in the app's config under `files`, written by Potok alone. Both
  take `post_values`, `attach_files` and the like from `everyone`, as they only
  keep files.

  A file is a data value of the collection `files` in one of them, with its
  attachment, written in the sender's name; the sender need not be a member, as
  the rules of the app's collection let them write. So it shows on that
  group's Files tab and in no chat. Its data says which app, slot and value it
  belongs to: `response` is nil until a saved value names the file, which then
  belongs to that value alone and goes with it. Files nobody claimed within a
  day are swept (`sweep/1`), as are those whose value is gone.

  The sender always opens their own file (`Social.get_attachment_for_download/2`).
  """

  import Ecto.Query, warn: false

  use Gettext, backend: PotokIdeWeb.Gettext

  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.{Access, AppData, Group, Profile, Value, ValueAttachment, ValueRules}
  alias PotokIde.Storage

  @files "files"
  @image_slot "_image"
  @image_types ~w(image/png image/jpeg image/gif image/webp image/avif)
  @max_image_bytes 10 * 1024 * 1024
  @max_app_bytes 1024 * 1024 * 1024
  @outsider_uploads_per_hour 20
  @unclaimed_for_seconds 24 * 60 * 60

  # A file group only keeps files.
  @taken ~w(post_values attach_files open_threads create_subgroups create_polls create_events)a

  @doc "The sub-groups of the app's config: `%{\"public\" => id, \"private\" => id}`, either may be missing."
  def groups(%Value{data: %{"files" => files}}) when is_map(files), do: files
  def groups(_config), do: %{}

  @doc """
  Makes the app's file groups that are missing, as an editor who may make
  sub-groups, and records them in the config, which must exist. Returns
  `{:ok, files}`.
  """
  def ensure_groups(%Profile{} = profile, %Group{} = group, alt) do
    group = Repo.get!(Group, group.id)
    access = Access.for_profile(profile, group)
    config = AppData.get_config(group, alt)

    cond do
      not ValueRules.manage?(access) or not Access.can?(access, :create_subgroups) ->
        {:error, :not_permitted}

      is_nil(config) ->
        {:error, :no_config}

      true ->
        files = groups(config)

        missing =
          Enum.reject(["public", "private"], &match?({:ok, _}, file_group(files, group, &1)))

        if missing == [] do
          {:ok, files}
        else
          Social.create_groups_quietly(
            profile,
            group,
            Enum.map(missing, &group_attrs(&1, group)),
            @taken,
            fn made ->
              current = AppData.get_config(group, alt) || Repo.rollback(:no_config)

              files =
                missing
                |> Enum.zip(made)
                |> Enum.reduce(groups(current), fn {target, made}, acc ->
                  Map.put(acc, target, made.id)
                end)

              AppData.put_files(current, files)
              files
            end
          )
        end
    end
  end

  defp group_attrs("public", %Group{} = parent) do
    %{
      "name" => gettext("Files"),
      "description" =>
        gettext("Files sent with %{name}. Every member of that group opens them.",
          name: parent.name
        ),
      "description_format" => :markdown,
      "is_public" => false,
      "inherits_members" => not parent.is_root
    }
  end

  defp group_attrs("private", %Group{} = parent) do
    %{
      "name" => gettext("Private files"),
      "description" =>
        gettext("Files sent with %{name}. Only members of this group open them.",
          name: parent.name
        ),
      "description_format" => :markdown,
      "is_public" => false,
      "inherits_members" => false
    }
  end

  @doc """
  The file group of `target` ("public" or "private") as it stands now: one
  that left the app's group is missing, and a private one that is no longer
  closed is exposed, so nothing more goes into it.
  """
  def file_group(files, %Group{id: app_group_id}, target) do
    case Map.get(files, target) do
      id when is_integer(id) ->
        case Repo.get(Group, id) do
          %Group{parent_id: ^app_group_id, uses_api: false} = file_group ->
            if target == "private" and not Group.closed?(file_group),
              do: {:error, :files_exposed},
              else: {:ok, file_group}

          _gone ->
            {:error, :files_missing}
        end

      _none ->
        {:error, :files_missing}
    end
  end

  @doc """
  Whether `profile` may send a file of `size` bytes and `type` for `slot` of
  `collection`, and where it goes. Returns `{:ok, upload}` to keep until the
  file has arrived (`store/3`).
  """
  def prepare(%Profile{} = profile, %Group{} = group, alt, collection, slot, file) do
    now = DateTime.utc_now(:second)
    config = AppData.get_config(group, alt)
    group = Repo.get!(Group, group.id)
    access = Access.for_profile(profile, group)
    rule = AppData.rule(config, collection)
    spec = Map.get(rule.uploads, slot)

    with :ok <- writable(rule, group, access, profile, now),
         %{} <- spec || {:error, :invalid_files},
         :ok <- fits_spec(spec, file),
         :ok <- room_for(group, alt, file.size),
         :ok <- outsider_room(profile, group, access),
         {:ok, file_group} <- file_group(groups(config), group, spec["target"]) do
      {:ok,
       %{
         app_group_id: group.id,
         alt_id: AppData.alt_id(alt),
         file_group_id: file_group.id,
         collection: collection,
         slot: slot,
         name: file.name,
         size: file.size,
         type: file.type,
         max_bytes: spec["max_bytes"]
       }}
    end
  end

  @doc "As `prepare/6`, for a picture of the app itself: editors only, into the public group."
  def prepare_image(%Profile{} = profile, %Group{} = group, alt, file) do
    config = AppData.get_config(group, alt)
    group = Repo.get!(Group, group.id)
    access = Access.for_profile(profile, group)

    cond do
      not ValueRules.manage?(access) ->
        {:error, :not_permitted}

      file.type not in @image_types or file.size > @max_image_bytes or file.size <= 0 ->
        {:error, :invalid_files}

      true ->
        with :ok <- room_for(group, alt, file.size),
             {:ok, file_group} <- file_group(groups(config), group, "public") do
          {:ok,
           %{
             app_group_id: group.id,
             alt_id: AppData.alt_id(alt),
             file_group_id: file_group.id,
             collection: nil,
             slot: @image_slot,
             name: file.name,
             size: file.size,
             type: file.type,
             max_bytes: @max_image_bytes
           }}
        end
    end
  end

  defp writable(rule, group, access, profile, now) do
    case ValueRules.write_block(rule, group, access, profile, now) do
      nil -> :ok
      block -> {:error, block}
    end
  end

  defp fits_spec(spec, file) do
    if file.size > 0 and file.size <= spec["max_bytes"] and
         ValueRules.accepts_type?(spec["types"], file.type),
       do: :ok,
       else: {:error, :invalid_files}
  end

  # All the files of one app together, as a form takes a gigabyte by default.
  defp room_for(group, alt, size) do
    used =
      from(a in ValueAttachment,
        join: v in Value,
        on: v.id == a.value_id,
        where:
          v.collection == @files and
            fragment("? @> ?", v.data, type(^app_tag(group, alt), :map)),
        select: type(coalesce(sum(a.byte_size), 0), :integer)
      )
      |> Repo.one()

    if used + size <= @max_app_bytes, do: :ok, else: {:error, :too_large}
  end

  defp outsider_room(_profile, _group, %Access{member?: true}), do: :ok

  defp outsider_room(%Profile{id: profile_id}, %Group{} = group, _access) do
    since = DateTime.add(DateTime.utc_now(), -3600, :second)

    sent =
      from(v in Value,
        where:
          v.collection == @files and v.creator_id == ^profile_id and v.inserted_at >= ^since and
            fragment("? @> ?", v.data, type(^%{"app" => group.id}, :map)),
        select: count()
      )
      |> Repo.one()

    if sent < @outsider_uploads_per_hour, do: :ok, else: {:error, :rate_limited}
  end

  defp app_tag(%Group{id: group_id}, alt), do: %{"app" => group_id, "alt" => AppData.alt_id(alt)}

  @doc """
  Records a file that arrived for `upload` (`prepare/6`): a data value in the
  file group with its attachment. `attrs` are the attachment's
  (`storage_key`, `filename`, `content_type`, `byte_size`).
  """
  def store(%Profile{} = profile, upload, attrs) do
    Repo.transaction(fn ->
      value =
        Repo.insert!(%Value{
          group_id: upload.file_group_id,
          creator_id: profile.id,
          is_data: true,
          collection: @files,
          content: "data:",
          content_format: :markdown,
          data: %{
            "app" => upload.app_group_id,
            "alt" => upload.alt_id,
            "collection" => upload.collection,
            "slot" => upload.slot,
            "response" => nil,
            "kept" => upload.slot == @image_slot
          }
        })

      %ValueAttachment{
        value_id: value.id,
        group_id: upload.file_group_id,
        profile_id: profile.id,
        storage_key: attrs.storage_key
      }
      |> ValueAttachment.changeset(Map.take(attrs, [:filename, :content_type, :byte_size]))
      |> Repo.insert()
      |> case do
        {:ok, attachment} -> attachment
        {:error, _changeset} -> Repo.rollback(:invalid_files)
      end
    end)
  end

  @doc """
  The files a value names under each slot of its rule: each must have been sent
  by `profile` for that slot of this app, and belong to no other value
  (`value_id` is the value being changed, nil for a new one). Returns the ids
  of their data values; anything else rolls the transaction back.
  """
  def check_refs(rule, config, group, alt, data, profile, value_id)

  def check_refs(%{uploads: uploads, under: under}, config, group, alt, data, profile, value_id)
      when map_size(uploads) > 0 and is_list(under) do
    answers = get_in(data, under)
    answers = if is_map(answers), do: answers, else: %{}

    named =
      Enum.flat_map(uploads, fn {slot, %{"max_files" => max_files}} ->
        case Map.get(answers, slot) do
          nil ->
            []

          refs when is_list(refs) and length(refs) <= max_files ->
            Enum.map(refs, &{slot, file_id(&1)})

          _invalid ->
            Repo.rollback(:invalid_files)
        end
      end)

    if Enum.any?(named, fn {_slot, id} -> is_nil(id) end), do: Repo.rollback(:invalid_files)

    ids = Enum.map(named, &elem(&1, 1))
    file_group_ids = config |> groups() |> Map.values() |> Enum.filter(&is_integer/1)

    found =
      from(a in ValueAttachment,
        join: v in Value,
        on: v.id == a.value_id,
        where:
          a.id in ^ids and a.profile_id == ^profile.id and v.collection == @files and
            v.group_id in ^file_group_ids,
        select: {a.id, v.id, v.data}
      )
      |> Repo.all()
      |> Map.new(fn {attachment_id, file_value_id, data} ->
        {attachment_id, {file_value_id, data}}
      end)

    Enum.map(named, fn {slot, id} ->
      case Map.get(found, id) do
        {file_value_id, %{"app" => app, "alt" => alt_ref, "slot" => ^slot} = file}
        when app == group.id ->
          if alt_ref == AppData.alt_id(alt) and file["response"] in [nil, value_id],
            do: file_value_id,
            else: Repo.rollback(:invalid_files)

        _not_theirs ->
          Repo.rollback(:invalid_files)
      end
    end)
    |> Enum.uniq()
  end

  def check_refs(_rule, _config, _group, _alt, _data, _profile, _value_id), do: []

  defp file_id(%{"file" => id}) when is_integer(id), do: id
  defp file_id(_ref), do: nil

  @doc "Gives the file values to `value`."
  def claim([], _value), do: :ok

  def claim(file_value_ids, %Value{id: value_id}) do
    from(v in Value,
      where: v.id in ^file_value_ids,
      update: [
        set: [
          data: fragment("jsonb_set(?, '{response}', to_jsonb(?::bigint))", v.data, ^value_id)
        ]
      ]
    )
    |> Repo.update_all([])

    :ok
  end

  @doc """
  As `claim/2` after a change: files the value no longer names are deleted.
  Returns the storage keys to delete once the transaction is through.
  """
  def reclaim(file_value_ids, %Value{id: value_id} = value) do
    claim(file_value_ids, value)

    from(v in Value,
      where:
        v.collection == @files and v.id not in ^file_value_ids and
          fragment("? @> ?", v.data, type(^%{"response" => value_id}, :map))
    )
    |> delete_files()
  end

  @doc """
  Deletes the files that belong to the values `ids` of the app whose config
  this is. Returns the storage keys to delete once the transaction is through.
  """
  def delete_for_values(_config, []), do: []

  def delete_for_values(config, ids) when is_list(ids) do
    case config |> groups() |> Map.values() |> Enum.filter(&is_integer/1) do
      [] ->
        []

      file_group_ids ->
        from(v in Value,
          where:
            v.group_id in ^file_group_ids and v.collection == @files and
              fragment(
                "(? ->> 'response')::bigint = ANY(?)",
                v.data,
                type(^ids, {:array, :integer})
              )
        )
        |> delete_files()
    end
  end

  @doc """
  Deletes files sent more than a day before `now` that no value claimed, and
  files whose value is gone. Returns how many.
  """
  def sweep(%DateTime{} = now \\ DateTime.utc_now()) do
    since = DateTime.add(now, -@unclaimed_for_seconds, :second)

    from(v in Value,
      where:
        v.collection == @files and
          ((v.inserted_at < ^since and
              fragment(
                "? ->> 'response' IS NULL AND COALESCE(? ->> 'kept', 'false') <> 'true'",
                v.data,
                v.data
              )) or
             fragment(
               "? ->> 'response' IS NOT NULL AND NOT EXISTS (SELECT 1 FROM \"values\" r WHERE r.id = (? ->> 'response')::bigint)",
               v.data,
               v.data
             ))
    )
    |> delete_files()
    |> tap(&Storage.delete_later/1)
    |> length()
  end

  # The rows go now and the keys come back, as the bytes may only go once the
  # transaction that deleted the rows is through.
  defp delete_files(query) do
    ids = query |> select([v], v.id) |> Repo.all()

    if ids == [] do
      []
    else
      keys =
        from(a in ValueAttachment, where: a.value_id in ^ids, select: a.storage_key)
        |> Repo.all()

      Repo.delete_all(from(v in Value, where: v.id in ^ids))
      keys
    end
  end
end
