defmodule PotokIde.Social.GroupTemplate do
  @moduledoc """
  A template of a group's own for descriptions: the fields of a form and an
  HTML template that turns what the form holds into a description
  (`PotokIdeWeb.PostTemplates.Custom` renders it, `GroupTemplate.Syntax`
  reads it). It serves its group and every group below it
  (`PotokIde.Social.GroupTemplates.catalog/2`), and is made there by whoever
  may edit the group.

  A field is `%{"key", "label", "kind", "required", "hint", "options"}`. The
  first required `text` field names a post FeedCreator writes, the first
  `textarea` is the text of a shared link's card. A `pictures` field keeps its
  captions under `<key>_captions`.
  """

  use Ecto.Schema
  use Gettext, backend: PotokIdeWeb.Gettext

  import Ecto.Changeset

  alias PotokIde.Social.GroupTemplate.Syntax

  @kinds ~w(text textarea url date time choice items image pictures video)
  @max_fields 30
  @max_options 20
  @max_html 32_768
  @key ~r/\A[a-z][a-z0-9_]{0,29}\z/

  schema "group_templates" do
    field :name, :string
    field :purpose, :string, default: ""
    field :fields, {:array, :map}, default: []
    field :html, :string, default: ""
    field :rev, :integer, default: 1
    field :position, :integer, default: 0

    belongs_to :group, PotokIde.Social.Group
    belongs_to :creator, PotokIde.Social.Profile

    timestamps(type: :utc_datetime)
  end

  def kinds, do: @kinds
  def max_fields, do: @max_fields
  def max_html, do: @max_html

  @doc "The key a `pictures` field keeps its captions under."
  def captions_key(key), do: key <> "_captions"

  @doc """
  `group_id`, `creator_id`, `rev` and `position` are set by
  `GroupTemplates`, never cast.
  """
  def changeset(template, attrs) do
    template
    |> cast(attrs, [:name, :purpose, :html])
    |> put_fields(attrs)
    |> update_change(:name, &trim/1)
    |> update_change(:purpose, &trim/1)
    |> put_blank(:purpose)
    |> put_blank(:html)
    |> validate_required([:name])
    |> validate_length(:name, min: 1, max: 60)
    |> validate_length(:purpose, max: 160)
    |> validate_length(:html, max: @max_html, count: :bytes)
    |> validate_syntax()
    |> unique_constraint(:name,
      name: :group_templates_group_id_lower_name_index,
      message: dgettext("errors", "is already used by another template")
    )
  end

  defp put_fields(changeset, attrs) do
    case Map.get(attrs, "fields", Map.get(attrs, :fields)) do
      nil ->
        changeset

      fields ->
        case normalize_fields(fields) do
          {:ok, fields} -> put_change(changeset, :fields, fields)
          {:error, message} -> add_error(changeset, :fields, message)
        end
    end
  end

  # The template has to name only fields it has, in tags it knows.
  defp validate_syntax(changeset) do
    if Keyword.has_key?(changeset.errors, :fields) do
      changeset
    else
      html = get_field(changeset, :html) || ""
      fields = get_field(changeset, :fields) || []

      case Syntax.parse(html, fields) do
        {:ok, _tree} -> changeset
        {:error, message} -> add_error(changeset, :html, message)
      end
    end
  end

  @doc """
  The fields as a form sends them (a list, or a map by row number), checked
  and in the stored shape: `{:ok, fields}` or `{:error, message}`.
  """
  def normalize_fields(fields) when is_map(fields) do
    fields
    |> Enum.sort_by(fn {index, _field} -> sort_index(index) end)
    |> Enum.map(&elem(&1, 1))
    |> normalize_fields()
  end

  def normalize_fields(fields) when is_list(fields) do
    rows = Enum.map(fields, &normalize_field/1)

    cond do
      length(rows) > @max_fields ->
        {:error, dgettext("errors", "has more than %{count} fields", count: @max_fields)}

      error = Enum.find_value(rows, &(match?({:error, _}, &1) && elem(&1, 1))) ->
        {:error, error}

      true ->
        rows = Enum.map(rows, &elem(&1, 1))
        keys = Enum.flat_map(rows, &field_keys/1)

        if length(keys) == length(Enum.uniq(keys)),
          do: {:ok, rows},
          else: {:error, dgettext("errors", "has two fields with the same key")}
    end
  end

  def normalize_fields(_fields), do: {:error, dgettext("errors", "is not a list of fields")}

  defp sort_index(index) do
    case Integer.parse(to_string(index)) do
      {number, ""} -> number
      _other -> 0
    end
  end

  defp field_keys(%{"kind" => "pictures", "key" => key}), do: [key, captions_key(key)]
  defp field_keys(%{"key" => key}), do: [key]

  defp normalize_field(field) when is_map(field) do
    label = field |> text("label") |> String.slice(0, 60)
    kind = text(field, "kind")
    key = with "" <- text(field, "key"), do: slug(label)

    cond do
      label == "" ->
        {:error, dgettext("errors", "has a field without a label")}

      kind not in @kinds ->
        {:error, dgettext("errors", "has a field of an unknown kind")}

      not Regex.match?(@key, key) ->
        {:error,
         dgettext(
           "errors",
           "has a field key that is not lowercase letters, digits and _ (%{key})",
           key: key
         )}

      true ->
        with {:ok, options} <- options(kind, field["options"]) do
          {:ok,
           %{
             "key" => key,
             "label" => label,
             "kind" => kind,
             "required" => field["required"] in [true, "true", "on"],
             "hint" => field |> text("hint") |> String.slice(0, 160),
             "options" => options
           }}
        end
    end
  end

  defp normalize_field(_field), do: {:error, dgettext("errors", "is not a list of fields")}

  # A choice's options come as a list or as lines of text.
  defp options("choice", options) do
    options =
      options
      |> List.wrap()
      |> Enum.flat_map(&String.split(to_string(&1), ["\n", ","]))
      |> Enum.map(&(&1 |> String.trim() |> String.slice(0, 40)))
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    cond do
      options == [] ->
        {:error, dgettext("errors", "has a choice without options")}

      length(options) > @max_options ->
        {:error, dgettext("errors", "has a choice with too many options")}

      true ->
        {:ok, options}
    end
  end

  defp options(_kind, _options), do: {:ok, []}

  @doc "A key from a label: `Naslov vesti` gives `naslov_vesti`."
  def slug(label) do
    label
    |> String.downcase()
    |> String.replace(["č", "ć"], "c")
    |> String.replace("đ", "dj")
    |> String.replace("š", "s")
    |> String.replace("ž", "z")
    |> :unicode.characters_to_nfd_binary()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
    |> then(&if(Regex.match?(~r/\A[a-z]/, &1), do: &1, else: "polje_" <> &1))
    |> String.slice(0, 30)
    |> String.trim_trailing("_")
  end

  defp text(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> String.trim(value)
      _other -> ""
    end
  end

  defp trim(value) when is_binary(value), do: String.trim(value)
  defp trim(value), do: value

  defp put_blank(changeset, field) do
    if get_field(changeset, field) == nil, do: put_change(changeset, field, ""), else: changeset
  end
end
