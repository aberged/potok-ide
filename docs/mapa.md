# Mapa: podgrupe kao pinovi na mapi

Mapa prikazuje mapu Srbije, ili prikaz koji sačuvaju njeni urednici, i na njoj kao pinove sve podgrupe neposredno ispod svoje grupe koje imaju mesto. Kod je u projektu `potok-mapa`, napravljenom po šablonu `potok-vite`, uz Leaflet i supercluster. Referenca API-ja je u [README-u](../README.md#windowpotok), a ovde je opisano kako se ti pozivi slažu u mapu.

## Ideja

Mapa ne čuva mesta. Svako mesto je obična grupa:

| Mapa ima | Gde to stoji |
|---|---|
| mesta | podgrupe grupe mape, sa geografskom širinom i dužinom (`Group.latitude`, `longitude`) |
| izgled pina | `Group.pin_icon`: ikonica iz kataloga (`PotokIde.Social.GroupPins`), slika grupe, ili ništa za znak vrste; izabrani pin u gornjem desnom uglu zadržava mali znak vrste (`mark` vrste u katalogu), kao avatar grupe, a zatvorena grupa ima katanac u gornjem levom |
| crteže pinova i njihova imena | stranica ih šalje uz `getMapConfig` (`PotokIdeWeb.PinIcons`), pa nova ikonica ne traži novi build |
| početni prikaz | konfiguracija aplikacije (`saveConfig`): `{view: {bounds: [[jug, zapad], [sever, istok]]}}` |
| pločice mape | Potok ih šalje dalje sa OpenStreetMap-a, preko `/tiles` (`PotokIde.MapTiles`), i čuva ih nedelju dana |

Zato mapa vidi tačno ono što gledalac vidi: zatvorena grupa u kojoj nije član nije ni na mapi. Dublje grupe nisu na mapi, samo one neposredno ispod. Sve grupe sa mestom, na bilo kojoj dubini, pokazuje mapa korena (vidi dole).

## Postavljanje

Najkraći put je preset: **Kreiraj podgrupu** pa **Mapa**. Koren ga ne nudi, jer ima svoju mapu. Grupa počinje zatvorena, sa aplikacijom u opisu. Preset uzima kopiju iz `priv/apps/mapa.html`, koju `mix potok.sync_apps` osvežava iz build-a projekta. Svaka mapa čuva kopiju sa kojom je napravljena.

Ručno: u `potok-mapa` pokreni `npm run build`, u **Uredi grupu** uključi **Opis je aplikacija (API)** i u opis nalepi `dist/potok-build.html`.

Mesto dobija grupa na dva načina:

- u svojim podešavanjima, na kartici **Lokacija**: dodir ili prevlačenje pina na mapi, ili koordinate, i izbor pina. To sme ko sme da uređuje tu grupu.
- sa mape, dugmetom **Dodaj mesto**: krstić u sredini, naziv i vrsta. Nastaje podgrupa kao iz menija „Kreiraj podgrupu“, sa istim podrazumevanim podešavanjima. To sme član mape koji sme da pravi podgrupe, najviše 20 mesta na sat.
- iz druge aplikacije u istoj grupi, pozivima `createChild`/`updateChild` sa `lat`, `lng` i `pin`, ili `createChildren` za do 100 odjednom. Tako aplikacija za uvoz (`potok-saobracajke`) od redova otvorenih podataka pravi mesta.

## Zapisi

Grupa koju je aplikacija napravila sa ključem (`createChildren`, `Group.external_key`) je zapis, kao jedna saobraćajna nezgoda iz tabele MUP-a. Ključ se upisuje jednom i jedinstven je ispod roditelja, pa ponovni uvoz istog fajla ne pravi duplikate. Zapis je obična grupa sa mestom i stoji na mapi svoje grupe, ali ga **mapa korena i biranje mesta za događaje izostavljaju**: inače bi stotine hiljada tačaka zatrpale mapu korena i usporile svako njeno pomeranje. Indeksi koje mapa korena čita (`groups_place_index`, `groups_pin_index`) zato i ne drže zapise. Nepročitano profila koji ih je uneo ih ne prati, pa uvoz radi poseban profil, kao kod uvoza područja. Probni uvoz se briše sa `PotokIde.Social.RecordImport.start_remove(parent_id, profile_id)` preko `bin/potok_ide rpc`.

## Klik na pin

Mapa poziva `showGroup(id)`, a Potok otvara opis te grupe preko mape, u dijalogu svoje stranice, sa linkom ka celoj grupi. Unutra radi poseban LiveView vezan za tu grupu (`GroupLive.Sheet`), pa aplikacija u njenom opisu, recimo forma ili glasanje, radi sa pravima te grupe. Mapa sama nikad ne pokreće tuđu aplikaciju: svaki poziv aplikacije važi samo za grupu koja ju je pokrenula.

Kad gledalac zatvori dijalog, mapa dobija `onGroupSheetClose(id)` i pušta pin.

## Gusta mesta

Mesta koja su na ekranu bliže od 60 piksela skupljaju se u krug sa brojem, pinovi područja kao i svi ostali. Obod kruga je prsten podeljen po tonovima pinova u njemu (mesta i usluge, zajednica, priroda, prijave, vrste grupa), pa se mešavina vidi pre otvaranja. Dodir otvara krug za nivo bliže. Mesta na istoj adresi ostaju zajedno do poslednjeg nivoa, pa dodir na takav krug otvara njihovu listu.

## Velike mape

Do 2000 mesta mapa ih dobija sva odjednom i sama ih skuplja u krugove. Preko toga, kao godina saobraćajnih nezgoda sa oko 35.000 tačaka, `listPlaces` sa pogledom (`bbox`, `zoom`) odgovara sa `mode: "view"`: server skuplja neposredne podgrupe u ćelije od oko 64 piksela, istim upitom kao mapa korena (`Social.list_map_cells/4` sa filterom `:parent_id`), a mapa pita ponovo kad se pomeri. Pretraga po imenu i filter po pinu tada idu na server, a dodir na krug koji se više ne raspada otvara listu (`listPlacesAt`, najviše 50 po imenu). Indeks `groups_placed_parent_index (parent_id, latitude, longitude)` drži taj upit brzim.

Filter po pinu se pojavi čim na mapi postoje bar dva različita pina, a urednik mape čipovima daje svoja imena (legenda u konfiguraciji, npr. `problem` = „Poginuli“).

## Kad se nešto promeni

Kad se podgrupa napravi, promeni ili obriše, stranica javi aplikaciji `onSubgroupsChange` bez ikakvih podataka, jer bi id mogao da oda grupu koju gledalac ne vidi. Mapa onda ponovo pita `listPlaces`, svaki gledalac u svom nasumičnom trenutku do dve sekunde. `createChildren` javlja jednom za ceo poziv, a velika mapa pita ponovo najviše jednom u 10 sekundi, pa uvoz dok je mapa otvorena ne zatrpava ni stranicu ni server.

## Mapa korena

Koren nema aplikaciju Mapa. Umesto nje ima svoj tab **Mapa grupa** (`/groups/:root/map`, `RootMapState` i `RootMapTab` u Potoku, kuka `root_map.js`), na kom su sve grupe sa mestom koje gledalac vidi, na bilo kojoj dubini: grupe u kojima je član i javne grupe, uz isti prekidač **Javne grupe** kao u podgrupama korena. Grupe koje prati ostaju na mapi i kad je prekidač isključen, a filter **Grupe koje pratim** ostavlja samo njih. Threadovi, direktni razgovori i zapisi (vidi gore) nisu na njoj.

Filteri su isti kao u podgrupama korena (član ili autor, vrsta, ime), uz filter po pinu (meni **Pin**, jedan ili više pinova, po delovima kao u biraču pina) i filter po vremenu: poslednja 24 sata, 7 ili 30 dana, 12 meseci, bilo kada, ili od datuma do datuma. Vreme se računa po nastanku grupe (kad je nastala ili postala javna, kao u Feed-u) ili po poslednjoj poruci. Mapa se otvara na svim vremenima. Pretraga po imenu (i u podgrupama i u meniju **Područje**) ne mari za velika slova, kvačice ni pismo: „cacak“ nalazi „Čačak“, „beograd“ nalazi „Београд“ (`NameSearch`, `potok_fold/1` u bazi).

Grupa može biti jako mnogo, pa ih broji server, a ne telefon: dok se mapa pomera, pregledač pita samo za ono što vidi (`root_map_view`), a `Social.list_map_cells/4` skuplja grupe u ćelije od oko 64 piksela. Ćelija sa jednom grupom vraća pin, svaka druga krug sa brojem, pa odgovor ima najviše nekoliko stotina oznaka. Oznake susednih ćelija koje bi se na ekranu dodirivale pregledač spaja u jedan krug, pa između oznaka uvek ostaje malo mesta. Dodir na krug približava mapu dok se krug ne raspadne, a grupe na istom mestu otvara kao listu. Dodir na pin otvara opis grupe u istom dijalogu kao kod aplikacije Mapa.

Mapa korena se ne osvežava sama: novo stanje stiže kad se mapa pomeri, kad se promeni filter ili kad se tab ponovo otvori.

### Linkovi na jedno mesto

Mapa korena se otvara i na jednom mestu, od bilo kada i kakvi god da su filteri:

| Link | Šta pokazuje |
|---|---|
| `?place=ID` | mesto grupe: istaknut pin sa prstenom koji pulsira, a područje ili rutu i uokvirene; vodi ga traka iznad opisa grupe-tačke („Prikaži na mapi“) |
| `?event=ID` | mesto događaja iz kalendara, uz karticu događaja dole (naslov, vreme, mesto, **Otvori događaj**, × je sklanja, dodir na pin je vraća); otkazan događaj ne pokazuje ništa |

Oba parametra čita samo tab mape (`RootMapState`), jer kalendar ima svoj `event`. Grupa ili događaj koje gledalac ne vidi ne menjaju ništa.

Mesto događaja su reči („Mesto“), a na mapi može biti **grupa sa mestom** (`group_events.place_group_id`) ili **svoje mesto**: tačka, područje ili ruta (`latitude`/`longitude`, `area`, `route`), nikad oboje. U formi događaja dugme **Izaberi lokaciju** otvara meni grupa sa mestom koje autor vidi, od najbližih (`GroupPlaces.search/4`), a **Izaberi na mapi** otvara malu mapu sa istim izborom **Tačka / Područje / Ruta** kao na kartici Lokacija grupe (isti `LocationPicker`, uz događaje forme `calendar_place_area` i `calendar_place_route`, i zajedničke delove u `LocationEditor`). Područje drži pin u sebi, a ruta na početku; na mapi korena područje događaja je uokvireno, a ruta istaknuta, i pregledač ih traži jednom (`root_map_focus_shape`). Događaj na mestu grupe stoji gde i grupa i prati je kad se pomeri; ko grupu ne vidi, vidi samo reči (`Events.place/2`), a brisanje grupe ostavlja reči. Detalj događaja ima link **Prikaži na mapi**, a `.ics` dobija liniju `GEO`.

## Područja

Mesto grupe može biti i područje, kao kod mesne zajednice: granica od jednog ili više poligona, sa rupama ili bez njih (`Group.area`, PostGIS, `PotokIde.Social.GroupAreas`). Zadaje je ko sme da uređuje grupu, na kartici **Lokacija** (prekidač **Tačka / Područje**): crta se dodirom na mapu (temena, tačke na sredini ivica, poništavanje), ili se uvozi iz GeoJSON fajla, koji čita pregledač. Ako fajl ima više područja, bira se jedno po imenu (`name`, `naziv`…). Granica ide serveru posebnim događajem, ne kroz formu, a server je proverava i sam stavlja pin područja u njegovu unutrašnjost.

| Pravilo | Kako |
|---|---|
| Ko je u području | grupa čiji je pin unutar granice; drugo područje samo ako je manje (centar grada ne „leži“ u kvartu) |
| Ko vidi područje | ko vidi njegovu grupu: članovi, a za javnu grupu svi prijavljeni, i gosti bez naloga u aplikaciji Mapa grupe koja je otvorila opis za njih |
| Nalazi se u | na opisu grupe i u listu preko mape: vidljiva područja oko pina, od najmanjeg |
| Na mapi korena | područje je samo oblik svoje grupe: filteri (i prekidač **Javne grupe**) ga zadrže ili izostave kao svaku grupu, a broj, „Prikaži sve“, lista na mestu i dodir računaju isti skup; pin područja je u krugovima kao i svaki drugi, a kad je područje široko bar ~64 px (dva pina) ispod pinova se crta i njegova granica |
| Slojevi | **Mesta** i **Područja** se pale i gase dugmetom na mapi, pregledač pamti izbor |
| Dodir na mapu | kartica sa područjima na tom mestu: Otvori, Samo unutra, Uvećaj, i veća područja okolo |
| Filter | meni **Područje** (pretraga, više područja), ostavlja grupe unutar njih i zatamni ostalo; izabrana područja ostaju uokvirena na svakom zumu; **Samo unutra** na kartici bira samo to područje; link `?area=ID` |
| Granice | stižu jednom po nivou detalja (`root_map_shapes`, uprošćene za ~0,75 px), server ih čuva (`AreaShapes`), a pregledač ih drži u svom kešu |

### Područja u aplikaciji Mapa

Aplikacija Mapa crta područja među svojim podgrupama po istim pravilima kao mapa korena (`src/areas.ts`):

- `listPlaces` uz svako mesto kaže `shape` (`point` ili `area`) i `areas`, područja među tim mestima koja ga obuhvataju, od najmanjeg; područje ima i `bbox` i `v`.
- Granice traži `placeShapes(ids, zoom)`, sto po pozivu, i čuva ih po `id`, `v` i nivou detalja.
- Pin područja je među ostalim pinovima i skuplja se u krugove; područje šire od ~64 px dobija i granicu ispod pinova. Čipovi vrsta i pretraga biraju područja kao i mesta.
- Dugme **Slojevi** (samo kad mapa ima područja) pali i gasi **Mesta** i **Područja**.
- Dodir na mapu van pinova otvara karticu područja na tom mestu (Otvori, Samo unutra, Uvećaj, i veća područja okolo). **Samo unutra** ostavlja pinove tog područja, zatamni ostatak i stavi čip „U: …“ koji filter skida.
- U listi mesta red kaže „Područje“ ili „U: …“ (najmanje područje oko mesta).
- Područje druge grupe (koje nije neposredno ispod mape) nije na mapi i ne obuhvata ništa u njoj.

## Rute

Mesto grupe može biti i ruta: otvorena linija od jednog ili više delova, kao šetnja, trka, protestna ili komemorativna šetnja, pešačka ili biciklistička staza (`Group.route`, PostGIS `MultiLineString`, `PotokIde.Social.GroupRoutes`). Zadaje je ko sme da uređuje grupu, na kartici **Lokacija** (prekidač **Tačka / Područje / Ruta**): crta se dodirom na mapu (tačke redom, tačkice na sredini deonica, poništavanje, **Obrni smer**), ili se uvozi iz GPX, KML ili GeoJSON fajla, koji čita pregledač (`route_files.js`). Ruta ide serveru posebnim događajem (`edit_group_route`), a server je proverava i stavlja pin na njen početak.

| Pravilo | Kako |
|---|---|
| Pin | na početku rute (prva tačka prvog dela), gde se ljudi okupljaju; kraj je kružić na mapi |
| Ili, ili | mesto je tačka, područje ili ruta, nikad i područje i ruta (`groups_route_check`); nova ruta briše područje i obrnuto |
| Ruta sme | da seče samu sebe i da se završi gde počinje (krug); deo mora imati bar dve tačke; najviše 100 delova i 10.000 tačaka |
| Fajlovi | GPX (`trk`/`trkseg`, `rte`), KML (`LineString`, i u `MultiGeometry`, `gx:Track`), GeoJSON (`LineString`, `MultiLineString`); KMZ treba raspakovati; do 20 MB; ako ima više ruta, bira se jedna po imenu; preko 10.000 tačaka pregledač je uprošćava |
| U području | ruta je u svakom području kroz koje prolazi, ne samo u onom gde počinje (`GroupAreas.areas_along/3`); stranica grupe kaže „Prolazi kroz“, uz dužinu rute |
| Na mapi korena | ruta je samo oblik svoje grupe, kao područje: filteri je zadrže ili izostave; pin je u krugovima, a kad je ruta široka bar ~64 px, preko područja se crta njena linija (najviše 150 po pogledu); dodir na liniju otvara grupu |
| Sloj | **Rute** se pale i gase u meniju slojeva, pored **Mesta** i **Područja** |
| Filter po području | zadržava i rute koje samo prolaze kroz izabrano područje |
| Link | `?route=ID` otvara mapu na ruti, od bilo kada, i crta je kakvi god da su filteri |
| Linije | stižu kao granice (`root_map_shapes`, `ST_Simplify` koji čuva kratke petlje), u istom kešu |

### Rute u aplikaciji Mapa

Aplikacija Mapa crta rute među svojim podgrupama po istim pravilima kao mapa korena (`src/areas.ts`):

- `listPlaces` za rutu kaže `shape: "route"`, `bbox`, `v` i `length` (metri), a `lat`, `lng` su njen početak; `areas` su područja među tim mestima kroz koja prolazi.
- Linije daje `placeShapes(ids, zoom)` kao i granice (`MultiLineString`), u istom kešu.
- Pin rute je među ostalim pinovima; ruta šira od ~64 px dobija i liniju iznad granica, sa kružićem na kraju (najviše 150 u pogledu). Dodir na liniju otvara grupu kao i dodir na pin.
- Dugme **Slojevi** (kad mapa ima područja ili rute) pali i gasi i **Rute**; bez **Mesta** ostaju oblici čiji je sloj upaljen.
- **Samo unutra** zadržava i rute koje prolaze kroz to područje; u listi red kaže „Ruta · 1,3 km“ i „Kroz: …“.
