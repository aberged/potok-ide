defmodule PotokIdeWeb.GroupLive.Show.PinnedStrip do
  @moduledoc """
  The groups the viewer pinned (`Social.list_pinned_groups/1`), in a row at
  the top of the root's list of groups: one tap to each from the home page,
  on a phone too, where the column of the viewer's groups (`GroupSidebar`)
  is a panel. It only leads to them; unpinning stays in the group's menu and
  in that column.

  Each counts what is unread at or below its group, as a closed folder of
  the column does, so every number of the home badge can still be followed.
  """
  use PotokIdeWeb, :html

  alias PotokIdeWeb.Avatars
  alias PotokIdeWeb.GroupLive.Show.Components

  attr :pins, :list, required: true, doc: "`%{group, path}` maps, in the order they were pinned"
  attr :unread_counts, :map, required: true, doc: "at or below each group"
  attr :muted_unread_counts, :map, required: true
  attr :muted_group_ids, :any, required: true, doc: "the groups the viewer silenced"
  attr :waiting_counts, :map, required: true, doc: "what waits for the viewer, by group"

  def strip(assigns) do
    assigns = assign(assigns, :items, Enum.map(assigns.pins, &item(&1, assigns)))

    ~H"""
    <section id="root-pinned" aria-labelledby="root-pinned-title" class="mb-3">
      <h2
        id="root-pinned-title"
        class="px-1 pb-1 text-xs font-semibold uppercase tracking-[0.14em] text-base-content/60"
      >
        {gettext("Pinned")}
      </h2>
      <ul
        id="root-pinned-list"
        aria-label={gettext("Pinned groups")}
        class="-mx-2 flex snap-x snap-mandatory scroll-px-2 gap-1 overflow-x-auto overscroll-x-contain px-2 pt-1.5 pb-2 [scrollbar-width:thin]"
      >
        <li :for={item <- @items} id={"root-pinned-#{item.group.id}"} class="shrink-0 snap-start">
          <.link
            id={"root-pinned-link-#{item.group.id}"}
            navigate={~p"/groups/#{item.group.id}"}
            title={Enum.join(item.path ++ [item.group.name], " › ")}
            class="group/pinned flex w-[4.5rem] flex-col items-center gap-1.5 rounded-2xl px-1 py-1.5 text-center transition duration-150 hover:bg-base-200/70 active:scale-95 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40"
          >
            <span class="relative">
              <img
                src={Avatars.group_avatar_url(item.group)}
                alt=""
                loading="lazy"
                class={[
                  "size-12 rounded-full border border-base-300 object-cover shadow-sm transition-transform duration-150 group-hover/pinned:-translate-y-0.5",
                  item.muted? && "opacity-70"
                ]}
              />
              <Components.avatar_mark
                icon={
                  if(item.group.is_public, do: "hero-globe-alt-micro", else: "hero-lock-closed-micro")
                }
                class="-bottom-0.5 -left-0.5"
              />
              <Components.avatar_mark
                :if={item.kind}
                icon={item.kind.icon}
                title={item.kind.title}
                class="-right-0.5 -bottom-0.5"
              />
              <span
                id={"root-pinned-waiting-#{item.group.id}"}
                hidden={item.waiting == 0}
                title={gettext("Waiting for you: %{count}", count: item.waiting)}
                aria-label={gettext("Waiting for you: %{count}", count: item.waiting)}
                class="absolute -top-0.5 -left-0.5 size-3 rounded-full bg-amber-500 ring-2 ring-base-100"
              >
              </span>
              <.count_badge
                id={"root-pinned-unread-#{item.group.id}"}
                count={item.unread}
                hidden={item.unread == 0}
                class="absolute -top-1 -right-2"
              />
              <.count_badge
                id={"root-pinned-muted-unread-#{item.group.id}"}
                count={item.muted_unread}
                tone={:muted}
                hidden={item.unread > 0 or item.muted_unread == 0}
                class="absolute -top-1 -right-2"
              />
            </span>
            <span class="line-clamp-2 w-full text-xs font-medium leading-4 break-words text-base-content/85">
              {item.group.name}
            </span>
          </.link>
        </li>
      </ul>
    </section>
    """
  end

  defp item(%{group: group, path: path}, assigns) do
    %{
      group: group,
      path: path,
      kind: Components.group_kind_mark(group),
      unread: Map.get(assigns.unread_counts, group.id, 0),
      muted_unread: Map.get(assigns.muted_unread_counts, group.id, 0),
      muted?: MapSet.member?(assigns.muted_group_ids, group.id),
      waiting: Map.get(assigns.waiting_counts, group.id, 0)
    }
  end
end
