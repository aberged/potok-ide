defmodule PotokIde.Social.AppProfileStore do
  @moduledoc """
  An app's personal memory: keys an app, or a site in its frame, keeps for
  one profile alone (`listPersonal`, `getPersonal`, `setPersonal`,
  `deletePersonal` in the SDK), the same on every device the person uses.

  It is private: only that profile reads and writes it, never the app's
  editors, its collections (`PotokIde.Social.AppData`) or its processes. The
  person sees what each app keeps in the account settings and can delete it.
  Deleting the group or the alternative description deletes it too, and so
  does deleting the account (`PotokIde.Accounts.Deletion`).

  A guest has no profile, so a guest's frame keeps the same calls in the
  browser (`GroupAppFrame` in app.js), under the same limits.
  """

  import Ecto.Query

  alias PotokIde.Repo
  alias PotokIde.Social.{AppProfileEntry, Group, Profile}

  @max_keys 100
  @max_value_bytes 16_384
  @key_format ~r/\A[A-Za-z0-9_.:-]{1,64}\z/

  def max_keys, do: @max_keys
  def max_value_bytes, do: @max_value_bytes

  @doc "Whether `key` may name a key: 1 to 64 letters, digits and `_ . : -`."
  def key?(key), do: is_binary(key) and Regex.match?(@key_format, key)

  @doc "Every key of the app the profile keeps, as `[%{key, value, updated_at}]`, by key."
  def list(%Profile{id: profile_id}, %Group{id: group_id}, alt) do
    from(e in AppProfileEntry, order_by: e.key)
    |> where_app(profile_id, group_id, alt)
    |> select([e], %{key: e.key, value: e.value, updated_at: e.updated_at})
    |> Repo.all()
    |> Enum.map(&%{&1 | value: unwrap(&1.value)})
  end

  @doc "The value of `key`, or nil."
  def get(%Profile{id: profile_id}, %Group{id: group_id}, alt, key) do
    with true <- key?(key) || {:error, :invalid_key} do
      from(e in AppProfileEntry, where: e.key == ^key, select: e.value)
      |> where_app(profile_id, group_id, alt)
      |> Repo.one()
      |> unwrap()
      |> then(&{:ok, &1})
    end
  end

  @doc """
  Keeps `value` (anything JSON holds) under `key`. `{:error, :invalid_key}`,
  `{:error, :too_big}` past #{@max_value_bytes} bytes of JSON, or
  `{:error, :too_many_keys}` for a new key past #{@max_keys}.
  """
  def put(%Profile{id: profile_id}, %Group{id: group_id}, alt, key, value) do
    with true <- key?(key) || {:error, :invalid_key},
         {:ok, json} <- Jason.encode(value),
         true <- byte_size(json) <= @max_value_bytes || {:error, :too_big} do
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [group_id, profile_id])

        existing =
          from(e in AppProfileEntry, where: e.key == ^key)
          |> where_app(profile_id, group_id, alt)
          |> Repo.one()

        cond do
          existing ->
            existing |> Ecto.Changeset.change(value: %{"v" => value}) |> Repo.update!()

          count(profile_id, group_id, alt) >= @max_keys ->
            Repo.rollback(:too_many_keys)

          true ->
            Repo.insert!(%AppProfileEntry{
              group_id: group_id,
              alt_description_id: alt_id(alt),
              profile_id: profile_id,
              key: key,
              value: %{"v" => value}
            })
        end

        :ok
      end)
    else
      {:error, %Jason.EncodeError{}} -> {:error, :invalid_value}
      {:error, %Protocol.UndefinedError{}} -> {:error, :invalid_value}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Forgets `key`. Forgetting a key that is not there is fine."
  def delete(%Profile{id: profile_id}, %Group{id: group_id}, alt, key) do
    with true <- key?(key) || {:error, :invalid_key} do
      from(e in AppProfileEntry, where: e.key == ^key)
      |> where_app(profile_id, group_id, alt)
      |> Repo.delete_all()

      :ok
    end
  end

  @doc """
  What the profile keeps in each app, for the settings: `[%{group_id,
  group_name, alt_description_id, alt_name, keys, bytes, updated_at}]`, the
  newest first.
  """
  def summary(%Profile{id: profile_id}) do
    from(e in AppProfileEntry,
      join: g in Group,
      on: g.id == e.group_id,
      left_join: a in assoc(e, :alt_description),
      where: e.profile_id == ^profile_id,
      group_by: [e.group_id, g.name, e.alt_description_id, a.name],
      order_by: [desc: max(e.updated_at)],
      select: %{
        group_id: e.group_id,
        group_name: g.name,
        alt_description_id: e.alt_description_id,
        alt_name: a.name,
        keys: count(e.id),
        bytes: type(sum(fragment("octet_length(?::text)", e.value)), :integer),
        updated_at: max(e.updated_at)
      }
    )
    |> Repo.all()
  end

  @doc "Forgets everything the profile keeps in one app (`alt` nil: the default one)."
  def clear_app(%Profile{id: profile_id}, group_id, alt_id) when is_integer(group_id) do
    from(e in AppProfileEntry, where: e.profile_id == ^profile_id and e.group_id == ^group_id)
    |> where_alt(alt_id)
    |> Repo.delete_all()

    :ok
  end

  @doc "Forgets everything the profile keeps in every app."
  def clear_all(%Profile{id: profile_id}) do
    from(e in AppProfileEntry, where: e.profile_id == ^profile_id) |> Repo.delete_all()
    :ok
  end

  defp unwrap(%{"v" => value}), do: value
  defp unwrap(_), do: nil

  defp count(profile_id, group_id, alt) do
    from(e in AppProfileEntry, select: count())
    |> where_app(profile_id, group_id, alt)
    |> Repo.one()
  end

  defp where_app(query, profile_id, group_id, alt) do
    query
    |> where([e], e.profile_id == ^profile_id and e.group_id == ^group_id)
    |> where_alt(alt_id(alt))
  end

  defp where_alt(query, nil), do: where(query, [e], is_nil(e.alt_description_id))
  defp where_alt(query, id), do: where(query, [e], e.alt_description_id == ^id)

  defp alt_id(nil), do: nil
  defp alt_id(%{id: id}), do: id
  defp alt_id(id) when is_integer(id), do: id
end
