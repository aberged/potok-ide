defmodule PotokIde.Social.ScheduledValue do
  @moduledoc """
  A message a profile wrote in a group to go out later
  (`PotokIde.Social.ScheduledValues`). It is seen by those who use the profile
  and nobody else, and it is gone once it is sent or cancelled: what was sent
  is an ordinary `PotokIde.Social.Value`.

  `files` are already in `PotokIde.Storage` and belong to this row until the
  message takes them over, so whoever deletes the row deletes them too
  (`storage_keys/1`).
  """
  use Ecto.Schema

  import Ecto.Changeset

  alias PotokIde.Events.Recurrence
  alias PotokIde.PlainText

  @failures [:late, :not_permitted, :error]
  @max_days_ahead 366

  schema "scheduled_values" do
    # Kept out of logs: nobody else reads it until it goes out.
    field :content, :string, default: "", redact: true
    # `%{"storage_key", "filename", "content_type", "byte_size"}`; read them
    # with `attachments/1`.
    field :files, {:array, :map}, default: []
    field :send_at, :utc_datetime
    # Why it did not go out at its time. One that failed waits for its author,
    # who sends it, gives it another time or deletes it.
    field :failure, Ecto.Enum, values: @failures

    # The time of the form, in the viewer's zone.
    field :send_local, :naive_datetime, virtual: true

    belongs_to :group, PotokIde.Social.Group
    belongs_to :profile, PotokIde.Social.Profile
    belongs_to :parent, PotokIde.Social.Value

    timestamps(type: :utc_datetime)
  end

  def failures, do: @failures
  def max_days_ahead, do: @max_days_ahead

  @doc "The time alone, as the dialog before the message is written asks it."
  def time_changeset(%__MODULE__{} = scheduled, attrs, time_zone) do
    scheduled
    |> cast(attrs, [:send_local])
    |> validate_required([:send_local])
    |> put_send_at(time_zone)
  end

  @doc """
  The text and the time of a message that waits. One that failed needs a new
  time, and then waits again.
  """
  def changeset(%__MODULE__{} = scheduled, attrs, time_zone) do
    scheduled
    |> cast(attrs, [:content, :send_local])
    |> validate_content()
    |> validate_required([:send_local])
    |> put_send_at(time_zone)
    |> put_change(:failure, nil)
  end

  @doc "A new row; the profile, the group and the files are set on the struct, never cast."
  def insert_changeset(%__MODULE__{} = scheduled, attrs, %DateTime{} = send_at) do
    scheduled
    |> cast(attrs, [:content, :parent_id])
    |> validate_content()
    |> put_change(:send_at, send_at)
    |> foreign_key_constraint(:parent_id)
    |> foreign_key_constraint(:group_id)
  end

  @doc "Fills `send_local` from `send_at`, for the form."
  def with_form_fields(%__MODULE__{send_at: %DateTime{} = send_at} = scheduled, time_zone) do
    local = send_at |> DateTime.shift_zone!(time_zone) |> DateTime.to_naive()
    %{scheduled | send_local: local}
  end

  @doc "`:ok`, or why a message cannot wait for `send_at`: `:past` or `:too_far`."
  def check_time(%DateTime{} = send_at, now \\ DateTime.utc_now(:second)) do
    cond do
      DateTime.compare(send_at, now) != :gt -> :past
      DateTime.diff(send_at, now, :day) > @max_days_ahead -> :too_far
      true -> :ok
    end
  end

  @doc "The files as `PotokIde.Social` takes attachments."
  def attachments(%__MODULE__{files: files}) do
    Enum.map(files, fn file ->
      %{
        storage_key: file["storage_key"],
        filename: file["filename"],
        content_type: file["content_type"],
        byte_size: file["byte_size"]
      }
    end)
  end

  @doc "The keys of the files in storage, of one row's `files` or of many."
  def storage_keys(files) when is_list(files),
    do: files |> List.flatten() |> Enum.map(& &1["storage_key"])

  @doc "The text as one line, or the name of the first file when there is none."
  def excerpt(scheduled, max_length \\ 120)

  def excerpt(%__MODULE__{content: content, files: files}, max_length) do
    PlainText.excerpt(content, :markdown, max_length) || files_summary(files, max_length)
  end

  defp files_summary([], _max_length), do: ""

  defp files_summary([first | rest], max_length) do
    more = if rest == [], do: "", else: " +#{length(rest)}"
    PlainText.truncate("📎 " <> first["filename"], max_length) <> more
  end

  # A message needs text or at least one file; the column is NOT NULL, and
  # casting "" yields nil.
  defp validate_content(changeset) do
    cond do
      get_field(changeset, :files) == [] -> validate_required(changeset, [:content])
      is_nil(get_field(changeset, :content)) -> put_change(changeset, :content, "")
      true -> changeset
    end
  end

  defp put_send_at(changeset, time_zone) do
    case get_field(changeset, :send_local) do
      %NaiveDateTime{} = local ->
        send_at =
          Recurrence.to_utc(NaiveDateTime.to_date(local), NaiveDateTime.to_time(local), time_zone)

        case check_time(send_at) do
          :ok -> put_change(changeset, :send_at, send_at)
          :past -> add_error(changeset, :send_local, "must be in the future")
          :too_far -> add_error(changeset, :send_local, "must be within a year")
        end

      nil ->
        changeset
    end
  end
end
