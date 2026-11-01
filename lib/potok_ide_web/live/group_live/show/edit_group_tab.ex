defmodule PotokIdeWeb.GroupLive.Show.EditGroupTab do
  use PotokIdeWeb, :html

  alias PotokIde.Social.GroupRole
  alias PotokIdeWeb.GroupLive.Show.Components

  attr :group, :map, required: true
  attr :current_profile, :map, required: true
  attr :group_path, :list, required: true
  attr :edit_group_form, :any, required: true
  attr :format_options, :list, required: true
  attr :home_page_options, :list, required: true
  attr :description_details_open, :boolean, required: true
  attr :can_delete_group, :boolean, default: false

  attr :alt_descriptions, :list, default: [], doc: "every alternative description of the group"

  attr :alt_description_form, :any,
    default: nil,
    doc: "the open form of a new or edited alternative description"

  attr :editing_alt_description, :any, default: nil
  attr :roles, :list, default: [], doc: "roles of the group's manifest"
  attr :max_alt_descriptions, :integer, required: true

  def panel(assigns) do
    ~H"""
    <div id="group-panel-edit-group" class="flex min-h-0 flex-1 flex-col px-2">
      <Components.group_path
        path={@group_path}
        group={@group}
        current_profile={@current_profile}
        class="shadow-md"
      />
      <div class="card-body min-h-0 flex-1 overflow-y-auto overscroll-contain">
        <h3 class="card-title">{gettext("Edit group")}</h3>

        <.form
          for={@edit_group_form}
          id="group-edit-form"
          phx-change="validate_edit_group"
          phx-submit="save_edit_group"
        >
          <.input field={@edit_group_form[:name]} label={gettext("Name")} required />
          <Components.group_picture_form_field field={@edit_group_form[:group_picture_url]} />
          <div class="flex flex-row items-start gap-4">
            <.input
              field={@edit_group_form[:is_public]}
              label={gettext("Public")}
              type="checkbox"
            />
            <.input
              field={@edit_group_form[:is_root_public]}
              label={gettext("Root public")}
              type="checkbox"
            />
            <.input
              field={@edit_group_form[:uses_api]}
              label={gettext("Uses API")}
              type="checkbox"
            />
          </div>

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
          <details
            open={@description_details_open}
            class="rounded-2xl border border-base-300/80 bg-base-100/70 px-4 py-3 w-full mb-4 shadow-sm"
          >
            <summary
              phx-click="set_edit_group_description_open"
              phx-value-open={if(@description_details_open, do: "false", else: "true")}
              class="cursor-pointer select-none font-medium text-base-content"
            >
              {gettext("Description")}
            </summary>

            <div class="mt-4">
              <.input
                field={@edit_group_form[:description_name]}
                label={gettext("Name next to the alternative descriptions")}
                placeholder={gettext("Description")}
              />
            </div>

            <Components.description_workspace
              id_prefix="group-description"
              description_field={@edit_group_form[:description]}
              format_field={@edit_group_form[:description_format]}
              uses_api={@edit_group_form[:uses_api].value}
              format_options={@format_options}
            />
          </details>

          <div class="flex flex-wrap items-center justify-between gap-3">
            <div class="flex flex-wrap items-center gap-3">
              <button
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
                class="inline-flex items-center gap-2 rounded-2xl border border-amber-500/30 bg-amber-500/10 px-4 py-2 text-sm font-medium text-amber-900 transition hover:bg-amber-500/15 focus:outline-none focus:ring-2 focus:ring-amber-500/30"
              >
                <.icon name="hero-trash" class="size-4" />
                <span>{gettext("Delete Data Values")}</span>
              </button>
              <button
                :if={!@group.is_root and @can_delete_group}
                id="group-delete-button"
                type="button"
                phx-click="delete_group"
                data-confirm={gettext("Are you sure you want to delete this group?")}
                class="inline-flex items-center gap-2 rounded-2xl border border-error/30 bg-error/10 px-4 py-2 text-sm font-medium text-error transition hover:bg-error/15 focus:outline-none focus:ring-2 focus:ring-error/30"
              >
                <.icon name="hero-trash" class="size-4" /> <span>{gettext("Delete group")}</span>
              </button>
            </div>

            <.button phx-disable-with={gettext("Saving...")} variant="primary">
              {gettext("Save changes")}
            </.button>
          </div>
        </.form>

        <section
          id="group-alt-descriptions"
          class="mt-6 rounded-2xl border border-base-300/80 bg-base-100/70 px-4 py-4 shadow-sm"
        >
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div class="min-w-0">
              <h4 class="font-medium text-base-content">{gettext("Alternative descriptions")}</h4>
              <p class="mt-1 text-sm text-base-content/60">
                {gettext(
                  "Extra descriptions or apps, shown as tabs next to the default description. Each app keeps its own data."
                )}
              </p>
            </div>
            <button
              :if={
                is_nil(@alt_description_form) and length(@alt_descriptions) < @max_alt_descriptions
              }
              id="alt-description-new"
              type="button"
              phx-click="new_alt_description"
              class="inline-flex shrink-0 items-center gap-2 rounded-2xl border border-primary/30 bg-primary/10 px-4 py-2 text-sm font-medium text-primary transition duration-150 hover:-translate-y-px hover:bg-primary/15 focus:outline-none focus:ring-2 focus:ring-primary/30"
            >
              <.icon name="hero-plus" class="size-4" /> <span>{gettext("New description")}</span>
            </button>
          </div>

          <ul :if={@alt_descriptions != []} id="alt-description-list" class="mt-4 flex flex-col gap-2">
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
                  <span class="shrink-0 rounded-full bg-base-200 px-2 py-0.5 text-[11px] font-semibold uppercase tracking-wider text-base-content/60">
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
                <button
                  id={"alt-description-#{alt.id}-up"}
                  type="button"
                  phx-click="move_alt_description"
                  phx-value-id={alt.id}
                  phx-value-direction="up"
                  disabled={index == 0}
                  title={gettext("Move up")}
                  class={alt_action_class()}
                >
                  <.icon name="hero-arrow-up" class="size-4" />
                </button>
                <button
                  id={"alt-description-#{alt.id}-down"}
                  type="button"
                  phx-click="move_alt_description"
                  phx-value-id={alt.id}
                  phx-value-direction="down"
                  disabled={index == length(@alt_descriptions) - 1}
                  title={gettext("Move down")}
                  class={alt_action_class()}
                >
                  <.icon name="hero-arrow-down" class="size-4" />
                </button>
                <button
                  id={"alt-description-#{alt.id}-edit"}
                  type="button"
                  phx-click="edit_alt_description"
                  phx-value-id={alt.id}
                  title={gettext("Edit")}
                  class={alt_action_class()}
                >
                  <.icon name="hero-pencil-square" class="size-4" />
                </button>
                <button
                  id={"alt-description-#{alt.id}-promote"}
                  type="button"
                  phx-click="promote_alt_description"
                  phx-value-id={alt.id}
                  disabled={alt.visible_role_keys != []}
                  title={
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
                  class={alt_action_class()}
                >
                  <.icon name="hero-star" class="size-4" />
                </button>
                <button
                  id={"alt-description-#{alt.id}-delete"}
                  type="button"
                  phx-click="delete_alt_description"
                  phx-value-id={alt.id}
                  title={gettext("Delete")}
                  data-confirm={
                    gettext("Delete this description? The data values of its app are deleted too.")
                  }
                  class={[alt_action_class(), "hover:text-error"]}
                >
                  <.icon name="hero-trash" class="size-4" />
                </button>
              </div>
            </li>
          </ul>

          <.form
            :if={@alt_description_form}
            for={@alt_description_form}
            id="alt-description-form"
            phx-change="validate_alt_description"
            phx-submit="save_alt_description"
            class="mt-4 rounded-2xl border border-primary/30 bg-base-100 p-4 shadow-sm"
          >
            <h5 class="mb-2 font-medium text-base-content">
              {if(new_alt_description?(@editing_alt_description),
                do: gettext("New description"),
                else: gettext("Edit description")
              )}
            </h5>

            <.input field={@alt_description_form[:name]} label={gettext("Name")} required />
            <.input
              field={@alt_description_form[:uses_api]}
              label={gettext("Uses API")}
              type="checkbox"
            />

            <fieldset id="alt-description-roles" class="fieldset mt-2">
              <legend class="fieldset-legend">{gettext("Visible to")}</legend>
              <p class="text-xs text-base-content/60">
                {gettext(
                  "Without a role it is visible to everyone who sees the group's description. Editors always see it."
                )}
              </p>
              <input
                type="hidden"
                name={@alt_description_form[:visible_role_keys].name <> "[]"}
                value=""
              />
              <div class="mt-1 flex flex-wrap gap-3">
                <label :for={role <- @roles} class="inline-flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    name={@alt_description_form[:visible_role_keys].name <> "[]"}
                    value={role.key}
                    checked={role.key in List.wrap(@alt_description_form[:visible_role_keys].value)}
                    class="checkbox checkbox-sm"
                  />
                  <span>{role_label(role)}</span>
                </label>
              </div>
            </fieldset>

            <Components.description_workspace
              id_prefix="alt-description"
              description_field={@alt_description_form[:description]}
              format_field={@alt_description_form[:description_format]}
              uses_api={@alt_description_form[:uses_api].value}
              format_options={@format_options}
            />

            <div class="mt-4 flex flex-wrap items-center justify-between gap-3">
              <button
                :if={!new_alt_description?(@editing_alt_description)}
                id="alt-description-delete-data-values"
                type="button"
                phx-click="delete_alt_description_data_values"
                phx-value-id={@editing_alt_description.id}
                data-confirm={gettext("Delete every data value of this description's app?")}
                class="inline-flex items-center gap-2 rounded-2xl border border-amber-500/30 bg-amber-500/10 px-4 py-2 text-sm font-medium text-amber-900 transition hover:bg-amber-500/15 focus:outline-none focus:ring-2 focus:ring-amber-500/30"
              >
                <.icon name="hero-trash" class="size-4" />
                <span>{gettext("Delete Data Values")}</span>
              </button>
              <div class="ml-auto flex items-center gap-2">
                <button
                  id="alt-description-cancel"
                  type="button"
                  phx-click="cancel_alt_description"
                  class="rounded-2xl px-4 py-2 text-sm font-medium text-base-content/70 transition hover:bg-base-200 hover:text-base-content focus:outline-none focus:ring-2 focus:ring-base-content/20"
                >
                  {gettext("Cancel")}
                </button>
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
        </section>
      </div>
    </div>
    """
  end

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

  defp alt_action_class do
    "inline-flex size-8 cursor-pointer items-center justify-center rounded-full text-base-content/60 transition duration-150 hover:bg-base-200 hover:text-base-content focus:outline-none focus-visible:ring-2 focus-visible:ring-primary/40 disabled:cursor-not-allowed disabled:opacity-30 disabled:hover:bg-transparent"
  end
end
