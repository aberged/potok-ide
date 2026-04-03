defmodule PotokIdeWeb.GroupLive.Show.EditGroupTab do
  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.Components

  attr :group, :map, required: true
  attr :current_profile, :map, required: true
  attr :edit_group_form, :any, required: true
  attr :format_options, :list, required: true

  def panel(assigns) do
    ~H"""
    <div id="group-panel-edit-group" class="card">
      <Components.group_path
        group={@group}
        current_profile={@current_profile}
        class="shadow-md"
      />
      <div class="card-body h-[calc(100dvh-12rem)] overflow-y-auto">
        <h3 class="card-title">{gettext("Edit group")}</h3>

        <.form
          for={@edit_group_form}
          id="group-edit-form"
          phx-change="validate_edit_group"
          phx-submit="save_edit_group"
        >
          <.input field={@edit_group_form[:name]} label={gettext("Name")} required />
          <.input
            field={@edit_group_form[:group_picture_url]}
            label={gettext("Group picture URL")}
            type="url"
          />
          <.input
            field={@edit_group_form[:description_format]}
            type="hidden"
          />
          <.input
            field={@edit_group_form[:description]}
            label={gettext("Description")}
            type="textarea"
          />
          <div class="flex items-start gap-4">
            <.input
              field={@edit_group_form[:is_public]}
              label={gettext("Public")}
              type="checkbox"
            />
            <.input
              field={@edit_group_form[:has_public_chat]}
              label={gettext("Public chat")}
              type="checkbox"
            />
            <fieldset class="fieldset">
              <div class="flex flex-wrap gap-3">
                <label
                  :for={{label, value} <- @format_options}
                  class="inline-flex items-center gap-2"
                >
                  <input
                    type="radio"
                    name={@edit_group_form[:description_format].name}
                    value={Atom.to_string(value)}
                    checked={description_format_checked?(@edit_group_form[:description_format].value, value)}
                    class="radio radio-sm"
                  />
                  <span>{label}</span>
                </label>
              </div>
            </fieldset>
          </div>
          <.button phx-disable-with={gettext("Saving...")} variant="primary">
            {gettext("Save changes")}
          </.button>
        </.form>
      </div>
    </div>
    """
  end

  defp description_format_checked?(current_value, option_value)
       when is_atom(current_value) and is_atom(option_value),
       do: current_value == option_value

  defp description_format_checked?(current_value, option_value) when is_binary(current_value),
    do: current_value == Atom.to_string(option_value)

  defp description_format_checked?(_, _), do: false
end
