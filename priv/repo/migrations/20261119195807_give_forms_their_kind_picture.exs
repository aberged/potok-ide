defmodule PotokIde.Repo.Migrations.GiveFormsTheirKindPicture do
  use Ecto.Migration

  # A group made from a preset starts with its kind's picture
  # (`GroupPresets.picture/1`). Forms made before that get the Form's too,
  # unless they have a picture of their own; other kinds keep their initials.
  # `updated_at` moves, as it is the version in the picture's address that
  # browsers keep. Without the file there is nothing to give, as in a new
  # database, which has no forms either.
  def up do
    case File.read(Application.app_dir(:potok_ide, "priv/kinds/questionnaire.png")) do
      {:ok, png} ->
        repo().query!(
          """
          UPDATE groups
          SET group_picture_url = $1, updated_at = now() AT TIME ZONE 'UTC'
          WHERE preset = 'questionnaire' AND coalesce(btrim(group_picture_url), '') = ''
          """,
          ["data:image/png;base64," <> Base.encode64(png)]
        )

      {:error, _reason} ->
        :ok
    end
  end

  # Which pictures were given here is not kept: they stay.
  def down, do: :ok
end
