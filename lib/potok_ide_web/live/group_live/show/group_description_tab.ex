defmodule PotokIdeWeb.GroupLive.Show.GroupDescriptionTab do
  use PotokIdeWeb, :html

  alias PotokIde.Social
  alias PotokIde.Social.{Group, GroupAreas}
  alias PotokIdeWeb.Distance
  alias PotokIdeWeb.GroupLive.Show.{AppApi, AppHost, Components}
  alias PotokIdeWeb.PostTemplates.Post

  @doc """
  Where a group with a place stands, for the strip over its description: the
  areas the viewer sees around its pin, smallest first, or for a route the
  areas it passes through and its length; and a link to the root's map: for
  an area narrowed to it, for a route showing it, for a point with its pin in
  focus. Nil for a group without a place, or for a guest.
  """
  def location(nil, _group), do: nil

  def location(profile, %Group{} = group) do
    if Group.placed?(group) do
      kind = GroupAreas.place_kind(group)
      root = Social.root_group_id()

      {shape, map_path} =
        case kind do
          {:area, _size} -> {:area, ~p"/groups/#{root}/map?#{[area: group.id]}"}
          {:route, _meters} -> {:route, ~p"/groups/#{root}/map?#{[route: group.id]}"}
          _point -> {:point, ~p"/groups/#{root}/map?#{[place: group.id]}"}
        end

      %{
        within: GroupAreas.containing(profile, group, kind),
        route_length: with({:route, meters} <- kind, do: meters, else: (_other -> nil)),
        shape: shape,
        map_path: map_path
      }
    end
  end

  attr :group, :map, required: true
  attr :current_profile, :map, default: nil
  attr :is_member, :boolean, default: false

  attr :viewer_roles, :string,
    default: "",
    doc: "the viewer's role keys; a change restarts the app"

  attr :pending_join_request, :map, default: nil
  attr :can_edit, :boolean, default: false, doc: "may write the description"

  attr :alt_descriptions, :list,
    default: [],
    doc: "the alternative descriptions the viewer sees, in order"

  attr :active_alt_description, :any,
    default: nil,
    doc: "the alternative description on screen; nil shows the default one"

  attr :reactions, :list, default: [], doc: "the group's reactions"
  attr :can_react, :boolean, default: false, doc: "may react to the group"

  attr :app_upload, :any,
    default: nil,
    doc: "the page's upload for files an app sends (`AppHost`); nil for a guest"

  attr :host, :string,
    default: "page",
    doc: ~s{who runs the app (`AppHost`): "page", or "sheet" over a map, whose ids start "sheet"}

  attr :switcher, :boolean, default: true, doc: "shows the chips of the alternative descriptions"

  attr :location, :map,
    default: nil,
    doc: "where the group stands (`location/2`), shown over the description"

  def panel(assigns) do
    source = assigns.active_alt_description || assigns.group

    assigns =
      assigns
      |> assign(:prefix, if(assigns.host == "sheet", do: "sheet", else: "group"))
      |> assign(:source, source)
      |> assign(:column, description_column(source))
      |> assign(:empty_description_image_src, empty_description_image_src(assigns.group))

    ~H"""
    <div class="flex min-h-0 flex-1 flex-col px-2">
      <div
        :if={@location && (@location.within != [] or @location.map_path)}
        id={"#{@prefix}-location"}
        class="flex shrink-0 flex-wrap items-center gap-1.5 px-1 pb-2 pt-1"
      >
        <span
          :if={@location.route_length}
          id={"#{@prefix}-location-route"}
          class="inline-flex items-center gap-1 text-xs font-semibold text-base-content/75"
        >
          <.icon name="hero-arrow-turn-up-right-micro" class="size-3.5" />
          {gettext("Route · %{length}", length: Distance.text(@location.route_length))}
        </span>
        <span
          :if={@location.within != []}
          class="inline-flex items-center gap-1 text-xs font-semibold text-base-content/60"
        >
          <.icon name="hero-map-pin-micro" class="size-3.5" />
          {if @location.route_length, do: gettext("Passes through"), else: gettext("Lies in")}
        </span>
        <.link
          :for={area <- @location.within}
          id={"#{@prefix}-location-area-#{area.id}"}
          navigate={~p"/groups/#{area.id}"}
          class="inline-flex max-w-full items-center gap-1 rounded-full border border-base-300/70 bg-base-100 px-2.5 py-1 text-xs font-semibold text-base-content/80 transition duration-150 ease-out hover:-translate-y-px hover:border-primary/40 hover:text-primary"
        >
          <.icon name="hero-viewfinder-circle-micro" class="size-3.5 shrink-0" />
          <span class="truncate">{area.name}</span>
        </.link>
        <.link
          :if={@location.map_path}
          id={"#{@prefix}-location-map"}
          navigate={@location.map_path}
          class="inline-flex items-center gap-1 rounded-full bg-primary/10 px-2.5 py-1 text-xs font-semibold text-primary transition duration-150 ease-out hover:-translate-y-px hover:bg-primary/15"
        >
          <.icon name="hero-map-micro" class="size-3.5 shrink-0" />
          <%= case @location.shape do %>
            <% :route -> %>
              {gettext("Route on the map")}
            <% :area -> %>
              {gettext("Groups in this area on the map")}
            <% :point -> %>
              {gettext("Show on the map")}
          <% end %>
        </.link>
      </div>
      <nav
        :if={@switcher and @alt_descriptions != []}
        id="group-description-switcher"
        aria-label={gettext("Descriptions")}
        class="-mx-2 flex shrink-0 gap-2 overflow-x-auto px-2 pt-1 pb-2 [scrollbar-width:none]"
      >
        <.link
          id="group-description-switcher-default"
          patch={~p"/groups/#{@group.id}/group_home?#{[d: "default"]}"}
          aria-current={if(is_nil(@active_alt_description), do: "page")}
          class={switcher_chip_class(is_nil(@active_alt_description))}
        >
          {Components.default_description_label(@group)}
        </.link>
        <.link
          :for={alt <- @alt_descriptions}
          id={"group-description-switcher-#{alt.id}"}
          patch={~p"/groups/#{@group.id}/group_home?#{[d: alt.id]}"}
          aria-current={if(active?(@active_alt_description, alt), do: "page")}
          class={switcher_chip_class(active?(@active_alt_description, alt))}
        >
          <.icon :if={alt.uses_api} name="hero-squares-2x2-mini" class="size-3.5 opacity-70" />
          <.icon
            :if={alt.visible_role_keys != []}
            name="hero-lock-closed-mini"
            class="size-3.5 opacity-70"
          />
          <span class="truncate">{alt.name}</span>
        </.link>
      </nav>
      <div class="flex min-h-0 flex-1 overflow-y-auto overscroll-contain flex-col pb-4">
        <div
          :if={blank_description?(@source.description)}
          id={"#{@prefix}-description-empty"}
          class="flex flex-col min-h-48 items-center justify-center rounded-3xl border border-dashed border-base-300 bg-base-100/70 px-6 text-center text-sm text-base-content/65"
        >
          <p class="p-2">{gettext("This group has no description yet.")}</p>
          <.button
            :if={@can_edit}
            id={"#{@prefix}-description-add"}
            type="button"
            phx-click={
              JS.push("switch_tab", value: %{tab: "edit_group"})
              |> JS.push("set_edit_group_section", value: %{section: "description"})
            }
            variant="soft"
            size="sm"
            class="mb-2"
          >
            <.icon name="hero-pencil-square" class="size-4" />
            {gettext("Add a description")}
          </.button>

          <div class="text-center opacity-85 overflow-hidden rounded-4xl">
            <img
              class="pointer-events-none inline-block align-bottom"
              src={@empty_description_image_src}
              alt={gettext("Group description illustration")}
              width="400"
              height="400"
              loading="lazy"
            />
          </div>
        </div>

        <%!-- Each app gets its own frame id, so switching apps mounts a new hook
        with that app's storage instead of reusing the previous one. --%>
        <div
          :if={!blank_description?(@source.description) and @source.uses_api}
          id={"#{@prefix}-panel-description"}
          class="flex min-h-0 flex-1 flex-col"
        >
          <Components.app_frame
            id={app_frame_id(@prefix, @active_alt_description)}
            html={@source.description}
            app_id={AppApi.app_id(@active_alt_description)}
            storage_key={storage_key(@group, @active_alt_description)}
            viewer_key={"#{@current_profile && @current_profile.id}:#{@is_member}:#{@viewer_roles}"}
            host={@host}
          />
          <%!-- The frame cannot upload: its hook sends the file through here. --%>
          <form
            :if={@app_upload}
            id={"#{@prefix}-app-upload-form"}
            phx-change="validate_app_file"
            class="hidden"
          >
            <.live_file_input upload={@app_upload} tabindex="-1" />
          </form>
        </div>

        <div
          :if={!blank_description?(@source.description) and !@source.uses_api}
          id={"#{@prefix}-panel-description"}
          class={@column}
        >
          <Components.formatted_content
            content={@source.description}
            content_format={@source.description_format}
          />
        </div>

        <%!-- An app has the whole panel, so its reactions are for a feed to show. --%>
        <Components.reaction_pills
          :if={!@source.uses_api and (@reactions != [] or @can_react)}
          id={"#{@prefix}-reactions"}
          pill_id_prefix={"#{@prefix}-reaction"}
          reactions={@reactions}
          can_react={@can_react}
          click="toggle_group_reaction"
          class={["shrink-0 pt-4", @column]}
        >
          <.icon_button
            :if={@can_react}
            id={"#{@prefix}-react"}
            type="button"
            data-reaction-trigger
            data-group-reaction
            aria-haspopup="dialog"
            icon="hero-face-smile"
            label={gettext("Add reaction")}
            size="xs"
          />
        </Components.reaction_pills>
      </div>
      <Components.reaction_picker
        :if={@can_react or (@current_profile && @source.uses_api)}
        id={AppHost.picker_id(@host)}
      />
    </div>
    """
  end

  # A template is made for the width it has in Feed, which is this column
  # there, so it does not spread over a wide screen here. Anything else takes
  # the whole panel, as an author may have written a wide table.
  defp description_column(%{uses_api: true}), do: nil

  defp description_column(source) do
    if Post.decode(source.description) != :free, do: "mx-auto w-full max-w-2xl sm:px-5"
  end

  defp active?(%{id: id}, %{id: id}), do: true
  defp active?(_active, _alt), do: false

  defp app_frame_id(prefix, nil), do: "#{prefix}-app-frame"
  defp app_frame_id(prefix, %{id: id}), do: "#{prefix}-app-frame-alt-#{id}"

  defp storage_key(group, nil), do: "potok-app:#{group.id}"
  defp storage_key(group, %{id: id}), do: "potok-app:#{group.id}:alt-#{id}"

  defp switcher_chip_class(active?) do
    [
      "inline-flex max-w-56 shrink-0 items-center gap-1.5 rounded-full border px-3 py-1 text-sm font-medium transition duration-150 focus:outline-none focus-visible:ring-2 focus-visible:ring-primary/40",
      if(active?,
        do: "border-primary bg-primary text-primary-content shadow-sm",
        else:
          "border-base-300 bg-base-100 text-base-content/75 hover:-translate-y-px hover:border-base-content/30 hover:text-base-content"
      )
    ]
  end

  defp blank_description?(description), do: is_nil(description) or String.trim(description) == ""

  # Picked per group instead of at random, so re-renders never swap the image.
  defp empty_description_image_src(group) do
    case rem(group.id || 0, 4) do
      0 -> ~p"/images/social-media.gif"
      1 -> ~p"/images/mark-rotating.svg"
      2 -> ~p"/images/pencil.gif"
      _ -> ~p"/images/idea.gif"
    end
  end
end
