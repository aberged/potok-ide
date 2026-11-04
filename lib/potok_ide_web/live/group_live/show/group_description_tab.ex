defmodule PotokIdeWeb.GroupLive.Show.GroupDescriptionTab do
  use PotokIdeWeb, :html

  alias PotokIdeWeb.GroupLive.Show.{AppApi, Components}

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

  def panel(assigns) do
    source = assigns.active_alt_description || assigns.group

    assigns =
      assigns
      |> assign(:source, source)
      |> assign(:empty_description_image_src, empty_description_image_src(assigns.group))

    ~H"""
    <div class="flex min-h-0 flex-1 flex-col px-2">
      <nav
        :if={@alt_descriptions != []}
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
          id="group-description-empty"
          class="flex flex-col min-h-48 items-center justify-center rounded-3xl border border-dashed border-base-300 bg-base-100/70 px-6 text-center text-sm text-base-content/60"
        >
          <p class="p-2">{gettext("This group has no description yet.")}</p>
          <.button
            :if={@can_edit}
            id="group-description-add"
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
          id="group-panel-description"
          class="flex min-h-0 flex-1 flex-col"
        >
          <Components.app_frame
            id={app_frame_id(@active_alt_description)}
            html={@source.description}
            app_id={AppApi.app_id(@active_alt_description)}
            storage_key={storage_key(@group, @active_alt_description)}
            viewer_key={"#{@current_profile && @current_profile.id}:#{@is_member}:#{@viewer_roles}"}
          />
        </div>

        <div
          :if={!blank_description?(@source.description) and !@source.uses_api}
          id="group-panel-description"
        >
          <Components.formatted_content
            content={@source.description}
            content_format={@source.description_format}
          />
        </div>
      </div>
    </div>
    """
  end

  defp active?(%{id: id}, %{id: id}), do: true
  defp active?(_active, _alt), do: false

  defp app_frame_id(nil), do: "group-app-frame"
  defp app_frame_id(%{id: id}), do: "group-app-frame-alt-#{id}"

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
