defmodule PotokIdeWeb.MessageLinks do
  @moduledoc """
  The card of a link to a chat message (`/groups/<id>/values?value=<id>`,
  "Link poruke") under a chat value (`PotokIde.LinkPreviews`).

  The value with the link keeps only which message it names (`ref/1`),
  never its text, author or files: a private message is never copied into
  another group, and the card follows the message as it is now. The chat's
  page reads the messages its cards name for each viewer
  (`PotokIde.Social.readable_linked_values/2`) and draws `card/3` for those
  the viewer may read. The others see `"guest"`, the card a guest gets of a
  public group, or only the link.
  """

  alias PotokIde.PlainText
  alias PotokIde.Social
  alias PotokIde.Social.{Value, ValueAttachment}
  alias PotokIdeWeb.{Avatars, PublicPreview}
  alias PotokIdeWeb.GroupLive.Show.Components

  @kind "message"
  @text_length 300
  @files_length 120

  @doc """
  `{:ok, ref}` for a link to a chat message of a group (`/groups/<id>` or
  `/groups/<id>/values`, with `?value=<id>`), whoever may read it, `:error`
  for anything else. The ref is `%{"url", "kind" => "message", "group_id",
  "value_id"}`.
  """
  def ref(url) when is_binary(url) do
    %URI{path: path, query: query} = URI.parse(url)

    with ["groups", id | rest] when rest in [[], ["values"]] <-
           String.split(path || "", "/", trim: true),
         %{"value" => value_param} <- URI.decode_query(query || ""),
         group_id when is_integer(group_id) <- PublicPreview.parse_id(id),
         value_id when is_integer(value_id) <- PublicPreview.parse_id(value_param),
         true <- Social.linked_chat_value?(group_id, value_id) do
      {:ok, %{"url" => url, "kind" => @kind, "group_id" => group_id, "value_id" => value_id}}
    else
      _ -> :error
    end
  end

  @doc "The message a kept card names, or nil for any other card."
  def value_id(%{"kind" => @kind, "value_id" => value_id}) when is_integer(value_id),
    do: value_id

  def value_id(_preview), do: nil

  @doc """
  What the card of a link to `value` shows `viewer`, who may read it: the
  group (a direct conversation by the other side's name), the author, when
  it was written, its text and, where `picture?`, its first picture, shown
  through `/files` as in the chat.
  """
  def card(%Value{} = value, picture?, viewer) do
    picture = if picture?, do: Enum.find(value.attachments, &picture?/1)
    text = PlainText.excerpt(value.content, value.content_format, @text_length)

    %{
      value_id: value.id,
      group_id: value.group_id,
      path: "/groups/#{value.group_id}/values?value=#{value.id}",
      group_name: Components.group_identity_name(value.group, viewer),
      author: value.creator,
      avatar_url: Avatars.profile_avatar_url(value.creator),
      at: value.inserted_at,
      text: text || if(is_nil(picture), do: Value.attachment_summary(value, @files_length)),
      picture_id: picture && picture.id
    }
  end

  defp picture?(%ValueAttachment{} = attachment),
    do: ValueAttachment.media_kind(attachment) == :image
end
