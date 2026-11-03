defmodule PotokIdeWeb.GroupLive.Show.CreateGroupTab do
  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.Components

  attr :new_group_form, :any, required: true
  attr :format_options, :list, required: true
  attr :home_page_options, :list, required: true
  attr :value_parent_options, :list, required: true
  attr :group, :map, required: true
  attr :current_profile, :map, default: nil
  attr :group_path, :list, required: true

  attr :section, :string,
    default: "basics",
    doc: "the card on screen, picked in the section bar (see `sections/0`)"

  # Laid out like the edit tab: cards picked one at a time, the others only
  # hidden so the form still sends every field, and the actions in a bar at
  # the bottom that is always in reach. The form is `novalidate`: the browser
  # cannot point at a required field in a hidden card and would silently not
  # submit, so the server checks and opens the card with the error.
  def panel(assigns) do
    ~H"""
    <div id="group-panel-create-group" class="flex min-h-0 flex-1 flex-col px-2">
      <Components.group_path
        :if={!@group.is_root}
        path={@group_path}
        group={@group}
        current_profile={@current_profile}
        class="shadow-md"
      />
      <Components.tab_body id="group-create-scroll">
        <.page_header id="group-create-header" icon="hero-folder-plus">
          {gettext("Create sub-group")}
          <:subtitle>{gettext("A new group inside this one, with you as its admin.")}</:subtitle>
        </.page_header>

        <Components.settings_tabs
          id="group-create-sections"
          tabs={sections()}
          current={@section}
          event="set_create_group_section"
          tab_id_prefix="group-create-tab"
        />

        <.form
          for={@new_group_form}
          id="group-create-form"
          phx-change="validate_group"
          phx-submit="create_group"
          novalidate
        >
          <Components.settings_card
            id="group-create-basics"
            tab_id="group-create-tab-basics"
            active={@section == "basics"}
            icon="hero-identification"
            title={gettext("Basics")}
            subtitle={gettext("The name and picture members see.")}
          >
            <.input field={@new_group_form[:name]} label={gettext("Name")} required />
            <Components.group_picture_form_field field={@new_group_form[:group_picture_url]} />
          </Components.settings_card>

          <Components.settings_card
            id="group-create-access"
            tab_id="group-create-tab-access"
            active={@section == "access"}
            icon="hero-lock-open"
            title={gettext("Access and members")}
            subtitle={gettext("Who sees the group and who is a member.")}
          >
            <%!-- "Root public" only ever turned "Public" on, so the form
                 leaves it off and "Public" alone decides. --%>
            <input type="hidden" name={@new_group_form[:is_root_public].name} value="false" />
            <.input
              field={@new_group_form[:is_public]}
              label={gettext("Public group")}
              type="checkbox"
            />
            <p class="-mt-1 mb-3 text-xs text-base-content/60">
              {gettext("Everyone can see the group and ask to join it.")}
            </p>

            <%!-- The root's children never inherit: they would hold every profile. --%>
            <div :if={!@group.is_root} id="group-create-inherits-members">
              <.input
                field={@new_group_form[:inherits_members]}
                label={gettext("Inherit members")}
                type="checkbox"
              />
              <p class="-mt-1 mb-1 text-xs text-base-content/60">
                {gettext(
                  "Every member of this group is also a member of the sub-group, with the same roles."
                )}
              </p>
            </div>
          </Components.settings_card>

          <Components.settings_card
            id="group-create-home"
            tab_id="group-create-tab-home"
            active={@section == "home"}
            icon="hero-home"
            title={gettext("What opens first")}
            subtitle={gettext("The panel and the description a member sees on opening the group.")}
          >
            <.input
              field={@new_group_form[:home_page]}
              label={gettext("Home page")}
              type="select"
              options={@home_page_options}
            />
          </Components.settings_card>

          <Components.settings_card
            id="group-create-description"
            tab_id="group-create-tab-description"
            active={@section == "description"}
            icon="hero-document-text"
            title={gettext("Description")}
            subtitle={gettext("The text or app on the group's home page.")}
          >
            <.input
              field={@new_group_form[:uses_api]}
              label={gettext("The description is an app (API)")}
              type="checkbox"
            />
            <p class="-mt-1 mb-3 text-xs text-base-content/60">
              {gettext("The app runs on the group's home page and can keep its own data.")}
            </p>

            <Components.description_workspace
              id_prefix="group-create-description"
              description_field={@new_group_form[:description]}
              format_field={@new_group_form[:description_format]}
              uses_api={@new_group_form[:uses_api].value}
              format_options={@format_options}
            />
          </Components.settings_card>

          <.input
            :if={false}
            field={@new_group_form[:parent_value_id]}
            label={gettext("Reply to value (optional)")}
            type="select"
            prompt={gettext("(none)")}
            options={@value_parent_options}
          />
        </.form>

        <%!-- Outside the form, which it submits through `form`, so it can
             stick to the bottom over every card. --%>
        <div
          id="group-create-bar"
          class="sticky bottom-0 z-10 mt-4 flex flex-wrap items-center justify-end gap-2 rounded-3xl border border-base-300/70 bg-base-100/95 px-4 py-3 shadow-xl shadow-primary/10 backdrop-blur"
        >
          <.button
            id="group-create-cancel"
            navigate={~p"/groups/#{@group.id}/sub_groups"}
            variant="ghost"
          >
            {gettext("Cancel")}
          </.button>
          <.button
            id="group-create-submit"
            type="submit"
            form="group-create-form"
            phx-disable-with={gettext("Creating...")}
            variant="primary"
          >
            {gettext("Create")}
          </.button>
        </div>
      </Components.tab_body>
    </div>
    """
  end

  # The cards of the section bar, in order: `{key, panel id, label, danger?}`.
  # The keys are the ones `GroupLive.Show` accepts for `set_create_group_section`.
  defp sections do
    [
      {"basics", "group-create-basics", gettext("Basics"), false},
      {"access", "group-create-access", gettext("Access"), false},
      {"home", "group-create-home", gettext("Opens first"), false},
      {"description", "group-create-description", gettext("Description"), false}
    ]
  end
end
