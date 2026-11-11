defmodule PotokIde.Social.ValuePreview do
  @moduledoc """
  A chat value as one line in a list of groups: whose it is and the start of
  what it says (`Value.excerpt/2`, so a value with only files reads
  "📎 name +2", as a reply quote does). The lists read it with the page
  (`Social.last_chat_previews/1`), and new, edited and deleted values bring
  it to them in the same shape.
  """

  alias PotokIde.Social.{Value, ValueAttachment}

  @max_length 120

  @type t :: %{
          value_id: pos_integer(),
          creator_id: pos_integer(),
          author: String.t(),
          text: String.t() | nil
        }

  @doc "The preview of a value whose creator and attachments are loaded."
  @spec from_value(%Value{}) :: t()
  def from_value(%Value{creator: %{username: author}} = value) do
    %{
      value_id: value.id,
      creator_id: value.creator_id,
      author: author,
      text: Value.excerpt(value, @max_length)
    }
  end

  @doc """
  The preview from the columns `Social.last_chat_previews/1` reads: the
  value's id, creator, creator's name, content and its format, and the names
  of its files in order.
  """
  def from_columns(value_id, creator_id, author, content, format, filenames) do
    value = %Value{
      id: value_id,
      creator_id: creator_id,
      content: content,
      content_format: if(format == "html", do: :html, else: :markdown),
      attachments: Enum.map(filenames, &%ValueAttachment{filename: &1})
    }

    %{
      value_id: value_id,
      creator_id: creator_id,
      author: author,
      text: Value.excerpt(value, @max_length)
    }
  end
end
