defmodule PotokIde.Social.AppScope do
  @moduledoc """
  Where an app keeps what it has: everything is filed under its group and the
  description it runs in (`alt_description_id`, nil for the default one).

  - its data values (`values` with `is_data`), the config among them;
  - its processes, drawn ones too (`app_processes`);
  - its personal memory (`app_profile_entries`);
  - the files sent with its values, which live in the app's file groups and
    name their app in their data (`%{"app" => group_id, "alt" => alt_id}`,
    `PotokIde.Social.AppFiles`).

  An app that moves to another description takes all of it along, so the app
  left in its place starts empty and the moved one keeps working. Both run
  inside the caller's transaction, which holds the group.
  """

  import Ecto.Query, warn: false

  alias PotokIde.History
  alias PotokIde.Social.{AppProcess, AppProfileEntry, GroupAltDescription, Value}

  @doc """
  Moves what the app of description `from` keeps to description `to` (alt
  ids, nil for the default). Nothing may be filed under `to` yet, as the
  unique keys of processes and personal memory would clash.
  """
  def move(repo, group_id, from, to) when is_integer(group_id) do
    :ok = refile(repo, group_id, from, to)
    told(group_id, from, to)
  end

  # The history says the app moved, once; what it kept changes hands unsaid.
  defp told(group_id, from, to) do
    History.record!(group_id, "app", to || from, :changed,
      fields: ["moved"],
      before: %{"from" => from, "to" => to},
      alt_description_id: to
    )
  end

  defp refile(repo, group_id, from, to) do
    repo.update_all(scoped(Value, group_id, from) |> where([v], v.is_data == true),
      set: [alt_description_id: to]
    )

    repo.update_all(scoped(AppProcess, group_id, from), set: [alt_description_id: to])
    repo.update_all(scoped(AppProfileEntry, group_id, from), set: [alt_description_id: to])

    repo.update_all(
      from(v in Value,
        where:
          v.collection == "files" and
            fragment("? @> ?", v.data, type(^%{"app" => group_id, "alt" => from}, :map)),
        update: [
          set: [
            data:
              fragment(
                "jsonb_set(?, '{alt}', COALESCE(to_jsonb(?::bigint), 'null'::jsonb))",
                v.data,
                ^to
              )
          ]
        ]
      ),
      []
    )

    History.move_app(repo, group_id, from, to)
  end

  @doc """
  Swaps what the apps of descriptions `a` and `b` keep. The unique keys are
  checked row by row, so the swap goes through a description made for the
  moment and dropped again.
  """
  def swap(repo, group_id, a, b) when is_integer(group_id) do
    parking =
      repo.insert!(%GroupAltDescription{
        group_id: group_id,
        name: "⁠swap-#{System.unique_integer([:positive])}",
        position: -1
      })

    :ok = refile(repo, group_id, a, parking.id)
    :ok = refile(repo, group_id, b, a)
    :ok = refile(repo, group_id, parking.id, b)
    repo.delete!(parking)
    told(group_id, b, a)
  end

  defp scoped(schema, group_id, nil),
    do: from(r in schema, where: r.group_id == ^group_id and is_nil(r.alt_description_id))

  defp scoped(schema, group_id, alt_id),
    do: from(r in schema, where: r.group_id == ^group_id and r.alt_description_id == ^alt_id)
end
