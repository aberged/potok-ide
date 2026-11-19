defmodule PotokIdeWeb.FormLinks do
  @moduledoc """
  The card of a link to a form, a group made from the Form preset while it
  still runs the app (`GroupPresets.shown/1`), under a chat value or a notice
  (`PotokIde.LinkPreviews`): the form's own title and subtitle from its config
  (`AppData.get_config/2`), with the group's picture and the kind's mark.

  A guest's card (`PotokIdeWeb.PublicPreview`) is made only for a group guests
  see. A form's card is made whoever may see the form, and `"open"` says
  whether everyone may: a form that takes non-members in a public group
  ("Javna forma"), whose config anyone reads, as the app shows it to them.
  Any other is shown only to the form's members (`LinkPreviews.visible/2`),
  the others seeing at most `"guest"`, the card a guest would get.
  """

  alias PotokIde.PlainText
  alias PotokIde.Social
  alias PotokIde.Social.{AppData, Group, GroupPresets}
  alias PotokIdeWeb.{Avatars, PublicPreview}

  @kind :questionnaire
  @title_length 200
  @description_length 200

  @doc """
  `{:ok, card}` for a link to a form's own page (`/groups/<id>`, with a tab or
  without), `:error` for anything else. A link into an app (`?at=`) stands
  for the group the app opens, so it is never a form's.

  The card is `%{"url", "kind", "group_id", "title", "description",
  "image_url", "open"}`, the description nil when the form has none.
  """
  def card(url) when is_binary(url) do
    %URI{path: path, query: query} = URI.parse(url)

    with ["groups", id | rest] when length(rest) <= 1 <-
           String.split(path || "", "/", trim: true),
         false <- Map.has_key?(URI.decode_query(query || ""), "at"),
         id when is_integer(id) <- PublicPreview.parse_id(id),
         %Group{} = group <- Social.get_linked_group(id),
         @kind <- GroupPresets.shown(group) do
      config = AppData.get_config(group, nil)
      form = form(config)

      {:ok,
       %{
         "url" => url,
         "kind" => Atom.to_string(@kind),
         "group_id" => group.id,
         "title" => text(form["title"], @title_length) || name(group),
         "description" => text(form["description"], @description_length),
         "image_url" => Avatars.group_avatar_url(group),
         "open" => AppData.public_config?(config, group)
       }}
    else
      _ -> :error
    end
  end

  # The form as the app saved it (`potok-forme`, `model/config.ts`).
  defp form(%{data: %{"form" => %{} = form}}), do: form
  defp form(_config), do: %{}

  # The app's own small markup (`model/rich.ts`) is close to Markdown, but for
  # `*italic*`, which `PlainText` leaves as it is.
  defp text(source, max_length) when is_binary(source) do
    source
    |> String.replace(~r/(?<![*\w])\*(?=\S)([^*\n]*?\S)\*(?![*\w])/u, "\\1")
    |> PlainText.excerpt(:markdown, max_length)
  end

  defp text(_source, _max_length), do: nil

  defp name(%Group{name: name}) do
    name
    |> to_string()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
    |> PlainText.truncate(@title_length)
  end
end
