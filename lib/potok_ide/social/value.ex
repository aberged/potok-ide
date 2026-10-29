defmodule PotokIde.Social.Value do
  use Ecto.Schema

  import Ecto.Changeset

  alias PotokIde.UTF8

  @content_formats [:markdown, :html]

  schema "values" do
    field :content, :string
    field :content_format, Ecto.Enum, values: @content_formats, default: :markdown
    field :is_data, :boolean, default: false
    field :data, :map
    # Set from the content by `Social.Mentions`, never cast: the handles that
    # resolved (`%{"profiles" => [...], "roles" => [...]}`, lowercased) and the
    # members they reached.
    field :mentions, :map, default: %{}
    field :mentioned_profile_ids, {:array, :id}, default: []

    belongs_to :creator, PotokIde.Social.Profile
    belongs_to :group, PotokIde.Social.Group

    belongs_to :parent, __MODULE__
    has_many :children, __MODULE__, foreign_key: :parent_id
    has_many :reactions, PotokIde.Social.ValueReaction
    # The sub-group started from this value (`Social.get_or_create_value_thread/4`).
    has_one :thread, PotokIde.Social.Group, foreign_key: :parent_value_id

    timestamps(type: :utc_datetime)
  end

  def changeset(value, attrs) do
    attrs =
      attrs
      |> normalize_data_attr()
      |> normalize_content_attr()

    value
    |> cast(attrs, [
      :content,
      :content_format,
      :is_data,
      :data,
      :creator_id,
      :group_id,
      :parent_id
    ])
    |> validate_required([:content_format, :creator_id, :group_id])
    |> validate_content_required()
    |> check_constraint(:content_format, name: :values_content_format_check)
  end

  def changeset_for_update(value, attrs) do
    attrs =
      attrs
      |> normalize_data_attr()
      |> normalize_content_attr()

    value
    |> cast(attrs, [
      :content,
      :content_format,
      :is_data,
      :data,
      :creator_id,
      :group_id,
      :parent_id
    ])
    |> validate_required([:content_format, :creator_id, :group_id])
    |> check_constraint(:content_format, name: :values_content_format_check)
  end

  @doc """
  The value's content as one line of plain text, for reply quotes and thread
  names: markdown syntax and html tags are stripped, whitespace is collapsed
  and the text is cut to `max_length` characters. Returns nil when nothing
  readable is left.
  """
  def excerpt(value, max_length \\ 120)

  def excerpt(%__MODULE__{content: content, content_format: format}, max_length)
      when is_binary(content) and is_integer(max_length) and max_length > 1 do
    content
    |> UTF8.replace_invalid()
    |> plain_text(format)
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> truncate(max_length)
  end

  def excerpt(_value, _max_length), do: nil

  defp plain_text(html, :html) do
    html
    |> String.replace(~r{<(script|style)\b[^>]*>.*?</\1\s*>}isu, " ")
    # Block boundaries would otherwise glue neighbouring words together.
    |> String.replace(~r{<(?:br|/p|/div|/li|/h[1-6]|/tr|/blockquote)\b[^>]*>}iu, " ")
    |> HtmlSanitizeEx.strip_tags()
    |> decode_html_entities()
  end

  defp plain_text(markdown, _format) do
    markdown
    |> String.replace(~r/!\[([^\]]*)\]\([^)]*\)/u, "\\1")
    |> String.replace(~r/\[([^\]]+)\]\([^)]*\)/u, "\\1")
    |> String.replace(~r/^[ \t]*(?:#+|>+|[-*+]|\d+[.)])[ \t]+/mu, "")
    |> String.replace(~r/\*\*|__|~~|`+/u, "")
  end

  defp decode_html_entities(text) do
    text
    |> String.replace("&nbsp;", " ")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace(["&#39;", "&#x27;", "&apos;"], "'")
    |> String.replace("&amp;", "&")
  end

  defp truncate("", _max_length), do: nil

  defp truncate(text, max_length) do
    if String.length(text) <= max_length do
      text
    else
      String.trim_trailing(String.slice(text, 0, max_length - 1)) <> "…"
    end
  end

  defp validate_content_required(changeset) do
    if get_field(changeset, :is_data) do
      changeset
    else
      validate_required(changeset, [:content])
    end
  end

  defp normalize_data_attr(attrs) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, "data") -> Map.update!(attrs, "data", &decode_data_value/1)
      Map.has_key?(attrs, :data) -> Map.update!(attrs, :data, &decode_data_value/1)
      true -> attrs
    end
  end

  defp normalize_data_attr(attrs), do: attrs

  defp normalize_content_attr(attrs) when is_map(attrs) do
    cond do
      Map.has_key?(attrs, "content") -> Map.update!(attrs, "content", &UTF8.replace_invalid/1)
      Map.has_key?(attrs, :content) -> Map.update!(attrs, :content, &UTF8.replace_invalid/1)
      true -> attrs
    end
  end

  defp normalize_content_attr(attrs), do: attrs

  defp decode_data_value(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" ->
        nil

      true ->
        case Jason.decode(trimmed) do
          {:ok, decoded} when is_map(decoded) -> decoded
          _ -> value
        end
    end
  end

  defp decode_data_value(value), do: value
end
