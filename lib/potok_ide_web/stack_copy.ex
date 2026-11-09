defmodule PotokIdeWeb.StackCopy do
  @moduledoc """
  The words of the page at `/stack`, in the `stack` Gettext domain: what each
  tool under Potok solves in the app, and how.

  Every sentence says what the code does today, so a new dependency, a process
  of its own or a daisyUI part taken up or dropped can make it wrong. See
  "Landing page and domain map" in `AGENTS.md`.

  Code in the texts is marked as `` `name` ``, as in
  `PotokIdeWeb.DomainCopy.parts/1`. The tools' own names stay in Latin through
  `@kept` in `mix potok.sr_cyrl`, so a name that is new here goes there too.
  """

  use Gettext, backend: PotokIdeWeb.Gettext

  def title, do: dgettext("stack", "What Potok is made of")

  def lead do
    dgettext(
      "stack",
      "Five tools, from the virtual machine to the message bubble. Each one solves its own part of the app, and this page says which part and how."
    )
  end

  def teaser, do: dgettext("stack", "Potok uses BEAM, Elixir, Phoenix, Tailwind and daisyUI.")
  def more, do: dgettext("stack", "See what each of them solves and how")
  def back, do: dgettext("stack", "Domain map")
  def tools_label, do: dgettext("stack", "Tools")
  def solves, do: dgettext("stack", "What it solves")
  def how, do: dgettext("stack", "How")

  @doc "The tools, from the bottom layer up."
  def tools, do: [beam(), elixir(), phoenix(), tailwind(), daisyui()]

  defp beam do
    %{
      id: "beam",
      name: "BEAM",
      kind: dgettext("stack", "Virtual machine"),
      part:
        dgettext(
          "stack",
          "Everything that happens at once: open pages, notifications, reminders and the links between servers."
        ),
      text:
        dgettext(
          "stack",
          "BEAM is the virtual machine of Erlang, a language born for telephone exchanges, where thousands of calls run at once and none may bring the others down. Conversations in Potok ask for the same. The logo here is Erlang's, as BEAM has none of its own."
        ),
      points: [
        %{
          title: dgettext("stack", "A process for every open page"),
          text:
            dgettext(
              "stack",
              "Every open page has a light process of its own on the server, with its own memory. Processes share no memory and send each other messages, and BEAM keeps switching between them, so slow work on one page does not hold up the others."
            )
        },
        %{
          title: dgettext("stack", "A crash stays in its process"),
          text:
            dgettext(
              "stack",
              "When something goes wrong, only that process falls. Its page reconnects on its own and nobody else notices. A supervisor starts the permanent parts of the app and brings them back if they stop."
            )
        },
        %{
          title: dgettext("stack", "Memory is cleaned per process"),
          text:
            dgettext(
              "stack",
              "Each process cleans its own memory, so cleaning never stops the whole server. Potok makes use of that: a page's connection does a full sweep every time, both are swept once more two seconds after loading, and after that the page looks at its connection every 20 seconds and has it swept if it has grown. A page that receives nothing for two seconds shrinks to what it really holds. That is how a small server holds many open pages."
            )
        },
        %{
          title: dgettext("stack", "Background work is ordinary processes"),
          text:
            dgettext(
              "stack",
              "Notifications go out from processes of their own, so a page does not wait for the delivery services. They wait in one line and go two at a time, so a run of posts does not start hundreds of deliveries at once. Event reminders are a process that wakes up every half minute, and so are the deadlines of polls. Once an hour another one deletes the files apps took in that no answer claimed. The pictures for link cards and for the avatars in notifications are drawn one at a time, each in a process of its own, and at most three link previews are fetched at once. None of this needs a separate job queue."
            )
        },
        %{
          title: dgettext("stack", "Several servers, one system"),
          text:
            dgettext(
              "stack",
              "Servers find each other through DNS and join a cluster. A message sent on one reaches a process on another, with no broker such as Redis in between."
            )
        },
        %{
          title: dgettext("stack", "A cache inside the machine"),
          text:
            dgettext(
              "stack",
              "ETS is an in-memory table that every process can read. Potok keeps in it what is expensive to compute and rarely changes: rendered Markdown and the access token for notifications. The pictures it draws, link cards and avatars, go to files on disk instead, so they take no memory. ETS also counts log-in attempts and the emails someone asks Potok to send, so nobody can repeat them without end."
            )
        }
      ]
    }
  end

  defp elixir do
    %{
      id: "elixir",
      name: "Elixir",
      kind: dgettext("stack", "Programming language"),
      part:
        dgettext(
          "stack",
          "All the rules of the app: who may do what, how threads and inheritance work, what is unread, how events repeat."
        ),
      text:
        dgettext(
          "stack",
          "Elixir is a language that runs on BEAM. It gets everything above from it and adds readable code and good tools. All of Potok's server code is written in it, with every rule from the domain map."
        ),
      points: [
        %{
          title: dgettext("stack", "Data never changes in place"),
          text:
            dgettext(
              "stack",
              "A function takes a value and returns a new one, and the old one stays as it was, so nothing can change it while something else reads it. Data is easy to follow: steps come one after another, and the shape of the data picks the branch that runs."
            )
        },
        %{
          title: dgettext("stack", "Ecto guards the database"),
          text:
            dgettext(
              "stack",
              "Ecto describes every table in code, and changes pass their checks before they reach PostgreSQL. Changes that belong together form one transaction: all of them are written, or none."
            )
        },
        %{
          title: dgettext("stack", "The compiler does part of the checking"),
          text:
            dgettext(
              "stack",
              "Templates and addresses are checked while the code is built. A link to a page that does not exist is a warning, and a warning stops the change. The compiler also splits a template into fixed and changing parts, which is why LiveView sends only the differences."
            )
        },
        %{
          title: dgettext("stack", "Code that reads itself"),
          text:
            dgettext(
              "stack",
              "The fields and keys on the domain map are not copied by hand: fields come from the Ecto schemas and keys from the database catalog, so they cannot fall behind the code. When a table shows up without a description, a test fails."
            )
        },
        %{
          title: dgettext("stack", "Tools in the same language"),
          text:
            dgettext(
              "stack",
              "Tests (ExUnit) and helper tasks are written in Elixir too. One command before every change builds the code with no warnings, formats it and runs the tests, and the Cyrillic version of this page is generated from the Latin one."
            )
        }
      ]
    }
  end

  defp phoenix do
    %{
      id: "phoenix",
      name: "Phoenix",
      kind: dgettext("stack", "Web framework"),
      part:
        dgettext(
          "stack",
          "Everything between the browser and the rules: pages, the live connection, log-in, addresses, files."
        ),
      text:
        dgettext(
          "stack",
          "Phoenix is a web framework written in Elixir. It takes every request, checks the session and the language, leads it to the right page and keeps the connection to the browser open."
        ),
      points: [
        %{
          title: dgettext("stack", "LiveView: pages live on the server"),
          text:
            dgettext(
              "stack",
              "Every page after log-in is LiveView. The view is worked out on the server, and over a WebSocket connection the browser gets only what changed. JavaScript stays for what only a browser can do, like scrolling or uploading files. The phone apps show the same pages from the same server, so a new feature reaches every device at once."
            )
        },
        %{
          title: dgettext("stack", "A conversation is a stream"),
          text:
            dgettext(
              "stack",
              "The messages of a conversation are a LiveView stream: the server keeps them out of the page's memory and sends the browser only the new, edited or deleted one. The browser holds the rest, so a long conversation does not weigh on the server."
            )
        },
        %{
          title: dgettext("stack", "PubSub: a new value reaches everyone"),
          text:
            dgettext(
              "stack",
              "When someone saves a value, Phoenix PubSub publishes it on the group's topic, and every page process listening there gets it and shows it. Unread counts have a topic of their own, so one value is one publication, however many members the group has. So do the values apps keep under rules, and each page decides by those rules whether its reader may see one."
            )
        },
        %{
          title: dgettext("stack", "Presence: who is here"),
          text:
            dgettext(
              "stack",
              "Presence tracks which profile has a group open and keeps that in step between servers, without the database. A page listens only to the profiles it cares about, so one member coming in does not wake a whole big group."
            )
        },
        %{
          title: dgettext("stack", "The router and access checks"),
          text:
            dgettext(
              "stack",
              "The router divides addresses into those for guests, accounts and profiles, and the same check holds for the first load and for the live connection. What needs no live connection, like the landing page, the domain map, this page, files and avatars, stays a plain response to a request, so a reader holds no process open."
            )
        },
        %{
          title: dgettext("stack", "Apps in a group"),
          text:
            dgettext(
              "stack",
              "An app from a group's description runs in an isolated frame, with no access to the page around it. It talks to Potok through messages that reach the page's process, and there every permission is checked again."
            )
        }
      ]
    }
  end

  defp tailwind do
    %{
      id: "tailwind",
      name: "Tailwind",
      kind: dgettext("stack", "Styling"),
      part:
        dgettext(
          "stack",
          "How every element looks: spacing, type, colors, and the layout on a phone and on a big screen."
        ),
      text:
        dgettext(
          "stack",
          "Tailwind is a set of small CSS classes written right in the template. Instead of a separate style for each part of the screen, an element carries its look with it."
        ),
      points: [
        %{
          title: dgettext("stack", "Only what is used"),
          text:
            dgettext(
              "stack",
              "At build time Tailwind goes through the templates and the JavaScript and makes one CSS file, with only the classes that appear there. A class removed from a template leaves the file by itself."
            )
        },
        %{
          title: dgettext("stack", "Phone first"),
          text:
            dgettext(
              "stack",
              "Plain classes hold for a narrow screen, and `sm:` and `lg:` add what changes on a wider one. Potok added variants of its own: `keyboard-open:` while the phone's keyboard is open, and `cramped:` for screens too short for the bars around a conversation."
            )
        },
        %{
          title: dgettext("stack", "States and the theme"),
          text:
            dgettext(
              "stack",
              "The variants `phx-click-loading:` and `phx-submit-loading:` change the look while the server handles a click, so a button reacts at once. `dark:` follows the chosen theme, or the device's."
            )
        },
        %{
          title: dgettext("stack", "Icons without images"),
          text:
            dgettext(
              "stack",
              "The icons are Heroicons, included as a plugin for Tailwind: the class `hero-bell` is a bell written into the CSS itself, so there is no image to load, and it takes its color from the text."
            )
        },
        %{
          title: dgettext("stack", "Where Tailwind stops"),
          text:
            dgettext(
              "stack",
              "Elaborate pages like the landing page and the domain map also have hand-written styles, in the same CSS file and with the same colors."
            )
        }
      ]
    }
  end

  defp daisyui do
    %{
      id: "daisyui",
      name: "daisyUI",
      kind: dgettext("stack", "Components and themes"),
      part:
        dgettext(
          "stack",
          "Ready-made parts of the screen and their colors: message bubbles, fields, menus, the light and the dark theme."
        ),
      text:
        dgettext(
          "stack",
          "daisyUI is a plugin for Tailwind. It gives the common parts of an interface as named classes and adds no JavaScript."
        ),
      points: [
        %{
          title: dgettext("stack", "Components as classes"),
          text:
            dgettext(
              "stack",
              "`chat-bubble` is a message bubble, `drawer` the side menu, `dropdown` a drop-down menu, `toast` a note at the bottom of the screen. It is all plain CSS, so it does not get in the way of LiveView, which updates the page by itself."
            )
        },
        %{
          title: dgettext("stack", "Colors by role"),
          text:
            dgettext(
              "stack",
              "Colors are named by role, like `base-100`, `primary` or `error`, and a theme gives them their values. Potok has its own light and dark theme, with the blue of its mark, and switches between them with one attribute on the page."
            )
        },
        %{
          title: dgettext("stack", "Forms"),
          text:
            dgettext(
              "stack",
              "Text fields, selects and checkboxes come from daisyUI, and one component in the code, `input`, shows them all the same way, with the same error messages."
            )
        },
        %{
          title: dgettext("stack", "Apps get the same classes"),
          text:
            dgettext(
              "stack",
              "An app in a group loads the same CSS as Potok, so its author can use the same components and colors, and the app follows the theme."
            )
        },
        %{
          title: dgettext("stack", "What Potok leaves out"),
          text:
            dgettext(
              "stack",
              "Potok does not use everything daisyUI offers. Buttons are written with Tailwind, and dialogs are native `<dialog>` elements, as they have to sit above everything on the page."
            )
        }
      ]
    }
  end
end
