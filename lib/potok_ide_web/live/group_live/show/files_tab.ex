defmodule PotokIdeWeb.GroupLive.Show.FilesTab do
  use PotokIdeWeb, :html

  alias PotokIde.Social.ValueAttachment
  alias PotokIdeWeb.GroupLive.Show.Components

  attr :group, :map, required: true
  attr :current_profile, :map, required: true
  attr :files, :any, required: true, doc: "stream of the group's attachments, newest first"
  attr :files_view, :string, required: true, doc: "\"list\" or \"tree\""
  attr :has_more, :boolean, default: false
  attr :tree, :map, default: nil, doc: "`Social.attachment_tree/2` of the group"
  attr :tree_truncated, :boolean, default: false

  def panel(assigns) do
    ~H"""
    <div id="group-panel-files" class="card flex min-h-0 flex-1 flex-col px-2">
      <Components.group_path
        group={@group}
        current_profile={@current_profile}
        class="shadow-md"
      />
      <div class="min-h-0 flex-1 overflow-y-auto overscroll-contain pt-4 pb-4">
        <div class="mb-4 flex flex-wrap items-start justify-between gap-3 px-1">
          <div class="min-w-0">
            <h3 class="card-title">{gettext("Files")}</h3>
            <p class="text-xs text-base-content/60">
              {if @files_view == "tree",
                do: gettext("Files of this group and its sub-groups, folder by folder."),
                else: gettext("Files attached to values in this group, newest first.")}
            </p>
          </div>
          <div
            id="group-files-view"
            role="group"
            aria-label={gettext("Show files as")}
            class="inline-flex shrink-0 rounded-full border border-base-300 bg-base-200/70 p-0.5"
          >
            <.view_button
              id="group-files-view-list"
              view="list"
              active={@files_view == "list"}
              icon="hero-list-bullet"
              label={gettext("List")}
            />
            <.view_button
              id="group-files-view-tree"
              view="tree"
              active={@files_view == "tree"}
              icon="hero-folder"
              label={gettext("Folders")}
            />
          </div>
        </div>

        <%= if @files_view == "tree" do %>
          <div
            :if={@tree && @tree.file_count > 0}
            id="group-files-tree"
            class="rounded-3xl border border-base-300/70 bg-base-100/70 p-2 shadow-sm"
          >
            <.tree_folder node={@tree} root={true} />
          </div>
          <.empty_state
            :if={@tree && @tree.file_count == 0}
            id="group-files-tree-empty"
            text={gettext("No files in this group or its sub-groups yet.")}
          />
          <p
            :if={@tree_truncated}
            id="group-files-tree-truncated"
            class="mt-3 flex items-center gap-2 px-1 text-xs text-base-content/60"
          >
            <.icon name="hero-information-circle" class="size-4 shrink-0" />
            {gettext("Only the newest files are shown. Open a sub-group to see all of its files.")}
          </p>
        <% else %>
          <ul id="group-files-list" class="space-y-2" phx-update="stream">
            <li id="group-files-empty" class="hidden only:block">
              <.empty_state text={gettext("No files yet. Attach one to a value with the paper clip.")} />
            </li>
            <li :for={{dom_id, file} <- @files} id={dom_id}>
              <.file_link
                file={file}
                class="rounded-2xl border border-base-300/60 bg-base-100/70 px-2.5 py-2 shadow-sm"
              >
                <:details>
                  <span>{file.profile.username}</span>
                  <span aria-hidden="true">·</span>
                  <Components.local_time
                    id={"file-inserted-at-#{file.id}"}
                    datetime={file.inserted_at}
                  />
                  <span aria-hidden="true">·</span>
                  <span class="tabular-nums">{Components.format_bytes(file.byte_size)}</span>
                </:details>
              </.file_link>
            </li>
          </ul>
          <div :if={@has_more} class="mt-3 flex justify-center">
            <button
              id="group-files-load-more"
              type="button"
              phx-click="load_more_files"
              class="btn btn-ghost btn-sm rounded-full border border-base-300 bg-base-100/80 px-4 phx-click-loading:animate-pulse"
            >
              {gettext("Load more files")}
            </button>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :view, :string, required: true
  attr :active, :boolean, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true

  defp view_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      phx-click="set_files_view"
      phx-value-view={@view}
      aria-pressed={to_string(@active)}
      class={[
        "inline-flex items-center gap-1.5 rounded-full px-3 py-1 text-xs font-semibold transition duration-150 ease-out phx-click-loading:opacity-70",
        if(@active,
          do: "bg-base-100 text-base-content shadow-sm",
          else: "text-base-content/60 hover:text-base-content"
        )
      ]}
    >
      <.icon name={@icon} class="size-4" />
      {@label}
    </button>
    """
  end

  attr :node, :map, required: true
  attr :root, :boolean, default: false

  # A folder is a group: its sub-groups first, then its own files. `open` is
  # left to the browser after mount, so re-renders keep folders as they were.
  defp tree_folder(assigns) do
    ~H"""
    <details
      id={"files-folder-#{@node.group.id}"}
      open={@root}
      phx-mounted={JS.ignore_attributes(["open"])}
    >
      <summary class="flex cursor-pointer list-none items-center gap-2 rounded-xl px-2 py-1.5 transition-colors hover:bg-base-200 [&::-webkit-details-marker]:hidden">
        <.icon
          name="hero-chevron-right"
          class="size-3.5 shrink-0 text-base-content/45 transition-transform duration-150 [details[open]>summary>&]:rotate-90"
        />
        <.icon
          name={folder_icon(@node.group)}
          class={[
            "size-5 shrink-0",
            if(@node.group.member?, do: "text-amber-500", else: "text-base-content/40")
          ]}
        />
        <span
          class="min-w-0 flex-1 truncate text-sm font-medium"
          title={
            if(@node.group.member?,
              do: @node.group.name,
              else: gettext("You are not a member of %{name}", name: @node.group.name)
            )
          }
        >
          {@node.group.name}
        </span>
        <span class="shrink-0 text-xs tabular-nums text-base-content/50">
          {ngettext("1 file", "%{count} files", @node.file_count)} · {Components.format_bytes(
            @node.byte_size
          )}
        </span>
        <.link
          :if={!@root}
          id={"files-folder-open-#{@node.group.id}"}
          navigate={~p"/groups/#{@node.group.id}"}
          title={gettext("Open group")}
          aria-label={gettext("Open group")}
          class="inline-flex size-7 shrink-0 items-center justify-center rounded-full text-base-content/50 transition-colors hover:bg-base-300 hover:text-base-content"
        >
          <.icon name="hero-arrow-up-right" class="size-4" />
        </.link>
      </summary>
      <div class="ml-[1.05rem] space-y-0.5 border-l border-base-300/70 pl-2">
        <.tree_folder :for={child <- @node.children} node={child} />
        <.file_link
          :for={file <- @node.files}
          file={file}
          id={"files-tree-file-#{file.id}"}
          class="rounded-xl px-2 py-1.5"
          compact
        >
          <:details>
            <span class="tabular-nums">{Components.format_bytes(file.byte_size)}</span>
          </:details>
        </.file_link>
      </div>
    </details>
    """
  end

  attr :file, ValueAttachment, required: true
  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :compact, :boolean, default: false
  slot :details

  # Images open in a new tab; other files download (`/files/:id` sends them
  # as attachments), so the page itself never navigates away.
  defp file_link(assigns) do
    assigns = assign(assigns, :image?, ValueAttachment.image?(assigns.file))

    ~H"""
    <a
      id={@id}
      href={~p"/files/#{@file.id}"}
      target={@image? && "_blank"}
      rel={@image? && "noopener"}
      download={!@image? && @file.filename}
      title={@file.filename}
      class={[
        "group/file flex min-w-0 items-center gap-3 transition duration-150 ease-out hover:bg-base-200",
        @class
      ]}
    >
      <img
        :if={@image? and !@compact}
        src={~p"/files/#{@file.id}"}
        alt=""
        loading="lazy"
        decoding="async"
        class="size-10 shrink-0 rounded-xl border border-base-300 object-cover"
      />
      <span
        :if={!@image? or @compact}
        class={[
          "inline-flex shrink-0 items-center justify-center rounded-xl bg-base-200 text-base-content/60",
          if(@compact, do: "size-7", else: "size-10")
        ]}
      >
        <.icon name={Components.file_icon(@file.content_type)} class="size-4" />
      </span>
      <span class="min-w-0 flex-1">
        <span class="block truncate text-sm font-medium text-base-content">{@file.filename}</span>
        <span
          :if={@details != [] and !@compact}
          class="flex flex-wrap items-center gap-x-1.5 text-xs text-base-content/55"
        >
          {render_slot(@details)}
        </span>
      </span>
      <span
        :if={@details != [] and @compact}
        class="shrink-0 text-xs text-base-content/50"
      >
        {render_slot(@details)}
      </span>
      <.icon
        name={if(@image?, do: "hero-arrow-top-right-on-square", else: "hero-arrow-down-tray")}
        class="size-4 shrink-0 text-base-content/40 transition-colors group-hover/file:text-base-content"
      />
    </a>
    """
  end

  attr :id, :string, default: nil
  attr :text, :string, required: true

  defp empty_state(assigns) do
    ~H"""
    <div
      id={@id}
      class="flex min-h-48 flex-col items-center justify-center gap-2 rounded-3xl border border-dashed border-base-300 bg-base-100/70 px-6 text-center text-sm text-base-content/60"
    >
      <.icon name="hero-paper-clip" class="size-6 text-base-content/35" />
      {@text}
    </div>
    """
  end

  defp folder_icon(%{member?: false}), do: "hero-lock-closed"
  defp folder_icon(%{thread?: true}), do: "hero-chat-bubble-left-right"
  defp folder_icon(_group), do: "hero-folder"
end
