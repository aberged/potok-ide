# Feed i FeedCreator: dve aplikacije na jednoj grupi

Primer šta sve može App API. Dve male aplikacije prave news-feed sa uredništvom, a server za to ne zna ništa o vestima. Referenca API-ja je u [README-u](../README.md#app-api), a ovde je opisano kako se ti pozivi slažu u nešto korisno.

Kod je u projektima `potok-feed` i `potok-feed-creator`, oba napravljena po šablonu `potok-vite`.

## Ideja

Potok nema pojam objave, ali ima grupu, a grupa već ima sve što objavi treba:

| Objavi treba | Grupa ima |
|---|---|
| tekst | opis |
| naslov i sličica | ime i sliku |
| razgovor | chat |
| publika | članove i prekidač „Javna grupa“ |
| ko sme da menja | uloge |

Zato je objava obična grupa, a aplikacije samo dve strane istog stabla:

```
Vesti                     roditeljska grupa; njen opis je Feed
└── .feed                 opis ove grupe je FeedCreator
    ├── Most na potoku    jedna objava: opis je tekst, chat je razgovor
    └── Nema vode         druga objava
```

| | Feed | FeedCreator |
|---|---|---|
| Stoji u | opisu roditeljske grupe | opisu `.feed` |
| Radi za | svakog ko otvori grupu | onog ko sme da menja `.feed` |
| Čita | grupe ispod `.feed` | direktne podgrupe svoje grupe |
| Piše | ništa | objave |

Aplikacije ne razgovaraju jedna sa drugom i ne znaju jedna za drugu. Ceo ugovor između njih je ime `.feed` i to da je opis grupe tekst objave. Zato Feed prikazuje i vesti napravljene ručno, a FeedCreator uređuje i njih.

## Postavljanje

1. U oba projekta pokreni `npm run build`. Svaki pravi jedan fajl, `dist/potok-build.html`.
2. Napravi roditeljsku grupu, ili otvori postojeću. U **Uredi grupu** uključi **Opis je aplikacija (API)** i u opis nalepi build Feed-a.
3. U toj grupi napravi podgrupu tačnog imena `.feed`:
   - uključi **Nasleđuje članove**;
   - uključi **Javna grupa** ako je roditeljska grupa javna;
   - uključi **Opis je aplikacija (API)** i u opis nalepi build FeedCreator-a.
4. U `.feed` otvori **Uloge**, klikni **Napravi sopstveni manifest** i za ulogu **Svi** isključi **Kreiranje podgrupa**. Bez toga svaki član može ručno da napravi javnu grupu u `.feed`, i ona odmah ulazi u feed.
5. Ako objavljuju i drugi, a ne samo admini, u istom manifestu napravi ulogu, na primer `urednik`, i daj joj **Kreiranje podgrupa** i **Uređivanje grupe**.

Tačka u imenu `.feed` nema posebno značenje za Potok, pa se ta grupa vidi u listi podgrupa kao svaka druga. Ako ima više podgrupa tog imena, važi najstarija.

FeedCreator proverava ove korake. Kad admin otvori aplikaciju, vidi šta u podešavanjima ne valja i kako se popravlja.

## Ko šta sme

Aplikacija radi za svakog ko je otvori, sa pravima tog gledaoca. Zato API ima jedno pravilo za sve što piše u grupe:

> Aplikacija čita izvor i piše u podgrupe samo za gledaoca koji sme da menja grupu u kojoj aplikacija stoji (dozvola `edit_group`).

To su oni koji mogu i da prepišu kod aplikacije, pa im aplikacija ne može ništa novo. Podrazumevano su to samo admini. Bez ovog pravila bi svaka aplikacija u svakoj grupi mogla tiho da pravi grupe u ime običnog člana koji je otvori, jer članovi podrazumevano smeju da prave podgrupe.

Još ograničenja, koja važe i za onog ko prođe to pravilo:

- Doseg je samo direktna podgrupa grupe u kojoj aplikacija stoji.
- Pravljenje traži i **Kreiranje podgrupa**, a izmena traži i **Uređivanje grupe** u samoj podgrupi.
- Aplikacija ne može da postavi „Opis je aplikacija (API)“, pa ne može da napravi drugu aplikaciju.
- Grupu koja je aplikacija ne može da menja ni da čita njen izvor.
- Nema poziva za brisanje grupe. FeedCreator vodi na stranu grupe, gde je brisanje sa potvrdom.
- Upisi troše isti limit kao i ostali upisi aplikacije.

Manifest `.feed` se prenosi sam. Objava nema svoj manifest, pa koristi manifest prve grupe iznad sebe koja ga ima, a to je `.feed`. Uloge se prenose nasleđivanjem članova: admin `.feed` je admin i svake objave koja nasleđuje. Autor je admin svoje objave i bez toga.

Zato uloga koja objavljuje mora da ima **Uređivanje grupe** u `.feed`, što joj daje i izmenu same aplikacije. Da treba da objavljuje svaki član, ovo pravilo bi moralo da se olabavi.

## Stanja objave

Potok ne zna šta je nacrt. Stanje objave je samo ono što daju dva prekidača njene grupe:

| Stanje | Javna grupa | Nasleđuje članove | Ko vidi | Ko je u chatu |
|---|---|---|---|---|
| Nacrt | ne | ne | autor i oni koje pozove | isti |
| Članovi | ne | da | članovi `.feed` | isti, odmah |
| Javno | da | da | svi prijavljeni | članovi `.feed` |
| Javno, bez članova | da | ne | svi prijavljeni | samo oni koji dobiju pristup |

- **Sačuvaj** pravi zatvorenu grupu. Vidi je samo autor, i u svom Feed-u je vidi sa oznakom **Nacrt**.
- **Objavi** uključuje prekidače. Podrazumevana publika prati `.feed`: javna ako je `.feed` javna, inače članovi. Nasleđivanje je podrazumevano uključeno.
- **Povuci** vraća objavu u nacrt, a nasleđeni članovi izlaze iz grupe. Direktni članovi i chat ostaju. Onaj ko povlači ostaje kao direktan član, pa grupa ne ostane bez nikog.

Povuci je poseban poziv jer obično isključivanje nasleđivanja nikog ne izbacuje: nasleđeni članovi tada postaju direktni i dalje vide grupu. Zato FeedCreator posle objave zaključa prekidač za nasleđivanje.

**Red u feed-u.** Grupe idu od najnovije, a zatvorena grupa se računa od trenutka kad se otvorila (`published_at`). Nacrt napisan u ponedeljak i objavljen u petak izlazi na vrh, a ne iza svega što je objavljeno tog dana. Isto važi kad se povučena objava ponovo objavi.

## Lanac članstva

Članovi teku odozgo nadole, ali samo kroz grupe koje nasleđuju:

```
Vesti  ──  .feed  ──  objava
```

- Član roditelja ulazi u objavu samo ako nasleđuje i `.feed` i objava. Kad jedna karika ne nasleđuje, lanac tu staje.
- Novi član roditelja odmah ulazi u sve objave koje nasleđuju, a njihova istorija mu je već pročitana, pa ne dobija poplavu nepročitanih.
- Ko izađe iz roditelja, izlazi i iz objava u koje je ušao nasleđivanjem. Direktni članovi ostaju.

Vidljivost ide posebnim putem. Feed čita kroz `.feed`, pa gledalac mora da vidi i `.feed` i objavu:

| Podešavanje | Šta se dešava |
|---|---|
| Roditelj javan, `.feed` privatna | nečlan dobija `not_found`, a Feed mu kaže da `.feed` ne postoji |
| `.feed` javna, objava privatna | objavu vide samo njeni članovi, a to je način za objave samo za članove |
| `.feed` privatna, objava javna | u Feed-u je vide samo članovi `.feed`, ali svako sa linkom je vidi van Potoka |

Chat vide samo članovi grupe, bez izuzetka. Nečlan koji klikne Chat vidi opis objave i dugme za pristup. Polje `has_public_chat` postoji u šemi, ali ga ništa ne čita. Ko želi da razgovara o svim objavama, treba da uđe u roditeljsku grupu, a ne u pojedinačnu objavu.

## Format opisa

Opis objave mora sam da stoji, jer ga Feed prikazuje onakvog kakav stiže sa servera. FeedCreator zato piše HTML sa stilovima u samim tagovima, a u prvi red stavlja ono od čega je objava napravljena:

```html
<!--potok-post {"v":1,"template":"quote","fields":{"quote":"..."},"hash":"1a2b3c4d"}-->
<blockquote style="background-color: #1e3a8a; color: #ffffff; ...">...</blockquote>
```

- Grupa čuva komentar u izvoru, a sanitizer ga briše iz svega što gledalac dobija, pa i iz teksta za deljeni link. Izvor dobija samo onaj ko sme da ga menja.
- `hash` je otisak HTML-a ispod komentara. Ako se ne slaže, neko je tekst promenio ručno, pa FeedCreator otvara objavu kao slobodan tekst i nudi povratak na šablon. Forma sa poljima bi inače pregazila tu izmenu.
- Grupa bez komentara otvara se kao slobodan tekst, sa svojim formatom.
- Pregled ide preko `previewDescription`, kroz isti sanitizer, pa autor vidi tačno ono što će Feed dobiti.

Sanitizer određuje kako šablon sme da izgleda:

| Prolazi | Ne prolazi |
|---|---|
| `h1`-`h6`, `p`, `div`, `section`, `article`, `blockquote`, `figure`, `table`, `ul`, `ol`, `details` | `class`, `id`, `data-*`, `<style>`, `<script>`, `<iframe>`, `<video>` |
| `style` na tim tagovima | `style` na `img` i `a` |
| `color`, `background-color`, `border`, `border-radius`, `padding`, `margin`, `font-size`, `font-weight`, `line-height`, `text-align`, `width`, `height` | `flex`, `grid`, `max-width`, `gap`, `box-shadow`, `opacity`, `transform`, `position`, `overflow: hidden` |
| `#ffffff` i `rgb(1,2,3)` | `#FFFFFF`, `rgba()`, `var()`, gradijenti |
| `http`, `https`, `mailto` i relativne adrese | `data:` u `img` |

Iz toga slede tri pravila za šablone:

- Stubovi se prave tabelom, kao u email-u. `.rich-content` tabeli daje `width: max-content`, pa joj treba `display: block; width: 100%`, inače dugačak tekst ne prelama.
- Tema stranice ne stiže do boje upisane u `style`. Površina u boji zato uvek postavlja i pozadinu i tekst, a par boja mora da radi i u svetloj i u tamnoj temi.
- Boja linka dolazi iz teme, pa na površini u boji nema linkova.

`src/sanitizer.test.ts` u projektu FeedCreator drži kopiju ovih pravila i proverava svaki šablon.

## Pozivi koje par koristi

| Poziv | Ko ga zove | Čemu služi |
|---|---|---|
| `listSubgroups(".feed", {limit, beforeId})` | Feed | vesti, stranu po stranu |
| `openGroup(id, {tab})` | oba | chat, strana aplikacije, podešavanja, roditelj |
| `getGroup()` | FeedCreator | sme li gledalac da piše i da li je grupa dobro podešena |
| `listChildren({limit, beforeId})` | FeedCreator | lista objava |
| `getChild(id)` | FeedCreator | izvor objave za uređivanje |
| `createChild(attrs)` | FeedCreator | Sačuvaj i Objavi za novu objavu |
| `updateChild(id, attrs)` | FeedCreator | izmena, Objavi za nacrt |
| `withdrawChild(id)` | FeedCreator | Povuci |
| `previewDescription(text, options)` | FeedCreator | pregled |

## Ograničenja

- **Slike.** Opis ne sme da sadrži `data:` sliku, a API nema slanje fajlova. Slika sa uređaja zato postaje slika grupe, do oko 1080 piksela, pa je objava ima jednu i ista je i avatar. Ruta `/avatar/group/:id` ne traži prijavu, pa je slika privatne objave dostupna svakome ko pogodi adresu. FeedCreator je briše iz grupe kad je autor ukloni. Slika je i avatar u svakoj listi grupa, pa lista sa mnogo objava učitava i te slike.
- **Cena nasleđivanja.** Svaki član je red u članstvu svake objave: 100 članova i 500 objava je 50.000 redova, a svaki novi član dodaje 500. Svaka poruka u chatu objave ide kao push svim njenim članovima, a opcije za utišavanje grupe nema. Za veliku publiku i živ chat bolja je javna objava bez nasleđivanja, uz manje udobnosti pri ulasku u chat.
- **Objava ne šalje obaveštenje.** Pravljenje grupe nikog ne obaveštava. Članovi vide novu objavu kad otvore Feed.
- **Feed se ne osvežava uživo.** Vesti se učitavaju kad se aplikacija otvori.
- **Poslednji upis pobeđuje.** Ako dvoje istovremeno menja istu objavu, ostaje ono što je sačuvano poslednje.
- **Nacrt je lični.** Drugi urednik ga ne vidi dok ga autor ne pozove u grupu.
- **Bez zakazivanja.** Objava izlazi kad se klikne.
- **Prijava.** App API radi samo za prijavljene. Neprijavljeni sa linkom vide pregled javne grupe, a ne Feed.

## Isti obrazac za druge stvari

Ništa ovde nije vezano za vesti. Isti raspored radi kad god sadržaj treba da ima svoj razgovor i svoju publiku:

| Primena | Roditeljska aplikacija prikazuje | Aplikacija u podgrupi pravi |
|---|---|---|
| Oglasna tabla | oglase u mreži | oglas sa cenom i kontaktom |
| Blog | listu tekstova | tekst sa naslovom i slikom |
| Katalog | proizvode | karticu proizvoda |
| Česta pitanja | pitanja na otvaranje | pitanje i odgovor |
| Događaji | program | događaj sa vremenom i mestom |

Šta menjaš: ime podgrupe, šablone i način prikaza. Šta dobijaš bez koda: razgovor uz svaku stavku, članstvo, uloge, nepročitano, datoteke i deljene linkove sa karticom.

Dobra provera da li je obrazac prikladan: ako stavci treba razgovor ili sopstvena publika, neka bude grupa. Ako je samo red podataka, dovoljna je data vrednost u jednoj aplikaciji (`insertValue`), koja je mnogo jeftinija.
