defmodule PotokIde.Social.ProfileField do
  @moduledoc """
  One detail of a profile: first or last name, occupation, place, phone,
  contact email or links. A row exists only while the field is filled. Each
  says who sees it (`audience`):

    * `:only_me`, the accounts that hold the profile;
    * `:groups`, members of the picked groups (`group_ids`) who share one of
      them with the profile;
    * `:shared_groups`, anyone who shares a group with the profile;
    * `:signed_in`, anyone signed in who sees the profile.

  `PotokIde.Social.ProfileDetails` decides who that is; a shared group is one
  that is neither the root nor a direct conversation, a thread or a record
  (`PotokIde.Social.ProfileFacts`).
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias PotokIde.Social.Profile

  # In the order the profile shows them.
  @keys [:first_name, :last_name, :occupation, :place, :phone, :email, :website]
  @audiences [:only_me, :groups, :shared_groups, :signed_in]

  # Names and what one does are what a group needs to know who someone is;
  # how to reach them stays with them until they open it.
  @default_audiences %{
    first_name: :shared_groups,
    last_name: :shared_groups,
    occupation: :shared_groups,
    place: :shared_groups,
    phone: :only_me,
    email: :only_me,
    website: :only_me
  }

  @max_lengths %{
    first_name: 50,
    last_name: 50,
    occupation: 120,
    place: 80,
    phone: 32,
    email: 160,
    website: 500
  }

  @single_line [:first_name, :last_name, :occupation, :place, :phone, :email]
  @phone_format ~r/^\+?[0-9 ()\/.-]{5,32}$/
  @email_format ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/
  @max_links 3
  @max_link_length 200

  schema "profile_fields" do
    belongs_to :profile, Profile
    field :key, Ecto.Enum, values: @keys
    field :value, :string
    field :audience, Ecto.Enum, values: @audiences, default: :only_me
    field :group_ids, {:array, :id}, default: []

    timestamps(type: :utc_datetime)
  end

  def keys, do: @keys
  def audiences, do: @audiences

  @doc "Who sees a field that is not filled yet, once it is."
  def default_audience(key) when key in @keys, do: Map.fetch!(@default_audiences, key)

  @doc "An empty field of the profile, for the form, with its default audience."
  def new(profile_id, key) when key in @keys,
    do: %__MODULE__{profile_id: profile_id, key: key, audience: default_audience(key)}

  @doc """
  The field as the form sends it: `value`, `audience` and `group_ids`. The
  value is trimmed, and checked against what the key holds; picked groups are
  kept only among `allowed_group_ids` (the profile's own shared groups) and
  only for `:groups`. A blank value is valid: saving it deletes the field
  (`blank?/1`).
  """
  def changeset(%__MODULE__{key: key} = field, attrs, allowed_group_ids)
      when key in @keys and is_list(allowed_group_ids) do
    field
    |> cast(normalize(attrs, key), [:value, :audience, :group_ids], empty_values: [])
    |> validate_required([:audience])
    |> validate_value(key)
    |> keep_group_ids(allowed_group_ids)
  end

  @doc "Whether the changeset leaves the field empty, so saving deletes it."
  def blank?(%Ecto.Changeset{} = changeset), do: get_field(changeset, :value) in [nil, ""]

  @doc "The links of a `:website` field, one per line."
  def links(%__MODULE__{key: :website, value: value}) when is_binary(value),
    do: String.split(value, "\n", trim: true)

  def links(_field), do: []

  defp normalize(attrs, key) when is_map(attrs) do
    attrs
    |> Map.new(fn {k, v} -> {to_string(k), v} end)
    |> Map.update("value", nil, &normalize_value(&1, key))
    |> Map.update("group_ids", [], &normalize_ids/1)
  end

  defp normalize_value(value, :website) when is_binary(value) do
    value
    |> String.split(~r/\R/, trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&with_scheme/1)
    |> Enum.join("\n")
  end

  defp normalize_value(value, _key) when is_binary(value), do: String.trim(value)
  defp normalize_value(_value, _key), do: ""

  # A bare domain, as people write it, is a link to its site.
  defp with_scheme(link) do
    if Regex.match?(~r/^[a-z][a-z0-9+.-]*:/i, link), do: link, else: "https://" <> link
  end

  # A checkbox group sends a hidden "" so that none picked still sends the key.
  defp normalize_ids(ids) when is_list(ids) do
    Enum.flat_map(ids, fn
      id when is_integer(id) ->
        [id]

      id when is_binary(id) ->
        case Integer.parse(id) do
          {int, ""} -> [int]
          _ -> []
        end

      _ ->
        []
    end)
  end

  defp normalize_ids(_ids), do: []

  defp validate_value(changeset, key) do
    changeset
    |> validate_length(:value, max: Map.fetch!(@max_lengths, key))
    |> validate_change(:value, fn :value, value -> value_errors(key, value) end)
  end

  defp value_errors(_key, ""), do: []

  defp value_errors(key, value) when key in @single_line do
    cond do
      String.contains?(value, ["\n", "\r"]) ->
        [value: "must be one line"]

      key == :phone and not Regex.match?(@phone_format, value) ->
        [value: "is not a phone number"]

      key == :email and not Regex.match?(@email_format, value) ->
        [value: "is not an email address"]

      true ->
        []
    end
  end

  defp value_errors(:website, value) do
    links = String.split(value, "\n", trim: true)

    cond do
      length(links) > @max_links -> [value: "has more than three links"]
      not Enum.all?(links, &link?/1) -> [value: "has a line that is not a link"]
      true -> []
    end
  end

  defp link?(link) do
    String.length(link) <= @max_link_length and not String.contains?(link, [" ", "\t"]) and
      match?(
        %URI{scheme: scheme, host: host} when scheme in ["http", "https"] and is_binary(host),
        URI.parse(link)
      ) and String.contains?(URI.parse(link).host, ".")
  end

  defp keep_group_ids(changeset, allowed_group_ids) do
    if get_field(changeset, :audience) == :groups do
      allowed = MapSet.new(allowed_group_ids)

      ids =
        changeset
        |> get_field(:group_ids)
        |> Enum.filter(&MapSet.member?(allowed, &1))
        |> Enum.uniq()

      changeset = put_change(changeset, :group_ids, ids)

      if ids == [] and not blank?(changeset),
        do: add_error(changeset, :group_ids, "pick at least one group"),
        else: changeset
    else
      put_change(changeset, :group_ids, [])
    end
  end
end
