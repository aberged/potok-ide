defmodule PotokIde.Social.Value do
  use Ecto.Schema

  import Ecto.Changeset

  alias PotokIde.PlainText
  alias PotokIde.UTF8

  @content_formats [:markdown, :html]
  @outsider_max_content_length 4_000

  schema "values" do
    field :content, :string
    field :content_format, Ecto.Enum, values: @content_formats, default: :markdown
    field :is_data, :boolean, default: false
    field :data, :map
    # The collection of an app's data value and what goes with it, all set by
    # `PotokIde.Social.AppData`, never cast: nil for chat values and for app
    # values written without one. `anonymous` is fixed when the value is
    # written, `lock_version` counts in-place updates and `managed` holds
    # what the server and the app's editors add (a quiz score, grades).
    field :collection, :string
    field :anonymous, :boolean, default: false
    field :lock_version, :integer, default: 0
    field :managed, :map
    # Set from the content by `Social.Mentions`, never cast: the handles that
    # resolved (`%{"profiles" => [...], "roles" => [...]}`, lowercased) and the
    # members they reached.
    field :mentions, :map, default: %{}
    field :mentioned_profile_ids, {:array, :id}, default: []
    # Set by `Social` after the first link's page is fetched, never cast:
    # `%{"url", "title", "description", "site_name", "image_url"}`. The
    # author can dismiss it, and then it is never fetched again.
    field :link_preview, :map
    field :link_preview_dismissed, :boolean, default: false
    # The tags the viewing profile sees (`PotokIde.Tags.put_tags/3`): the
    # public ones and its own private ones.
    field :tags, {:array, :any}, virtual: true, default: []
    # What the viewing profile sees of the value's poll (`Polls.put_views/5`).
    field :poll_view, :any, virtual: true

    belongs_to :creator, PotokIde.Social.Profile
    belongs_to :group, PotokIde.Social.Group
    # The app a data value belongs to: nil for the default description's app.
    # Set by `Social.create_data_value/4`, never cast.
    belongs_to :alt_description, PotokIde.Social.GroupAltDescription

    belongs_to :parent, __MODULE__
    has_many :children, __MODULE__, foreign_key: :parent_id
    has_many :reactions, PotokIde.Social.ValueReaction
    has_many :attachments, PotokIde.Social.ValueAttachment
    # The sub-group started from this value (`Social.get_or_create_value_thread/4`).
    has_one :thread, PotokIde.Social.Group, foreign_key: :parent_value_id
    # The calendar event this value announced (`Social.post_announcement/6`).
    has_one :event, PotokIde.Events.Event, foreign_key: :value_id
    # The poll this value carries, gone with it.
    has_one :poll, PotokIde.Polls.Poll, foreign_key: :value_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  With `attachments?: true` the value carries files, so its text may be empty.
  """
  def changeset(value, attrs, opts \\ []) do
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
    |> validate_content_required(Keyword.get(opts, :attachments?, false))
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
  What a value from someone outside the group may hold, in an open chat: never
  html, which reaches the page itself in an app group, and not much of it.
  """
  def outsider_changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> put_change(:content_format, :markdown)
    |> validate_length(:content, max: @outsider_max_content_length)
  end

  @doc """
  The value's content as one line of plain text, for reply quotes and thread
  names: markdown syntax and html tags are stripped, whitespace is collapsed
  and the text is cut to `max_length` characters. A value with no readable
  text falls back to `attachment_summary/2`; nil when that is empty too.
  """
  def excerpt(value, max_length \\ 120)

  def excerpt(%__MODULE__{content: content, content_format: format} = value, max_length)
      when is_binary(content) and is_integer(max_length) and max_length > 1 do
    PlainText.excerpt(content, format, max_length) || attachment_summary(value, max_length)
  end

  def excerpt(_value, _max_length), do: nil

  @doc """
  "📎 report.pdf +2" for a value with loaded attachments, cut to `max_length`
  characters; nil when it has none or they are not loaded.
  """
  def attachment_summary(%__MODULE__{attachments: [first | rest]}, max_length)
      when is_integer(max_length) and max_length > 1 do
    more = if rest == [], do: "", else: " +#{length(rest)}"
    name_length = max(max_length - String.length(more), 2)

    PlainText.truncate("📎 " <> first.filename, name_length) <> more
  end

  def attachment_summary(_value, _max_length), do: nil

  # The column is NOT NULL, and casting "" yields nil, so a value that only
  # carries files stores "" explicitly.
  defp validate_content_required(changeset, attachments?) do
    cond do
      get_field(changeset, :is_data) ->
        changeset

      attachments? and get_field(changeset, :content) == nil ->
        put_change(changeset, :content, "")

      attachments? ->
        changeset

      true ->
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
