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

Zato mapa vidi tačno ono što gledalac vidi: zatvorena grupa u kojoj nije član nije ni na mapi. Dublje grupe nisu na mapi, samo one neposredno ispod.

## Postavljanje

Najkraći put je preset: **Kreiraj podgrupu** pa **Mapa**. Grupa počinje zatvorena, sa aplikacijom u opisu. Preset uzima kopiju iz `priv/apps/mapa.html`, koju `mix potok.sync_apps` osvežava iz build-a projekta. Svaka mapa čuva kopiju sa kojom je napravljena.

Ručno: u `potok-mapa` pokreni `npm run build`, u **Uredi grupu** uključi **Opis je aplikacija (API)** i u opis nalepi `dist/potok-build.html`.

Mesto dobija grupa na dva načina:

- u svojim podešavanjima, na kartici **Lokacija**: dodir ili prevlačenje pina na mapi, ili koordinate, i izbor pina. To sme ko sme da uređuje tu grupu.
- sa mape, dugmetom **Dodaj mesto**: krstić u sredini, naziv i vrsta. Nastaje podgrupa kao iz menija „Kreiraj podgrupu“, sa istim podrazumevanim podešavanjima. To sme član mape koji sme da pravi podgrupe, najviše 20 mesta na sat.

## Klik na pin

Mapa poziva `showGroup(id)`, a Potok otvara opis te grupe preko mape, u dijalogu svoje stranice, sa linkom ka celoj grupi. Unutra radi poseban LiveView vezan za tu grupu (`GroupLive.Sheet`), pa aplikacija u njenom opisu, recimo forma ili glasanje, radi sa pravima te grupe. Mapa sama nikad ne pokreće tuđu aplikaciju: svaki poziv aplikacije važi samo za grupu koja ju je pokrenula.

Kad gledalac zatvori dijalog, mapa dobija `onGroupSheetClose(id)` i pušta pin.

## Gusta mesta

Mesta koja su na ekranu bliže od 60 piksela skupljaju se u krug sa brojem. Obod kruga je prsten podeljen po tonovima pinova u njemu (mesta i usluge, zajednica, priroda, prijave, vrste grupa), pa se mešavina vidi pre otvaranja. Dodir otvara krug za nivo bliže. Mesta na istoj adresi ostaju zajedno do poslednjeg nivoa, pa dodir na takav krug otvara njihovu listu.

## Kad se nešto promeni

Kad se podgrupa napravi, promeni ili obriše, stranica javi aplikaciji `onSubgroupsChange` bez ikakvih podataka, jer bi id mogao da oda grupu koju gledalac ne vidi. Mapa onda ponovo pita `listPlaces`, svaki gledalac u svom nasumičnom trenutku do dve sekunde.
