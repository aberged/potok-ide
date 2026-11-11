defmodule PotokIdeWeb.GroupLive.Show.EditGroupTab do
  use PotokIdeWeb, :html

  alias PotokIde.MapTiles
  alias PotokIde.Social.{Group, GroupAreas, GroupPins, GroupRole, GroupRoutes}
  alias PotokIdeWeb.Avatars
  alias PotokIdeWeb.Distance
  alias PotokIdeWeb.GroupLive.Show.{Components, LocationEditor}
  alias PotokIdeWeb.PinIcons

  attr :card, :map, required: true

  # Drawn like the card of a link in a chat, as sites and apps show about the
  # same. The picture is lazy, so a section that stays hidden does not ask for it.
  defp link_card(assigns) do
    ~H"""
    <div id="group-edit-link-card" class="mb-4">
      <p class="text-sm font-semibold text-base-content">
        {gettext("How a link to the group looks outside Potok")}
      </p>
      <p class="mb-2 text-xs text-base-content/65">{gettext("As saved so far.")}</p>

      <div class="max-w-sm overflow-hidden rounded-2xl border border-l-4 border-base-300 border-l-primary bg-base-200/60">
        <img
          id="group-edit-link-card-image"
          src={@card.preview["image_url"]}
          alt=""
          loading="lazy"
          decoding="async"
          class="block aspect-[1.91/1] w-full bg-base-300/40 object-cover"
        />
        <div class="px-3 py-2.5">
          <p class="truncate text-[11px] font-semibold uppercase tracking-wide opacity-90">
            {@card.preview["site_name"]}
          </p>
          <p class="mt-0.5 line-clamp-2 text-sm font-semibold leading-snug">
            {@card.preview["title"]}
          </p>
          <p
            id="group-edit-link-card-description"
            class="mt-0.5 line-clamp-2 text-sm leading-snug opacity-90"
          >
            {@card.preview["description"]}
          </p>
        </div>
      </div>

      <p
        :if={!@card.describes_itself and !@card.app}
        id="group-edit-link-card-add-description"
        class="mt-2 text-xs text-base-content/65"
      >
        {gettext("Add a description, so the card says what the group is about.")}
      </p>
      <p
        :if={!@card.describes_itself and @card.app}
        id="group-edit-link-card-add-meta"
        class="mt-2 text-xs text-base-content/65"
      >
        {gettext(
          "An app says what it is with a <meta name=\"description\" content=\"...\"> tag in its HTML."
        )}
      </p>
    </div>
    """
  end

  # Follows the form, so the choice comes up as soon as "Public group" is ticked.
  # A form that changed holds the string "false", which `if` would take for true.
  defp open_chat_option?(%Group{} = group, form) do
    not group.is_root and not group.is_direct and is_nil(group.parent_value_id) and
      Phoenix.HTML.Form.normalize_value("checkbox", form[:is_public].value)
  end

  attr :group, :map, required: true
  attr :edit_group_form, :any, required: true
  attr :link_card, :map, default: nil, doc: "what a link to the group shows, if guests see it"

  attr :location_mode, :string,
    default: "point",
    doc: ~s{the Location card's "point", "area" or "route"}

  attr :location_within, :list,
    default: [],
    doc: "the areas the viewer sees around the card's pin, or along its route, smallest first"

  attr :shape_error, :string, default: nil, doc: "what is wrong with the border or route drawn"
  attr :dirty, :boolean, default: false, doc: "whether the form has unsaved changes"
  attr :format_options, :list, required: true
  attr :home_page_options, :list, required: true
  attr :description_details_open, :boolean, required: true
  attr :can_delete_group, :boolean, default: false

  attr :inherits_members_option, :boolean,
    default: false,
    doc: "whether the group can inherit members (see `Social.inherits_members_option?/1`)"

  attr :alt_descriptions, :list, default: [], doc: "every alternative description of the group"

  attr :alt_description_form, :any,
    default: nil,
    doc: "the open form of a new or edited alternative description"

  attr :editing_alt_description, :any, default: nil
  attr :roles, :list, default: [], doc: "roles of the group's manifest"
  attr :max_alt_descriptions, :integer, required: true

  attr :template_list, :string,
    default: nil,
    doc: "the description workspace whose list of templates is open"

  attr :picture_upload, :any,
    default: nil,
    doc: "the upload of a template's picture, when the viewer may post one to the chat"

  attr :section, :string,
    default: "basics",
    doc: "the card on screen, picked in the section bar (see `sections/0`)"

  attr :everyone_can_post, :boolean,
    default: true,
    doc: "whether the \"everyone\" role may post, which an open chat also needs"

  # Cards picked one at a time from the section bar: the group form's
  # sections, the alternative descriptions (their own form) and the danger
  # zone. The other cards are only hidden, so the group form still sends
  # every field and an edit made in one card survives a switch to another.
  # The save bar shows while the group form has unsaved changes, whichever
  # card is on screen, and never sits next to a delete button. The form is
  # `novalidate`, as a required field in a hidden card would silently stop the
  # browser from submitting; the server opens the card with the error instead.
  def panel(assigns) do
    assigns =
      assign(
        assigns,
        :open_chat_option,
        open_chat_option?(assigns.group, assigns.edit_group_form)
      )

    ~H"""
    <div id="group-panel-edit-group" class="flex min-h-0 flex-1 flex-col px-2">
      <Components.tab_body id="group-edit-scroll">
        <.page_header id="group-edit-header" icon="hero-cog-6-tooth">
          {pgettext("page title", "Edit group")}
          <:subtitle>
            {gettext("Name, picture, visibility, description and apps of the group.")}
          </:subtitle>
        </.page_header>

        <Components.settings_tabs
          id="group-edit-sections"
          tabs={sections(@group)}
          current={@section}
          event="set_edit_group_section"
          tab_id_prefix="group-edit-tab"
        />

        <.form
          for={@edit_group_form}
          id="group-edit-form"
          phx-change="validate_edit_group"
          phx-submit="save_edit_group"
          novalidate
          class="space-y-4"
        >
          <Components.settings_card
            id="group-edit-basics"
            tab_id="group-edit-tab-basics"
            active={@section == "basics"}
            icon="hero-identification"
            title={gettext("Basics")}
            subtitle={gettext("The name and picture members see.")}
          >
            <.input field={@edit_group_form[:name]} label={gettext("Name")} required />
            <Components.group_picture_form_field field={@edit_group_form[:group_picture_url]} />
          </Components.settings_card>

          <Components.settings_card
            id="group-edit-access"
            tab_id="group-edit-tab-access"
            active={@section == "access"}
            icon="hero-lock-open"
            title={gettext("Access and members")}
            subtitle={gettext("Who sees the group and who is a member.")}
          >
            <%!-- "Root public" only ever turned "Public" on, so the form
                   leaves it off and "Public" alone decides. --%>
            <input
              type="hidden"
              name={@edit_group_form[:is_root_public].name}
              value="false"
            />
            <.input
              field={@edit_group_form[:is_public]}
              label={gettext("Public group")}
              type="checkbox"
            />
            <p class="-mt-1 mb-3 text-xs text-base-content/65">
              {gettext("Everyone can see the group and ask to join it.")}
              {gettext(
                "Its name, picture and description also show outside Potok, to anyone with the link."
              )}
            </p>

            <div :if={@open_chat_option} id="group-edit-open-chat">
              <.input
                field={@edit_group_form[:has_public_chat]}
                label={gettext("Non-members can write")}
                type="checkbox"
              />
              <p class="-mt-1 mb-3 text-xs text-base-content/65">
                {gettext(
                  "Everyone signed in sees all messages and pictures in the chat, earlier ones too, and can write without joining. They send no files and open no threads."
                )}
                <span :if={!@everyone_can_post} id="group-edit-open-chat-read-only">
                  {gettext(
                    "The everyone role cannot post here, so those outside the group only read."
                  )}
                </span>
              </p>
            </div>

            <.link_card :if={@link_card} card={@link_card} />

            <div :if={@inherits_members_option} id="group-edit-inherits-members">
              <.input
                field={@edit_group_form[:inherits_members]}
                label={gettext("Inherit members")}
                type="checkbox"
                disabled={!is_nil(@group.parent_value_id)}
              />
              <p class="-mt-1 mb-1 text-xs text-base-content/65">
                {if(@group.parent_value_id,
                  do: gettext("Threads always inherit the members of their group."),
                  else:
                    gettext(
                      "Every member of the parent group is also a member here, with the same roles."
                    )
                )}
              </p>
            </div>
          </Components.settings_card>

          <Components.settings_card
            id="group-edit-home"
            tab_id="group-edit-tab-home"
            active={@section == "home"}
            icon="hero-home"
            title={gettext("What opens first")}
            subtitle={gettext("The panel and the description a member sees on opening the group.")}
          >
            <.input
              field={@edit_group_form[:home_page]}
              label={gettext("Home page")}
              type="select"
              options={@home_page_options}
            />
            <.input
              :if={@alt_descriptions != []}
              field={@edit_group_form[:home_alt_description_id]}
              label={gettext("Home description")}
              type="select"
              options={home_description_options(@group, @alt_descriptions)}
            />
          </Components.settings_card>

          <Components.settings_card
            id="group-edit-description"
            tab_id="group-edit-tab-description"
            active={@section == "description"}
            icon="hero-document-text"
            title={gettext("Description")}
            subtitle={gettext("The text or app on the group's home page.")}
          >
            <.input
              field={@edit_group_form[:description_name]}
              label={gettext("Name next to the alternative descriptions")}
              placeholder={gettext("Description")}
            />
            <.input
              field={@edit_group_form[:uses_api]}
              label={gettext("The description is an app (API)")}
              type="checkbox"
            />
            <p class="-mt-1 mb-3 text-xs text-base-content/65">
              {gettext("The app runs on the group's home page and can keep its own data.")}
              {gettext(
                "For shared links, it can describe itself in a <meta name=\"description\" content=\"...\"> tag."
              )}
            </p>

            <details
              id="group-edit-description-editor"
              open={@description_details_open}
              class="w-full rounded-2xl border border-base-300/80 bg-base-100/70 px-4 py-3 shadow-sm"
            >
              <summary
                phx-click="set_edit_group_description_open"
                phx-value-open={if(@description_details_open, do: "false", else: "true")}
                class="cursor-pointer select-none font-medium text-base-content"
              >
                {gettext("Content")}
              </summary>

              <Components.description_workspace
                id_prefix="group-description"
                description_field={@edit_group_form[:description]}
                format_field={@edit_group_form[:description_format]}
                uses_api={@edit_group_form[:uses_api].value}
                format_options={@format_options}
                templates
                template_list_open={@template_list == "group-description"}
                picture_upload={@picture_upload}
              />
            </details>
          </Components.settings_card>

          <Components.settings_card
            :if={!@group.is_root}
            id="group-edit-location"
            tab_id="group-edit-tab-location"
            active={@section == "location"}
            icon="hero-map-pin"
            title={pgettext("map", "Location")}
            subtitle={
              gettext(
                "Where the group stands on a map, a point, an area or a route, and the pin it shows there."
              )
            }
          >
            <p class="mb-3 text-xs text-base-content/65">
              {gettext(
                "The map of groups shows this group as a pin to everyone who sees it, and so does a Map app in the group above. Tap the map to put it, or drag it."
              )}
            </p>
            <LocationEditor.mode_switch
              id="group-location-mode"
              mode={@location_mode}
              event="set_location_mode"
              class="mb-3 sm:w-96"
            />
            <LocationEditor.shape_hint prefix="group" mode={@location_mode} />
            <div id="group-location-map-wrap" phx-update="ignore">
              <div
                id="group-location-map"
                phx-hook="LocationPicker"
                class="potok-map h-64 w-full overflow-hidden rounded-2xl border border-base-300 bg-base-200 sm:h-80"
                data-tiles={MapTiles.url_template("/tiles")}
                data-attribution={MapTiles.attribution()}
                data-max-zoom={MapTiles.max_zoom()}
                data-default-bounds={Jason.encode!(MapTiles.default_bounds())}
                data-lat-input="group-edit-latitude"
                data-lng-input="group-edit-longitude"
                data-pin-name={@edit_group_form[:pin_icon].name}
                data-clear-button="group-location-clear"
                data-locate-button="group-location-locate"
                data-error-target="group-location-error"
                data-locate-error={gettext("Your location is not available.")}
                data-load-error={gettext("The map could not load. Type the coordinates instead.")}
                data-mode={@location_mode}
                data-area={Jason.encode!(GroupAreas.to_geojson(@edit_group_form.data.area))}
                data-route={Jason.encode!(GroupRoutes.to_geojson(@edit_group_form.data.route))}
                data-route-length={
                  @edit_group_form.data.route_length &&
                    Distance.text(@edit_group_form.data.route_length)
                }
                {LocationEditor.picker_attrs("group")}
              >
              </div>
              <p id="group-location-error" class="mt-2 text-xs text-error" hidden></p>
              <p id="group-area-status" class="mt-2 text-xs text-base-content/65" hidden></p>
              <div id="group-area-choices" class="mt-2" hidden></div>
            </div>
            <LocationEditor.shape_tools prefix="group" mode={@location_mode} />
            <p
              :if={@shape_error}
              id={if @location_mode == "route", do: "group-route-error", else: "group-area-error"}
              class="mt-2 text-xs text-error"
            >
              {@shape_error}
            </p>
            <p
              :for={message <- shape_errors(@edit_group_form, @shape_error)}
              class="mt-2 text-xs text-error"
            >
              {message}
            </p>
            <div
              :if={@location_within != []}
              id="group-location-within"
              class="mt-3 flex flex-wrap items-center gap-1.5"
            >
              <span class="text-xs font-semibold text-base-content/60">
                {if @location_mode == "route", do: gettext("Passes through"), else: gettext("Lies in")}
              </span>
              <.link
                :for={area <- @location_within}
                id={"group-location-within-#{area.id}"}
                navigate={~p"/groups/#{area.id}"}
                class="inline-flex max-w-full items-center gap-1 rounded-full border border-base-300/70 bg-base-100 px-2.5 py-1 text-xs font-semibold text-base-content/80 transition duration-150 ease-out hover:-translate-y-px hover:border-primary/40 hover:text-primary"
              >
                <.icon name="hero-viewfinder-circle-micro" class="size-3.5 shrink-0" />
                <span class="truncate">{area.name}</span>
              </.link>
            </div>
            <div class={["mt-3 grid grid-cols-2 gap-3", @location_mode != "point" && "hidden"]}>
              <.input
                field={@edit_group_form[:latitude]}
                id="group-edit-latitude"
                type="number"
                step="any"
                min="-90"
                max="90"
                inputmode="decimal"
                label={gettext("Latitude")}
              />
              <.input
                field={@edit_group_form[:longitude]}
                id="group-edit-longitude"
                type="number"
                step="any"
                min="-180"
                max="180"
                inputmode="decimal"
                label={gettext("Longitude")}
              />
            </div>
            <div class="flex flex-wrap gap-2">
              <.button
                id="group-location-locate"
                type="button"
                variant="soft"
                size="sm"
                hidden
                phx-mounted={JS.ignore_attributes(["hidden"])}
              >
                <.icon name="hero-map-pin" class="size-4" />
                {gettext("My location")}
              </.button>
              <.button id="group-location-clear" type="button" variant="ghost" size="sm">
                <.icon name="hero-x-mark" class="size-4" />
                {gettext("Remove location")}
              </.button>
            </div>

            <fieldset id="group-edit-pins" class="mt-6">
              <legend class="text-sm font-semibold text-base-content">
                {gettext("Pin on the map")}
              </legend>
              <p class="text-xs text-base-content/65">
                {gettext(
                  "Unless you pick another, the pin shows the kind of group, like the mark on its picture. A pin you pick keeps the kind in its corner."
                )}
              </p>
              <%= for section <- pin_sections(@group) do %>
                <p class="mt-4 mb-1.5 text-xs font-semibold uppercase tracking-wide text-base-content/55">
                  {section.title}
                </p>
                <div class="grid grid-cols-3 gap-2 min-[420px]:grid-cols-4 sm:grid-cols-6">
                  <label
                    :for={pin <- section.pins}
                    id={"group-edit-pin-#{pin.key}"}
                    class="relative flex cursor-pointer flex-col items-center gap-1 rounded-2xl border border-base-300 bg-base-100 px-1 py-2 text-center text-[11px] leading-tight text-base-content/75 transition duration-150 ease-out hover:-translate-y-px hover:border-base-content/30 active:scale-95 has-[:checked]:border-primary has-[:checked]:bg-primary/5 has-[:checked]:text-base-content has-[:focus-visible]:ring-2 has-[:focus-visible]:ring-primary/40"
                  >
                    <input
                      type="radio"
                      name={@edit_group_form[:pin_icon].name}
                      value={pin.value}
                      checked={pin_checked?(@edit_group_form, pin.value)}
                      class="sr-only"
                    />
                    <span data-pin-svg>
                      <PinIcons.pin
                        id={"group-edit-pin-svg-#{pin.key}"}
                        color={pin.look.color}
                        paths={pin.look.paths}
                        picture_url={pin.picture_url}
                        mark={pin.look.mark}
                        class="h-10 w-8 drop-shadow-sm"
                      />
                    </span>
                    <span class="line-clamp-2">{pin.label}</span>
                  </label>
                </div>
              <% end %>
            </fieldset>
          </Components.settings_card>
        </.form>

        <section
          id="group-alt-descriptions"
          role="tabpanel"
          aria-labelledby="group-edit-tab-alt_descriptions"
          class={[
            "rounded-3xl border border-base-300/70 bg-base-100/80 p-4 shadow-sm sm:p-5",
            @section != "alt_descriptions" && "hidden"
          ]}
        >
          <div class="flex flex-wrap items-start justify-between gap-3">
            <.card_title
              icon="hero-squares-plus"
              title={gettext("Alternative descriptions")}
              subtitle={
                gettext(
                  "Extra descriptions or apps, shown as tabs next to the default description. Each app keeps its own data."
                )
              }
            />
            <.button
              :if={
                is_nil(@alt_description_form) and length(@alt_descriptions) < @max_alt_descriptions
              }
              id="alt-description-new"
              type="button"
              phx-click="new_alt_description"
              variant="soft"
              class="shrink-0"
            >
              <.icon name="hero-plus" class="size-4" /> <span>{gettext("New description")}</span>
            </.button>
          </div>

          <ul
            :if={@alt_descriptions != []}
            id="alt-description-list"
            class="mt-4 flex flex-col gap-2"
          >
            <li
              :for={{alt, index} <- Enum.with_index(@alt_descriptions)}
              id={"alt-description-#{alt.id}"}
              class={[
                "flex flex-wrap items-center gap-3 rounded-2xl border px-3 py-2 transition duration-150",
                if(editing?(@editing_alt_description, alt),
                  do: "border-primary/50 bg-primary/5",
                  else: "border-base-300/80 bg-base-100 hover:border-base-content/20"
                )
              ]}
            >
              <div class="flex min-w-0 flex-1 flex-col gap-1">
                <div class="flex min-w-0 items-center gap-2">
                  <span class="truncate font-medium text-base-content">{alt.name}</span>
                  <span class="shrink-0 rounded-full bg-base-200 px-2 py-0.5 text-[11px] font-semibold uppercase tracking-wider text-base-content/65">
                    {kind_label(alt)}
                  </span>
                </div>
                <div :if={alt.visible_role_keys != []} class="flex flex-wrap gap-1">
                  <span
                    :for={name <- role_names(alt.visible_role_keys, @roles)}
                    class="inline-flex items-center gap-1 rounded-full border border-base-300 px-2 py-0.5 text-xs text-base-content/70"
                  >
                    <.icon name="hero-lock-closed" class="size-3" /> {name}
                  </span>
                </div>
              </div>

              <div class="flex items-center gap-1">
                <.icon_button
                  id={"alt-description-#{alt.id}-up"}
                  type="button"
                  phx-click="move_alt_description"
                  phx-value-id={alt.id}
                  phx-value-direction="up"
                  disabled={index == 0}
                  icon="hero-arrow-up"
                  label={gettext("Move up")}
                />
                <.icon_button
                  id={"alt-description-#{alt.id}-down"}
                  type="button"
                  phx-click="move_alt_description"
                  phx-value-id={alt.id}
                  phx-value-direction="down"
                  disabled={index == length(@alt_descriptions) - 1}
                  icon="hero-arrow-down"
                  label={gettext("Move down")}
                />
                <.icon_button
                  id={"alt-description-#{alt.id}-edit"}
                  type="button"
                  phx-click="edit_alt_description"
                  phx-value-id={alt.id}
                  icon="hero-pencil-square"
                  label={gettext("Edit")}
                />
                <.icon_button
                  id={"alt-description-#{alt.id}-promote"}
                  type="button"
                  phx-click="promote_alt_description"
                  phx-value-id={alt.id}
                  disabled={alt.visible_role_keys != []}
                  icon="hero-star"
                  label={
                    if(alt.visible_role_keys == [],
                      do: gettext("Make default"),
                      else: gettext("Remove the role limit to make it the default")
                    )
                  }
                  data-confirm={
                    gettext(
                      "Make this the default description? The current default takes its place in the list."
                    )
                  }
                />
                <.icon_button
                  id={"alt-description-#{alt.id}-delete"}
                  type="button"
                  phx-click="delete_alt_description"
                  phx-value-id={alt.id}
                  icon="hero-trash"
                  label={gettext("Delete")}
                  variant="danger"
                  data-confirm={
                    gettext("Delete this description? The data values of its app are deleted too.")
                  }
                />
              </div>

              <%!-- An edited description opens right under its row. --%>
              <.alt_description_form
                :if={@alt_description_form && editing?(@editing_alt_description, alt)}
                form={@alt_description_form}
                editing={@editing_alt_description}
                roles={@roles}
                format_options={@format_options}
                template_list_open={@template_list == "alt-description"}
                picture_upload={@picture_upload}
                class="basis-full"
              />
            </li>
          </ul>

          <.alt_description_form
            :if={@alt_description_form && new_alt_description?(@editing_alt_description)}
            form={@alt_description_form}
            editing={@editing_alt_description}
            roles={@roles}
            format_options={@format_options}
            template_list_open={@template_list == "alt-description"}
            picture_upload={@picture_upload}
            class="mt-4"
          />
        </section>

        <section
          id="group-edit-danger"
          role="tabpanel"
          aria-labelledby="group-edit-tab-danger"
          class={[
            "rounded-3xl border border-error/30 bg-error/5 p-4 sm:p-5",
            @section != "danger" && "hidden"
          ]}
        >
          <div class="flex items-start gap-3">
            <span class="inline-flex size-9 shrink-0 items-center justify-center rounded-2xl bg-error/10 text-error">
              <.icon name="hero-exclamation-triangle" class="size-5" />
            </span>
            <div class="min-w-0">
              <h2 class="font-semibold leading-tight text-error">{gettext("Danger zone")}</h2>
              <p class="mt-0.5 text-sm text-base-content/65">
                {gettext("None of this can be undone.")}
              </p>
            </div>
          </div>

          <div class="mt-4 divide-y divide-error/15">
            <div class="flex flex-wrap items-center justify-between gap-3 py-3">
              <div class="min-w-0 flex-1 basis-60">
                <p class="font-medium">{gettext("Delete the app's data")}</p>
                <p class="text-sm text-base-content/65">
                  {if(@alt_descriptions == [],
                    do: gettext("Deletes every data value the group's app saved."),
                    else:
                      gettext(
                        "Deletes the data values of the default description's app. The other apps keep theirs."
                      )
                  )}
                </p>
              </div>
              <.button
                id="group-delete-data-values-button"
                type="button"
                phx-click="delete_group_data_values"
                data-confirm={
                  if(@alt_descriptions == [],
                    do: gettext("Are you sure you want to delete all data values in this group?"),
                    else:
                      gettext(
                        "Delete every data value of the default description's app? The other apps keep theirs."
                      )
                  )
                }
                variant="warning"
                class="shrink-0"
              >
                <.icon name="hero-trash" class="size-4" />
                <span>{gettext("Delete Data Values")}</span>
              </.button>
            </div>

            <div
              :if={!@group.is_root and @can_delete_group}
              class="flex flex-wrap items-center justify-between gap-3 py-3"
            >
              <div class="min-w-0 flex-1 basis-60">
                <p class="font-medium">{gettext("Delete the group")}</p>
                <p class="text-sm text-base-content/65">
                  {gettext(
                    "Deletes the group with its messages and files. A group with sub-groups cannot be deleted."
                  )}
                </p>
              </div>
              <.button
                id="group-delete-button"
                type="button"
                phx-click="delete_group"
                data-confirm={gettext("Are you sure you want to delete this group?")}
                variant="danger"
                class="shrink-0"
              >
                <.icon name="hero-trash" class="size-4" />
                <span>{gettext("Delete group")}</span>
              </.button>
            </div>
          </div>
        </section>

        <%!-- Outside the form, which it submits through `form`, so it can
               stick to the bottom over every section. --%>
        <div
          :if={@dirty}
          id="group-edit-save-bar"
          class="sticky bottom-0 z-10 mt-4 flex flex-wrap items-center justify-between gap-3 rounded-3xl border border-primary/30 bg-base-100/95 px-4 py-3 shadow-xl shadow-primary/10 backdrop-blur"
        >
          <p class="flex items-center gap-2 text-sm font-medium">
            <span class="size-2 shrink-0 rounded-full bg-primary"></span>
            {gettext("You have unsaved changes.")}
          </p>
          <div class="ml-auto flex items-center gap-2">
            <.button
              id="group-edit-discard"
              type="button"
              phx-click="discard_edit_group"
              variant="ghost"
            >
              {gettext("Discard")}
            </.button>
            <.button
              id="group-edit-save"
              type="submit"
              form="group-edit-form"
              phx-disable-with={gettext("Saving...")}
              variant="primary"
            >
              {gettext("Save changes")}
            </.button>
          </div>
        </div>

        <.description_picture_picker :if={@picture_upload} upload={@picture_upload} />
      </Components.tab_body>
    </div>
    """
  end

  attr :form, :any, required: true
  attr :editing, :any, required: true
  attr :roles, :list, required: true
  attr :format_options, :list, required: true
  attr :template_list_open, :boolean, default: false
  attr :picture_upload, :any, default: nil
  attr :class, :any, default: nil

  defp alt_description_form(assigns) do
    ~H"""
    <.form
      for={@form}
      id="alt-description-form"
      phx-change="validate_alt_description"
      phx-submit="save_alt_description"
      class={["rounded-2xl border border-primary/30 bg-base-100 p-4 shadow-sm", @class]}
    >
      <h5 class="mb-2 font-medium text-base-content">
        {if(new_alt_description?(@editing),
          do: gettext("New description"),
          else: gettext("Edit description")
        )}
      </h5>

      <.input field={@form[:name]} label={gettext("Name")} required />
      <.input
        field={@form[:uses_api]}
        label={gettext("The description is an app (API)")}
        type="checkbox"
      />

      <fieldset id="alt-description-roles" class="fieldset mt-2">
        <legend class="fieldset-legend">{gettext("Visible to")}</legend>
        <p class="text-xs text-base-content/65">
          {gettext(
            "Without a role it is visible to everyone who sees the group's description. Editors always see it."
          )}
        </p>
        <input type="hidden" name={@form[:visible_role_keys].name <> "[]"} value="" />
        <div class="mt-1 flex flex-wrap gap-3">
          <label :for={role <- @roles} class="inline-flex items-center gap-2 text-sm">
            <input
              type="checkbox"
              name={@form[:visible_role_keys].name <> "[]"}
              value={role.key}
              checked={role.key in List.wrap(@form[:visible_role_keys].value)}
              class="checkbox checkbox-sm"
            />
            <span>{role_label(role)}</span>
          </label>
        </div>
      </fieldset>

      <Components.description_workspace
        id_prefix="alt-description"
        description_field={@form[:description]}
        format_field={@form[:description_format]}
        uses_api={@form[:uses_api].value}
        format_options={@format_options}
        templates
        template_list_open={@template_list_open}
        picture_upload={@picture_upload}
      />

      <div class="mt-4 flex flex-wrap items-center justify-between gap-3">
        <.button
          :if={!new_alt_description?(@editing)}
          id="alt-description-delete-data-values"
          type="button"
          phx-click="delete_alt_description_data_values"
          phx-value-id={@editing.id}
          data-confirm={gettext("Delete every data value of this description's app?")}
          variant="warning"
        >
          <.icon name="hero-trash" class="size-4" />
          <span>{gettext("Delete Data Values")}</span>
        </.button>
        <div class="ml-auto flex items-center gap-2">
          <.button
            id="alt-description-cancel"
            type="button"
            phx-click="cancel_alt_description"
            variant="ghost"
          >
            {gettext("Cancel")}
          </.button>
          <.button
            id="alt-description-save"
            phx-disable-with={gettext("Saving...")}
            variant="primary"
          >
            {gettext("Save description")}
          </.button>
        </div>
      </div>
    </.form>
    """
  end

  attr :upload, :any, required: true

  # A picture from the device for a template, wherever the form with it stands:
  # the buttons in the forms send `potok:pick-picture` here with the input that
  # gets the address. It sits outside those forms, as a form holds no form and
  # a file input only uploads from one of its own. The picture goes out small,
  # as a phone's photo would be read by everyone who opens the description.
  defp description_picture_picker(assigns) do
    ~H"""
    <div id="description-picture" phx-hook=".DescriptionPicture" data-max-dimension="1080">
      <input
        type="file"
        accept="image/*"
        tabindex="-1"
        aria-hidden="true"
        class="sr-only"
        data-description-picture-file
      />
      <form id="description-picture-form" phx-change="validate_description_picture" class="hidden">
        <.live_file_input upload={@upload} tabindex="-1" />
      </form>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".DescriptionPicture">
      const loadImage = file =>
        new Promise((resolve, reject) => {
          const address = URL.createObjectURL(file)
          const image = new Image()

          image.onload = () => {
            URL.revokeObjectURL(address)
            resolve(image)
          }

          image.onerror = () => {
            URL.revokeObjectURL(address)
            reject(new Error("invalid-image"))
          }

          image.src = address
        })

      const shrink = (image, maxDimension) =>
        new Promise((resolve, reject) => {
          const longest = Math.max(image.naturalWidth, image.naturalHeight)
          const scale = Math.min(maxDimension / longest, 1)
          const canvas = document.createElement("canvas")

          canvas.width = Math.max(1, Math.round(image.naturalWidth * scale))
          canvas.height = Math.max(1, Math.round(image.naturalHeight * scale))

          const context = canvas.getContext("2d")

          // JPEG has no transparency, which it would turn black.
          context.fillStyle = "#ffffff"
          context.fillRect(0, 0, canvas.width, canvas.height)
          context.drawImage(image, 0, 0, canvas.width, canvas.height)

          canvas.toBlob(
            blob => (blob ? resolve(blob) : reject(new Error("no-image"))),
            "image/jpeg",
            0.82
          )
        })

      export default {
        mounted() {
          this.fileInput = this.el.querySelector("[data-description-picture-file]")

          this.el.addEventListener("potok:pick-picture", event => {
            this.target = event.detail.target
            this.fileInput.click()
          })

          this.fileInput.addEventListener("change", async () => {
            const file = this.fileInput.files?.[0]
            this.fileInput.value = ""

            if (!file) return

            try {
              const image = await loadImage(file)
              const blob = await shrink(image, Number(this.el.dataset.maxDimension))
              const name = `${file.name.replace(/\.[^.]*$/, "") || "picture"}.jpg`

              this.upload("description_picture", [new File([blob], name, {type: "image/jpeg"})])
            } catch (error) {
              console.error("Unable to process the picked picture", error)
              this.pushEvent("description_picture_invalid", {})
            }
          })

          // The form with the field may be gone by now, and then so is the need.
          this.handleEvent("description_picture_ready", ({url}) => {
            const input = document.getElementById(this.target)
            if (!input) return

            input.value = url
            input.dispatchEvent(new Event("input", {bubbles: true}))
          })
        },
      }
    </script>
    """
  end

  # The cards of the section bar, in order: `{key, panel id, label, danger?}`.
  # The keys are the ones `GroupLive.Show` accepts for `set_edit_group_section`.
  # The danger zone is always there, for the app's data.
  # The root stands nowhere on a map: nothing is above it to show it.
  defp sections(group) do
    [
      {"basics", "group-edit-basics", gettext("Basics"), false},
      {"access", "group-edit-access", gettext("Access"), false},
      {"home", "group-edit-home", gettext("Opens first"), false},
      {"description", "group-edit-description", gettext("Description"), false},
      {"alt_descriptions", "group-alt-descriptions", gettext("Alternative descriptions"), false},
      !group.is_root && {"location", "group-edit-location", pgettext("map", "Location"), false},
      {"danger", "group-edit-danger", gettext("Danger zone"), true}
    ]
    |> Enum.filter(& &1)
  end

  # The pins a group can show, under the headings of `GroupPins`: its kind's,
  # its picture, then the icons, which keep the kind's mark as on the map.
  # `value` is what the form sends ("" for the kind's).
  defp pin_sections(group) do
    kind = GroupPins.kind(group)

    own = [
      %{
        key: "kind",
        value: "",
        label: gettext("By kind: %{kind}", kind: PinIcons.kind_label(kind)),
        look: PinIcons.kind_look(kind),
        picture_url: nil
      },
      %{
        key: "picture",
        value: GroupPins.picture(),
        label: gettext("Group picture"),
        look: %{PinIcons.kind_look(kind) | mark: PinIcons.mark(kind)},
        picture_url: Avatars.group_avatar_url(group)
      }
    ]

    icons =
      for section <- PinIcons.sections() do
        %{
          title: section.title,
          pins:
            Enum.map(section.keys, fn key ->
              %{
                key: key,
                value: key,
                label: PinIcons.label(key),
                look: %{PinIcons.icon_look(key) | mark: PinIcons.mark(kind)},
                picture_url: nil
              }
            end)
        }
      end

    [%{title: gettext("This group"), pins: own} | icons]
  end

  # Errors of the border that came back from a save, unless the card already
  # says what is wrong with it.
  # What the changeset says of the border or the route, when the card's own
  # error does not say it already.
  defp shape_errors(_form, error) when is_binary(error), do: []

  defp shape_errors(%Phoenix.HTML.Form{source: %Ecto.Changeset{action: action} = changeset}, nil)
       when not is_nil(action),
       do: translate_errors(changeset.errors, :area) ++ translate_errors(changeset.errors, :route)

  defp shape_errors(_form, _error), do: []

  defp pin_checked?(form, value), do: to_string(form[:pin_icon].value || "") == value

  defp home_description_options(group, alt_descriptions) do
    [
      {Components.default_description_label(group), ""}
      | Enum.map(alt_descriptions, &{&1.name, &1.id})
    ]
  end

  defp editing?(%{id: id}, %{id: id}) when not is_nil(id), do: true
  defp editing?(_editing, _alt), do: false

  defp new_alt_description?(%{id: nil}), do: true
  defp new_alt_description?(_editing), do: false

  defp kind_label(%{uses_api: true}), do: gettext("App")
  defp kind_label(%{description_format: :html}), do: gettext("HTML")
  defp kind_label(_alt), do: gettext("Markdown")

  # Roles deleted since are held by nobody and are not shown.
  defp role_names(keys, roles) do
    for role <- roles, role.key in keys, do: role_label(role)
  end

  defp role_label(%{key: key} = role) do
    if key == GroupRole.everyone_key(), do: gettext("All members"), else: role.name
  end
end
