# Mapa: podgrupe kao pinovi na mapi

Mapa prikazuje mapu Srbije, ili prikaz koji sačuvaju njeni urednici, i na njoj kao pinove sve podgrupe neposredno ispod svoje grupe koje imaju mesto. Kod je u projektu `potok-mapa`, napravljenom po šablonu `potok-vite`, uz Leaflet i supercluster. Referenca API-ja je u [README-u](../README.md#windowpotok), a ovde je opisano kako se ti pozivi slažu u mapu.

## Ideja

Mapa ne čuva mesta. Svako mesto je obična grupa:

| Mapa ima | Gde to stoji |
|---|---|
| mesta | podgrupe grupe mape, sa geografskom širinom i dužinom (`Group.latitude`, `longitude`) |
| izgled pina | `Group.pin_icon`: ikonica iz kataloga (`PotokIde.Social.GroupPins`), slika grupe, ili ništa za znak vrste |
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

## Klik na pin

Mapa poziva `showGroup(id)`, a Potok otvara opis te grupe preko mape, u dijalogu svoje stranice, sa linkom ka celoj grupi. Unutra radi poseban LiveView vezan za tu grupu (`GroupLive.Sheet`), pa aplikacija u njenom opisu, recimo forma ili glasanje, radi sa pravima te grupe. Mapa sama nikad ne pokreće tuđu aplikaciju: svaki poziv aplikacije važi samo za grupu koja ju je pokrenula.

Kad gledalac zatvori dijalog, mapa dobija `onGroupSheetClose(id)` i pušta pin.

## Gusta mesta

Mesta koja su na ekranu bliže od 60 piksela skupljaju se u krug sa brojem, pinovi područja kao i svi ostali. Obod kruga je prsten podeljen po tonovima pinova u njemu (mesta i usluge, zajednica, priroda, prijave, vrste grupa), pa se mešavina vidi pre otvaranja. Dodir otvara krug za nivo bliže. Mesta na istoj adresi ostaju zajedno do poslednjeg nivoa, pa dodir na takav krug otvara njihovu listu.

## Kad se nešto promeni

Kad se podgrupa napravi, promeni ili obriše, stranica javi aplikaciji `onSubgroupsChange` bez ikakvih podataka, jer bi id mogao da oda grupu koju gledalac ne vidi. Mapa onda ponovo pita `listPlaces`, svaki gledalac u svom nasumičnom trenutku do dve sekunde.

## Mapa korena

Koren nema aplikaciju Mapa. Umesto nje ima svoj tab **Mapa grupa** (`/groups/:root/map`, `RootMapState` i `RootMapTab` u Potoku, kuka `root_map.js`), na kom su sve grupe sa mestom koje gledalac vidi, na bilo kojoj dubini: grupe u kojima je član i javne grupe, uz isti prekidač **Javne grupe** kao u podgrupama korena. Threadovi i direktni razgovori nisu na njoj.

Filteri su isti kao u podgrupama korena (član ili autor, vrsta, ime), uz filter po pinu (meni **Pin**, jedan ili više pinova, po delovima kao u biraču pina) i filter po vremenu: poslednja 24 sata, 7 ili 30 dana, 12 meseci, bilo kada, ili od datuma do datuma. Vreme se računa po nastanku grupe (kad je nastala ili postala javna, kao u Feed-u) ili po poslednjoj poruci. Mapa se otvara na svim vremenima. Pretraga po imenu (i u podgrupama i u meniju **Područje**) ne mari za velika slova, kvačice ni pismo: „cacak“ nalazi „Čačak“, „beograd“ nalazi „Београд“ (`NameSearch`, `potok_fold/1` u bazi).

Grupa može biti jako mnogo, pa ih broji server, a ne telefon: dok se mapa pomera, pregledač pita samo za ono što vidi (`root_map_view`), a `Social.list_map_cells/4` skuplja grupe u ćelije od oko 64 piksela. Ćelija sa jednom grupom vraća pin, svaka druga krug sa brojem, pa odgovor ima najviše nekoliko stotina oznaka. Oznake susednih ćelija koje bi se na ekranu dodirivale pregledač spaja u jedan krug, pa između oznaka uvek ostaje malo mesta. Dodir na krug približava mapu dok se krug ne raspadne, a grupe na istom mestu otvara kao listu. Dodir na pin otvara opis grupe u istom dijalogu kao kod aplikacije Mapa.

Mapa korena se ne osvežava sama: novo stanje stiže kad se mapa pomeri, kad se promeni filter ili kad se tab ponovo otvori.

## Područja

Mesto grupe može biti i područje, kao kod mesne zajednice: granica od jednog ili više poligona, sa rupama ili bez njih (`Group.area`, PostGIS, `PotokIde.Social.GroupAreas`). Zadaje je ko sme da uređuje grupu, na kartici **Lokacija** (prekidač **Tačka / Područje**): crta se dodirom na mapu (temena, tačke na sredini ivica, poništavanje), ili se uvozi iz GeoJSON fajla, koji čita pregledač. Ako fajl ima više područja, bira se jedno po imenu (`name`, `naziv`…). Granica ide serveru posebnim događajem, ne kroz formu, a server je proverava i sam stavlja pin područja u njegovu unutrašnjost.

| Pravilo | Kako |
|---|---|
| Ko je u području | grupa čiji je pin unutar granice; drugo područje samo ako je manje (centar grada ne „leži“ u kvartu) |
| Ko vidi područje | ko vidi njegovu grupu: članovi, a za javnu grupu svi prijavljeni |
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
