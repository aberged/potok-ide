defmodule PotokIde.Social.AreaImport do
  @moduledoc """
  Brings the areas of a GeoJSON file in as groups, as the local communities of
  Serbia came in (2026-11-10). The features are grouped by one of their
  properties (`:parent`, a municipality), and each such value becomes a group
  under the root, with the union of its features' borders as its area. Under
  it, each feature becomes a group with its own border, named by another
  property (`:name`). Both are public pages that show pins of their own
  (`GroupPins`): `"municipality"` and `"local_community"`.

  A profile on an account makes them all, and is a member and admin of each:
  a profile of its own, so that some person's groups and unread counts do not
  carry thousands of them.

  Running it again is safe: a group of the same name under the same parent by
  the same profile is taken again, and a border is written only where there
  is none, so an import that stopped goes on where it was. `remove/1` takes it
  all away again.

  Run it with `mix potok.import_areas` locally, and on a release with `start/4`
  over `bin/potok_ide rpc`.
  """

  import Ecto.Query

  require Logger

  alias PotokIde.{Accounts, Repo, Social}
  alias PotokIde.Social.{AccountProfile, Group, GroupAreas, Profile}

  @parent_pin "municipality"
  @child_pin "local_community"
  @preset "page"

  # Parts of a union and holes in it smaller than this (in m²) are the gaps
  # between neighbours that do not quite meet, not land; so are holes
  # narrower than this on average (2 × area / perimeter, in m), which run
  # long and thin between two neighbours. A real hole, as the enclave of
  # Sastavci in Priboj, is far wider. In the communities of Serbia, 179 of
  # the 189 holes left by the first rule were under 50 m wide.
  @sliver_m2 10_000.0
  @sliver_width_m 50.0

  # As `GroupAreas` takes at most this many points, a bigger union is
  # simplified, by a tolerance (in degrees, ~1 m at first) that grows until
  # it fits.
  @max_points 10_000
  @tolerances [0.00001, 0.00002, 0.00005, 0.0001, 0.0002, 0.0005, 0.001, 0.002]

  # Words that stay lowercase inside a name. Not "do": in "Suvi Do" it is a
  # valley, not a preposition.
  @lowercase ~w(i u na od iz sa za uz po pri kod pod nad)

  @progress_every 100

  @doc """
  Reads the GeoJSON file at `path` and brings its areas in as groups made by
  the profile `username` of the account `email`, which it makes when the
  account has none of that name. `opts`: `:name` and `:parent`, the
  properties that name a feature and its parent group.

  `{:ok, report}`, where the report counts what was made and taken again and
  lists what failed, or `{:error, reason}` when nothing could start.
  """
  def import_file(path, email, username, opts) do
    with {:ok, features} <- read(path, opts),
         {:ok, profile} <- profile(email, username) do
      {:ok, run(profile, features)}
    end
  end

  @doc """
  `import_file/4` in a task of the app's own, logging its report when done:
  what an `rpc` on a release starts, so that a dropped connection does not
  stop it.
  """
  def start(path, email, username, opts) do
    Task.Supervisor.start_child(PotokIde.TaskSupervisor, fn ->
      case import_file(path, email, username, opts) do
        {:ok, report} -> Logger.info("Area import done: #{inspect(report)}")
        {:error, reason} -> Logger.error("Area import failed: #{inspect(reason)}")
      end
    end)
  end

  @doc """
  The features of a GeoJSON file, as `%{name, parent, geometry}` with the
  names in `title_case/1`, or `{:error, reason}`.
  """
  def read(path, opts) do
    name_key = Keyword.fetch!(opts, :name)
    parent_key = Keyword.fetch!(opts, :parent)

    with {:ok, text} <- File.read(path),
         {:ok, %{"features" => features}} when is_list(features) <- Jason.decode(text) do
      {:ok,
       for %{"properties" => %{} = properties, "geometry" => %{} = geometry} <- features,
           name = properties[name_key],
           parent = properties[parent_key],
           is_binary(name) and is_binary(parent) and name != "" and parent != "" do
         %{name: title_case(name), parent: title_case(parent), geometry: geometry}
       end}
    else
      {:ok, _other} -> {:error, :not_a_feature_collection}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The profile `username` of the account `email`, made when there is none of
  that name, unless `make?` is false. One of that name on another account is
  an error.
  """
  def profile(email, username, make? \\ true) do
    case Accounts.get_account_by_email(email) do
      nil ->
        {:error, :no_account}

      account ->
        case Repo.get_by(Profile, username: username) do
          nil when make? ->
            Social.create_profile_for_account(account, %{"username" => username})

          nil ->
            {:error, :no_profile}

          profile ->
            on_account? =
              Repo.exists?(
                from(ap in AccountProfile,
                  where: ap.account_id == ^account.id and ap.profile_id == ^profile.id
                )
              )

            if on_account?, do: {:ok, profile}, else: {:error, :username_taken}
        end
    end
  end

  @doc """
  A name written in capitals as names are written: each word with a capital
  first letter, and the parts around a hyphen or in brackets too, but the
  short words of `@lowercase` inside a name, while "MZ", Roman numerals, a
  lone letter and words with digits stay as they are.

      iex> title_case("PETROVAC NA MLAVI")
      "Petrovac na Mlavi"
      iex> title_case("2. MZ SLOBODAN BAJIĆ PAJA")
      "2. MZ Slobodan Bajić Paja"
  """
  def title_case(name) when is_binary(name) do
    words = String.split(name, ~r/\s+/u, trim: true)
    last = length(words) - 1

    words
    |> Enum.with_index()
    |> Enum.map_join(" ", fn {word, index} -> word(word, index == 0, index == last) end)
  end

  defp word(word, first?, last?) do
    lower = String.downcase(word)

    cond do
      # A lone "I" at the end is a numeral ("Kumodraž I"), anywhere else "and".
      word == "I" and last? and not first? -> word
      lower in @lowercase and not first? -> lower
      word == "MZ" -> word
      word =~ ~r/^[IVX]{2,}$/ -> word
      String.length(word) == 1 -> word
      true -> word |> String.split("-") |> Enum.map_join("-", &capitalize/1)
    end
  end

  # "(BEOGRAD)" is "(Beograd)": what comes before the first letter stays.
  defp capitalize(part) do
    [_, lead, rest] = Regex.run(~r/^([^\p{L}]*)(.*)$/su, part)
    lead <> String.capitalize(rest)
  end

  ## Making the groups

  defp run(%Profile{} = profile, features) do
    root = Social.get_root_group!()

    report = %{
      parents: 0,
      children: 0,
      created: 0,
      reused: 0,
      areas: 0,
      repaired: 0,
      failed: []
    }

    features
    |> Enum.group_by(& &1.parent)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.reduce(report, fn {parent_name, children}, report ->
      import_parent(profile, root, parent_name, children, report)
    end)
    |> Map.update!(:failed, &Enum.reverse/1)
  end

  defp import_parent(profile, root, parent_name, children, report) do
    case take_or_make(profile, root, parent_name, 1) do
      {:ok, parent, has_area?, made?} ->
        report = count_group(%{report | parents: report.parents + 1}, made?)

        {report, changed?} =
          children
          |> Enum.group_by(& &1.name)
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.reduce({report, false}, fn {name, same_name}, acc ->
            same_name
            |> Enum.with_index(1)
            |> Enum.reduce(acc, fn {feature, nth}, {report, changed?} ->
              {report, set?} = import_child(profile, parent, name, nth, feature, report)
              {report, changed? or set?}
            end)
          end)

        if has_area? and not changed?,
          do: report,
          else: put_union(profile, parent, report)

      {:error, reason} ->
        fail(report, parent_name, nil, reason)
    end
  end

  # Gives the report and whether the child got its border now.
  defp import_child(profile, parent, name, nth, feature, report) do
    report = %{report | children: report.children + 1}

    if rem(report.children, @progress_every) == 0 do
      Logger.info("Area import: #{report.children} areas, now #{parent.name}")
    end

    case take_or_make(profile, parent, name, nth) do
      {:ok, _group, true, made?} ->
        {count_group(report, made?), false}

      {:ok, group, false, made?} ->
        report = count_group(report, made?)

        case border(feature.geometry) do
          {:ok, area, repaired?} ->
            case put_area(profile, group, area, @child_pin) do
              :ok ->
                report = %{report | areas: report.areas + 1}
                {if(repaired?, do: %{report | repaired: report.repaired + 1}, else: report), true}

              {:error, reason} ->
                {fail(report, parent.name, name, reason), false}
            end

          {:error, reason} ->
            {fail(report, parent.name, name, reason), false}
        end

      {:error, reason} ->
        {fail(report, parent.name, name, reason), false}
    end
  end

  defp count_group(report, true), do: %{report | created: report.created + 1}
  defp count_group(report, false), do: %{report | reused: report.reused + 1}

  defp fail(report, parent_name, name, reason),
    do: %{report | failed: [{parent_name, name, reason} | report.failed]}

  # The `nth` group of that name the profile made under `parent`, or a new one:
  # `{:ok, group, whether it has an area, whether it was made now}`.
  defp take_or_make(%Profile{} = profile, %Group{} = parent, name, nth) do
    taken =
      from(g in Group,
        where: g.parent_id == ^parent.id and g.name == ^name and g.creator_id == ^profile.id,
        order_by: g.id,
        select: {g, not is_nil(g.area)}
      )
      |> Repo.all()
      |> Enum.at(nth - 1)

    case taken do
      {group, has_area?} ->
        {:ok, group, has_area?, false}

      nil ->
        choices = %{"name" => name, "is_public" => true, "inherits_members" => false}

        case Social.create_group_from_preset(profile, parent, @preset, choices) do
          {:ok, %{group: group}} -> {:ok, group, false, true}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # A feature's border as `GroupAreas` keeps it, mended when PostGIS does not
  # take it as it is: `{:ok, area, whether it was mended}`.
  defp border(geometry) do
    with {:ok, area} <- GroupAreas.decode(geometry) do
      if valid?(area) do
        {:ok, area, false}
      else
        with {:ok, mended} <- mend(area), true <- valid?(mended) || {:error, :crosses_itself} do
          {:ok, mended, true}
        end
      end
    end
  end

  defp valid?(%Geo.MultiPolygon{} = area),
    do: Repo.query!("SELECT ST_IsValid($1::geometry)", [area]).rows == [[true]]

  defp mend(area) do
    case Repo.query!(
           "SELECT ST_Multi(ST_CollectionExtract(ST_MakeValid($1::geometry), 3))",
           [area]
         ).rows do
      [[%Geo.MultiPolygon{coordinates: [_ | _]} = mended]] -> GroupAreas.normalize(mended)
      _none -> {:error, :crosses_itself}
    end
  end

  defp put_area(profile, group, area, pin) do
    case Social.update_group(profile, group, %{"area" => area, "pin_icon" => pin}) do
      {:ok, _group} -> :ok
      {:error, %Ecto.Changeset{} = changeset} -> {:error, changeset_errors(changeset)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp changeset_errors(changeset) do
    Enum.map(changeset.errors, fn {field, {message, _opts}} -> {field, message} end)
  end

  # The parent's border: the union of its children's, without slivers, small
  # enough for `GroupAreas`.
  defp put_union(profile, parent, report) do
    case union(parent.id) do
      {:ok, area} ->
        case put_area(profile, parent, area, @parent_pin) do
          :ok -> %{report | areas: report.areas + 1}
          {:error, reason} -> fail(report, parent.name, nil, reason)
        end

      {:error, reason} ->
        fail(report, parent.name, nil, reason)
    end
  end

  @union_sql """
  WITH u AS (
    SELECT ST_CollectionExtract(ST_MakeValid(ST_UnaryUnion(ST_Collect(area))), 3) AS g
    FROM groups
    WHERE parent_id = $1 AND area IS NOT NULL
  ),
  parts AS (
    SELECT (ST_Dump(g)).geom AS p FROM u
  ),
  kept AS (
    SELECT ST_MakePolygon(
             ST_ExteriorRing(p),
             ARRAY(
               SELECT ST_ExteriorRing(r.geom)
               FROM ST_DumpRings(p) AS r
               WHERE r.path[1] > 0
                 AND ST_Area(r.geom::geography) >= $2::float8
                 AND 2 * ST_Area(r.geom::geography) / ST_Perimeter(r.geom::geography) >= $3::float8
             )
           ) AS p
    FROM parts
    WHERE ST_Area(p::geography) >= $2::float8
  )
  SELECT ST_Multi(ST_Collect(p)) FROM kept
  """

  defp union(parent_id) do
    case Repo.query!(@union_sql, [parent_id, @sliver_m2, @sliver_width_m]).rows do
      [[%Geo.MultiPolygon{coordinates: [_ | _]} = area]] -> fitting(area)
      _none -> {:error, :no_areas_below}
    end
  end

  defp fitting(area) do
    if points(area) <= @max_points do
      GroupAreas.normalize(area)
    else
      @tolerances
      |> Enum.find_value({:error, :too_many_points}, fn tolerance ->
        [[simpler]] =
          Repo.query!(
            "SELECT ST_Multi(ST_SimplifyPreserveTopology($1::geometry, $2::float8))",
            [area, tolerance]
          ).rows

        if points(simpler) <= @max_points, do: GroupAreas.normalize(simpler)
      end)
    end
  end

  defp points(%Geo.MultiPolygon{coordinates: polygons}),
    do: polygons |> Enum.flat_map(& &1) |> Enum.map(&length/1) |> Enum.sum()

  ## Taking it away

  @doc """
  Takes away what an import by `profile` made: the groups it made under the
  root that start from the import's preset, and the groups it made under
  those, each through `Social.delete_group/2`. A group that has got groups
  of others' below it stays. `{:ok, deleted, kept}`.
  """
  def remove(%Profile{} = profile) do
    root = Social.get_root_group!()
    preset = String.to_existing_atom(@preset)

    parents =
      from(g in Group,
        where: g.parent_id == ^root.id and g.creator_id == ^profile.id and g.preset == ^preset,
        order_by: g.id
      )
      |> Repo.all()

    {deleted, kept} =
      Enum.reduce(parents, {0, 0}, fn parent, counts ->
        children =
          from(g in Group,
            where: g.parent_id == ^parent.id and g.creator_id == ^profile.id,
            order_by: g.id
          )
          |> Repo.all()

        Enum.reduce(children ++ [parent], counts, &delete(profile, &1, &2))
      end)

    {:ok, deleted, kept}
  end

  defp delete(profile, group, {deleted, kept}) do
    case Social.delete_group(profile, group) do
      {:ok, _group} -> {deleted + 1, kept}
      {:error, _reason} -> {deleted, kept + 1}
    end
  end
end
