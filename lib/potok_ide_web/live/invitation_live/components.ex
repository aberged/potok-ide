defmodule PotokIdeWeb.InvitationLive.Components do
  @moduledoc "Pieces of the Invitations page."

  use PotokIdeWeb, :html

  alias PotokIdeWeb.Avatars
  alias PotokIdeWeb.ProfileLive.Components, as: ProfileComponents

  attr :invitation, :any, required: true, doc: "a waiting invitation, with its group and inviter"

  attr :choices, :list,
    required: true,
    doc: "the account's other unique profiles (`Social.invitation_profile_choices/2`)"

  @doc """
  Which profile accepts an invitation to a unique profile, in a modal
  `<dialog>`: another unique profile of the account, or a new one. The page
  handles `accept_as` (`profile` the id), `accept_as_new` and
  `accept_as_close`.
  """
  def accept_as_dialog(assigns) do
    assigns = assign(assigns, :inviter, assigns.invitation.inviter.username)

    ~H"""
    <dialog
      id="accept-as-dialog"
      phx-hook=".AcceptAsDialog"
      phx-mounted={JS.ignore_attributes(["open"])}
      aria-labelledby="accept-as-title"
      class="fixed inset-0 m-0 size-full max-h-none max-w-none overflow-hidden bg-transparent p-0 backdrop:bg-transparent"
    >
      <div class="flex size-full items-end justify-center sm:items-center sm:p-4">
        <div
          id="accept-as-backdrop"
          class="absolute inset-0 bg-black/30 backdrop-blur-[2px] dark:bg-black/60"
          phx-click="accept_as_close"
          aria-hidden="true"
        >
        </div>
        <section class="relative flex max-h-[92dvh] w-full flex-col overflow-hidden rounded-t-3xl border border-b-0 border-base-300/70 bg-base-100 text-base-content shadow-2xl shadow-base-content/10 sm:max-w-md sm:rounded-3xl sm:border-b">
          <header class="flex items-start gap-3 px-5 pt-5">
            <img
              id="accept-as-group"
              src={Avatars.group_avatar_url(@invitation.group)}
              alt=""
              class="size-11 shrink-0 rounded-2xl border border-base-300/70 bg-base-200 object-cover"
            />
            <div class="min-w-0 flex-1">
              <h2 id="accept-as-title" class="text-lg font-semibold leading-tight">
                {gettext("Accept with another profile")}
              </h2>
              <p id="accept-as-lead" class="mt-1 text-sm leading-6 text-base-content/70">
                {gettext(
                  "@%{username} invites you to “%{group}”. Choose the profile you join with.",
                  username: @inviter,
                  group: @invitation.group.name
                )}
              </p>
            </div>
            <.icon_button
              id="accept-as-close"
              type="button"
              phx-click="accept_as_close"
              icon="hero-x-mark"
              label={gettext("Close")}
              class="-mt-1 -mr-1"
            />
          </header>

          <div class="min-h-0 flex-1 overflow-y-auto px-5 pt-4 pb-[calc(1.25rem+var(--app-safe-area-bottom))] sm:pb-5">
            <ul id="accept-as-profiles" class="space-y-1">
              <li
                :for={{profile, reason} <- @choices}
                id={"accept-as-choice-#{profile.id}"}
                class="flex items-center gap-2 rounded-2xl px-1 py-1"
              >
                <span class={["min-w-0 flex-1", reason && "opacity-55"]}>
                  <ProfileComponents.profile_identity
                    profile={profile}
                    subtitle={reason_label(reason)}
                  />
                </span>
                <.button
                  :if={is_nil(reason)}
                  id={"accept-as-profile-#{profile.id}"}
                  type="button"
                  phx-click="accept_as"
                  phx-value-profile={profile.id}
                  phx-disable-with={gettext("Joining...")}
                  variant="success"
                  size="sm"
                  class="shrink-0"
                >
                  {gettext("Join")}
                </.button>
              </li>

              <li>
                <button
                  id="accept-as-new"
                  type="button"
                  phx-click="accept_as_new"
                  class="group/new flex w-full cursor-pointer items-center gap-3 rounded-2xl px-2 py-2 text-left transition-colors duration-150 hover:bg-base-200 focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-primary/40"
                >
                  <span class="inline-flex size-11 shrink-0 items-center justify-center rounded-full border border-dashed border-primary/40 bg-primary/5 text-primary transition-transform duration-150 group-hover/new:scale-105">
                    <.icon name="hero-user-plus" class="size-5" />
                  </span>
                  <span class="min-w-0 flex-1">
                    <span class="block text-sm font-semibold">{gettext("New profile")}</span>
                    <span class="block text-xs text-base-content/65">
                      {gettext("A name and a picture, and you are in the group.")}
                    </span>
                  </span>
                  <.icon name="hero-chevron-right" class="size-4 shrink-0 text-base-content/40" />
                </button>
              </li>
            </ul>

            <p
              id="accept-as-note"
              class="mt-4 flex items-start gap-2 rounded-2xl bg-base-200/60 px-3 py-2 text-xs leading-5 text-base-content/70"
            >
              <.icon name="hero-eye" class="mt-0.5 size-4 shrink-0" />
              <span>
                {gettext("@%{username} will see which profile accepted the invitation.",
                  username: @inviter
                )}
              </span>
            </p>
          </div>
        </section>
      </div>
    </dialog>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".AcceptAsDialog">
      export default {
        mounted() {
          // Escape closes the dialog through the server, which removes it.
          this.el.addEventListener("cancel", event => {
            event.preventDefault()
            this.pushEvent("accept_as_close", {})
          })
          this.el.showModal()
        },
        updated() {
          if (!this.el.open) this.el.showModal()
        },
      }
    </script>
    """
  end

  defp reason_label(nil), do: nil
  defp reason_label(:member), do: gettext("Already a member")
  defp reason_label(:blocked), do: gettext("Blocked in this group")
end
