defmodule PotokIdeWeb.PostTemplates do
  @moduledoc """
  The ready-made looks of a description: each has a form, and turns what the
  form holds into HTML that stands alone.

  The same templates as `templates.ts` of FeedCreator, so that a description
  made there opens here and the other way around (`Post` holds the format they
  share). `test/potok_ide_web/post_templates/post_test.exs` compares the two.
  The HTML is written once, when the form changes, so a template changed later
  reaches a description the next time it is saved. The words a template writes
  itself stay in the language of the one who saved it.

  The sanitizer decides what a template may look like: styles in the tags, no
  classes, and a colored surface sets its background and text together, as the
  theme does not reach them. See `docs/feed-i-feedcreator.md`.

  Everything with words in it is a function, so they come in the locale of the
  moment.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  alias PotokIde.Events.Format
  alias PotokIdeWeb.PostTemplates.Markup

  @max_items 10

  # Stands for a picture in a template's sample.
  @waiting_image "https://potok.invalid/picture-on-its-way"

  # A beach of colors for the pictures in the list of templates.
  @sample_image "data:image/svg+xml," <>
                  URI.encode(
                    ~s|<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 150"><rect width="320" height="150" fill="#bfdbfe"/><circle cx="250" cy="44" r="22" fill="#fde68a"/><path d="M0 110 C70 70 120 130 190 96 S300 80 320 100 V150 H0Z" fill="#2563eb"/></svg>|,
                    &URI.char_unreserved?/1
                  )

  # What sets a title apart from `.rich-content`, which underlines an h1 and an h2.
  @heading "border: none; padding: 0;"

  @free_text "text"

  def max_items, do: @max_items

  @doc "The template that is the plain editor: it has no form and leaves no trace."
  def free_text, do: @free_text

  @doc "Every template, in the order of the list."
  def templates do
    [
      %{
        id: "article",
        name: dgettext("post_templates", "News"),
        purpose: dgettext("post_templates", "Headline, intro, picture and text."),
        fields: [
          field("kicker", dgettext("post_templates", "Kicker"), :text,
            placeholder: dgettext("post_templates", "Around here")
          ),
          field("title", dgettext("post_templates", "Headline"), :text, required: true),
          field("lead", dgettext("post_templates", "Intro"), :textarea,
            hint: dgettext("post_templates", "One or two sentences that get read first.")
          ),
          field("image", dgettext("post_templates", "Picture"), :image),
          field("caption", dgettext("post_templates", "Caption"), :text),
          field("body", dgettext("post_templates", "Text"), :textarea,
            hint: dgettext("post_templates", "An empty line starts a new paragraph.")
          )
        ],
        sample: %{
          "kicker" => dgettext("post_templates", "Around here"),
          "title" => dgettext("post_templates", "The bridge over the stream has reopened"),
          "lead" => dgettext("post_templates", "After two months the works are over."),
          "image" => @waiting_image,
          "body" => dgettext("post_templates", "The works finished ahead of schedule.")
        }
      },
      %{
        id: "photo",
        name: dgettext("post_templates", "Photo"),
        purpose: dgettext("post_templates", "A big picture and a few words."),
        fields: [
          field("image", dgettext("post_templates", "Picture"), :image, required: true),
          field("title", dgettext("post_templates", "Headline"), :text, required: true),
          field("about", dgettext("post_templates", "Description"), :textarea)
        ],
        sample: %{
          "image" => @waiting_image,
          "title" => dgettext("post_templates", "Morning on the shore"),
          "about" => dgettext("post_templates", "Taken before sunrise.")
        }
      },
      %{
        id: "quote",
        name: dgettext("post_templates", "Quote"),
        purpose: dgettext("post_templates", "A sentence that fills the screen."),
        fields: [
          field("quote", dgettext("post_templates", "Quote"), :textarea, required: true),
          field("author", dgettext("post_templates", "Author"), :text),
          field("source", dgettext("post_templates", "Source"), :text)
        ],
        sample: %{
          "quote" => dgettext("post_templates", "A river carries all it is given."),
          "author" => dgettext("post_templates", "Old saying")
        }
      },
      %{
        id: "event",
        name: dgettext("post_templates", "Event"),
        purpose: dgettext("post_templates", "What, when and where."),
        fields: [
          field("title", dgettext("post_templates", "Name"), :text, required: true),
          field("date", dgettext("post_templates", "Date"), :date),
          field("time", dgettext("post_templates", "Time"), :time),
          field("place", dgettext("post_templates", "Place"), :text),
          field("about", dgettext("post_templates", "Description"), :textarea),
          field("more", dgettext("post_templates", "Link for more"), :url)
        ],
        sample: %{
          "title" => dgettext("post_templates", "Cleaning the shore"),
          "date" => "2026-11-14",
          "time" => "10:00",
          "place" => dgettext("post_templates", "By the old bridge")
        }
      },
      %{
        id: "list",
        name: dgettext("post_templates", "List"),
        purpose: dgettext("post_templates", "Numbered items, up to ten."),
        fields: [
          field("title", dgettext("post_templates", "Headline"), :text, required: true),
          field("intro", dgettext("post_templates", "Intro"), :textarea),
          field("items", dgettext("post_templates", "Items"), :items, required: true)
        ],
        sample: %{
          "title" => dgettext("post_templates", "Three things for the weekend"),
          "items" => [
            dgettext("post_templates", "Walk along the stream"),
            dgettext("post_templates", "Visit the market"),
            dgettext("post_templates", "Call on a neighbor")
          ]
        }
      },
      %{
        id: "link",
        name: dgettext("post_templates", "Link"),
        purpose: dgettext("post_templates", "A recommendation with a short description."),
        fields: [
          field("address", dgettext("post_templates", "Address"), :url,
            required: true,
            placeholder: "https://"
          ),
          field("title", dgettext("post_templates", "Headline"), :text, required: true),
          field("about", dgettext("post_templates", "Description"), :textarea),
          field("image", dgettext("post_templates", "Picture"), :image)
        ],
        sample: %{
          "address" => "https://example.com/clanak",
          "title" => dgettext("post_templates", "Worth reading"),
          "about" => dgettext("post_templates", "A short text about our area.")
        }
      },
      %{
        id: "notice",
        name: dgettext("post_templates", "Notice"),
        purpose: dgettext("post_templates", "A colored band, from plain to urgent."),
        fields: [
          field("level", dgettext("post_templates", "Importance"), :level),
          field("title", dgettext("post_templates", "Headline"), :text, required: true),
          field("body", dgettext("post_templates", "Text"), :textarea)
        ],
        sample: %{
          "level" => "important",
          "title" => dgettext("post_templates", "No water on Tuesday"),
          "body" => dgettext("post_templates", "From 8 to 12.")
        }
      },
      %{
        id: "question",
        name: dgettext("post_templates", "Question"),
        purpose: dgettext("post_templates", "Invite the members to talk."),
        fields: [
          field("question", dgettext("post_templates", "Question"), :textarea, required: true),
          field("about", dgettext("post_templates", "Addition"), :textarea)
        ],
        sample: %{
          "question" => dgettext("post_templates", "What would you change around here?"),
          "about" => dgettext("post_templates", "Let us know.")
        }
      },
      %{
        id: @free_text,
        name: dgettext("post_templates", "Free text"),
        purpose: dgettext("post_templates", "Anything else, in Markdown or HTML."),
        fields: [],
        sample: %{"source" => dgettext("post_templates", "Write as you like.")}
      }
    ]
  end

  defp field(key, label, kind, opts \\ []) do
    Map.merge(
      %{key: key, label: label, kind: kind, required: false, hint: nil, placeholder: nil},
      Map.new(opts)
    )
  end

  @doc "The template with that id, or nil."
  def template(id), do: Enum.find(templates(), &(&1.id == id))

  @doc "Whether `id` is a template with a form, which free text is not."
  def form?(id) when id == @free_text, do: false
  def form?(id), do: template(id) != nil

  @doc "The choices of a `:level` field, as a select takes them."
  def level_options do
    for level <- ~w(info important urgent), do: {level_style(level).label, level}
  end

  defp level_style("important") do
    %{
      label: dgettext("post_templates", "Important"),
      background: "#fef3c7",
      text: "#78350f",
      line: "#f59e0b"
    }
  end

  defp level_style("urgent") do
    %{
      label: dgettext("post_templates", "Urgent"),
      background: "#fee2e2",
      text: "#7f1d1d",
      line: "#dc2626"
    }
  end

  defp level_style(_info) do
    %{
      label: dgettext("post_templates", "Notice"),
      background: "#dbeafe",
      text: "#1e3a8a",
      line: "#2563eb"
    }
  end

  @doc "The labels of required fields left empty."
  def missing_fields(id, fields) do
    for %{required: true, key: key, label: label} <- template(id).fields,
        empty?(fields[key]),
        do: label
  end

  defp empty?(value) when is_binary(value), do: Markup.trim(value) == ""
  defp empty?(value) when is_list(value), do: Enum.all?(value, &empty?/1)
  defp empty?(_value), do: true

  @doc """
  The template with its sample filled in, for the list of templates. Only ever
  made from this module's own words, which is why it may skip the sanitizer
  and show a picture that would not pass it.
  """
  def thumbnail(@free_text),
    do: "<p>#{Markup.escape(template(@free_text).sample["source"])}</p>"

  def thumbnail(id) do
    id
    |> render(template(id).sample)
    |> String.replace(@waiting_image, @sample_image)
  end

  # A field holds text or a list only when a form wrote it: a description's
  # comment can be edited by hand, so anything else counts as empty.
  defp text(fields, key) do
    case fields[key] do
      value when is_binary(value) -> Markup.trim(value)
      _other -> ""
    end
  end

  defp items(fields, key) do
    case fields[key] do
      values when is_list(values) ->
        for value <- values, is_binary(value), item = Markup.trim(value), item != "", do: item

      _other ->
        []
    end
  end

  defp filled(texts), do: Enum.reject(texts, &(&1 == ""))
  defp first_filled(texts), do: texts |> filled() |> List.first("")

  defp html(parts), do: parts |> Enum.filter(&is_binary/1) |> Enum.join()

  defp picture(fields, alt) do
    case Markup.safe_image(text(fields, "image")) do
      "" -> ""
      address -> ~s|<img src="#{Markup.escape(address)}" alt="#{Markup.escape(alt)}">|
    end
  end

  defp figure(fields, alt, caption) do
    case picture(fields, alt) do
      "" ->
        ""

      image ->
        note =
          if caption == "", do: "", else: "<figcaption>#{Markup.inline(caption)}</figcaption>"

        ~s|<figure style="margin: 16px 0 0;">#{image}#{note}</figure>|
    end
  end

  @doc "The HTML of a template, without the comment that brings the form back."
  def render("article", fields) do
    kicker = text(fields, "kicker")
    title = text(fields, "title")
    lead = text(fields, "lead")

    html([
      "<article>",
      kicker != "" &&
        ~s|<p style="margin: 0 0 10px;"><span style="background-color: #1e3a8a; color: #ffffff; font-size: 13px; font-weight: bold; padding: 3px 10px; border-radius: 99px;">#{Markup.escape(kicker)}</span></p>|,
      ~s|<h1 style="#{@heading} font-size: 32px; line-height: 1.15; margin: 0;">#{Markup.escape(title)}</h1>|,
      lead != "" &&
        ~s|<p style="font-size: 19px; line-height: 1.45; font-weight: bold; margin: 12px 0 0;">#{Markup.inline(lead)}</p>|,
      figure(fields, title, text(fields, "caption")),
      Markup.paragraphs(text(fields, "body"), "margin: 14px 0 0;"),
      "</article>"
    ])
  end

  def render("photo", fields) do
    title = text(fields, "title")

    html([
      ~s|<figure style="margin: 0;">#{picture(fields, title)}</figure>|,
      ~s|<h2 style="#{@heading} font-size: 24px; line-height: 1.2; margin: 12px 0 0;">#{Markup.escape(title)}</h2>|,
      Markup.paragraphs(text(fields, "about"), "font-size: 17px; margin: 6px 0 0;")
    ])
  end

  def render("quote", fields) do
    source = [text(fields, "author"), text(fields, "source")] |> filled() |> Enum.join(", ")

    html([
      ~s|<blockquote style="background-color: #1e3a8a; color: #ffffff; border: none; border-radius: 20px; padding: 28px 24px; margin: 0;">|,
      ~s|<p style="color: #93c5fd; font-size: 60px; font-weight: bold; line-height: 0.8; margin: 0;">“</p>|,
      Markup.paragraphs(
        text(fields, "quote"),
        "font-size: 25px; font-weight: bold; line-height: 1.3; margin: 0 0 10px;",
        links: false
      ),
      source != "" &&
        ~s|<p style="color: #bfdbfe; font-size: 16px; margin: 16px 0 0;">#{Markup.escape(source)}</p>|,
      "</blockquote>"
    ])
  end

  def render("event", fields) do
    date = event_date(text(fields, "date"))
    place = text(fields, "place")
    more = Markup.safe_href(text(fields, "more"))
    moment = event_moment(fields)

    html([
      ~s|<table style="display: block; margin: 0; width: 100%;"><tbody><tr>|,
      date && date_badge(date),
      ~s|<td style="border: none; padding: 0 0 0 #{if(date, do: 16, else: 0)}px; vertical-align: middle;">|,
      ~s|<h1 style="#{@heading} font-size: 25px; line-height: 1.2; margin: 0;">#{Markup.escape(text(fields, "title"))}</h1>|,
      moment != "" &&
        ~s|<p style="font-weight: bold; margin: 6px 0 0;">#{Markup.escape(moment)}</p>|,
      place != "" && ~s|<p style="margin: 2px 0 0;">#{Markup.escape(place)}</p>|,
      "</td></tr></tbody></table>",
      Markup.paragraphs(text(fields, "about"), "margin: 16px 0 0;"),
      more != "" &&
        ~s|<p style="margin: 14px 0 0;"><a href="#{Markup.escape(more)}" target="_blank" rel="noopener">#{dgettext("post_templates", "More about the event")}</a></p>|
    ])
  end

  def render("list", fields) do
    rows =
      fields
      |> items("items")
      |> Enum.take(@max_items)
      |> Enum.with_index(1)
      |> Enum.map_join(fn {item, number} ->
        ~s|<tr><td style="background-color: transparent; border: none; color: #3b82f6; font-size: 30px; font-weight: bold; line-height: 1.1; padding: 8px 14px 8px 0; text-align: right; vertical-align: top; width: 44px;">#{number}</td><td style="background-color: transparent; border: none; font-size: 18px; line-height: 1.4; padding: 10px 0; vertical-align: top;">#{Markup.inline(item)}</td></tr>|
      end)

    html([
      ~s|<h1 style="#{@heading} font-size: 28px; line-height: 1.2; margin: 0;">#{Markup.escape(text(fields, "title"))}</h1>|,
      Markup.paragraphs(text(fields, "intro"), "margin: 10px 0 0;"),
      rows != "" &&
        ~s|<table style="display: block; margin: 10px 0 0; width: 100%;"><tbody>#{rows}</tbody></table>|
    ])
  end

  def render("link", fields) do
    address = Markup.safe_href(text(fields, "address"))
    host = Markup.host(address)
    image = picture(fields, text(fields, "title"))

    html([
      ~s|<div style="border: 1px solid #9ca3af; border-radius: 18px; padding: 16px;">|,
      image != "" && ~s|<p style="margin: 0 0 12px;">#{image}</p>|,
      host != "" &&
        ~s|<p style="font-size: 14px; font-weight: bold; margin: 0 0 4px;">#{Markup.escape(host)}</p>|,
      ~s|<h2 style="#{@heading} font-size: 24px; line-height: 1.2; margin: 0;">#{Markup.escape(text(fields, "title"))}</h2>|,
      Markup.paragraphs(text(fields, "about"), "margin: 8px 0 0;"),
      address != "" &&
        ~s|<p style="font-weight: bold; margin: 12px 0 0;"><a href="#{Markup.escape(address)}" target="_blank" rel="noopener">#{dgettext("post_templates", "Read more")}</a></p>|,
      "</div>"
    ])
  end

  def render("notice", fields) do
    level = level_style(text(fields, "level"))

    html([
      ~s|<section style="background-color: #{level.background}; color: #{level.text}; border-left: 6px solid #{level.line}; border-radius: 14px; padding: 20px;">|,
      ~s|<p style="font-size: 14px; font-weight: bold; margin: 0;">#{level.label}</p>|,
      ~s|<h1 style="#{@heading} font-size: 25px; line-height: 1.2; margin: 4px 0 0;">#{Markup.escape(text(fields, "title"))}</h1>|,
      Markup.paragraphs(text(fields, "body"), "margin: 10px 0 0;", links: false),
      "</section>"
    ])
  end

  def render("question", fields) do
    html([
      ~s|<div style="background-color: #134e4a; color: #ffffff; border-radius: 20px; padding: 32px 24px; text-align: center;">|,
      ~s|<h1 style="#{@heading} font-size: 29px; line-height: 1.25; margin: 0;">#{Markup.escape(text(fields, "question"))}</h1>|,
      Markup.paragraphs(
        text(fields, "about"),
        "color: #ccfbf1; font-size: 17px; margin: 12px 0 0;",
        links: false
      ),
      ~s|<p style="color: #99f6e4; font-size: 15px; font-weight: bold; margin: 20px 0 0;">#{dgettext("post_templates", "Reply in the chat")}</p>|,
      "</div>"
    ])
  end

  # In a div: a table cell takes no `border-radius` with `border-collapse:
  # collapse`, and the sanitizer does not know `separate`.
  defp date_badge(date) do
    short_month = date.month |> Format.month_name() |> String.slice(0, 3)

    ~s|<td style="border: none; padding: 0; vertical-align: middle; width: 76px;"><div style="background-color: #1e3a8a; color: #ffffff; border-radius: 16px; padding: 12px 8px; text-align: center;"><span style="display: block; font-size: 32px; font-weight: bold; line-height: 1;">#{date.day}</span><span style="display: block; font-size: 14px; margin-top: 4px;">#{short_month}</span></div></td>|
  end

  defp event_date(value) do
    with [_whole, year, month, day] <- Regex.run(~r/\A(\d{4})-(\d{2})-(\d{2})\z/, value),
         {:ok, date} <-
           Date.new(String.to_integer(year), String.to_integer(month), String.to_integer(day)) do
      date
    else
      _invalid -> nil
    end
  end

  defp event_moment(fields) do
    date = event_date(text(fields, "date"))
    time = text(fields, "time")

    [
      if(date,
        do:
          dgettext("post_templates", "%{weekday}, %{month} %{day}, %{year}",
            weekday: Format.weekday_name(Date.day_of_week(date)),
            month: Format.month_name(date.month),
            day: date.day,
            year: date.year
          ),
        else: ""
      ),
      if(time == "", do: "", else: dgettext("post_templates", "at %{time}", time: time))
    ]
    |> filled()
    |> Enum.join(" ")
  end

  @doc "What the card of a shared link says about a template's description."
  def card(id, fields) when id in ~w(photo question), do: text(fields, "about")

  def card("article", fields), do: first_filled([text(fields, "lead"), text(fields, "body")])

  def card("quote", fields) do
    [text(fields, "author"), text(fields, "source")] |> filled() |> Enum.join(", ")
  end

  def card("event", fields) do
    [event_moment(fields), text(fields, "place"), text(fields, "about")]
    |> filled()
    |> Enum.join(" · ")
  end

  def card("list", fields) do
    first_filled([
      text(fields, "intro"),
      fields |> items("items") |> Enum.take(@max_items) |> Enum.join(", ")
    ])
  end

  def card("link", fields) do
    first_filled([
      text(fields, "about"),
      fields |> text("address") |> Markup.safe_href() |> Markup.host()
    ])
  end

  def card("notice", fields) do
    [level_style(text(fields, "level")).label, text(fields, "body")]
    |> filled()
    |> Enum.join(": ")
  end
end
