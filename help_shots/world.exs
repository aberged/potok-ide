defmodule HelpShots.World do
  @moduledoc """
  The made-up world the help page's pictures show: twelve people, the three
  organizations of the help text's examples (a local community, a buying co-op
  and a building) and the neighbourhood's news feed, with what they wrote
  yesterday and today. Names, places and words are invented; the map is real.

  `build/1` returns what `shots.mjs` needs: ids by name and a signed log-in
  cookie for every person.
  """

  import Ecto.Query

  alias PotokIde.Accounts
  alias PotokIde.Events
  alias PotokIde.Notices
  alias PotokIde.Polls
  alias PotokIde.Repo
  alias PotokIde.Social
  alias PotokIde.Social.Group
  alias PotokIde.Social.GroupAreas
  alias PotokIde.Social.GroupRoutes
  alias PotokIde.Social.Value
  alias PotokIde.Storage
  alias PotokIde.Tags
  alias PotokIdeWeb.PostTemplates

  @zone "Europe/Belgrade"
  @password "hello world!"
  @people ~w(ana marko jelena stefan milica nikola ivana dragan tamara luka sara petar)

  def build(files_dir) do
    # Announcements of events and polls are written in the seed's language.
    Gettext.put_locale(PotokIdeWeb.Gettext, "sr")
    File.mkdir_p!(files_dir)
    people = Map.new(@people, &{&1, person(&1)})
    p = fn name -> people[name].profile end
    root = Social.get_root_group!()

    mz = local_community(p, root, files_dir)
    news = news(p, root)
    coop = coop(p, root)
    shared = shared_profile(people)
    building = building(p, root, files_dir, shared)
    direct = direct(p)
    pending(p, mz)

    # Ana reads everything up to yesterday evening, so today's messages are new.
    for {group, until} <- [
          {mz.zbor, :yesterday},
          {mz.root, :latest},
          {building.root, :yesterday}
        ] do
      mark_read(p.("ana"), group, until)
    end

    for person <- Map.values(people) do
      {:ok, _} = Accounts.set_current_profile(person.account, person.profile)
    end

    # Announcements went out now; the lists order groups by their newest
    # message as backdated.
    Repo.query!("""
    UPDATE groups SET last_value_at =
      (SELECT max(v.inserted_at) FROM values v WHERE v.group_id = groups.id AND NOT v.is_data)
    """)

    %{
      people:
        Map.new(people, fn {name, person} ->
          {name,
           %{
             email: person.account.email,
             profile_id: person.profile.id,
             cookie: cookie(person.account)
           }}
        end),
      groups:
        Map.new(
          [
            root: root,
            mz: mz.root,
            mz_notices: mz.notices,
            mz_zbor: mz.zbor,
            mz_thread: mz.thread,
            mz_map: mz.map,
            mz_pothole: mz.pothole,
            news: news,
            coop: coop.root,
            coop_orders: coop.orders,
            coop_notices: coop.notices,
            building: building.root,
            building_council: building.council,
            direct: direct
          ],
          fn {key, group} -> {key, group.id} end
        ),
      values: %{
        zbor_question: mz.question.id,
        zbor_thread: mz.thread_origin.id,
        zbor_poll: mz.poll.value_id,
        zbor_photo: mz.photo.id
      },
      polls: %{zbor: mz.poll.id, building: building.poll.id},
      events: %{zbor: mz.event.id},
      shared_profile_id: shared.id,
      # For the date fields of forms, which take it as written.
      dates: %{saturday: Date.to_iso8601(next_weekday(6))}
    }
  end

  # People ------------------------------------------------------------------

  defp person(name) do
    {:ok, account} = Accounts.ensure_account_with_password("#{name}@example.com", @password)

    {:ok, profile} =
      Social.create_profile_for_account(account, %{
        username: name,
        profile_picture_url: nil,
        description: "",
        description_format: :markdown,
        sharing: :unique
      })

    %{account: Accounts.get_account!(account.id), profile: profile}
  end

  defp cookie(account) do
    token = Accounts.generate_account_session_token(account)
    secret = PotokIdeWeb.Endpoint.config(:secret_key_base)

    Plug.Crypto.sign(secret, "_potok_ide_web_account_remember_me_cookie", token,
      keys: Plug.Keys,
      max_age: 14 * 24 * 60 * 60
    )
  end

  # A local community -------------------------------------------------------

  # Somewhere in Novi Sad; the community and its streets' names are made up.
  @mz_area [
    [19.8236, 45.2468],
    [19.8402, 45.2441],
    [19.8489, 45.2522],
    [19.8411, 45.2611],
    [19.8259, 45.2598],
    [19.8236, 45.2468]
  ]

  defp local_community(p, root, files_dir) do
    ana = p.("ana")

    mz =
      folder(ana, root, "MZ Topolik", true, """
      Mesna zajednica Topolik: obaveštenja saveta, zbor građana, glasanja i mapa svega \
      što u kraju treba popraviti.

      - **Zbor građana** je svakog prvog četvrtka u mesecu, u Domu kulture.
      - **Savet MZ** odgovara na poruke radnim danima.
      - Problem u kraju? Dodaj ga na **Mapu kraja**, sa slikom.
      """)

    {:ok, mz} = Social.update_group(ana, mz, %{"area" => area(@mz_area), "pin_icon" => "local_community"})

    members(ana, mz, ~w(marko jelena stefan milica nikola ivana dragan tamara) |> Enum.map(p))

    {:ok, _manifest} = Social.create_own_group_manifest(ana, mz)
    {:ok, council} = Social.create_group_role(ana, mz, %{"name" => "savet"})

    for permission <- ~w(send_notices manage_events publish_events manage_polls delete_values)a do
      {:ok, _} = Social.set_group_role_permission(ana, mz, council.key, permission, :allow)
    end

    for name <- ~w(marko jelena) do
      {:ok, _} = Social.assign_group_member_role(ana, mz, p.(name).id, council.key)
    end

    notices = preset(ana, mz, "announcements", "Obaveštenja saveta")

    # The council writes in its notices; the others read and react.
    for permission <- ~w(post_values attach_files)a do
      {:ok, _} = Social.set_group_role_permission(ana, notices, council.key, permission, :allow)
    end

    zbor = preset(ana, mz, "chat", "Zbor građana")
    map = preset(ana, mz, "map", "Mapa kraja")

    places = [
      {"Rupa u Ulici lipa", "problem", 45.2531, 19.8338},
      {"Divlja deponija kod pruge", "waste", 45.2489, 19.8297},
      {"Ugašena svetla u parku", "power", 45.2566, 19.8415},
      {"Igralište kod škole", "nature", 45.2551, 19.8302},
      {"Dom kulture", "institution", 45.2520, 19.8380}
    ]

    [pothole, _dump, _lights, _playground, hall] =
      for {name, pin, lat, lng} <- places do
        {:ok, %{group: group}} =
          Social.create_group_from_preset(
            p.("marko"),
            map,
            "chat",
            %{"name" => name, "inherits_members" => true},
            %{"latitude" => lat, "longitude" => lng, "pin_icon" => pin}
          )

        group
      end

    {:ok, pothole} =
      Social.update_group(p.("marko"), pothole, %{
        "description" =>
          "Rupa duboka oko 15 cm ispred broja 12. Prijavljena komunalnom preduzeću 10. novembra; " <>
            "popravka je na spisku za ovaj mesec.",
        "description_format" => :markdown
      })

    {:ok, _route} =
      Social.create_group_from_preset(
        ana,
        map,
        "chat",
        %{"name" => "Staza uz kanal", "inherits_members" => true},
        %{"pin_icon" => "route"}
      )
      |> then(fn {:ok, %{group: group}} ->
        Social.update_group(ana, group, %{
          "route" =>
            route([
              [19.8262, 45.2489],
              [19.8318, 45.2502],
              [19.8371, 45.2535],
              [19.8422, 45.2571],
              [19.8455, 45.2602]
            ])
        })
      end)

    for {name, emoji} <- [{"jelena", "👍"}, {"nikola", "👍"}, {"ivana", "❤️"}] do
      {:ok, _} = Social.toggle_group_reaction(p.(name), mz, emoji)
    end

    Tags.add_tag(ana, :group, mz.id, "mesna-zajednica", :public)
    Tags.add_tag(ana, :group, map.id, "komunalno", :public)
    Tags.add_tag(ana, :group, zbor.id, "zbor", :public)

    # The council's notices to whoever follows the community.
    for name <- ~w(ana stefan milica nikola tamara luka sara) do
      {:ok, _} = Notices.follow(p.(name), mz)
    end

    send_notice(p.("marko"), mz, """
    Od ponedeljka do srede nema vode u ulicama Lipa i Breza, od 8 do 14 časova, zbog \
    radova na vodovodu.
    """)

    send_notice(ana, mz, "Zbor građana je u četvrtak u 18 časova u Domu kulture. Dođite!")

    post(p.("marko"), notices, "Javna rasveta u parku biće popravljena do petka.", ago(1, 9, 5))

    post(ana, notices, """
    Komunalno preduzeće odnosi krupni otpad u subotu. Iznesite ga ispred zgrade do 7 \
    časova.
    """, ago(0, 8, 12))

    # The assembly's chat: yesterday evening and this morning.
    question =
      post(p.("stefan"), zbor, """
      Da li neko zna kad počinje popravka Ulice lipa? Rupa kod broja 12 je sve veća.
      """, ago(1, 18, 4))

    post(p.("marko"), zbor, "Prijavio sam je komunalnom. Kažu da je na spisku za ovaj mesec.", ago(1, 18, 11),
      parent: question
    )

    post(p.("milica"), zbor, "Stavila sam je i na mapu kraja, sa slikom.", ago(1, 18, 20))

    thread_origin =
      post(p.("jelena"), zbor, """
      Predlažem da na zboru tražimo ležeće policajce u Ulici lipa. Deca tuda idu u školu.
      """, ago(1, 19, 2))

    react(zbor, thread_origin, [{"stefan", "👍"}, {"milica", "👍"}, {"nikola", "👍"}, {"ana", "❤️"}], p)

    # Only Ana sees her own tags.
    Tags.add_tag(ana, :value, question.id, "za-zbor", :private)
    Tags.add_tag(ana, :value, thread_origin.id, "za-zbor", :private)

    {:ok, thread} =
      Social.get_or_create_value_thread(p.("dragan"), zbor, thread_origin, %{
        "name" => "Ležeći policajci u Ulici lipa"
      })

    post(p.("dragan"), thread, "Slažem se. Može li neko da proveri koliko ih treba?", ago(1, 19, 15))
    post(p.("jelena"), thread, "Pitaću u opštini koja su pravila.", ago(1, 19, 22))
    post(p.("stefan"), thread, "Ja mogu da izmerim dužinu ulice ovog vikenda.", ago(0, 8, 40))

    post(p.("nikola"), zbor, "@ana možeš li da staviš glasanje o tome pre zbora?", ago(0, 9, 3))
    post(ana, zbor, "Može, evo ga.", ago(0, 9, 10))

    poll =
      poll(ana, zbor, %{
        "question" => "Da li da na zboru tražimo ležeće policajce u Ulici lipa?",
        "options" => options(["Za", "Protiv", "Uzdržan"]),
        "majority" => "simple",
        "quorum_percent" => "30",
        "closes_local" => local_in(3 * 24)
      }, ago(0, 9, 12))

    for {name, choice} <- [{"jelena", 0}, {"stefan", 0}, {"milica", 0}, {"dragan", 1}, {"nikola", 0}] do
      vote(p.(name), poll, choice)
    end

    photo = pothole(files_dir, "lipa-12.jpg")

    photo_value =
      post(p.("milica"), zbor, "Ovako izgleda danas posle kiše.", ago(0, 9, 31), files: [{zbor, photo}])
    post(p.("ivana"), zbor, "Strašno. Ja ću doneti potpise stanara sa broja 14.", ago(0, 9, 44))

    event =
      event(ana, zbor, next(4), ago(0, 9, 52), %{
        "title" => "Zbor građana",
        "description" => "Dnevni red: Ulica lipa, rasveta u parku, krupni otpad.",
        "place_group_id" => Integer.to_string(hall.id),
        "location" => "Dom kulture",
        "start_time" => "18:00",
        "end_time" => "20:00",
        "is_public" => "true"
      })

    for {name, status} <- [
          {"marko", :going},
          {"jelena", :going},
          {"stefan", :going},
          {"milica", :maybe},
          {"dragan", :going},
          {"ivana", :declined}
        ] do
      {:ok, _} = Events.respond(p.(name), event, next(4), status)
    end

    post(p.("milica"), pothole, "Rupa je duboka oko 15 cm, pazite biciklom.", ago(1, 18, 22),
      files: [{pothole, photo}]
    )

    %{
      root: mz,
      notices: notices,
      zbor: zbor,
      map: map,
      pothole: pothole,
      question: question,
      thread_origin: thread_origin,
      thread: thread,
      photo: photo_value,
      poll: poll,
      event: event
    }
  end

  # The neighbourhood's news -------------------------------------------------

  # A feed of its own, not one of the examples: the help text shows it with the
  # apps a group can have.
  defp news(p, root) do
    luka = p.("luka")
    %{group: news, feed: desk} = preset_full(luka, root, "feed", "Vesti Topolika", public: true)
    members(luka, news, ~w(ana stefan milica nikola) |> Enum.map(p))

    stories = [
      {"Sajam polovnih knjiga u Domu kulture", "Događaji",
       "U subotu od 10 do 14 časova: razmena i prodaja polovnih knjiga. Donesite one koje vam više ne trebaju.",
       ago(1, 20, 0)},
      {"Staza uz kanal je gotova", "Kraj",
       "Staza od pruge do mosta je asfaltirana i obeležena. Šetači i biciklisti mogu njome već od danas.",
       ago(0, 9, 0)}
    ]

    for {title, kicker, lead, at} <- stories do
      {:ok, story} =
        Social.create_group(luka, desk, %{
          "name" => title,
          "description" =>
            PostTemplates.render("article", %{"kicker" => kicker, "title" => title, "lead" => lead}),
          "description_format" => :html,
          "home_page" => :description
        })

      {:ok, story} = Social.update_group(luka, story, %{"inherits_members" => true})
      Repo.update_all(from(g in Group, where: g.id == ^story.id), set: [published_at: at])
    end

    for name <- ~w(ana stefan) do
      {:ok, _} = Notices.follow(p.(name), news)
    end

    send_notice(luka, news, "Nova vest: staza uz kanal je gotova. Otvaranje je u nedelju u 11 časova, kod mosta.")

    news
  end

  # A buying co-op ------------------------------------------------------------

  defp coop(p, root) do
    dragan = p.("dragan")

    coop =
      folder(dragan, root, "Zadruga Livada", false, """
      Zajednička nabavka od domaćina iz okoline: mleko, sir, jaja i povrće. Porudžbine do \
      četvrtka, preuzimanje subotom.
      """)

    {:ok, coop} =
      Social.update_group(dragan, coop, %{
        "latitude" => 45.2502,
        "longitude" => 19.8361,
        "pin_icon" => "market"
      })

    members(dragan, coop, ~w(ana ivana milica sara) |> Enum.map(p))

    notices = preset(dragan, coop, "announcements", "Obaveštenja kupcima")
    orders = preset(dragan, coop, "questionnaire", "Porudžbine")
    order_form(dragan, orders, [
      {p.("ivana"), [0, 1], "2", 1, "Preuzima Sara."},
      {p.("milica"), [0, 2, 3], "3", 0, ""},
      {p.("sara"), [1, 3], "", 0, "Preuzimam i za Ivanu."},
      {dragan, [0, 2], "1", 0, ""}
    ])
    chat = preset(dragan, coop, "chat", "Dogovor")

    post(dragan, notices, "Ove subote ima i domaćeg sira. Porudžbine do četvrtka u 20 časova.", ago(1, 12, 0))
    post(p.("ivana"), chat, "Može li neko da preuzme i za mene? Radim u subotu.", ago(0, 7, 50))
    post(p.("sara"), chat, "Mogu ja, ostavi mi spisak.", ago(0, 8, 5))

    event(dragan, coop, next_weekday(6), ago(0, 8, 30), %{
      "title" => "Preuzimanje porudžbina",
      "location" => "Dvorište škole",
      "start_time" => "09:00",
      "end_time" => "11:00",
      "recurrence" => "weekly",
      "recurrence_weekdays" => ["6"]
    })

    %{root: coop, notices: notices, orders: orders, chat: chat}
  end

  # A building ----------------------------------------------------------------

  defp building(p, root, files_dir, shared) do
    ivana = p.("ivana")

    building =
      preset(ivana, root, "chat", "Zgrada Cvetna 12")

    members(ivana, building, ~w(ana marko petar tamara) |> Enum.map(p))

    # The council keeps to itself: no inherited members, only those invited,
    # and the profile it answers with in the building.
    council = preset(ivana, building, "chat", "Kućni savet", inherits: false)
    members(ivana, council, [p.("ana"), p.("marko"), shared])
    members(ivana, building, [shared])
    post(p.("marko"), council, "Da li za čišćenje podruma da iznajmimo kontejner?", ago(1, 19, 0))

    minutes = pdf(files_dir, "zapisnik-sastanka.pdf")

    post(ivana, building, "Zapisnik sa sastanka stanara je ovde.", ago(1, 20, 10),
      files: [{building, minutes}]
    )

    post(p.("marko"), building, "Hvala! Ko ima ključ od podruma?", ago(1, 20, 31))
    post(p.("petar"), building, "Ja, u stanu 7.", ago(1, 20, 40))

    poll =
      poll(ivana, building, %{
        "question" => "Koje boje da okrečimo ulaz?",
        "options" => options(["Bela", "Bež", "Svetlo siva"]),
        "closes_local" => local_in(48)
      }, ago(1, 20, 50))

    for {name, choice} <- [{"marko", 1}, {"petar", 2}, {"tamara", 1}] do
      vote(p.(name), poll, choice)
    end

    post(p.("petar"), building, "Evo kako izgledaju sve tri boje na zidu.", ago(1, 20, 55),
      files: [{building, swatches(files_dir, "boje-ulaza.png")}]
    )

    post(ivana, building, "I pravila kućnog reda, da budu pri ruci.", ago(1, 21, 5),
      files: [{building, pdf(files_dir, "pravila-kucnog-reda.pdf")}]
    )

    post(p.("tamara"), building, "Bež mi deluje najpraktičnije.", ago(0, 11, 15))

    event(ivana, building, next_weekday(6), ago(0, 11, 20), %{
      "title" => "Čišćenje podruma",
      "location" => "Podrum",
      "start_time" => "10:00",
      "end_time" => "12:00"
    })

    post(shared, building, "Ključ od podruma je kod Petra, u stanu 7. Vreće za otpad donosi savet.", ago(0, 11, 30))

    %{root: building, council: council, poll: poll}
  end

  defp direct(p) do
    {:ok, direct} = Social.get_or_create_direct_group(p.("marko"), p.("ana"))
    post(p.("marko"), direct, "Možeš li da pogledaš obaveštenje pre nego što ga pošaljem?", ago(0, 10, 30))
    direct
  end

  # Ana and Marko answer for the building's council with one shared profile:
  # Ana made it and invited Marko's profile, which accepted.
  defp shared_profile(people) do
    %{"ana" => ana, "marko" => marko} = people

    {:ok, profile} =
      Social.create_profile_for_account(ana.account, %{
        username: "savet-cvetna",
        profile_picture_url: nil,
        description: "Kućni savet zgrade Cvetna 12.",
        description_format: :markdown,
        sharing: :shared
      })

    {:ok, invitation} = Social.invite_profile_to_profile(ana.account, ana.profile, profile, marko.profile)
    {:ok, _} = Social.accept_profile_invitation(invitation, marko.profile, marko.account)

    profile
  end

  defp pending(p, mz) do
    {:ok, _} = Social.request_group_access(p.("sara"), mz.root)
    {:ok, _} = Social.request_group_access(p.("petar"), mz.root)
  end

  # Helpers --------------------------------------------------------------------

  defp folder(creator, parent, name, public?, description) do
    group = preset(creator, parent, "folder", name, public: public?)

    {:ok, group} =
      Social.update_group(creator, group, %{
        "description" => String.trim(description),
        "description_format" => :markdown
      })

    group
  end

  defp preset(creator, parent, preset, name, opts \\ []) do
    preset_full(creator, parent, preset, name, opts).group
  end

  defp preset_full(creator, parent, preset, name, opts) do
    choices =
      %{"name" => name, "inherits_members" => Keyword.get(opts, :inherits, not parent.is_root)}
      |> then(&if Keyword.has_key?(opts, :public), do: Map.put(&1, "is_public", opts[:public]), else: &1)

    {:ok, result} = Social.create_group_from_preset(creator, parent, preset, choices)
    result
  end

  defp members(owner, group, profiles) do
    for profile <- profiles do
      {:ok, invitation} = Social.invite_profile_to_group(owner, group, profile)
      {:ok, _} = Social.accept_group_invitation(invitation, profile)
    end
  end

  defp area(ring), do: elem(GroupAreas.decode(%{"type" => "Polygon", "coordinates" => [ring]}), 1)
  defp route(points), do: elem(GroupRoutes.decode(%{"type" => "LineString", "coordinates" => points}), 1)

  # A message written at `at`, as if then: the same time for both stamps, so it
  # does not read as edited.
  defp post(profile, group, content, at, opts \\ []) do
    attachments =
      for {file_group, path} <- Keyword.get(opts, :files, []) do
        key = Storage.new_key(file_group.id)
        :ok = Storage.put_file(key, path)

        %{
          storage_key: key,
          filename: Path.basename(path),
          content_type: MIME.from_path(path),
          byte_size: File.stat!(path).size
        }
      end

    attrs =
      %{"content" => String.trim(content)}
      |> then(fn attrs ->
        case opts[:parent] do
          nil -> attrs
          parent -> Map.put(attrs, "parent_id", parent.id)
        end
      end)

    {:ok, value} = Social.create_value(profile, group, attrs, attachments)
    backdate(value.id, group, at)
    %{value | inserted_at: at, updated_at: at}
  end

  defp backdate(nil, _group, _at), do: :ok

  defp backdate(value_id, group, at) do
    Repo.update_all(from(v in Value, where: v.id == ^value_id), set: [inserted_at: at, updated_at: at])

    Repo.update_all(from(a in PotokIde.Social.ValueAttachment, where: a.value_id == ^value_id),
      set: [inserted_at: at]
    )

    Repo.update_all(
      from(g in Group, where: g.id == ^group.id and (is_nil(g.last_value_at) or g.last_value_at < ^at)),
      set: [last_value_at: at]
    )
  end

  defp react(group, value, reactions, p) do
    for {name, emoji} <- reactions do
      {:ok, _} = Social.toggle_value_reaction(p.(name), group, value, emoji)
    end
  end

  defp send_notice(author, group, body) do
    {:ok, _} =
      Notices.send_notice(author, group, Social.get_group_access(author, group), %{
        "body" => String.trim(body)
      })
  end

  # A poll put to the chat at `at`.
  defp poll(creator, group, attrs, at) do
    {:ok, poll} = Polls.create_poll(creator, group, attrs, @zone, announce: true)
    poll = Polls.get_poll(poll.id)
    backdate(poll.value_id, group, at)
    poll
  end

  defp options(texts) do
    texts |> Enum.with_index() |> Map.new(fn {text, i} -> {Integer.to_string(i), %{"text" => text}} end)
  end

  defp vote(profile, poll, index) do
    account = profile_account(profile)
    option = Enum.at(Polls.get_poll(poll.id).options, index)
    {:ok, _} = Polls.vote(profile, account, poll, [option.id])
  end

  defp profile_account(profile) do
    Repo.one!(
      from(a in PotokIde.Accounts.Account,
        join: ap in PotokIde.Social.AccountProfile,
        on: ap.account_id == a.id,
        where: ap.profile_id == ^profile.id,
        limit: 1
      )
    )
  end

  # An event on `date`, announced in the chat at `at`.
  defp event(creator, group, date, at, attrs) do
    attrs =
      Map.merge(
        %{
          "title" => "",
          "description" => "",
          "location" => "",
          "all_day" => "false",
          "start_date" => Date.to_iso8601(date),
          "end_date" => Date.to_iso8601(date),
          "recurrence" => "none",
          "recurrence_interval" => "1",
          "reminder_minutes" => ["", "60"]
        },
        attrs
      )

    {:ok, event} = Events.create_event(creator, group, attrs, @zone, announce: true)
    backdate(event.value_id, group, at)
    event
  end

  defp mark_read(profile, group, :latest), do: Social.mark_group_values_read(profile, group)

  defp mark_read(profile, group, :yesterday) do
    last =
      Repo.one(
        from(v in Value,
          where: v.group_id == ^group.id and v.inserted_at < ^ago(0, 0, 0),
          select: max(v.id)
        )
      )

    if last, do: Social.mark_group_values_read(profile, group, last), else: :ok
  end

  # `days` ago at `hour`:`minute` in Belgrade, in UTC.
  defp ago(days, hour, minute) do
    today()
    |> Date.add(-days)
    |> DateTime.new!(Time.new!(hour, minute, 0), @zone)
    |> DateTime.shift_zone!("Etc/UTC")
  end

  defp today, do: DateTime.utc_now() |> DateTime.shift_zone!(@zone) |> DateTime.to_date()
  defp next(days), do: Date.add(today(), days)

  defp next_weekday(weekday) do
    days = rem(weekday - Date.day_of_week(today()) + 7, 7)
    next(if days == 0, do: 7, else: days)
  end

  defp local_in(hours) do
    DateTime.utc_now()
    |> DateTime.add(hours, :hour)
    |> DateTime.shift_zone!(@zone)
    |> DateTime.to_naive()
    |> NaiveDateTime.truncate(:second)
    |> NaiveDateTime.to_iso8601()
  end

  # A photo stand-in, drawn by ImageMagick: a road with a lane marking and a
  # pothole full of rain.
  defp pothole(dir, name) do
    path = Path.join(dir, name)

    layer = fn draw -> ["(", "-size", "1200x900", "xc:none" | draw] ++ [")", "-composite"] end

    unless File.exists?(path) do
      {:ok, _} =
        PotokIde.ImageMagick.run(
          ~w(-seed 7 -size 1200x900 xc:#7a7975 -attenuate 1.2 +noise Gaussian -modulate 100,15 -blur 0x0.6) ++
            layer.([
              "-stroke",
              "#e8e4d8",
              "-strokewidth",
              "34",
              "-draw",
              "line 140,900 330,560",
              "-draw",
              "line 380,470 520,220",
              "-draw",
              "line 560,150 640,0",
              "-blur",
              "0x2"
            ]) ++
            ["-stroke", "none"] ++
            layer.([
              "-fill",
              "#2c2d2e",
              "-draw",
              "polygon 430,520 520,430 680,415 820,455 900,540 860,640 700,690 540,675 450,620",
              "-blur",
              "0x10"
            ]) ++
            layer.([
              "-fill",
              "#8aa1ae",
              "-draw",
              "polygon 500,530 570,470 690,460 790,500 830,560 790,620 670,650 560,630",
              "-blur",
              "0x14",
              "-channel",
              "A",
              "-evaluate",
              "multiply",
              "0.8",
              "+channel"
            ]) ++
            ["(", "-size", "1200x900", "gradient:#ffffff-#9a9a9a", ")"] ++
            ~w(-compose multiply -composite -quality 80) ++ [path]
        )
    end

    path
  end

  # Three wall colours side by side, for the building's poll.
  defp swatches(dir, name) do
    path = Path.join(dir, name)

    unless File.exists?(path) do
      {:ok, _} =
        PotokIde.ImageMagick.run(
          ~w(-size 400x600 xc:#f4f2ec -size 400x600 xc:#e3d3b3 -size 400x600 xc:#cfd3d4 +append) ++
            ~w(-bordercolor #ffffff -border 24) ++ [path]
        )
    end

    path
  end

  # The co-op's order form, as the Forma app saves it: published, filled in by
  # every member once and changed by its author until Thursday at 20:00, with
  # the orders of `answers`: who, the products (by index), litres of milk, who
  # picks up (by index) and a note.
  defp order_form(editor, group, answers) do
    closes_at =
      next_weekday(4)
      |> DateTime.new!(~T[20:00:00], @zone)
      |> DateTime.shift_zone!("Etc/UTC")
      |> DateTime.to_iso8601()

    option = fn label -> %{"id" => id(), "goTo" => nil, "label" => label, "picture" => nil} end

    question = fn kind, title, extra ->
      Map.merge(
        %{
          "id" => id(),
          "key" => nil,
          "kind" => kind,
          "type" => "question",
          "title" => title,
          "description" => "",
          "showDescription" => false,
          "required" => false,
          "options" => [],
          "rows" => [],
          "columns" => [],
          "other" => false,
          "points" => 0,
          "picture" => nil,
          "shuffle" => false,
          "dateTime" => false,
          "dateYear" => true,
          "scaleMax" => 5,
          "scaleMin" => 1,
          "branching" => false,
          "fileCount" => 1,
          "fileTypes" => [],
          "fileSizeMb" => 10,
          "ratingIcon" => "star",
          "validation" => nil,
          "filePrivate" => true,
          "rowRequired" => false,
          "shuffleRows" => false,
          "ratingLevels" => 5,
          "timeDuration" => false,
          "scaleMaxLabel" => "",
          "scaleMinLabel" => "",
          "limitPerColumn" => false
        },
        extra
      )
    end

    [products, milk, pick_up, note] =
      items = [
        question.("checkbox", "Šta poručuješ?", %{
          "required" => true,
          "options" => Enum.map(["Mleko, 1 l", "Domaći sir, 500 g", "Jaja, 10 komada", "Paket povrća"], option)
        }),
        question.("short", "Koliko litara mleka?", %{}),
        question.("choice", "Ko preuzima?", %{
          "required" => true,
          "options" => Enum.map(["Ja, u subotu", "Neko drugi za mene"], option)
        }),
        question.("paragraph", "Napomena", %{})
      ]

    form = %{
      "v" => 1,
      "title" => "Porudžbine za subotu",
      "description" => "Poruči do četvrtka u 20 časova. Preuzimanje je u subotu od 9 do 11, u dvorištu škole.",
      "theme" => %{"header" => nil},
      "startNext" => "next",
      "items" => items,
      "settings" => %{
        "fill" => ["everyone"],
        "once" => true,
        "open" => true,
        "quiz" => %{
          "enabled" => false,
          "release" => "immediate",
          "released" => false,
          "showMissed" => true,
          "showPoints" => true,
          "showCorrect" => true,
          "defaultPoints" => 0
        },
        "view" => [],
        "public" => false,
        "editOwn" => true,
        "closesAt" => closes_at,
        "anonymous" => false,
        "published" => true,
        "anotherLink" => false,
        "progressBar" => false,
        "confirmation" => "Hvala! Vidimo se u subotu.",
        "closedMessage" => "",
        "requiredDefault" => false,
        "shuffleQuestions" => false,
        "summaryForRespondents" => false
      }
    }

    data = %{
      "v" => 1,
      "form" => form,
      "files" => %{},
      "rules" => %{
        "responses" => %{
          "once" => true,
          "open" => true,
          "read" => [],
          "score" => nil,
          "under" => ["a"],
          "write" => ["everyone"],
          "public" => false,
          "summary" => [],
          "uploads" => %{},
          "edit_own" => true,
          "anonymous" => false,
          "closes_at" => closes_at
        }
      },
      "secret" => %{"keys" => %{}, "score" => %{"responses" => %{}}}
    }

    {:ok, _} = PotokIde.Social.AppData.save_config(editor, group, nil, data, nil)

    for {profile, chosen, litres, who, text} <- answers do
      response = %{
        "v" => 1,
        "form_rev" => 1,
        "a" => %{
          products["id"] => Enum.map(chosen, &Enum.at(products["options"], &1)["id"]),
          milk["id"] => litres,
          pick_up["id"] => Enum.at(pick_up["options"], who)["id"],
          note["id"] => text
        },
        "other" => %{}
      }

      {:ok, _value, _rule} =
        PotokIde.Social.AppData.insert(profile, profile_account(profile), group, nil, "responses", response)
    end
  end

  defp id, do: :crypto.strong_rand_bytes(5) |> Base.encode32(case: :lower, padding: false)

  defp pdf(dir, name) do
    path = Path.join(dir, name)

    unless File.exists?(path) do
      {:ok, _} = PotokIde.ImageMagick.run(["-size", "595x842", "xc:white", path])
    end

    path
  end
end
