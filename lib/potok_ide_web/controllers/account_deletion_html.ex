defmodule PotokIdeWeb.AccountDeletionHTML do
  @moduledoc """
  The pages of `PotokIdeWeb.AccountDeletionController`: the form that asks for
  the link, what deleting would do, and the goodbye.
  """

  use PotokIdeWeb, :html

  embed_templates "account_deletion_html/*"

  @doc """
  What deleting an account does and keeps, as `PotokIde.Accounts.Deletion`
  does it: shown on the public page and in the settings.
  """
  attr :id, :string, required: true
  attr :preview, :map, required: true

  def deletion_preview(assigns) do
    ~H"""
    <div id={@id} class="space-y-4 text-sm leading-6">
      <ul class="space-y-2">
        <li class="flex gap-2">
          <.icon name="hero-trash" class="mt-0.5 size-4 shrink-0 text-error" />
          <span>
            {gettext(
              "Gone: the account, its sign-ins and devices, your memberships, follows, reactions, tags and invitations."
            )}
          </span>
        </li>
        <li class="flex gap-2">
          <.icon name="hero-chat-bubble-left-right" class="mt-0.5 size-4 shrink-0 opacity-70" />
          <span>
            {gettext(
              "Stays: what you wrote in groups, your files, polls and events, under \"Deleted user\", with no name, picture or description of yours."
            )}
          </span>
        </li>
      </ul>

      <div :if={@preview.tombstones != []} id={"#{@id}-profiles"}>
        <p class="font-medium">{gettext("Profiles that become \"Deleted user\"")}</p>
        <p class="mt-1 text-base-content/70">
          {Enum.map_join(@preview.tombstones, ", ", & &1.username)}
        </p>
      </div>

      <div :if={@preview.kept_shared != []} id={"#{@id}-shared"}>
        <p class="font-medium">
          {gettext("Profiles that stay for the other accounts that use them")}
        </p>
        <p class="mt-1 text-base-content/70">
          {Enum.map_join(@preview.kept_shared, ", ", & &1.username)}
        </p>
      </div>

      <div :if={@preview.deleted_groups != []} id={"#{@id}-groups"}>
        <p class="font-medium">
          {gettext("Groups that go with the account, as you are their only member")}
        </p>
        <p class="mt-1 text-base-content/70">
          {Enum.map_join(@preview.deleted_groups, ", ", & &1.name)}
        </p>
      </div>

      <div
        :if={@preview.blocking != []}
        id={"#{@id}-blocking"}
        class="rounded-2xl border border-warning/40 bg-warning/10 px-4 py-3"
      >
        <p class="font-medium">
          {gettext("First make someone else an admin of these groups:")}
        </p>
        <ul class="mt-2 space-y-1">
          <li :for={group <- @preview.blocking} id={"#{@id}-blocking-#{group.id}"}>
            <.link href={~p"/groups/#{group.id}/members"} class="underline underline-offset-4">
              {group.name}
            </.link>
          </li>
        </ul>
        <p class="mt-2 text-base-content/70">
          {gettext("A group never loses its last admin, so the account can't be deleted until then.")}
        </p>
      </div>
    </div>
    """
  end
end
