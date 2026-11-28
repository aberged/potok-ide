defmodule PotokIde.Social.SiteExample do
  @moduledoc """
  An example of a site (the Sajt app, preset `site`) with made-up content, to
  show on production what the app does: "Glas Potoka", the news portal of
  an invented local community called Potok, as the app is, in the theme
  Novine. It has four sections (pages, news, culture, sport), three pages,
  twelve articles, a draft only
  its editors see and an article that opens by itself on the next Saturday.
  People, places, news and results are invented, the pictures drawn
  (`SiteExample.Pictures`), and the site says so on a page of its own and in
  its footer.

  Everything goes the way the app goes: sections made for editors only,
  articles written as its block editor writes them (`SiteDoc`), pictures in
  the app's public file group behind signed addresses, its config public. So
  the app opens the site as if its editors had made it, and they go on from
  there. Nobody comments: the example makes no people.

  A profile of an account makes the site and is its admin. On a release:

      bin/potok_ide rpc 'PotokIde.Social.SiteExample.start("email")'

  and `remove/1` with the site's id takes it away again.
  """

  import Ecto.Query

  require Logger

  alias PotokIde.{Accounts, History, Repo, Social, Storage}

  alias PotokIde.Social.{
    AppData,
    AppFiles,
    AreaImport,
    Group,
    Profile,
    ScheduledPublications,
    SiteDoc
  }

  alias PotokIde.Social.SiteExample.Pictures
  alias PotokIdeWeb.PostTemplates.Picture

  @name "Glas Potoka"
  @zone "Europe/Belgrade"

  # The pictures that go into the articles and on the home page, uploaded as
  # the app uploads its own; the rest are only cover pictures of articles.
  @uploaded ~w(naslovna rasveta ulica obala-1 obala-2 obala-3 staza vikend stara-1 stara-2
               stara-3 stara-4 hor trka-1 trka-2 trka-3 jesen-1 jesen-2 jesen-3 park dan)

  @doc """
  Makes the example site in the root as the profile `username` of the
  account `email`, or as the profile the account is using when `username` is
  nil. `{:ok, %{site: id, url: url, articles: count, pictures: count}}`, or
  `{:error, reason}`: `:no_account`, `:no_profile`, `:username_taken`,
  `:exists` when that profile already made one, or what failed on the way
  (drawing needs ImageMagick).

  The pictures are drawn into a folder of their own that goes when it is
  done, or into `opts[:dir]`, which stays, and where a picture already drawn
  is taken as it is.
  """
  def create(email, username \\ nil, opts \\ []) do
    with {:ok, profile} <- profile(email, username),
         root = Social.get_root_group!(),
         :ok <- not_made(profile, root) do
      dir =
        opts[:dir] ||
          Path.join(System.tmp_dir!(), "site-example-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)

      try do
        with {:ok, pictures} <- draw(dir) do
          build(profile, root, pictures)
        end
      after
        unless opts[:dir], do: File.rm_rf(dir)
      end
    end
  end

  @doc """
  `create/2` in a task of the app's own, logging how it went: what an `rpc`
  on a release starts, so that a dropped connection does not stop it.
  """
  def start(email, username \\ nil) do
    Task.Supervisor.start_child(PotokIde.TaskSupervisor, fn ->
      case create(email, username) do
        {:ok, report} -> Logger.info("Site example done: #{inspect(report)}")
        {:error, reason} -> Logger.error("Site example failed: #{inspect(reason)}")
      end
    end)
  end

  @doc """
  Takes away the site `site_id` with everything below it, the deepest groups
  first, each through `Social.delete_group/2` as the profile that made the
  site. A group someone else made below it, which that profile may not
  delete, stays, and so do the groups above it. `{:ok, deleted, kept}`, or
  `{:error, :not_found}` / `{:error, :not_a_site}`.
  """
  def remove(site_id) when is_integer(site_id) do
    case Repo.get(Group, site_id) do
      nil ->
        {:error, :not_found}

      %Group{preset: :site} = site ->
        owner = Repo.get!(Profile, site.creator_id)

        {deleted, kept} =
          site
          |> subtree()
          |> Enum.reduce({0, 0}, fn group, {deleted, kept} ->
            case Social.delete_group(owner, group) do
              {:ok, _group} -> {deleted + 1, kept}
              {:error, _reason} -> {deleted, kept + 1}
            end
          end)

        {:ok, deleted, kept}

      %Group{} ->
        {:error, :not_a_site}
    end
  end

  # The group and every group below it, the deepest first.
  defp subtree(%Group{} = group) do
    Stream.unfold([group.id], fn
      [] -> nil
      ids -> {ids, Repo.all(from(g in Group, where: g.parent_id in ^ids, select: g.id))}
    end)
    |> Enum.to_list()
    |> Enum.reverse()
    |> Enum.flat_map(fn ids ->
      Repo.all(from(g in Group, where: g.id in ^ids, order_by: g.id))
    end)
  end

  defp profile(email, nil) do
    case Accounts.get_account_by_email(email) do
      nil -> {:error, :no_account}
      %{current_profile_id: nil} -> {:error, :no_profile}
      %{current_profile_id: id} -> {:ok, Repo.get!(Profile, id)}
    end
  end

  defp profile(email, username), do: AreaImport.profile(email, username, false)

  defp not_made(%Profile{id: profile_id}, %Group{id: root_id}) do
    made? =
      Repo.exists?(
        from(g in Group,
          where:
            g.parent_id == ^root_id and g.creator_id == ^profile_id and g.name == ^@name and
              g.preset == :site
        )
      )

    if made?, do: {:error, :exists}, else: :ok
  end

  # All the pictures first, so a missing ImageMagick stops it before anything
  # is made.
  defp draw(dir) do
    Enum.reduce_while(Pictures.names(), {:ok, %{}}, fn name, {:ok, paths} ->
      path = Path.join(dir, name <> ".jpg")
      drawn = if File.exists?(path), do: {:ok, path}, else: Pictures.draw(name, dir)

      case drawn do
        {:ok, path} -> {:cont, {:ok, Map.put(paths, name, path)}}
        {:error, reason} -> {:halt, {:error, {:picture, name, reason}}}
      end
    end)
  end

  # ---------
  # Making it
  # ---------

  defp build(profile, root, pictures) do
    with {:ok, %{group: site}} <-
           Social.create_group_from_preset(profile, root, "site", %{
             "name" => @name,
             "is_public" => true,
             "inherits_members" => false
           }),
         {:ok, site} <- Social.update_group(profile, site, %{"description_for_guests" => true}),
         {:ok, sections} <- sections(profile, site),
         {:ok, first} <- save_config(profile, site, config(site, sections, %{}, %{}), nil),
         {:ok, _files} <- AppFiles.ensure_groups(profile, site, nil),
         {:ok, urls} <- upload_all(profile, site, pictures),
         {:ok, items} <- write_all(profile, sections, pictures, urls),
         {:ok, _config} <-
           save_config(profile, site, config(site, sections, items, urls), first.lock_version) do
      {:ok,
       %{
         site: site.id,
         url: PotokIdeWeb.Endpoint.url() <> "/groups/#{site.id}",
         articles: map_size(items),
         pictures: map_size(urls)
       }}
    end
  end

  defp sections(profile, site) do
    Enum.reduce_while(
      [pages: "Stranice", news: "Vesti", culture: "Kultura", sport: "Sport"],
      {:ok, %{}},
      fn {key, name}, {:ok, sections} ->
        case Social.create_editors_only_group(profile, site, %{
               "name" => name,
               "is_public" => true,
               "inherits_members" => true,
               "description_for_guests" => true
             }) do
          {:ok, section} -> {:cont, {:ok, Map.put(sections, key, section)}}
          {:error, reason} -> {:halt, {:error, {:section, name, reason}}}
        end
      end
    )
  end

  defp save_config(profile, site, config, revision) do
    case AppData.save_config(profile, site, nil, config, revision) do
      {:ok, saved} -> {:ok, saved}
      {:error, reason} -> {:error, {:config, reason}}
    end
  end

  # A picture as the app's `uploadImage` keeps it: a file of the app's public
  # file group, with an address anyone who sees the site opens.
  defp upload_all(profile, site, pictures) do
    Enum.reduce_while(@uploaded, {:ok, %{}}, fn name, {:ok, urls} ->
      case upload(profile, site, Map.fetch!(pictures, name)) do
        {:ok, url} -> {:cont, {:ok, Map.put(urls, name, url)}}
        {:error, reason} -> {:halt, {:error, {:upload, name, reason}}}
      end
    end)
  end

  defp upload(profile, site, path) do
    name = Path.basename(path)
    size = File.stat!(path).size

    with {:ok, upload} <-
           AppFiles.prepare_image(profile, site, nil, %{
             name: name,
             size: size,
             type: "image/jpeg"
           }),
         key = Storage.new_key(upload.file_group_id),
         :ok <- Storage.put_file(key, path),
         {:ok, attachment} <-
           History.signed([actor: profile], fn ->
             AppFiles.store(profile, upload, %{
               storage_key: key,
               filename: name,
               content_type: "image/jpeg",
               byte_size: size
             })
           end) do
      {:ok, Picture.address(attachment)}
    end
  end

  defp write_all(profile, sections, pictures, urls) do
    sections
    |> items(urls)
    |> Enum.reduce_while({:ok, %{}}, fn item, {:ok, written} ->
      case write(profile, item, pictures) do
        {:ok, group} -> {:cont, {:ok, Map.put(written, item.key, group)}}
        {:error, reason} -> {:halt, {:error, {:item, item.name, reason}}}
      end
    end)
  end

  # An article or a page: published at `item.at`, a draft its editors share
  # (`:draft`), or a draft that opens by itself (`:scheduled`), as the app
  # makes them.
  defp write(profile, item, pictures) do
    published? = match?(%DateTime{}, item.at)

    attrs =
      %{
        "name" => item.name,
        "description" => SiteDoc.encode(item.kind, item.excerpt, item.blocks),
        "description_format" => :html,
        "inherits_members" => true,
        "description_for_guests" => true,
        "is_public" => published?,
        "inherit_role_keys" => if(published?, do: [], else: ["admin"])
      }
      |> then(fn attrs ->
        case item[:cover] do
          nil -> attrs
          cover -> Map.put(attrs, "group_picture_url", data_url(Map.fetch!(pictures, cover)))
        end
      end)

    with {:ok, group} <- Social.create_group(profile, item.parent, attrs) do
      case item.at do
        %DateTime{} = at -> backdate(profile, group, at)
        :scheduled -> schedule(profile, group)
        :draft -> {:ok, group}
      end
    end
  end

  # Written and published then, as an editor of the app would have done.
  defp backdate(profile, group, at) do
    History.signed([actor: profile], fn ->
      {1, _} =
        Repo.update_all(from(g in Group, where: g.id == ^group.id),
          set: [published_at: at, inserted_at: at, updated_at: at]
        )

      {:ok, %{group | published_at: at, inserted_at: at, updated_at: at}}
    end)
  end

  defp schedule(profile, group) do
    days = rem(6 - Date.day_of_week(today()) + 7, 7)
    days = if days == 0, do: 7, else: days

    at =
      today()
      |> Date.add(days)
      |> DateTime.new!(~T[10:00:00], @zone)
      |> DateTime.shift_zone!("Etc/UTC")

    with {:ok, _scheduled} <-
           ScheduledPublications.schedule(profile, group, at, %{
             is_public: true,
             inherits_members: true
           }) do
      {:ok, group}
    end
  end

  defp data_url(path), do: "data:image/jpeg;base64," <> Base.encode64(File.read!(path))

  defp ago(days, hour, minute) do
    today()
    |> Date.add(-days)
    |> DateTime.new!(Time.new!(hour, minute, 0), @zone)
    |> DateTime.shift_zone!("Etc/UTC")
  end

  defp today, do: DateTime.utc_now() |> DateTime.shift_zone!(@zone) |> DateTime.to_date()

  # ---------
  # The config: look, menus, home page
  # ---------

  defp config(site, sections, items, urls) do
    section = &%{"type" => "section", "id" => sections[&1].id}
    item = &%{"type" => "item", "id" => items[&1].id}
    ready? = map_size(items) > 0

    %{
      "v" => 1,
      "public" => true,
      "rules" => %{},
      "site" => %{
        "title" => site.name,
        "tagline" => "Vesti iz kraja između kanala i pruge",
        "logo" => "",
        "footerText" => "Primer sajta u aplikaciji Potok. Ljudi, mesta i vesti su izmišljeni."
      },
      "theme" => %{
        "id" => "novine",
        "accent" => "#b3261e",
        "accentDark" => nil,
        "background" => nil,
        "text" => nil,
        "backgroundDark" => nil,
        "textDark" => nil,
        "headingFont" => "source-serif-4",
        "bodyFont" => "inter",
        "baseSize" => 17,
        "width" => "wide",
        "radius" => "small",
        "headerLayout" => "left",
        "menuPlace" => "below",
        "sticky" => false,
        "sidebar" => "right",
        "footerColumns" => 3
      },
      "sections" => [
        %{"id" => sections.pages.id, "kind" => "pages", "style" => "list", "perPage" => 20},
        %{"id" => sections.news.id, "kind" => "articles", "style" => "cards", "perPage" => 12},
        %{"id" => sections.culture.id, "kind" => "articles", "style" => "grid", "perPage" => 12},
        %{"id" => sections.sport.id, "kind" => "articles", "style" => "list", "perPage" => 12}
      ],
      "menus" => %{
        "main" =>
          [
            menu("m1", "Početna", %{"type" => "home"}),
            menu("m2", "Vesti", section.(:news)),
            menu("m3", "Kultura", section.(:culture)),
            menu("m4", "Sport", section.(:sport))
          ] ++
            if(ready?,
              do: [
                menu("m5", "O nama", item.(:about), [
                  menu("m6", "Kontakt", item.(:contact)),
                  menu("m7", "O primeru", item.(:example))
                ])
              ],
              else: []
            ),
        "footer" =>
          if(ready?,
            do: [menu("f1", "Kontakt", item.(:contact)), menu("f2", "O primeru", item.(:example))],
            else: []
          )
      },
      "home" => if(ready?, do: home(section, item, urls), else: []),
      "sidebar" => [
        %{"id" => "s1", "type" => "search", "title" => "Pretraga"},
        %{
          "id" => "s2",
          "type" => "latest",
          "title" => "Najnovije",
          "section" => "all",
          "count" => 5
        },
        %{"id" => "s3", "type" => "sections", "title" => "Rubrike"}
      ],
      "footer" =>
        [
          %{
            "id" => "w1",
            "type" => "about",
            "title" => site.name,
            "text" =>
              "Portal mesne zajednice Potok, kraja između kanala i pruge. Ovo je primer sajta u aplikaciji Potok: ljudi, mesta i vesti su izmišljeni."
          },
          %{"id" => "w2", "type" => "sections", "title" => "Rubrike"}
        ] ++
          if(ready?,
            do: [
              %{
                "id" => "w3",
                "type" => "links",
                "title" => "Korisno",
                "items" => [
                  %{"label" => "O nama", "target" => item.(:about)},
                  %{"label" => "Kontakt", "target" => item.(:contact)},
                  %{"label" => "O primeru", "target" => item.(:example)}
                ]
              }
            ],
            else: []
          ),
      "editorRoles" => [],
      "hiddenComments" => [],
      "commentsOnPages" => false
    }
  end

  defp menu(id, label, target, children \\ []),
    do: %{"id" => id, "label" => label, "target" => target, "children" => children}

  defp home(section, item, urls) do
    [
      %{
        "id" => "h1",
        "type" => "hero",
        "title" => @name,
        "text" => "Vesti, kultura i sport iz kraja između kanala i pruge.",
        "image" => urls["naslovna"],
        "buttons" => [
          %{"label" => "Najnovije vesti", "target" => section.(:news)},
          %{"label" => "O primeru", "target" => item.(:example)}
        ]
      },
      %{
        "id" => "h2",
        "type" => "latest",
        "title" => "Najnovije iz kraja",
        "section" => section.(:news)["id"],
        "count" => 4,
        "style" => "cards"
      },
      %{
        "id" => "h3",
        "type" => "latest",
        "title" => "Kultura",
        "section" => section.(:culture)["id"],
        "count" => 3,
        "style" => "grid"
      },
      %{
        "id" => "h4",
        "type" => "gallery",
        "title" => "Potok na slikama",
        "images" => [
          %{"src" => urls["jesen-1"], "caption" => "Drvored kod škole"},
          %{"src" => urls["jesen-2"], "caption" => "Staza kroz park"},
          %{"src" => urls["jesen-3"], "caption" => "Park u oktobru"},
          %{"src" => urls["park"], "caption" => "Park leti"},
          %{"src" => urls["naslovna"], "caption" => "Kanal u sumrak"}
        ]
      },
      %{
        "id" => "h5",
        "type" => "latest",
        "title" => "Sport",
        "section" => section.(:sport)["id"],
        "count" => 3,
        "style" => "list"
      },
      %{
        "id" => "h6",
        "type" => "tiles",
        "title" => @name,
        "items" => [
          %{"label" => "O nama", "text" => "Ko piše i kako radimo", "target" => item.(:about)},
          %{
            "label" => "Kontakt",
            "text" => "Gde smo i kako da pošalješ vest",
            "target" => item.(:contact)
          },
          %{
            "label" => "O primeru",
            "text" => "Šta je ovaj sajt i šta pokazuje",
            "target" => item.(:example)
          }
        ]
      },
      %{
        "id" => "h7",
        "type" => "cta",
        "title" => "Imaš vest iz kraja?",
        "text" =>
          "Javi nam se ili ostavi komentar ispod bilo kog članka. Najbolje vesti pišu komšije.",
        "button" => %{"label" => "Kontakt", "target" => item.(:contact)}
      }
    ]
  end

  # ---------
  # What it says: pages and articles
  # ---------

  defp items(sections, urls) do
    pic = &Map.fetch!(urls, &1)

    [
      # Pages ------------------------------------------------------------------
      %{
        key: :about,
        parent: sections.pages,
        kind: "page",
        name: "O nama",
        excerpt: "Ko piše Glas Potoka i kako radimo.",
        at: ago(20, 12, 0),
        blocks: [
          p(
            "Glas Potoka je portal mesne zajednice Potok, kraja između kanala i pruge. Pišemo o onome što se dešava u našim ulicama: šta se gradi i popravlja, šta se dogovara na zboru, šta se svira u Domu kulture i ko je pobedio u nedelju."
          ),
          img(
            pic.("ulica"),
            "Ulica sa kućama i svetiljkama",
            "Ulica lipa, srce Potoka",
            "wide"
          ),
          h(2, "Ko piše"),
          ul([
            "Redakcija od pet komšija, volontera",
            "Dopisnici iz škole, biblioteke i sportskih klubova",
            "Svi koji pošalju vest ili fotografiju"
          ]),
          p(
            "Svaki članak ima svoj razgovor ispod, u kome možeš da pitaš, dopuniš ili ispraviš. Pravila razgovora su ista kao u svakoj grupi u aplikaciji Potok."
          )
        ]
      },
      %{
        key: :contact,
        parent: sections.pages,
        kind: "page",
        name: "Kontakt",
        excerpt: "Gde smo i kako da nam pošalješ vest.",
        at: ago(20, 12, 5),
        blocks: [
          p("Redakcija je u Domu kulture, Ulica lipa 2, na prvom spratu."),
          table([
            ["Dan", "Vreme"],
            ["Utorak", "17–19 časova"],
            ["Četvrtak", "17–19 časova"],
            ["Subota", "10–12 časova"]
          ]),
          p(
            "Vest ili fotografiju možeš da pošalješ i u razgovoru ispod bilo kog članka. Ako je vest hitna, napiši to na početku."
          ),
          callout("Glas Potoka je primer sajta: redakcija, adresa i radno vreme su izmišljeni.")
        ]
      },
      %{
        key: :example,
        parent: sections.pages,
        kind: "page",
        name: "O primeru",
        excerpt: "Ovaj sajt je primer aplikacije Sajt. Mesto Potok, ljudi i vesti su izmišljeni.",
        at: ago(20, 12, 10),
        blocks: [
          callout(
            "Glas Potoka ne postoji, kao ni mesto Potok: ovo je primer sajta napravljenog aplikacijom <strong>Sajt</strong> u Potoku. Ljudi, mesta, vesti i rezultati su izmišljeni, a slike su nacrtane."
          ),
          p(
            "Sajt je grupa u aplikaciji Potok. Rubrike su njene podgrupe, a svaki članak je podgrupa rubrike, sa svojim razgovorom, reakcijama i karticom linka."
          ),
          h(2, "Šta ovde možeš da vidiš"),
          ul([
            "temu Novine, sa bočnom kolonom, pretragom i najnovijim člancima",
            "meni sa podmenijem, početnu stranu od blokova i futer u tri kolone",
            "četiri rubrike: Stranice, Vesti, Kultura i Sport",
            "članke od blokova: slike, galerije, tabele, kolone, citate, napomene i dugmad",
            "nacrt koji vide samo urednici i članak koji će se sam objaviti"
          ]),
          p(
            "Urednici menjaju izgled, meni i članke u samoj aplikaciji, a čitaoci vide gotov sajt, i bez naloga, kad je sajt otvoren za goste."
          ),
          buttons([{"Kako se pravi sajt", PotokIdeWeb.Endpoint.url() <> "/pomoc#sajt"}])
        ]
      },

      # News -------------------------------------------------------------------
      %{
        key: :lights,
        parent: sections.news,
        kind: "article",
        name: "Nova rasveta u Ulici lipa",
        excerpt: "Dvadeset dve nove svetiljke, a do proleća i Ulica jasika.",
        at: ago(2, 9, 30),
        cover: "rasveta",
        blocks: [
          p(
            "Od ponedeljka Ulicu lipa osvetljavaju dvadeset dve nove svetiljke. Stare sijalice zamenile su LED svetiljke koje troše upola manje struje, a svetle jače i ravnomernije."
          ),
          img(
            pic.("rasveta"),
            "Ulica noću pod novim svetiljkama",
            "Ulica lipa posle zamene svetiljki",
            "wide"
          ),
          p(
            "Zamenu je predložio zbor građana na prolećnoj sednici, a radove je platila opština iz budžeta za mesne zajednice."
          ),
          h(3, "Sledeće ulice"),
          ul([
            "Ulica jasika, do kraja godine",
            "Prolaz pored škole, u februaru",
            "Staza uz kanal, na proleće"
          ]),
          callout(
            "Vidiš ulicu u kojoj ne gori svetlo? Napiši u razgovoru ispod koja je ulica i kod kog broja."
          )
        ]
      },
      %{
        key: :cleanup,
        parent: sections.news,
        kind: "article",
        name: "Akcija čišćenja obale kanala",
        excerpt: "Četrdeset komšija i pun kamion smeća za jedno prepodne.",
        at: ago(5, 16, 0),
        cover: "obala-1",
        blocks: [
          p(
            "U subotu ujutru četrdeset komšija očistilo je obalu kanala od mosta do pruge. Za jedno prepodne skupljeno je dvesta džakova smeća, a komunalno preduzeće odvezlo je pun kamion."
          ),
          gallery("slides", [
            {pic.("obala-1"), "Komšije na obali", "Početak akcije"},
            {pic.("obala-2"), "Pešački most na kanalu", "Kod pešačkog mosta"},
            {pic.("obala-3"), "Čista obala kanala", "Obala posle čišćenja"}
          ]),
          quotation(
            "Najviše je bilo plastike koju voda donese posle kiše. Zato ćemo akciju ponavljati svake jeseni.",
            "Milena, organizatorka akcije"
          ),
          p(
            "Rukavice i džakove dala je mesna zajednica, a pekara iz Ulice jasika poslala je doručak za sve učesnike."
          )
        ]
      },
      %{
        key: :bike_path,
        parent: sections.news,
        kind: "article",
        name: "Biciklistička staza do pruge biće gotova na proleće",
        excerpt: "Dva kilometra staze uz kanal, sa rasvetom i klupama.",
        at: ago(9, 11, 15),
        cover: "staza",
        blocks: [
          p(
            "Radovi na biciklističkoj stazi uz kanal teku po planu. Staza će biti duga dva kilometra, od mosta do pruge, sa rasvetom, klupama i stalcima za bicikle."
          ),
          img(pic.("staza"), "Staza uz kanal", "Nova staza uz kanal", "right"),
          h(2, "Kako idu radovi"),
          ol([
            "Priprema terena, završena u oktobru",
            "Asfalt i ivičnjaci, do kraja novembra",
            "Rasveta i klupe, u martu",
            "Otvaranje staze, u aprilu"
          ]),
          p(
            "Dok traju radovi, deo staze kod pruge je zatvoren. Pešaci i biciklisti mogu da idu Ulicom jasika."
          )
        ]
      },
      %{
        key: :market,
        parent: sections.news,
        kind: "article",
        name: "Pijaca radi i nedeljom",
        excerpt: "Od ovog meseca tezge su otvorene sedam dana u nedelji.",
        at: ago(13, 8, 0),
        cover: "pijaca",
        blocks: [
          p(
            "Od ovog meseca pijaca u Potoku radi i nedeljom. Prodavci su to dugo tražili, a savet mesne zajednice se složio, uz uslov da se nedeljom zatvara ranije."
          ),
          table([
            ["Dan", "Radno vreme"],
            ["Ponedeljak – petak", "6–14 časova"],
            ["Subota", "6–15 časova"],
            ["Nedelja", "7–12 časova"]
          ]),
          p(
            "Na pijaci je dvadeset tezgi: voće, povrće, sir, med i cveće. Četiri tezge su nove, a dobili su ih proizvođači iz okolnih sela."
          )
        ]
      },
      %{
        key: :assembly,
        parent: sections.news,
        kind: "article",
        name: "Zbor građana: šta je odlučeno",
        excerpt: "Tri odluke i jedno pitanje za sledeći zbor.",
        at: ago(17, 20, 30),
        cover: "zbor",
        blocks: [
          p(
            "Na zboru građana u Domu kulture bilo je osamdeset komšija. Posle dva sata razgovora usvojene su tri odluke."
          ),
          h(2, "Odluke"),
          ol([
            "Rasveta u Ulici lipa menja se do kraja meseca.",
            "Obala kanala čisti se svake jeseni, uz pomoć mesne zajednice.",
            "Pijaca radi i nedeljom, od 7 do 12 časova."
          ]),
          separator(),
          h(3, "Za sledeći zbor"),
          p(
            "Ostalo je otvoreno pitanje parkiranja kod škole. Savet će do sledećeg zbora predložiti dva rešenja, a o njima će se glasati i u aplikaciji Potok."
          )
        ]
      },
      %{
        key: :spring,
        parent: sections.news,
        kind: "article",
        name: "Plan radova za proleće",
        excerpt: "",
        at: :draft,
        cover: "plan",
        blocks: [
          p(
            "Savet mesne zajednice predlaže tri posla za proleće: lipe uz stazu, novu klupu kod česme i tablu sa mapom kraja."
          ),
          p("Nacrt: dopuniti posle sednice saveta, sa cenama i rokovima.")
        ]
      },

      # Culture ----------------------------------------------------------------
      %{
        key: :weekend,
        parent: sections.culture,
        kind: "article",
        name: "Vikend u Domu kulture",
        excerpt: "Koncert, radionice za decu i bazar knjiga, u subotu i nedelju.",
        at: ago(1, 12, 0),
        cover: "vikend",
        blocks: [
          cover(pic.("vikend"), "Bina Doma kulture", "Vikend u Domu kulture"),
          p(
            "Ovog vikenda Dom kulture je otvoren od jutra do kasno uveče. Ulaz je slobodan za sve programe."
          ),
          columns([
            [
              h(4, "Subota"),
              ul([
                "10 časova: radionica crtanja za decu",
                "12 časova: bazar polovnih knjiga",
                "19 časova: koncert lokalnih bendova"
              ])
            ],
            [
              h(4, "Nedelja"),
              ul([
                "11 časova: lutkarska predstava",
                "17 časova: stari filmovi o Potoku",
                "19 časova: koncert hora Doma kulture"
              ])
            ]
          ]),
          callout(
            "Bazar knjiga traje oba dana. Donesi knjige koje ti više ne trebaju i odnesi nove."
          )
        ]
      },
      %{
        key: :library,
        parent: sections.culture,
        kind: "article",
        name: "Biblioteka produžava radno vreme",
        excerpt: "Čitaonica je otvorena do 20 časova, a subotom i za decu.",
        at: ago(6, 10, 0),
        cover: "biblioteka",
        blocks: [
          p(
            "Biblioteka u Domu kulture od ovog meseca radi duže. Čitaonica je otvorena do 20 časova, a subotom ujutru ima i dečji kutak sa pričama naglas."
          ),
          table([
            ["", "Pozajmica", "Čitaonica"],
            ["Radnim danima", "8–19", "8–20"],
            ["Subota", "9–13", "9–14"]
          ]),
          quotation(
            "Najviše su nas pitali za kasnije radno vreme, jer posle posla nisu stizali. Sada mogu.",
            "Jelena, bibliotekarka"
          ),
          p("Članarina je ista kao prošle godine, a za učenike i penzionere je besplatna.")
        ]
      },
      %{
        key: :photos,
        parent: sections.culture,
        kind: "article",
        name: "Izložba starih fotografija Potoka",
        excerpt: "Kako je kraj izgledao pre pola veka, na fotografijama komšija.",
        at: ago(11, 18, 0),
        cover: "stara-1",
        blocks: [
          p(
            "U holu Doma kulture otvorena je izložba starih fotografija Potoka. Fotografije su donele komšije iz porodičnih albuma, a najstarija je iz 1962. godine."
          ),
          gallery("polaroid", [
            {pic.("stara-1"), "Stara ulica sa kućama", "Ulica lipa, šezdesetih"},
            {pic.("stara-2"), "Stari most na kanalu", "Most na kanalu"},
            {pic.("stara-3"), "Stara pijaca", "Pijaca pre obnove"},
            {pic.("stara-4"), "Stari park", "Park kod škole"}
          ]),
          p(
            "Izložba je otvorena do kraja meseca, radnim danima od 10 do 18 časova. Ako imaš staru fotografiju kraja, donesi je u biblioteku: skeniraćemo je i vratiti ti je istog dana."
          )
        ]
      },
      %{
        key: :choir,
        parent: sections.culture,
        kind: "article",
        name: "Hor Doma kulture traži nove glasove",
        excerpt: "Probe su utorkom i četvrtkom, a iskustvo nije potrebno.",
        at: ago(19, 9, 0),
        cover: "hor",
        blocks: [
          p(
            "Hor Doma kulture prima nove članove. Ne treba ti muzičko obrazovanje ni iskustvo, samo volja da pevaš i da dolaziš na probe."
          ),
          img(pic.("hor"), "Hor na bini", "Hor na prošlom koncertu", "full"),
          ul([
            "Probe su utorkom i četvrtkom od 19 časova",
            "Hor peva starogradske pesme, horske klasike i pesme iz filmova",
            "Novi članovi prvi put nastupaju na sledećem koncertu"
          ]),
          p("Dođi na probu u salu na prvom spratu, ili se javi u razgovoru ispod ovog članka.")
        ]
      },
      %{
        key: :day,
        parent: sections.culture,
        kind: "article",
        name: "Dan mesne zajednice",
        excerpt: "Program za ceo dan, za decu i odrasle.",
        at: :scheduled,
        cover: "dan",
        blocks: [
          p(
            "Dan mesne zajednice slavimo u parku kod škole, od 10 časova: turnir u malom fudbalu, radionice za decu i koncert u 19 časova."
          ),
          img(
            pic.("dan"),
            "Park sa zastavicama i balonima",
            "Park kod škole, spreman za slavlje",
            "wide"
          )
        ]
      },

      # Sport ------------------------------------------------------------------
      %{
        key: :derby,
        parent: sections.sport,
        kind: "article",
        name: "FK Potok pobedio u derbiju",
        excerpt: "Dva gola u drugom poluvremenu i prvo mesto na tabeli.",
        at: ago(3, 19, 45),
        cover: "derbi",
        blocks: [
          p(
            "Fudbaleri FK Potok pobedili su u nedelju FK Prugu sa 2:0 i posle deset kola su prvi na tabeli opštinske lige."
          ),
          p(
            "Prvo poluvreme bilo je bez golova. U 58. minutu Stefan je pogodio glavom posle kornera, a deset minuta pre kraja Nikola je postavio konačan rezultat."
          ),
          quotation(
            "Momci su izdržali pritisak u prvom poluvremenu, a posle prvog gola sve je bilo lakše.",
            "trener FK Potok"
          ),
          h(3, "Tabela posle 10. kola"),
          table([
            ["", "Klub", "Utakmice", "Bodovi"],
            ["1.", "FK Potok", "10", "23"],
            ["2.", "FK Kanal", "10", "21"],
            ["3.", "FK Sloga", "10", "18"],
            ["4.", "FK Pruga", "10", "15"],
            ["5.", "FK Mladost", "10", "11"],
            ["6.", "FK Vrbak", "10", "7"]
          ])
        ]
      },
      %{
        key: :race,
        parent: sections.sport,
        kind: "article",
        name: "Trka uz kanal okupila 200 trkača",
        excerpt: "Pet kilometara uz vodu, od najmlađih do veterana.",
        at: ago(8, 13, 0),
        cover: "trka-1",
        blocks: [
          p(
            "Na petoj trci uz kanal startovalo je dvesta trkača, od predškolaca do veterana. Staza od pet kilometara vodila je od mosta do pruge i nazad."
          ),
          gallery("cards", [
            {pic.("trka-1"), "Cilj trke", "Cilj kod mosta"},
            {pic.("trka-2"), "Trkači na stazi", "Prvi kilometar"},
            {pic.("trka-3"), "Navijači na obali", "Navijači na obali"}
          ]),
          h(3, "Pobednici"),
          ol(["Marko, 17:42", "Ana, 18:05", "Luka, 18:31"]),
          p("Najmlađa učesnica imala je četiri godine i trku je završila na tatinim ramenima.")
        ]
      },
      %{
        key: :basketball,
        parent: sections.sport,
        kind: "article",
        name: "Upis u školu košarke",
        excerpt: "Treninzi za decu od 7 do 14 godina, na terenu kod škole.",
        at: ago(15, 17, 0),
        cover: "kosarka",
        blocks: [
          p(
            "Košarkaški klub Potok upisuje decu u školu košarke. Treninzi su na terenu kod osnovne škole, a kad je hladno, u fiskulturnoj sali."
          ),
          columns([
            [h(4, "Mlađi, 7–10 godina"), p("Utorkom i četvrtkom od 17 časova")],
            [h(4, "Stariji, 11–14 godina"), p("Ponedeljkom, sredom i petkom od 18 časova")]
          ]),
          callout("Prvi mesec treninga je besplatan. Ponesi patike i flašicu vode.")
        ]
      }
    ]
  end

  # Blocks of the Sajt app (`SiteDoc` fills in the rest of their fields).
  defp p(text), do: %{"type" => "paragraph", "text" => text}
  defp h(level, text), do: %{"type" => "heading", "level" => level, "text" => text}
  defp ul(items), do: %{"type" => "list", "ordered" => false, "items" => items}
  defp ol(items), do: %{"type" => "list", "ordered" => true, "items" => items}
  defp quotation(text, cite), do: %{"type" => "quote", "text" => text, "cite" => cite}
  defp callout(text), do: %{"type" => "callout", "text" => text}
  defp separator, do: %{"type" => "separator"}
  defp table(rows), do: %{"type" => "table", "header" => true, "rows" => rows}
  defp columns(columns), do: %{"type" => "columns", "columns" => columns}
  defp cover(src, alt, text), do: %{"type" => "cover", "src" => src, "alt" => alt, "text" => text}

  defp img(src, alt, caption, align),
    do: %{"type" => "image", "src" => src, "alt" => alt, "caption" => caption, "align" => align}

  defp gallery(look, images) do
    %{
      "type" => "gallery",
      "look" => look,
      "images" =>
        Enum.map(images, fn {src, alt, caption} ->
          %{"src" => src, "alt" => alt, "caption" => caption}
        end)
    }
  end

  defp buttons(items) do
    %{
      "type" => "buttons",
      "items" => Enum.map(items, fn {label, url} -> %{"label" => label, "url" => url} end)
    }
  end
end
