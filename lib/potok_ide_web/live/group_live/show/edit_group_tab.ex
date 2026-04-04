defmodule PotokIdeWeb.GroupLive.Show.EditGroupTab do
  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.Components

  attr :group, :map, required: true
  attr :current_profile, :map, required: true
  attr :edit_group_form, :any, required: true
  attr :format_options, :list, required: true
  attr :description_details_open, :boolean, required: true

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
          <div class="flex flex-row items-start gap-4">
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
          </div>
          <details open={@description_details_open} class="rounded-2xl border border-base-300/80 bg-base-100/70 px-4 py-3 w-full mb-4 shadow-sm">
            <summary
              phx-click="set_edit_group_description_open"
              phx-value-open={if(@description_details_open, do: "false", else: "true")}
              class="cursor-pointer select-none font-medium text-base-content"
            >
              {gettext("Description")}
            </summary>
            <div class="group-description-workspace mt-4">
              <input
                id="group-description-layout-editor"
                type="radio"
                name="group-description-layout"
                value="editor"
                class="group-description-layout-input sr-only"
              />
              <input
                id="group-description-layout-split"
                type="radio"
                name="group-description-layout"
                value="split"
                class="group-description-layout-input sr-only"
                checked
              />
              <input
                id="group-description-layout-preview"
                type="radio"
                name="group-description-layout"
                value="preview"
                class="group-description-layout-input sr-only"
              />

              <div class="group-description-layout-controls mb-4 flex flex-wrap gap-2">
                <label
                  for="group-description-layout-editor"
                  class="group-description-layout-button"
                >
                  {gettext("Editor")}
                </label>
                <label
                  for="group-description-layout-split"
                  class="group-description-layout-button"
                >
                  {gettext("Split")}
                </label>
                <label
                  for="group-description-layout-preview"
                  class="group-description-layout-button"
                >
                  {gettext("Preview")}
                </label>
              </div>

              <div style="height: calc(100vh - 24rem);" class="grid group-description-layout gap-4 grid-cols-2 card-body overflow-y-auto p-0">
                <div class="group-description-pane group-description-pane-editor rounded-2xl border border-base-300/80 bg-base-100/80 p-3 shadow-sm">
                  <.input
                    field={@edit_group_form[:description]}
                    type="textarea"
                    rows="16"
                  />
                </div>

                <div class="group-description-pane group-description-pane-preview rounded-2xl border border-base-300/80 bg-base-100/80 p-4 shadow-sm">
                  <div class="mb-3 text-xs font-semibold uppercase tracking-[0.2em] text-base-content/55">
                    {gettext("Live preview")}
                  </div>

                  <div
                    :if={blank_description?(@edit_group_form[:description].value)}
                    class="flex min-h-48 items-center justify-center rounded-2xl border border-dashed border-base-300 bg-base-200/50 px-6 text-center text-sm text-base-content/60"
                  >
                    {gettext("Start typing to preview the description.")}
                  </div>

                  <Components.formatted_content
                    :if={!blank_description?(@edit_group_form[:description].value)}
                    content={@edit_group_form[:description].value || ""}
                    content_format={normalize_description_format(@edit_group_form[:description_format].value)}
                    class="min-h-48"
                  />
                </div>
              </div>
            </div>
            <div class="mt-3 flex items-start gap-4 h-3/4 overflow-auto">
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
          </details>
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

  defp normalize_description_format(current_value) when current_value in [:markdown, :html],
    do: current_value

  defp normalize_description_format("markdown"), do: :markdown
  defp normalize_description_format("html"), do: :html
  defp normalize_description_format(_), do: :markdown

  defp blank_description?(description), do: is_nil(description) or String.trim(description) == ""
end
