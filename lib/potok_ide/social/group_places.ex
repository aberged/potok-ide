defmodule PotokIde.Social.GroupPlaces do
  @moduledoc """
  Groups with a place, whatever its shape (a point, an area or a route), as
  something to pick or to point at: the place of a calendar event
  (`PotokIde.Events.place/2`) and the root map's link to one group
  (`?place=`).

  A group is seen by whoever may see it (`Visibility`): its members and, for
  a public group, every signed-in profile. The root has no place, and records
  (`Group.external_key`) are left out: only their own map shows them.
  """

  import Ecto.Query

  alias PotokIde.Repo
  alias PotokIde.Social.{Group, GroupAreas, GroupRoutes, NameSearch, Profile, Visibility}

  @doc """
  What a group with a place is loaded with here: what its pin needs, the boxes
  of its area or route, and which of the two it has (`shape/1`).
  """
  def fields,
    do:
      GroupAreas.fields() ++
        GroupAreas.box_fields() ++ GroupRoutes.box_fields() ++ [:area_size, :route_length]

  @doc "The group `id` if it has a place and the profile may see it; nil otherwise."
  def get_visible(%Profile{} = profile, id) when is_integer(id) do
    profile
    |> placed()
    |> where([g], g.id == ^id)
    |> select([g], struct(g, ^fields()))
    |> Repo.one()
  end

  def get_visible(%Profile{}, _id), do: nil

  @doc """
  The groups with a place the profile may see whose name holds `term`
  (`NameSearch`; all for a blank one), at most `limit`, as `{group, meters}`.
  With `near`, a `{lat, lng}`, the nearest come first and `meters` is how far
  each one's pin stands from it; without it the profile's own groups come
  first, then the others by name, and `meters` is nil.
  """
  def search(%Profile{} = profile, term, near, limit) when is_integer(limit) do
    query =
      profile
      |> placed()
      |> NameSearch.where_matches(NameSearch.term(to_string(term)))
      |> limit(^limit)

    case near do
      {lat, lng} when is_number(lat) and is_number(lng) ->
        {lat, lng} = {lat * 1.0, lng * 1.0}

        # The same expression as the index `groups_pin_index`, alone, so the
        # nearest come from the index (a second key sorts every group: 380
        # against 14 ms over 4,210 places).
        query
        |> order_by(
          [g],
          asc:
            fragment(
              "ST_SetSRID(ST_MakePoint(?, ?), 4326) <-> ST_SetSRID(ST_MakePoint(?::float8, ?::float8), 4326)",
              g.longitude,
              g.latitude,
              ^lng,
              ^lat
            )
        )
        |> select(
          [g],
          {struct(g, ^fields()),
           fragment(
             "ST_Distance(ST_SetSRID(ST_MakePoint(?, ?), 4326)::geography, ST_SetSRID(ST_MakePoint(?::float8, ?::float8), 4326)::geography)",
             g.longitude,
             g.latitude,
             ^lng,
             ^lat
           )}
        )
        |> Repo.all()

      _none ->
        profile_id = profile.id

        query
        |> order_by(
          [g],
          desc:
            fragment(
              "EXISTS (SELECT 1 FROM group_memberships m WHERE m.group_id = ? AND m.profile_id = ?)",
              g.id,
              ^profile_id
            ),
          asc: fragment("lower(?)", g.name),
          asc: g.id
        )
        |> select([g], {struct(g, ^fields()), nil})
        |> Repo.all()
    end
  end

  @doc "A group's place as loaded with `fields/0`: `:point`, `:area` or `:route`."
  def shape(%Group{area_size: size}) when is_number(size), do: :area
  def shape(%Group{route_length: meters}) when is_number(meters), do: :route
  def shape(%Group{}), do: :point

  @doc """
  The box a map fits to show a group's place, `[[south, west], [north,
  east]]`: its area's or its route's, or its pin twice for a point.
  """
  def bounds(%Group{} = group) do
    case shape(group) do
      :area ->
        [west, south, east, north] = GroupAreas.bbox(group)
        [[south, west], [north, east]]

      :route ->
        GroupRoutes.bounds(group)

      :point ->
        [[group.latitude, group.longitude], [group.latitude, group.longitude]]
    end
  end

  # The groups with a place the profile may see. Records (`Group.external_key`)
  # stay on their own map: thousands of rows of a dataset are no place to pick
  # (and the index the nearest come from holds none).
  defp placed(%Profile{} = profile) do
    Visibility.plain_groups(profile)
    |> where([g], not is_nil(g.latitude) and not g.is_root and is_nil(g.external_key))
  end
end
