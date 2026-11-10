defmodule PotokIdeWeb.GroupLive.Show.RootMapTab do
  @moduledoc """
  The root's map (`RootMapState`): a bar of filters over a map of every group
  with a place the viewer sees, and of the areas it sees. The map is the
  browser's (`root_map.js`, ignored by patches); what stands over it, the
  count, the layers, the empty state, the list of a crowded spot and the card
  of the areas where the viewer tapped, is rendered here.
  """
  use PotokIdeWeb, :html

  alias PotokIde.Events.Format
  alias PotokIde.MapTiles
  alias PotokIde.Social.GroupPins
  alias PotokIdeWeb.Avatars
  alias PotokIdeWeb.GroupLive.Show.{ChoiceMenus, RootMapState}
  alias PotokIdeWeb.PinIcons

  attr :filters, :map, required: true, doc: "`@root_map_filters`"
  attr :show_public, :boolean, required: true, doc: "the root's public groups switch"
  attr :extent, :map, default: nil, doc: "`Social.map_extent/2`, nil until loaded"
  attr :empty_closed, :boolean, default: false, doc: "the empty state closed by the viewer"
  attr :total, :integer, default: nil, doc: "the groups in the map's view"
  attr :truncated, :boolean, default: false, doc: "the view had more cells than it shows"
  attr :spot, :map, default: nil, doc: "the groups of a crowded spot"
  attr :error, :boolean, default: false
  attr :range_form, :any, required: true
  attr :layers, :map, default: %{places: true, areas: true}, doc: "the layers shown"
  attr :here, :map, default: nil, doc: "the areas where the viewer tapped, and the one picked"
  attr :area_options, :list, default: [], doc: "the areas the filter's menu offers"
  attr :area_query, :string, default: "", doc: "what the filter's menu searches"
  attr :area_chosen, :list, default: [], doc: "the areas of the filter"

  def panel(assigns) do
    filters = assigns.filters

    assigns =
      assigns
      |> assign(:search_form, to_form(%{"q" => filters.search}, as: :root_map_search))
      |> assign(:area_form, to_form(%{"q" => assigns.area_query}, as: :root_map_area))
      |> assign(:empty_reason, RootMapState.empty_reason(filters, assigns.show_public))
      |> assign(:area_list, area_list(assigns.area_chosen, assigns.area_options))

    ~H"""
    <div id="group-panel-map" class="card relative flex min-h-0 flex-1 flex-col px-2 pb-2">
      <%!-- On a phone 360 px wide the six buttons and the search share one row:
           circles of 40 px, 4 px apart, the row flush with the left edge. --%>
      <div
        id="root-map-filters"
        class="group/filters relative z-45 flex shrink-0 flex-wrap items-start justify-end gap-1 px-2 pb-2 max-sm:pl-0 sm:gap-2"
      >
        <button
          id="root-map-public-toggle"
          type="button"
          phx-click="root_map_toggle_public"
          aria-pressed={to_string(@show_public)}
          title={
            if(@show_public,
              do: gettext("Hide public groups you are not in"),
              else: gettext("Show public groups you are not in")
            )
          }
          class={[
            "mt-1 inline-flex h-10 items-center gap-1.5 rounded-full border px-3 text-sm font-semibold shadow-xs max-sm:px-[11px] transition duration-150 ease-out hover:-translate-y-px active:scale-95 phx-click-loading:opacity-60 max-sm:group-has-[input:focus]/filters:hidden",
            if(@show_public,
              do: "border-primary/50 bg-base-100 text-primary hover:bg-base-200",
              else: "border-gray-500/50 bg-base-100 text-base-content/65 hover:text-base-content"
            )
          ]}
        >
          <.icon name={if(@show_public, do: "hero-globe-alt", else: "hero-eye-slash")} class="size-4" />
          <span class="hidden sm:inline">{gettext("Public groups")}</span>
        </button>

        <ChoiceMenus.choice_toggle
          id="root-map-relation"
          choices={ChoiceMenus.relation_choices()}
          selected={@filters.relation}
          idle_label={gettext("All groups")}
          title={gettext("Show the groups you are in or created")}
          label={gettext("Membership and authorship")}
        />
        <ChoiceMenus.choice_toggle
          id="root-map-preset"
          choices={ChoiceMenus.kind_choices()}
          selected={@filters.preset}
          idle_label={gettext("Kind")}
          title={gettext("Show one kind of groups")}
          label={gettext("Kind of groups")}
        />
        <ChoiceMenus.choice_toggle
          id="root-map-pin"
          choices={[%{key: "", icon: "hero-map-pin", title: gettext("All pins")}]}
          idle_label={gettext("Pin")}
          title={gettext("Show the groups with the pins you pick")}
          label={gettext("Pins on the map")}
          text={pin_text(@filters.pins)}
          icon="hero-map-pin"
          active={@filters.pins != []}
        />
        <ChoiceMenus.choice_toggle
          id="root-map-time"
          choices={period_choices()}
          selected={@filters.period}
          idle_label={gettext("Any time")}
          title={gettext("Show the groups of a time frame")}
          label={gettext("Time frame")}
          text={time_text(@filters)}
          icon={time_icon(@filters)}
          active={@filters.period != "any"}
        />
        <ChoiceMenus.choice_toggle
          id="root-map-area"
          choices={[%{key: "", icon: "hero-viewfinder-circle", title: gettext("All areas")}]}
          idle_label={gettext("Area")}
          title={gettext("Show the groups inside areas")}
          label={gettext("Areas")}
          text={area_text(@area_chosen)}
          icon="hero-viewfinder-circle"
          active={@filters.areas != []}
        />

        <.form for={@search_form} id="root-map-search-form" phx-change="root_map_search">
          <.search_field
            id="root-map-search-input"
            field={@search_form[:q]}
            reset_id="root-map-search-reset"
            reset_event="root_map_clear_search"
            placeholder={gettext("Search by name")}
          />
        </.form>
      </div>

      <%!-- Leaflet stacks its panes up to z-index 1000: `isolate` keeps them
           under the page's header and menus. --%>
      <div class="relative isolate min-h-0 flex-1 overflow-hidden rounded-3xl border border-base-300/70 bg-base-200">
        <div id="root-map-wrap" phx-update="ignore" class="absolute inset-0">
          <div
            id="root-map"
            phx-hook="RootMap"
            class="potok-map size-full"
            data-tiles={MapTiles.url_template("/tiles")}
            data-attribution={MapTiles.attribution()}
            data-max-zoom={MapTiles.max_zoom()}
            data-default-bounds={Jason.encode!(MapTiles.default_bounds())}
            data-pins={Jason.encode!(PinIcons.catalogue())}
            data-cluster-label={gettext("Groups here: %{count}. Tap to see them.", count: "%{count}")}
            data-load-error={gettext("The map could not load.")}
          >
          </div>
        </div>

        <div class="pointer-events-none absolute inset-x-2 top-2 z-[1100] flex items-start justify-between gap-2">
          <p
            :if={@total && @extent && @extent.count > 0}
            id="root-map-total"
            class="pointer-events-auto rounded-full border border-base-300/70 bg-base-100/90 px-3 py-1.5 text-xs font-semibold text-base-content/80 shadow-sm backdrop-blur"
          >
            {if(@total == 0,
              do: gettext("No groups in this part of the map"),
              else:
                ngettext(
                  "%{count} group in this part of the map",
                  "%{count} groups in this part of the map",
                  @total
                )
            )}
            <span :if={@truncated} id="root-map-truncated" class="font-normal text-base-content/60">
              {" · " <> gettext("only a part, zoom in")}
            </span>
          </p>
          <span :if={!(@total && @extent && @extent.count > 0)}></span>
          <div class="flex shrink-0 items-center gap-2">
            <button
              :if={@extent && @extent.count > 0}
              id="root-map-fit"
              type="button"
              phx-click="root_map_fit"
              class="pointer-events-auto inline-flex h-9 items-center gap-1.5 rounded-full border border-base-300/70 bg-base-100/90 px-3 text-xs font-semibold text-base-content/80 shadow-sm backdrop-blur transition duration-150 ease-out hover:-translate-y-px hover:text-base-content active:scale-95"
            >
              <.icon name="hero-arrows-pointing-out" class="size-4" />
              {pgettext("map", "Show all")}
            </button>
            <button
              id="root-map-layers-toggle"
              type="button"
              phx-click={JS.dispatch("potok:choice-menu-open", to: "#root-map-layers-menu")}
              aria-haspopup="menu"
              aria-controls="root-map-layers-menu"
              aria-label={gettext("Map layers")}
              title={gettext("Map layers")}
              class={[
                "pointer-events-auto inline-flex size-9 items-center justify-center rounded-full border bg-base-100/90 shadow-sm backdrop-blur transition duration-150 ease-out hover:-translate-y-px active:scale-95",
                if(@layers.places and @layers.areas,
                  do: "border-base-300/70 text-base-content/80 hover:text-base-content",
                  else: "border-primary/50 text-primary"
                )
              ]}
            >
              <.icon name="hero-square-3-stack-3d" class="size-4" />
            </button>
          </div>
        </div>

        <div
          :if={@extent && @extent.count == 0 && !@empty_closed}
          id="root-map-empty"
          class="pointer-events-none absolute inset-0 z-[1100] flex items-center justify-center p-6"
        >
          <div class="pointer-events-auto relative max-w-sm rounded-3xl border border-base-300/70 bg-base-100/95 p-5 text-center shadow-xl backdrop-blur">
            <.icon_button
              id="root-map-empty-close"
              type="button"
              phx-click="root_map_empty_close"
              icon="hero-x-mark"
              label={gettext("Close")}
              class="absolute right-2 top-2"
            />
            <span class="mx-auto mb-3 inline-flex size-11 items-center justify-center rounded-2xl bg-primary/10 text-primary">
              <.icon name="hero-map" class="size-6" />
            </span>
            <p class="text-sm font-semibold">
              <%= case @empty_reason do %>
                <% :area -> %>
                  {gettext("No group with a place inside the chosen areas fits these filters.")}
                <% :filters -> %>
                  {gettext("No group with a place fits these filters.")}
                <% :public -> %>
                  {gettext("Public groups you are not in are hidden.")}
                <% :none -> %>
                  {gettext("None of your groups has a place on the map yet.")}
              <% end %>
            </p>
            <p class="mt-1 text-xs text-base-content/65">
              {gettext("A group gets its place in its settings, on the Location card.")}
            </p>
            <.button
              :if={@empty_reason == :filters}
              id="root-map-clear-filters"
              type="button"
              phx-click="root_map_clear_filters"
              variant="soft"
              size="sm"
              class="mt-3"
            >
              {gettext("Clear filters")}
            </.button>
            <.button
              :if={@empty_reason == :public}
              id="root-map-show-public"
              type="button"
              phx-click="root_map_toggle_public"
              variant="soft"
              size="sm"
              class="mt-3"
            >
              <.icon name="hero-globe-alt" class="size-4" />
              {gettext("Show public groups")}
            </.button>
          </div>
        </div>

        <p
          :if={@error}
          id="root-map-error"
          role="alert"
          class="absolute inset-x-2 bottom-2 z-[1100] flex items-start gap-1.5 rounded-2xl border border-error/30 bg-base-100/95 px-3 py-2 text-xs text-error shadow-lg"
        >
          <.icon name="hero-exclamation-triangle" class="mt-0.5 size-4 shrink-0" />
          {gettext("The map took too long to load. Narrow the filters or zoom in.")}
        </p>

        <section
          :if={@spot}
          id="root-map-spot"
          aria-labelledby="root-map-spot-title"
          class="absolute inset-x-2 bottom-2 z-[1100] flex max-h-[55%] flex-col overflow-hidden rounded-3xl border border-base-300/70 bg-base-100/95 shadow-2xl backdrop-blur sm:left-auto sm:w-80"
        >
          <header class="flex items-center gap-2 border-b border-base-300/60 px-4 py-2.5">
            <h3 id="root-map-spot-title" class="min-w-0 flex-1 truncate text-sm font-semibold">
              {gettext("Groups in this place")}
            </h3>
            <.icon_button
              id="root-map-spot-close"
              type="button"
              phx-click="root_map_spot_close"
              icon="hero-x-mark"
              label={gettext("Close")}
            />
          </header>
          <ul class="min-h-0 flex-1 overflow-y-auto p-1.5">
            <li :for={group <- @spot.groups}>
              <button
                id={"root-map-spot-group-#{group.id}"}
                type="button"
                phx-click="root_map_open"
                phx-value-id={group.id}
                class="flex w-full cursor-pointer items-center gap-3 rounded-2xl px-2.5 py-2 text-left transition-colors duration-150 hover:bg-base-200 focus-visible:bg-base-200 focus-visible:outline-none"
              >
                <.group_pin
                  id={"root-map-spot-pin-#{group.id}"}
                  group={group}
                  class="h-8 w-[1.6rem] shrink-0 drop-shadow-sm"
                />
                <span class="min-w-0 flex-1">
                  <span class="block truncate text-sm font-semibold">{group.name}</span>
                  <span class="flex items-center gap-1 text-xs text-base-content/60">
                    <.icon
                      name={
                        if(group.is_public,
                          do: "hero-globe-alt-micro",
                          else: "hero-lock-closed-micro"
                        )
                      }
                      class="size-3.5"
                    />
                    <span class="truncate">{place_label(group)}</span>
                  </span>
                </span>
              </button>
            </li>
          </ul>
          <p
            :if={@spot.more?}
            class="border-t border-base-300/60 px-4 py-2 text-xs text-base-content/65"
          >
            {gettext("More groups stand here. Search by name to find one.")}
          </p>
        </section>

        <.here_card :if={@here && !@spot} here={@here} chosen={@filters.areas} />
      </div>

      <ChoiceMenus.choice_menu
        id="root-map-layers"
        choices={[]}
        event="root_map_layer"
        param="layer"
        label={gettext("Map layers")}
      >
        <:top>
          <p class="px-2.5 pb-1 pt-1.5 text-xs font-semibold text-base-content/60">
            {gettext("Map layers")}
          </p>
          <button
            :for={layer <- layer_rows()}
            id={"root-map-layer-#{layer.key}"}
            type="button"
            role="menuitemcheckbox"
            aria-checked={to_string(Map.fetch!(@layers, layer.key))}
            phx-click="root_map_layer"
            phx-value-layer={layer.key}
            class="group/layer flex w-full cursor-pointer items-center gap-2.5 rounded-xl px-2.5 py-2 text-left text-sm transition-colors duration-150 hover:bg-base-200 focus-visible:bg-base-200 focus-visible:outline-none"
          >
            <span class={[
              "inline-flex size-7 shrink-0 items-center justify-center rounded-lg transition-colors",
              if(Map.fetch!(@layers, layer.key),
                do: "bg-primary/15 text-primary",
                else: "bg-base-200 text-base-content/50"
              )
            ]}>
              <.icon name={layer.icon} class="size-4" />
            </span>
            <span class="min-w-0 flex-1">
              <span class="block font-semibold">{layer.title}</span>
              <span class="block text-xs text-base-content/60">{layer.hint}</span>
            </span>
            <span
              aria-hidden="true"
              class={[
                "relative inline-flex h-5 w-9 shrink-0 rounded-full transition-colors duration-150",
                if(Map.fetch!(@layers, layer.key), do: "bg-primary", else: "bg-base-300")
              ]}
            >
              <span class={[
                "absolute top-0.5 size-4 rounded-full bg-base-100 shadow-sm transition-all duration-150",
                if(Map.fetch!(@layers, layer.key), do: "left-4.5", else: "left-0.5")
              ]}>
              </span>
            </span>
          </button>
        </:top>
      </ChoiceMenus.choice_menu>

      <ChoiceMenus.choice_menu
        id="root-map-area"
        choices={[]}
        event="root_map_area"
        param="id"
        label={gettext("Areas")}
      >
        <:top>
          <.form
            for={@area_form}
            id="root-map-area-search-form"
            phx-change="root_map_area_search"
            phx-submit="root_map_area_search"
            class="px-1 pb-1"
          >
            <.input
              field={@area_form[:q]}
              id="root-map-area-search-input"
              type="search"
              placeholder={gettext("Find an area")}
              autocomplete="off"
              phx-debounce="250"
            />
          </.form>
          <button
            id="root-map-area-option-all"
            type="button"
            role="menuitemradio"
            aria-checked={to_string(@filters.areas == [])}
            phx-click={
              JS.push("root_map_area_clear") |> ChoiceMenus.close_choice_menu("root-map-area")
            }
            class={[
              "flex w-full cursor-pointer items-center gap-2.5 rounded-xl px-2.5 py-2 text-left text-sm transition-colors duration-150 hover:bg-base-200 focus-visible:bg-base-200 focus-visible:outline-none",
              if(@filters.areas == [],
                do: "font-semibold text-primary",
                else: "font-medium text-base-content/80"
              )
            ]}
          >
            <span class="inline-flex size-7 shrink-0 items-center justify-center rounded-lg bg-base-200">
              <.icon name="hero-viewfinder-circle" class="size-4" />
            </span>
            <span class="min-w-0 flex-1 truncate">{gettext("All areas")}</span>
            <.icon :if={@filters.areas == []} name="hero-check" class="size-4 shrink-0" />
          </button>
          <div class="mx-2 my-1 border-t border-base-300/70" aria-hidden="true"></div>
          <button
            :for={area <- @area_list}
            id={"root-map-area-option-#{area.id}"}
            type="button"
            role="menuitemcheckbox"
            aria-checked={to_string(area.id in @filters.areas)}
            phx-click="root_map_area"
            phx-value-id={area.id}
            class={[
              "flex w-full cursor-pointer items-center gap-2.5 rounded-xl px-2.5 py-1.5 text-left text-sm transition-colors duration-150 hover:bg-base-200 focus-visible:bg-base-200 focus-visible:outline-none",
              if(area.id in @filters.areas,
                do: "font-semibold text-primary",
                else: "font-medium text-base-content/80"
              )
            ]}
          >
            <.group_pin
              id={"root-map-area-pin-#{area.id}"}
              group={area}
              class="h-7 w-[1.4rem] shrink-0 drop-shadow-sm"
            />
            <span class="min-w-0 flex-1 truncate">{area.name}</span>
            <.icon :if={area.id in @filters.areas} name="hero-check" class="size-4 shrink-0" />
          </button>
          <p
            :if={@area_list == []}
            id="root-map-area-none"
            class="px-2.5 py-2 text-xs text-base-content/60"
          >
            {if(@area_query == "",
              do: gettext("No group you see has an area yet."),
              else: gettext("No area by that name.")
            )}
          </p>
        </:top>
      </ChoiceMenus.choice_menu>

      <ChoiceMenus.choice_menu
        id="root-map-relation"
        choices={ChoiceMenus.relation_choices()}
        selected={@filters.relation}
        event="root_map_relation"
        param="relation"
        label={gettext("Membership and authorship")}
      />
      <ChoiceMenus.choice_menu
        id="root-map-preset"
        choices={ChoiceMenus.kind_choices()}
        selected={@filters.preset}
        event="root_map_preset"
        param="preset"
        label={gettext("Kind of groups")}
      />
      <ChoiceMenus.choice_menu
        id="root-map-pin"
        choices={[]}
        event="root_map_pin"
        param="pin"
        label={gettext("Pins on the map")}
      >
        <:top>
          <button
            id="root-map-pin-option-all"
            type="button"
            role="menuitemradio"
            aria-checked={to_string(@filters.pins == [])}
            phx-click={JS.push("root_map_pin_clear") |> ChoiceMenus.close_choice_menu("root-map-pin")}
            class={[
              "flex w-full cursor-pointer items-center gap-2.5 rounded-xl px-2.5 py-2 text-left text-sm transition-colors duration-150 hover:bg-base-200 focus-visible:bg-base-200 focus-visible:outline-none",
              if(@filters.pins == [],
                do: "font-semibold text-primary",
                else: "font-medium text-base-content/80"
              )
            ]}
          >
            <span class="inline-flex size-7 shrink-0 items-center justify-center rounded-lg bg-base-200">
              <.icon name="hero-map-pin" class="size-4" />
            </span>
            <span class="min-w-0 flex-1 truncate">{gettext("All pins")}</span>
            <.icon :if={@filters.pins == []} name="hero-check" class="size-4 shrink-0" />
          </button>
          <p class="px-2.5 pb-1 pt-3 text-[0.7rem] font-semibold uppercase tracking-wide text-base-content/55">
            {gettext("Kind and picture")}
          </p>
          <button
            :for={{key, icon} <- [{"kind", "hero-squares-2x2"}, {"picture", "hero-photo"}]}
            id={"root-map-pin-option-#{key}"}
            type="button"
            role="menuitemcheckbox"
            aria-checked={to_string(key in @filters.pins)}
            phx-click="root_map_pin"
            phx-value-pin={key}
            class={[
              "flex w-full cursor-pointer items-center gap-2.5 rounded-xl px-2.5 py-1.5 text-left text-sm transition-colors duration-150 hover:bg-base-200 focus-visible:bg-base-200 focus-visible:outline-none",
              if(key in @filters.pins,
                do: "font-semibold text-primary",
                else: "font-medium text-base-content/80"
              )
            ]}
          >
            <span class="inline-flex h-7 w-[1.4rem] shrink-0 items-center justify-center rounded-lg bg-base-200">
              <.icon name={icon} class="size-4" />
            </span>
            <span class="min-w-0 flex-1 truncate">{pin_label(key)}</span>
            <.icon :if={key in @filters.pins} name="hero-check" class="size-4 shrink-0" />
          </button>
          <%= for section <- PinIcons.sections() do %>
            <p class="px-2.5 pb-1 pt-3 text-[0.7rem] font-semibold uppercase tracking-wide text-base-content/55">
              {section.title}
            </p>
            <button
              :for={key <- section.keys}
              id={"root-map-pin-option-#{key}"}
              type="button"
              role="menuitemcheckbox"
              aria-checked={to_string(key in @filters.pins)}
              phx-click="root_map_pin"
              phx-value-pin={key}
              class={[
                "flex w-full cursor-pointer items-center gap-2.5 rounded-xl px-2.5 py-1.5 text-left text-sm transition-colors duration-150 hover:bg-base-200 focus-visible:bg-base-200 focus-visible:outline-none",
                if(key in @filters.pins,
                  do: "font-semibold text-primary",
                  else: "font-medium text-base-content/80"
                )
              ]}
            >
              <PinIcons.pin
                id={"root-map-pin-icon-#{key}"}
                color={PinIcons.icon_look(key).color}
                paths={PinIcons.icon_look(key).paths}
                class="h-7 w-[1.4rem] shrink-0 drop-shadow-sm"
              />
              <span class="min-w-0 flex-1 truncate">{PinIcons.label(key)}</span>
              <.icon :if={key in @filters.pins} name="hero-check" class="size-4 shrink-0" />
            </button>
          <% end %>
        </:top>
      </ChoiceMenus.choice_menu>
      <ChoiceMenus.choice_menu
        id="root-map-time"
        choices={period_choices()}
        selected={@filters.period}
        event="root_map_period"
        param="period"
        label={gettext("Time frame")}
      >
        <:top>
          <div
            id="root-map-time-measure"
            role="group"
            aria-label={gettext("What the time frame counts")}
            class="mb-1.5 grid grid-cols-2 gap-1 rounded-xl bg-base-200 p-1"
          >
            <button
              :for={
                {key, label} <- [
                  {:created, gettext("Created")},
                  {:active, gettext("Last message")}
                ]
              }
              id={"root-map-time-#{key}"}
              type="button"
              phx-click="root_map_time"
              phx-value-time={key}
              aria-pressed={to_string(@filters.time == key)}
              class={[
                "cursor-pointer rounded-lg px-2 py-1.5 text-xs font-semibold transition duration-150 ease-out",
                if(@filters.time == key,
                  do: "bg-base-100 text-base-content shadow-sm",
                  else: "text-base-content/65 hover:text-base-content"
                )
              ]}
            >
              {label}
            </button>
          </div>
        </:top>
        <:bottom>
          <div class="mx-2 my-1 border-t border-base-300/70" aria-hidden="true"></div>
          <.form
            for={@range_form}
            id="root-map-range-form"
            phx-submit={
              JS.push("root_map_range")
              |> ChoiceMenus.close_choice_menu("root-map-time")
            }
            class="px-2 pb-1.5 pt-1"
          >
            <p class={[
              "mb-1.5 flex items-center gap-1.5 text-xs font-semibold",
              if(@filters.period == "custom", do: "text-primary", else: "text-base-content/70")
            ]}>
              <.icon name="hero-calendar-date-range" class="size-4" />
              {gettext("From date to date")}
            </p>
            <div class="grid grid-cols-1">
              <.input
                field={@range_form[:from]}
                id="root-map-range-from"
                type="date"
                label={gettext("From")}
              />
              <.input
                field={@range_form[:to]}
                id="root-map-range-to"
                type="date"
                label={gettext("To")}
              />
            </div>
            <.button
              id="root-map-range-submit"
              type="submit"
              variant="soft"
              size="sm"
              class="w-full"
            >
              {gettext("Show")}
            </.button>
          </.form>
        </:bottom>
      </ChoiceMenus.choice_menu>
    </div>
    """
  end

  defp period_choices do
    [
      %{
        key: "24h",
        icon: "hero-clock",
        title: gettext("Last 24 hours"),
        short: gettext("24 hours")
      },
      %{
        key: "7d",
        icon: "hero-calendar-days",
        title: gettext("Last 7 days"),
        short: gettext("7 days")
      },
      %{
        key: "30d",
        icon: "hero-calendar-days",
        title: gettext("Last 30 days"),
        short: gettext("30 days")
      },
      %{
        key: "12m",
        icon: "hero-calendar",
        title: gettext("Last 12 months"),
        short: gettext("12 months")
      },
      %{key: "any", icon: "hero-squares-2x2", title: gettext("Any time"), divider: true}
    ]
  end

  # The button says the time frame, and that it counts messages when it does.
  defp time_text(%{period: "any"}), do: gettext("Any time")

  defp time_text(%{period: period, time: time} = filters) do
    frame =
      case period do
        "custom" -> range_text(filters)
        key -> Enum.find(period_choices(), &(&1.key == key)).short
      end

    if time == :active, do: gettext("Active · %{frame}", frame: frame), else: frame
  end

  defp range_text(%{from: %Date{} = from, to: %Date{} = to}) when from == to,
    do: Format.day_month(from)

  defp range_text(%{from: %Date{} = from, to: %Date{} = to}),
    do: gettext("%{from} – %{to}", from: Format.day_month(from), to: Format.day_month(to))

  defp range_text(%{from: %Date{} = from}),
    do: gettext("from %{date}", date: Format.day_month(from))

  defp range_text(%{to: %Date{} = to}), do: gettext("until %{date}", date: Format.day_month(to))

  attr :here, :map, required: true
  attr :chosen, :list, required: true

  # The areas where the viewer tapped: the one picked, smallest first, what
  # it does, and the bigger ones around it.
  defp here_card(assigns) do
    area = Enum.find(assigns.here.areas, &(&1.id == assigns.here.selected))

    assigns =
      assigns
      |> assign(:area, area)
      |> assign(:others, Enum.reject(assigns.here.areas, &(&1.id == area.id)))

    ~H"""
    <section
      id="root-map-here"
      aria-labelledby="root-map-here-title"
      class="absolute inset-x-2 bottom-2 z-[1100] flex max-h-[55%] flex-col overflow-hidden rounded-3xl border border-base-300/70 bg-base-100/95 shadow-2xl backdrop-blur sm:left-auto sm:w-80"
    >
      <header class="flex items-center gap-3 px-4 pt-3">
        <.group_pin
          id="root-map-here-pin"
          group={@area}
          class="h-9 w-7 shrink-0 drop-shadow-sm"
        />
        <div class="min-w-0 flex-1">
          <h3 id="root-map-here-title" class="truncate text-sm font-semibold">{@area.name}</h3>
          <p class="flex items-center gap-1 text-xs text-base-content/60">
            <.icon
              name={if(@area.is_public, do: "hero-globe-alt-micro", else: "hero-lock-closed-micro")}
              class="size-3.5"
            />
            <span class="truncate">
              {gettext("Area")}{" · " <> PinIcons.kind_label(GroupPins.kind(@area))}
            </span>
          </p>
        </div>
        <.icon_button
          id="root-map-here-close"
          type="button"
          phx-click="root_map_here_close"
          icon="hero-x-mark"
          label={gettext("Close")}
        />
      </header>
      <div class="flex flex-wrap gap-2 px-4 pb-3 pt-2.5">
        <.button
          id="root-map-here-open"
          type="button"
          phx-click="root_map_open"
          phx-value-id={@area.id}
          variant="soft"
          size="sm"
        >
          <.icon name="hero-arrow-top-right-on-square" class="size-4" />
          {gettext("Open")}
        </.button>
        <.button
          id="root-map-here-filter"
          type="button"
          phx-click="root_map_area_only"
          phx-value-id={@area.id}
          variant="soft"
          size="sm"
          aria-pressed={to_string(@chosen == [@area.id])}
        >
          <.icon name="hero-viewfinder-circle" class="size-4" />
          {if(@chosen == [@area.id], do: gettext("Show all groups"), else: gettext("Only inside"))}
        </.button>
        <.icon_button
          id="root-map-here-fit"
          type="button"
          phx-click="root_map_area_fit"
          phx-value-id={@area.id}
          icon="hero-magnifying-glass-plus"
          label={gettext("Zoom to the area")}
        />
      </div>
      <div :if={@others != []} class="border-t border-base-300/60 px-4 py-2.5">
        <p class="text-xs font-semibold text-base-content/60">{gettext("Also here")}</p>
        <div class="mt-1.5 flex flex-wrap gap-1.5">
          <button
            :for={other <- @others}
            id={"root-map-here-pick-#{other.id}"}
            type="button"
            phx-click="root_map_here_pick"
            phx-value-id={other.id}
            class="inline-flex max-w-full cursor-pointer items-center gap-1 rounded-full border border-base-300/70 bg-base-100 px-2.5 py-1 text-xs font-semibold text-base-content/80 transition duration-150 ease-out hover:-translate-y-px hover:border-primary/40 hover:text-primary active:scale-95"
          >
            <span class="truncate">{other.name}</span>
          </button>
        </div>
      </div>
    </section>
    """
  end

  defp layer_rows do
    [
      %{
        key: :places,
        icon: "hero-map-pin",
        title: gettext("Places"),
        hint: gettext("Groups as pins, by the filters")
      },
      %{
        key: :areas,
        icon: "hero-viewfinder-circle",
        title: gettext("Areas"),
        hint: gettext("Borders of the areas wide enough, under the pins")
      }
    ]
  end

  attr :id, :string, required: true
  attr :group, :map, required: true
  attr :class, :string, required: true

  # A group's pin, with its kind's mark when it picked its own (`PinIcons.look/1`).
  defp group_pin(assigns) do
    assigns = assign(assigns, :look, PinIcons.look(assigns.group))

    ~H"""
    <PinIcons.pin
      id={@id}
      color={@look.color}
      paths={@look.paths}
      picture_url={@look.picture && Avatars.group_avatar_url(@group)}
      mark={@look.mark}
      class={@class}
    />
    """
  end

  # What the pin filter's button says.
  defp pin_text([]), do: nil
  defp pin_text([key]), do: pin_label(key)
  defp pin_text(keys), do: ngettext("%{count} pin", "%{count} pins", length(keys))

  defp pin_label("kind"), do: gettext("Pin of its kind")
  defp pin_label("picture"), do: gettext("Group picture")
  defp pin_label(key), do: PinIcons.label(key)

  # What a group on the map is, under its name: an area or its kind.
  defp place_label(%{area_west: west} = group) when is_number(west),
    do: gettext("Area") <> " · " <> PinIcons.kind_label(GroupPins.kind(group))

  defp place_label(group), do: PinIcons.kind_label(GroupPins.kind(group))

  defp area_text([]), do: nil
  defp area_text([area]), do: gettext("In %{name}", name: area.name)

  defp area_text(areas),
    do: ngettext("In %{count} area", "In %{count} areas", length(areas))

  # The menu lists the chosen areas first, then what the search found.
  defp area_list(chosen, options) do
    ids = MapSet.new(chosen, & &1.id)
    chosen ++ Enum.reject(options, &MapSet.member?(ids, &1.id))
  end

  defp time_icon(%{period: "any"}), do: "hero-squares-2x2"
  defp time_icon(%{time: :active}), do: "hero-chat-bubble-left-ellipsis"
  defp time_icon(_filters), do: "hero-clock"
end
