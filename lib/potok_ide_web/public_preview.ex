defmodule PotokIdeWeb.PublicPreview do
  @moduledoc """
  What a guest gets at the link of a public group or event, instead of the
  redirect to the log-in page: a small page with what the link is about. Its
  meta tags are what other sites and apps read to show the link as a card.

  It takes every guest rather than known crawlers, so there is no list of them
  to keep up, and whoever opens a card sees what it promised. Every other link
  goes on to `require_authenticated_account`, so a guest cannot tell a private
  group from one that does not exist.

  Guests get a name, a picture and a piece of the description, unless the
  group opened its description to them (`Group.guest_description?/1`): then
  they read that and the alternative descriptions marked for them
  (`PotokIdeWeb.GuestDescriptions`), text on this plain page, an app in a
  small LiveView of its own (`PotokIdeWeb.GroupLive.GuestApp`). The meta tags
  stay the card's either way. Chats, members and the rest of the group stay
  behind the login.

  A link into an app that names one of its groups (`?at=`, such as a story of
  a feed) gets the card of that group, with the app's name over its title and
  the app's mark on its picture, where guests reach the group through the app
  (`linked_groups/2`). Anything else the link names gets the app's own card.
  """

  use PotokIdeWeb, :verified_routes
  use Gettext, backend: PotokIdeWeb.Gettext

  import Phoenix.Controller, only: [current_path: 1, put_view: 2, render: 3]
  import Plug.Conn

  alias PotokIde.Events
  alias PotokIde.Events.{Event, Format, Recurrence}
  alias PotokIde.LinkCards
  alias PotokIde.LinkPreviews
  alias PotokIde.PlainText
  alias PotokIde.Social
  alias PotokIde.Social.Group
  alias PotokIdeWeb.GroupLive.GuestApp
  alias PotokIdeWeb.GuestDescriptions
  alias PotokIdeWeb.Locale

  @description_length 200
  @site_name_length 40
  # The largest id Postgres takes; asking for a larger one would raise.
  @max_id 9_223_372_036_854_775_807

  def init(opts), do: opts

  def call(%{method: "GET", path_info: ["groups" | path]} = conn, _opts) do
    case guest?(conn) && preview(path, conn.query_params) do
      {template, assigns} ->
        conn
        |> put_session(:account_return_to, current_path(conn))
        |> put_view(html: PotokIdeWeb.PageHTML)
        |> render_preview(template, assigns)
        |> halt()

      _ ->
        conn
    end
  end

  def call(conn, _opts), do: conn

  @doc """
  What a guest would see at `url`, a link to Potok, as a link preview for a chat
  (`PotokIde.LinkPreviews`): `{:ok, preview}`, or `:error` where a guest is sent
  to log in. In the default language, as everybody in the chat reads the same one.
  """
  def link_preview(url) when is_binary(url) do
    %URI{path: path, query: query} = URI.parse(url)

    Gettext.with_locale(PotokIdeWeb.Gettext, Locale.default_locale(), fn ->
      with ["groups" | rest] <- String.split(path || "", "/", trim: true),
           {_template, assigns} <- preview(rest, URI.decode_query(query || "")) do
        {:ok,
         %{
           "url" => url,
           "title" => assigns[:page_title],
           "description" => assigns[:page_description],
           "site_name" => assigns[:page_site_name] || "Potok",
           "image_url" => assigns[:page_image]
         }}
      else
        _ -> :error
      end
    end)
  end

  defp guest?(%{assigns: %{current_scope: %{account: %{}}}}), do: false
  defp guest?(_conn), do: true

  # A group that opened its description to guests shows it instead of the
  # card. An app runs in a LiveView of its own, which the route's live_session
  # must not reach: its first render would run the session's log-in check
  # (`Phoenix.LiveView.Static`) and send the guest to log in.
  defp render_preview(conn, :public_group, assigns) do
    case guest_page(assigns, conn) do
      nil ->
        render(conn, :public_group, [{:page_noindex, true} | assigns])

      page ->
        conn
        |> put_private(:phoenix_live_view, nil)
        |> then(&if(page.app_session, do: assign(&1, :live_module, GuestApp), else: &1))
        |> render(:public_group_page, [{:page_noindex, true}, {:guest, page} | assigns])
    end
  end

  defp render_preview(conn, template, assigns),
    do: render(conn, template, [{:page_noindex, true} | assigns])

  # The group of the link, or, for a link into an app (`?at=`) whose group
  # keeps its description from guests, the group the link stands for. Only
  # the groups the preview found count, so a link opens no other.
  defp guest_page(assigns, conn) do
    case assigns[:app_group] do
      %Group{} = app ->
        page_of(app, conn.query_params, conn) || page_of(assigns[:group], %{}, conn)

      nil ->
        page_of(assigns[:group], conn.query_params, conn)
    end
  end

  defp page_of(%Group{} = group, query, conn) do
    with [_ | _] = entries <- GuestDescriptions.entries(group),
         entry = GuestDescriptions.pick(entries, group, query["d"]),
         source when not is_nil(source) <- GuestDescriptions.source(group, entry) do
      %{
        group: group,
        entries: entries,
        entry: entry,
        source: source,
        app_session: app_session(group, entry, conn)
      }
    else
      _ -> nil
    end
  end

  defp page_of(_group, _query, _conn), do: nil

  defp app_session(_group, %{uses_api: false}, _conn), do: nil

  defp app_session(%Group{} = group, entry, conn),
    do: %{"group_id" => group.id, "alt_id" => entry.id, "client" => client_key(conn)}

  # The guest's address, hashed, for the limit on what one address asks of the
  # apps: the session is signed, not hidden, and sits in the page.
  defp client_key(%Plug.Conn{remote_ip: ip}) when is_tuple(ip) do
    ip
    |> :inet.ntoa()
    |> to_string()
    |> then(&:crypto.hash(:sha256, &1))
    |> binary_part(0, 12)
    |> Base.url_encode64(padding: false)
  end

  defp client_key(_conn), do: nil

  # A calendar link names its event whatever group it goes through: the root's
  # calendar shows the events of every group.
  defp preview([group_id, "calendar"], %{"event" => event_id}),
    do: event_preview(event_id) || group_preview(group_id)

  # A link into an app stands for the group it opens on (`shareGroup`), and so
  # does the address the app writes on the page (`linkGroup`), which has no tab
  # where the group opens on the app.
  defp preview([group_id, "group_home"], %{"at" => item_id} = query),
    do: linked_preview(group_id, item_id, query, :tab) || group_preview(group_id)

  defp preview([group_id], %{"at" => item_id} = query),
    do: linked_preview(group_id, item_id, query, :home) || group_preview(group_id)

  defp preview([group_id], _query), do: group_preview(group_id)
  defp preview([group_id, _tab], _query), do: group_preview(group_id)
  defp preview(_path, _query), do: nil

  defp group_preview(id) do
    with id when is_integer(id) <- parse_id(id),
         %Group{} = group <- Social.get_public_group(id) do
      {:public_group,
       group: group,
       page_title: group.name,
       page_description: group_description(group),
       page_image: group_image(group),
       page_url: url(~p"/groups/#{group.id}")}
    else
      _ -> nil
    end
  end

  # The card of the group a link into an app names, with the app's name and
  # mark. On the page's own address, only where the page opens on the app
  # (`GroupLive.Show`'s first tab). The address keeps its query, as on an
  # event's card, or a site that reads it again would show the card of the
  # app, and always names the tab, wherever the link came from.
  defp linked_preview(app_id, item_id, query, via) do
    with {app, item} <- linked_groups(app_id, item_id),
         true <- via == :tab or app.home_page == :description do
      {:public_group,
       group: item,
       app_group: app,
       page_title: item.name,
       page_description: group_description(item),
       page_image: linked_image(item, app),
       page_site_name: site_name(app),
       page_url: url(~p"/groups/#{app.id}/group_home?#{Map.take(query, ["d", "at"])}")}
    else
      _ -> nil
    end
  end

  @doc """
  The group of an app and the group a link into it names (`?at=`), as
  `{app, item}`: both seen by guests, the item one of the app's sub-groups or
  a group under one, as an app reaches them
  (`Social.get_visible_child_or_grandchild_group/3`). nil for anything else,
  so a link cannot put the app's mark on another group.
  """
  def linked_groups(app_id, item_id) do
    with app_id when is_integer(app_id) <- parse_id(app_id),
         item_id when is_integer(item_id) <- parse_id(item_id),
         %Group{} = app <- Social.get_public_group(app_id),
         %Group{} = item <- Social.get_visible_child_or_grandchild_group(app, nil, item_id),
         true <- Group.guest_preview?(item) do
      {app, item}
    else
      _ -> nil
    end
  end

  # The small line over the title of a card: the app's name, then Potok.
  defp site_name(%Group{name: name}) do
    case name |> to_string() |> String.replace(~r/\s+/u, " ") |> String.trim() do
      "" -> "Potok"
      name -> PlainText.truncate(name, @site_name_length) <> " · Potok"
    end
  end

  defp group_description(%Group{} = group), do: group_text(group) || default_description(group)

  @doc """
  What the card of `group` says under its name: a piece of its description,
  what an app says about itself, or what it is.
  """
  def card_text(%Group{} = group), do: group_description(group)

  defp default_description(%Group{uses_api: true}), do: gettext("An app on Potok.")
  defp default_description(%Group{}), do: gettext("A group on Potok.")

  @doc "Whether the card of `group` says something of its own, not only what it is."
  def describes_itself?(%Group{} = group), do: group_text(group) != nil

  # The description of a group with the API on is the code of an app, so its
  # card only says what the app says about itself, in the meta tags of any page.
  # HTML of any group can do that too, when its first lines are not a summary.
  defp group_text(%Group{uses_api: true} = group), do: own_description(group)

  defp group_text(%Group{description_format: :html} = group),
    do: own_description(group) || description_excerpt(group)

  defp group_text(%Group{} = group), do: description_excerpt(group)

  # The card shows the name above this text.
  defp description_excerpt(%Group{} = group) do
    PlainText.excerpt(
      group.description || "",
      group.description_format,
      @description_length,
      without_heading: group.name
    )
  end

  @doc "What a description says about itself in its meta tags, as plain text. Scripts never run."
  def own_description(%Group{} = group) do
    case LinkPreviews.parse(group.description || "", url(~p"/groups/#{group.id}")) do
      {:ok, %{"description" => description}} when is_binary(description) ->
        PlainText.truncate(description, @description_length)

      _ ->
        nil
    end
  end

  defp group_image(%Group{} = group) do
    version = group |> LinkCards.group_card() |> LinkCards.version()

    url(~p"/cards/group/#{"#{group.id}.jpg"}?#{[v: version]}")
  end

  # The card of `item` with the mark of `app`, served where the link is checked
  # again (`PotokIdeWeb.CardController.linked/2`).
  defp linked_image(%Group{} = item, %Group{} = app) do
    version = item |> LinkCards.linked_card(app) |> LinkCards.version()

    url(~p"/cards/group/#{app.id}/#{"#{item.id}.jpg"}?#{[v: version]}")
  end

  defp event_image(%Event{} = event) do
    version = event |> LinkCards.event_card() |> LinkCards.version()

    url(~p"/cards/event/#{"#{event.id}.jpg"}?#{[v: version]}")
  end

  defp event_preview(id) do
    with id when is_integer(id) <- parse_id(id),
         %Event{} = event <- Events.get_public_event(id) do
      time = event_time(event)
      recurrence = Format.recurrence(event)
      location = String.trim(event.location)
      description = PlainText.excerpt(event.description, :markdown, @description_length)

      {
        :public_event,
        # With its query: Facebook reads this address again, and without the
        # event it would show the card of the group.
        event: event,
        time: time,
        recurrence: recurrence,
        location: location,
        description: description,
        page_title: event.title,
        page_description:
          [time, recurrence, location, description]
          |> Enum.reject(&(&1 in [nil, ""]))
          |> Enum.join(" · "),
        page_image: event_image(event),
        page_url: url(~p"/groups/#{event.group_id}/calendar?#{[event: event.id]}")
      }
    else
      _ -> nil
    end
  end

  # The next occurrence, or the first one of a series that is over. Guests have
  # no zone of their own here, so the time is the event's.
  defp event_time(%Event{} = event) do
    now = DateTime.utc_now(:second)

    Format.occurrence(
      Recurrence.next_or_first(event, now),
      event.time_zone,
      Recurrence.local_date(now, event.time_zone)
    )
  end

  @doc "The id of a group or event in a link, nil for what cannot be one."
  def parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {id, ""} when id in 1..@max_id -> id
      _ -> nil
    end
  end

  def parse_id(_id), do: nil
end
