defmodule PotokIdeWeb.GroupLive.Show.CreateGroupTab do
  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.Components

  attr :new_group_form, :any, required: true
  attr :format_options, :list, required: true
  attr :home_page_options, :list, required: true
  attr :value_parent_options, :list, required: true
  attr :group, :map, required: true
  attr :current_profile, :map, default: nil

  def panel(assigns) do
    ~H"""
    <div id="group-panel-create-group" class="px-2">
      <Components.group_path
        :if={!@group.is_root}
        group={@group}
        current_profile={@current_profile}
        class="shadow-md"
      />
      <div class="h-[calc(100dvh-12rem-var(--app-safe-area-bottom)-var(--app-safe-area-top))] overflow-y-auto px-2 py-4">
        <h3 class="card-title">{gettext("Create sub-group")}</h3>

        <.form for={@new_group_form} phx-change="validate_group" phx-submit="create_group">
          <.input field={@new_group_form[:name]} label={gettext("Name")} required />
          <Components.group_picture_form_field field={@new_group_form[:group_picture_url]} />
          <.input
            :if={false}
            field={@new_group_form[:description_format]}
            label={gettext("Format")}
            type="select"
            options={@format_options}
          />
          <.input
            field={@new_group_form[:description]}
            label={gettext("Description")}
            type="textarea"
          />
          <.input
            field={@new_group_form[:home_page]}
            label={gettext("Home page")}
            type="select"
            options={@home_page_options}
          />
          <.input
            field={@new_group_form[:is_public]}
            label={gettext("Public")}
            type="checkbox"
          />
          <.input
            field={@new_group_form[:is_root_public]}
            label={gettext("Root public")}
            type="checkbox"
          />
          <.input
            :if={false}
            field={@new_group_form[:parent_value_id]}
            label={gettext("Reply to value (optional)")}
            type="select"
            prompt={gettext("(none)")}
            options={@value_parent_options}
          />
          <div class="mt-4 flex flex-wrap gap-2">
            <.button phx-disable-with={gettext("Creating...")} variant="primary">
              {gettext("Create")}
            </.button>
            <.button navigate={~p"/groups/#{@group.id}/sub_groups"} type="button">
              {gettext("Cancel")}
            </.button>
          </div>
        </.form>
      </div>
    </div>
    """
  end
end
