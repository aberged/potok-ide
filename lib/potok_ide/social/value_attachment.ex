defmodule PotokIde.Social.ValueAttachment do
  @moduledoc """
  A file attached to a chat value. The bytes live in `PotokIde.Storage` under
  `storage_key`; the row keeps what the browser reported about the file.
  """

  use Ecto.Schema

  import Ecto.Changeset

  @max_filename_length 255
  @fallback_content_type "application/octet-stream"
  @content_type_format ~r{\A[\w.+-]+/[\w.+-]+\z}
  # Raster images, audio and video are the only files shown in place: the
  # browser plays them with its own viewer and they cannot run scripts.
  @image_types ~w(image/png image/jpeg image/gif image/webp image/avif)
  @video_types ~w(video/mp4 video/webm video/ogg video/quicktime)
  @audio_types ~w(audio/mpeg audio/mp3 audio/mp4 audio/x-m4a audio/aac audio/ogg audio/opus
                  audio/wav audio/x-wav audio/wave audio/webm audio/flac audio/x-flac)

  schema "value_attachments" do
    field :storage_key, :string
    field :filename, :string
    field :content_type, :string
    field :byte_size, :integer

    belongs_to :value, PotokIde.Social.Value
    belongs_to :group, PotokIde.Social.Group
    belongs_to :profile, PotokIde.Social.Profile

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  `value_id`, `group_id`, `profile_id` and `storage_key` are set on the struct
  by the caller, never cast.
  """
  def changeset(attachment, attrs) do
    attachment
    |> cast(attrs, [:filename, :content_type, :byte_size])
    |> update_change(:filename, &clean_filename/1)
    |> update_change(:content_type, &clean_content_type/1)
    |> validate_required([:filename, :content_type, :byte_size, :storage_key])
    |> validate_number(:byte_size, greater_than_or_equal_to: 0)
    |> check_constraint(:byte_size, name: :value_attachments_byte_size_check)
    |> unique_constraint(:storage_key)
  end

  @doc """
  The file name without path separators, control characters or bidi
  overrides (which can disguise `evil.exe` as `exe.pdf`), cut to 255
  characters. Downloads use it as the suggested name.
  """
  def clean_filename(name) when is_binary(name) do
    name
    |> PotokIde.UTF8.replace_invalid()
    |> String.replace(~r/[\p{Cc}\x{202A}-\x{202E}\x{2066}-\x{2069}\/\\]/u, "_")
    |> String.trim()
    |> String.slice(0, @max_filename_length)
    |> case do
      "" -> "file"
      cleaned -> cleaned
    end
  end

  def clean_filename(_name), do: "file"

  @doc """
  A lowercase `type/subtype` without parameters, or `application/octet-stream`
  when the browser sent nothing usable.
  """
  def clean_content_type(type) when is_binary(type) do
    type =
      type
      |> String.split(";", parts: 2)
      |> hd()
      |> String.trim()
      |> String.downcase()

    if Regex.match?(@content_type_format, type), do: type, else: @fallback_content_type
  end

  def clean_content_type(_type), do: @fallback_content_type

  def image?(%__MODULE__{content_type: type}), do: type in @image_types
  def image?(type) when is_binary(type), do: type in @image_types
  def image?(_), do: false

  @doc "How the app previews the file: `:image`, `:video`, `:audio`, or `nil` (download only)."
  def media_kind(%__MODULE__{content_type: type}), do: media_kind(type)
  def media_kind(type) when type in @image_types, do: :image
  def media_kind(type) when type in @video_types, do: :video
  def media_kind(type) when type in @audio_types, do: :audio
  def media_kind(_type), do: nil

  def previewable?(attachment), do: media_kind(attachment) != nil
end
