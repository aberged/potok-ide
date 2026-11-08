defmodule PotokIdeWeb.AppFileToken do
  @moduledoc """
  A short-lived address of a file an app shows inside its frame: a form's
  answers with a picture in them. The sandboxed frame sends no session, so
  `/files/:id` would not open there. `AppApi` hands an address out only to a
  viewer who may open the file anyway (`Social.get_attachment_for_download/2`),
  and it stops working after ten minutes.
  """

  use PotokIdeWeb, :verified_routes

  alias PotokIde.Social.ValueAttachment
  alias PotokIdeWeb.Endpoint

  @salt "app file"
  @max_age 600

  def address(%ValueAttachment{id: id}) do
    url(~p"/app_files/#{Phoenix.Token.sign(Endpoint, @salt, id)}")
  end

  @doc "The id of the file a token stands for, while it is fresh."
  def verify(token), do: Phoenix.Token.verify(Endpoint, @salt, token, max_age: @max_age)
end
