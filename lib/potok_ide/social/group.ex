defmodule PotokIde.Social.Group do
  use Ecto.Schema

  import Ecto.Changeset

  @max_group_picture_url_length 1_000_000

  @description_formats [:markdown, :html]
  @home_pages [:chat, :description, :subgroups]
  # The keys of `PotokIde.Social.GroupPresets`, written out: that module matches
  # on this struct, so reading them from it would compile in a circle.
  @presets [:chat, :folder, :announcements, :feed, :polls, :questionnaire, :map, :page]

  @location_fields [:latitude, :longitude, :pin_icon]

  schema "groups" do
    field :name, :string
    # See Profile.profile_picture_url: loaded only on demand via `Social.load_picture/1`.
    field :group_picture_url, :string, load_in_query: false
    field :description, :string
    field :description_format, Ecto.Enum, values: @description_formats, default: :markdown
    # Label of the default description next to the alternative ones.
    field :description_name, :string
    field :home_page, Ecto.Enum, values: @home_pages, default: :description
    field :has_public_chat, :boolean, default: false
    # Guests, people without an account who have the group's link, read its
    # description while it is public (`guest_description?/1`). Kept while it
    # is private, like `has_public_chat`.
    field :description_for_guests, :boolean, default: false
    field :is_direct, :boolean, default: false
    field :is_public, :boolean, default: false
    field :is_root, :boolean, default: false
    field :is_root_public, :boolean, default: false
    field :uses_api, :boolean, default: false
    # The ready setup the group was made from, for the mark on its avatar
    # (`GroupPresets.shown/1`); nil for any other. Set once by
    # `Social.create_group_from_preset/4`, never cast.
    field :preset, Ecto.Enum, values: @presets
    # Holds every member of the parent (see `Social.MemberInheritance`).
    # Threads always do; `Social` keeps it off for the root's children.
    field :inherits_members, :boolean, default: false
    # When the newest chat value was posted; kept by Social, never cast.
    field :last_value_at, :utc_datetime
    # When a closed group (see `closed?/1`) last opened up, which is its place
    # in a feed; nil keeps the place from `inserted_at`. Kept by Social, never cast.
    field :published_at, :utc_datetime
    # Where the group stands on a map, both or neither; a map shows the placed
    # children of its group (`Social.list_visible_placed_children/3`).
    field :latitude, :float
    field :longitude, :float
    # The pin it shows there (`GroupPins`); nil shows its kind.
    field :pin_icon, :string
    # An app's own key for a group it made (`Social.create_children/4`),
    # unique under the parent, so that the same list brought in again makes no
    # duplicates. A group with a key is a record: its own map shows it, the
    # root's map and the place picker of events do not, and unread counts do
    # not follow it. Set once when the group is made, never cast.
    field :external_key, :string
    # The area it covers, when its place is an area rather than a point: a
    # border of one or more polygons (`GroupAreas`). Its pin then stands inside
    # it, set by `Social.update_group/3`. Loaded only on demand
    # (`Social.load_area/1`), as a border can hold thousands of points.
    field :area, Geo.PostGIS.Geometry, load_in_query: false
    # The line it runs along, when its place is a route rather than a point or
    # an area: one or more parts (`GroupRoutes`), as a walk or a bike path
    # runs. Its pin then stands at its start, set by `Social.update_group/3`.
    # A group has an area or a route, never both. Loaded with the area.
    field :route, Geo.PostGIS.Geometry, load_in_query: false
    # Kept by Postgres from the row (generated columns), never written here:
    # the name as a search compares it (`NameSearch`), an area's size, box and
    # width on a map (`GroupAreas`), and a route's length in metres, box and
    # width (`GroupRoutes`), so map queries need not read borders or lines.
    field :name_folded, :string, load_in_query: false, writable: :never
    field :area_size, :float, load_in_query: false, writable: :never
    field :area_west, :float, load_in_query: false, writable: :never
    field :area_south, :float, load_in_query: false, writable: :never
    field :area_east, :float, load_in_query: false, writable: :never
    field :area_north, :float, load_in_query: false, writable: :never
    field :area_span, :float, load_in_query: false, writable: :never
    field :route_length, :float, load_in_query: false, writable: :never
    field :route_west, :float, load_in_query: false, writable: :never
    field :route_south, :float, load_in_query: false, writable: :never
    field :route_east, :float, load_in_query: false, writable: :never
    field :route_north, :float, load_in_query: false, writable: :never
    field :route_span, :float, load_in_query: false, writable: :never
    # The tags the viewing profile sees (`PotokIde.Tags.put_tags/3`): the
    # public ones and its own private ones.
    field :tags, {:array, :any}, virtual: true, default: []
    # Shown in the sub-groups list, which loads them with the page
    # (`Social.list_child_groups_for_profile/3`); nil when not loaded.
    field :member_count, :integer, virtual: true
    field :sub_group_count, :integer, virtual: true
    field :viewer_is_member, :boolean, virtual: true
    # The newest chat value as a `PotokIde.Social.ValuePreview`, in the rows of
    # the groups whose chat the viewer reads there; nil otherwise.
    field :last_value, :map, virtual: true

    belongs_to :creator, PotokIde.Social.Profile
    belongs_to :parent, __MODULE__
    belongs_to :parent_value, PotokIde.Social.Value
    # Opened instead of the default description; nil opens the default.
    # `Social.update_group/3` checks that it is one of the group's own.
    belongs_to :home_alt_description, PotokIde.Social.GroupAltDescription

    has_many :children, __MODULE__, foreign_key: :parent_id
    has_many :alt_descriptions, PotokIde.Social.GroupAltDescription
    has_one :manifest, PotokIde.Social.GroupManifest

    many_to_many :members, PotokIde.Social.Profile,
      join_through: PotokIde.Social.GroupMembership,
      join_keys: [group_id: :id, profile_id: :id]

    has_many :values, PotokIde.Social.Value
    has_many :reactions, PotokIde.Social.GroupReaction

    timestamps(type: :utc_datetime)
  end

  def changeset(group, attrs) do
    group
    |> cast(attrs, [
      :name,
      :group_picture_url,
      :description,
      :description_format,
      :home_page,
      :has_public_chat,
      :description_for_guests,
      :is_direct,
      :is_public,
      :is_root,
      :is_root_public,
      :uses_api,
      :inherits_members,
      :creator_id,
      :parent_id,
      :parent_value_id
      | @location_fields
    ])
    |> validate_location()
    |> validate_required([
      :name,
      :description_format,
      :home_page,
      :has_public_chat,
      :description_for_guests,
      :is_public,
      :is_root,
      :is_root_public
    ])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:group_picture_url, max: @max_group_picture_url_length)
    |> maybe_force_public_from_root_public()
    |> maybe_force_html_from_uses_api()
    |> maybe_force_inherits_members_for_thread()
    |> add_check_constraints()
    |> check_constraint(:external_key, name: :groups_external_key_check)
    |> unique_constraint([:parent_id, :external_key],
      name: :groups_parent_external_key_index,
      error_key: :external_key
    )
    |> unique_constraint(:parent_value_id)
    |> validate_creation_constraints()
  end

  def update_changeset(group, attrs) do
    group
    |> cast(attrs, [
      :name,
      :group_picture_url,
      :description,
      :description_format,
      :description_name,
      :home_page,
      :home_alt_description_id,
      :has_public_chat,
      :description_for_guests,
      :is_public,
      :is_root_public,
      :uses_api,
      :inherits_members,
      :area,
      :route
      | @location_fields
    ])
    |> validate_location()
    |> validate_area()
    |> validate_route()
    |> one_shape()
    |> update_change(:description_name, &trim/1)
    |> validate_required([
      :name,
      :description_format,
      :home_page,
      :has_public_chat,
      :description_for_guests,
      :is_public,
      :is_root_public
    ])
    |> validate_length(:name, min: 1, max: 120)
    |> validate_length(:description_name, max: 60)
    |> validate_length(:group_picture_url, max: @max_group_picture_url_length)
    |> maybe_force_public_from_root_public()
    |> maybe_force_html_from_uses_api()
    |> maybe_force_inherits_members_for_thread()
    |> add_check_constraints()
    |> foreign_key_constraint(:home_alt_description_id)
  end

  @doc "Whether guests get a preview of the group at its link (`PotokIdeWeb.PublicPreview`)."
  def guest_preview?(%__MODULE__{
        is_public: true,
        is_root: false,
        is_direct: false,
        parent_value_id: nil
      }),
      do: true

  def guest_preview?(%__MODULE__{}), do: false

  @doc """
  Whether guests read the group's description, not only its card: a group
  they get a preview of (`guest_preview?/1`) that opened it to them. Its
  alternative descriptions follow only where each is marked for it
  (`PotokIde.Social.GroupAltDescription`). A group that stops being public
  keeps the choice, as with `open_chat?/1`.
  """
  def guest_description?(%__MODULE__{description_for_guests: true} = group),
    do: guest_preview?(group)

  def guest_description?(%__MODULE__{}), do: false

  @doc """
  Whether the group's chat reaches past its members: any signed-in profile reads
  it, and `Access` says who writes. Threads stay with the members, as opening one
  makes a group of its own. A group that stops being public closes its chat but
  remembers the choice, so that withdrawing a story and publishing it again
  leaves its comments as they were.
  """
  def open_chat?(%__MODULE__{
        has_public_chat: true,
        is_public: true,
        is_root: false,
        is_direct: false,
        parent_value_id: nil
      }),
      do: true

  def open_chat?(%__MODULE__{}), do: false

  @doc "Whether only the members added to the group itself can see it."
  def closed?(%__MODULE__{is_public: false, inherits_members: false}), do: true
  def closed?(%__MODULE__{}), do: false

  @doc "Whether the group has a place on a map."
  def placed?(%__MODULE__{latitude: lat, longitude: lng}), do: is_number(lat) and is_number(lng)

  @doc """
  The error messages of an area (`GroupAreas.normalize/1`), in the errors
  domain: whole sentences, as the Location card shows them on their own.
  """
  def area_error(:invalid), do: "The border is not an area on a map."
  def area_error(:too_many_points), do: "The border has too many points."
  def area_error(:too_many_parts), do: "The border has too many parts."
  def area_error(:too_wide), do: "The border is wider than half the world."
  def area_error(:crosses_itself), do: "The border crosses itself."

  @doc """
  The error messages of a route (`GroupRoutes.normalize/1`), in the errors
  domain, as whole sentences like `area_error/1`.
  """
  def route_error(:invalid), do: "The route is not a line on a map."
  def route_error(:too_many_points), do: "The route has too many points."
  def route_error(:too_many_parts), do: "The route has too many parts."
  def route_error(:too_wide), do: "The route is wider than half the world."
  def route_error(:with_area), do: "A place is either an area or a route."

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  # Both coordinates or neither, each within its range, to six decimals (about
  # 10 cm, finer than any finger on a map). An empty pin is the kind's.
  defp validate_location(changeset) do
    changeset
    |> update_change(:latitude, &round_coordinate/1)
    |> update_change(:longitude, &round_coordinate/1)
    |> update_change(:pin_icon, &blank_to_nil/1)
    |> validate_number(:latitude, greater_than_or_equal_to: -90, less_than_or_equal_to: 90)
    |> validate_number(:longitude, greater_than_or_equal_to: -180, less_than_or_equal_to: 180)
    |> validate_both_coordinates()
    |> validate_inclusion(:pin_icon, PotokIde.Social.GroupPins.keys())
  end

  # A border as `GroupAreas.normalize/1` keeps it: polygons, closed rings,
  # coordinates rounded like a pin's, within limits.
  defp validate_area(changeset) do
    case fetch_change(changeset, :area) do
      {:ok, area} when not is_nil(area) ->
        case PotokIde.Social.GroupAreas.normalize(area) do
          {:ok, area} -> put_change(changeset, :area, area)
          {:error, reason} -> add_error(changeset, :area, area_error(reason))
        end

      _none ->
        changeset
    end
  end

  # A line as `GroupRoutes.normalize/1` keeps it: parts of at least two
  # points, coordinates rounded like a pin's, within limits.
  defp validate_route(changeset) do
    case fetch_change(changeset, :route) do
      {:ok, route} when not is_nil(route) ->
        case PotokIde.Social.GroupRoutes.normalize(route) do
          {:ok, route} -> put_change(changeset, :route, route)
          {:error, reason} -> add_error(changeset, :route, route_error(reason))
        end

      _none ->
        changeset
    end
  end

  # A place is a point, an area or a route: a new area takes the route's
  # place and a new route the area's (written even when not loaded, so the
  # row never holds both), and both at once is a mistake.
  defp one_shape(changeset) do
    case {get_change(changeset, :area), get_change(changeset, :route)} do
      {nil, nil} -> changeset
      {_area, nil} -> force_change(changeset, :route, nil)
      {nil, _route} -> force_change(changeset, :area, nil)
      {_area, _route} -> add_error(changeset, :route, route_error(:with_area))
    end
  end

  defp validate_both_coordinates(changeset) do
    case {get_field(changeset, :latitude), get_field(changeset, :longitude)} do
      {nil, nil} -> changeset
      {lat, lng} when is_number(lat) and is_number(lng) -> changeset
      {nil, _lng} -> add_error(changeset, :latitude, "can't be blank", validation: :required)
      {_lat, nil} -> add_error(changeset, :longitude, "can't be blank", validation: :required)
    end
  end

  defp round_coordinate(value) when is_float(value), do: Float.round(value, 6)
  defp round_coordinate(value), do: value

  defp blank_to_nil(value) when is_binary(value) do
    if String.trim(value) == "", do: nil, else: String.trim(value)
  end

  defp blank_to_nil(value), do: value

  defp maybe_force_public_from_root_public(changeset) do
    if get_field(changeset, :is_root_public) do
      put_change(changeset, :is_public, true)
    else
      changeset
    end
  end

  defp maybe_force_html_from_uses_api(changeset) do
    if get_field(changeset, :uses_api) do
      put_change(changeset, :description_format, :html)
    else
      changeset
    end
  end

  # A thread holds the members of the group its value was posted in.
  defp maybe_force_inherits_members_for_thread(changeset) do
    if get_field(changeset, :parent_value_id) do
      put_change(changeset, :inherits_members, true)
    else
      changeset
    end
  end

  defp add_check_constraints(changeset) do
    changeset
    |> check_constraint(:description_format, name: :groups_description_format_check)
    |> check_constraint(:home_page, name: :groups_home_page_check)
    |> check_constraint(:preset, name: :groups_preset_check)
    |> check_constraint(:latitude, name: :groups_location_check)
    |> check_constraint(:area, name: :groups_area_check)
    |> check_constraint(:route, name: :groups_route_check)
    |> check_constraint(:is_public, name: :groups_root_private_check)
    |> check_constraint(:parent_id, name: :groups_root_parent_check)
    |> check_constraint(:creator_id, name: :groups_root_creator_check)
    |> check_constraint(:inherits_members, name: :groups_inherits_members_check)
    |> check_constraint(:inherits_members, name: :groups_thread_inherits_members_check)
  end

  defp validate_creation_constraints(changeset) do
    is_root = get_field(changeset, :is_root)

    if is_root do
      changeset
    else
      validate_required(changeset, [:creator_id, :parent_id])
    end
  end
end
