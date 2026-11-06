defmodule PotokIdeWeb.PostTemplates.Picture do
  @moduledoc """
  The address of a chat file used as a picture in a description.

  `/files/:id` asks for a session and membership, and a description is seen by
  more people than that: non-members of a public group, and everyone reading
  it inside an app's sandboxed frame, which sends no session. So the address is
  signed instead, and whoever got it from a description sees that one picture.
  It keeps working until the message with the file is deleted.

  The signature comes from `secret_key_base`, so changing that key breaks every
  address stored in a description.
  """

  use PotokIdeWeb, :verified_routes

  alias PotokIde.Social.ValueAttachment
  alias PotokIdeWeb.Endpoint

  @salt "description picture"

  @doc """
  A full address, not a path: FeedCreator only lets through addresses on the
  web, so a description saved there keeps the picture.
  """
  def address(%ValueAttachment{id: id}) do
    url(~p"/pictures/#{Phoenix.Token.sign(Endpoint, @salt, id)}")
  end

  @doc "The id of the file an address' token stands for."
  def verify(token), do: Phoenix.Token.verify(Endpoint, @salt, token, max_age: :infinity)
end
