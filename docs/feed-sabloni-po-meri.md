# Šabloni po meri za FeedCreator (predlog)

Predlog, ništa od ovoga nije napravljeno. Ideja: urednici sami prave šablone za feed. Šablon ima **definiciju forme** koju vide oni koji pišu objave i **HTML šablon** koji od upisanog (tekstova, linkova, slika) pravi opis objave.

## Šta postoji i može da se iskoristi

- **Format objave.** Opis počinje komentarom `<!--potok-post {...}-->` sa šablonom, poljima i otiskom (`hash`), a ispod je gotov HTML ([feed-i-feedcreator.md](feed-i-feedcreator.md#format-opisa)). Feed i strana grupe prikazuju taj HTML i ništa ne znaju o šablonima. Šablon po meri ne traži nikakvu promenu u Feed-u.
- **Vrste polja.** Ugrađeni šabloni već imaju `text`, `textarea`, `url`, `image`, `date`, `time`, `level`, `items`, a galerija dodaje `choice` i `pictures` (slike sa potpisima).
- **Sanitizer** proverava svaki opis kad se prikazuje, pa šablon ne može da ubaci skriptu ni tuđe klase.
- **Podaci aplikacije.** FeedCreator može da čuva šablone kao vrednosti u svojoj kolekciji, sa pravilom ko piše i ko čita (do 64 KB po vrednosti, do 20 kolekcija).
- **Slike.** `uploadImage` daje adresu `/pictures/...` koja ne traži prijavu.
- **`previewDescription`** već vraća HTML onakav kakav će gledalac videti.

## Predlog

### Definicija šablona

Jedna vrednost u kolekciji `templates` aplikacije FeedCreator u `.feed`:

```json
{
  "v": 1,
  "name": "Utakmica",
  "purpose": "Rezultat i strelci.",
  "fields": [
    {"key": "home", "label": "Domaćin", "kind": "text", "required": true},
    {"key": "score", "label": "Rezultat", "kind": "text"},
    {"key": "photos", "label": "Slike", "kind": "pictures", "max": 10}
  ],
  "html": "<h2>{{home}} {{score}}</h2>{{#photos}}<figure><img src=\"{{photos|image}}\"></figure>{{/photos}}",
  "sample": {"home": "Potok", "score": "2:1"},
  "rev": 3
}
```

- Pravilo kolekcije: pišu i čitaju urednici (`edit_group` u `.feed`), isti krug koji danas piše objave.
- Granice: do 30 polja, ceo šablon do 64 KB.

### Jezik šablona

Mali Mustache bez logike:

- `{{polje}}` je tekst, uvek escape-ovan.
- Filteri: `|inline` (`**jako**`, `*malo*`, linkovi), `|paragraphs`, `|date`, `|url`, `|image`. U `href` i `src` se stiže samo kroz `|url` i `|image`, koji prolaze kroz `safe_href` i `safe_image`.
- `{{#polje}}…{{/polje}}`: ako nije prazno, a za listu jednom za svaki red (`{{.}}`, a kod slika i `{{caption}}`).
- `{{^polje}}…{{/polje}}`: ako je prazno.
- Nema sirovog HTML-a iz polja i nema izraza. Sanitizer pri prikazu ostaje druga brana.

### Jedan renderer, na serveru

Danas su ugrađeni šabloni napisani dva puta (TypeScript u FeedCreatoru i Elixir u Potoku) i test ih poredi bajt po bajt. Za šablone po meri to ne treba ponavljati:

- `PotokIdeWeb.PostTemplates.Custom` u Potoku pravi HTML od definicije i polja.
- Dva nova poziva App API-ja: `renderTemplate(definicija, polja)` vraća HTML, a `checkTemplate(definicija)` vraća greške (nepoznato polje, nezatvoren blok, stil koji sanitizer briše, isto kao test „keeps every template's look“).
- FeedCreator nikad sam ne pravi HTML šablona po meri, pa nema dve verzije koje se razilaze. Kasnije i deset ugrađenih šablona mogu da pređu u isti format, i dupli kod nestaje.

### Objave

- Komentar objave nosi `"template": "custom:<id vrednosti>"` i `"rev"`.
- Objava zadržava svoj HTML kad se šablon promeni. Pri otvaranju forma popuni polja koja još postoje, a ostala čuva sa strane dok se objava ne sačuva.
- Uredi grupu može da menja i takve objave: server čita šablon iz kolekcije roditelja `.feed`.

### Uređivač u FeedCreatoru

Ekran **Šabloni**: lista, „novi od“ ugrađenog šablona (kopija kao početak), uređivanje polja po uzoru na pitanja u Formi, polje za HTML sa pregledom na uzornim vrednostima i ispod njega šta `checkTemplate` kaže.

### Deljenje

1. Prvo samo u jednom feed-u.
2. Zatim izvoz i uvoz kao JSON fajl, kao ZIP opisa aplikacije.
3. Zajednička biblioteka samo ako zatreba. Aplikacija danas ne čita podatke druge grupe (`list_scope`), pa bi to tražilo novo pravilo na serveru, recimo čitanje kolekcije imenovane grupe iznad.

### Bezbednost

Urednici već mogu da napišu bilo kakav HTML koji sanitizer pušta, u slobodnom tekstu. Šabloni im ne daju ništa novo, samo im štede posao.

## Otvorena pitanja

- Ko pravi šablone: svi urednici `.feed` ili samo admini?
- Da li šablon treba da važi u više feed-ova odjednom?
- Fajl koji nije slika (PDF i slično) nema trajnu javnu adresu: `/app_files` važi 10 minuta. Polje za takve fajlove traži novu potpisanu adresu, a to je odluka i za politiku privatnosti.
- Da li Uredi grupu treba da nudi šablone po meri za opis bilo koje grupe? Onda biblioteka ne stoji u `.feed`, nego više.

## Veličina

Srednje do veliko: renderer i provera na serveru, dva poziva API-ja sa testovima, ekran za šablone u FeedCreatoru. Otprilike koliko uređivač pitanja u Formi.
