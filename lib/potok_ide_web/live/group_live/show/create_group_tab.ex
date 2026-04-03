defmodule PotokIdeWeb.GroupLive.Show.CreateGroupTab do
  use PotokIdeWeb, :html

  attr :new_group_form, :any, required: true
  attr :format_options, :list, required: true
  attr :value_parent_options, :list, required: true

  def panel(assigns) do
    ~H"""
    <div id="group-panel-create-group" class="card">
      <div class="card-body h-[calc(100dvh-8rem)] overflow-y-auto">
        <h3 class="card-title">{gettext("Create sub-group")}</h3>

        <.form for={@new_group_form} phx-change="validate_group" phx-submit="create_group">
          <.input field={@new_group_form[:name]} label={gettext("Name")} required />
          <.input
            field={@new_group_form[:group_picture_url]}
            label={gettext("Group picture URL")}
            type="url"
          />
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
            field={@new_group_form[:is_public]}
            label={gettext("Public")}
            type="checkbox"
          />
          <.input
            field={@new_group_form[:has_public_chat]}
            label={gettext("Public chat")}
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
          <.button phx-disable-with={gettext("Creating...")} variant="primary">
            {gettext("Create")}
          </.button>
        </.form>
      </div>
    </div>
    """
  end
end
