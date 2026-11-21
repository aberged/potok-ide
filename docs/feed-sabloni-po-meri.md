# Šabloni grupe (šabloni po meri)

Grupa može da ima svoje šablone za opise, pored deset ugrađenih. Šablon ima **polja forme** koju vidi onaj ko piše opis i **HTML** koji od upisanog (tekstova, linkova, slika i videa) pravi opis. Koriste ih Uredi grupu, za opis bilo koje grupe, i FeedCreator, za objave.

Odluke (2026-11-21): šablone pravi ko sme da uređuje grupu (u `.feed` to su njegovi urednici), važe za opis bilo koje grupe, a od fajlova uzimaju samo slike i video. Deljenje je izabrano kao „praktičnije“: šablon važi u svojoj grupi i u svim grupama ispod nje.

## Gde stoje i ko ih pravi

- Tabela `group_templates` (`PotokIde.Social.GroupTemplate`): `name` (do 60 znakova, jedinstveno u grupi bez obzira na velika slova), `purpose` (do 160), `fields`, `html` (do 32 KB), `rev` (raste sa svakim čuvanjem), `position`. Najviše 30 šablona u grupi i 30 polja u šablonu.
- `PotokIde.Social.GroupTemplates`: `catalog/2` daje šablone same grupe pa svake grupe iznad nje, prvo najbliže, sa imenom grupe iz koje dolaze kad je gledalac vidi. Menja ih ko ima `edit_group` u toj grupi; direktni razgovori i niti nemaju šablone. Svaka izmena javlja `{:group_templates_updated, id}` na temi grupe.
- Prave se na kartici **Šabloni** u Uredi grupu (`TemplatesCard`, `TemplatesState`): lista sopstvenih (uredi, pomeri, obriši), lista onih iz grupa iznad (samo za čitanje), i forma sa poljima, HTML-om, dugmetom „Napravi HTML od polja“ (`Custom.starter_html/1`) i pregledom sa primerima vrednosti koji kaže šta sanitizer izostavlja (`Custom.dropped/1`).

## Polja

Polje je `%{"key", "label", "kind", "required", "hint", "options"}`. Ključ je `^[a-z][a-z0-9_]{0,29}$`; bez njega nastaje od naziva (`Naslov vesti` daje `naslov_vesti`). Vrste: `text`, `textarea`, `url`, `date`, `time`, `choice` (do 20 opcija), `items` (lista teksta, do 30 redova), `image`, `pictures` (slike sa potpisima, potpisi pod `<ključ>_captions`, do 20) i `video`.

- Prvo obavezno `text` polje daje ime objave u FeedCreatoru (do 120 znakova), inače ime šablona.
- Prvo `textarea` polje je tekst kartice deljenog linka.

## Jezik šablona

Mali Mustache bez logike (`GroupTemplate.Syntax`):

- `{{ključ}}` je tekst, uvek escape-ovan; lista se spaja zarezima.
- Filteri: `|inline` (`**jako**`, `*malo*`, linkovi), `|paragraphs`, `|date`, `|url`, `|image`, `|video`. U `href` i `src` se stiže samo kroz poslednja tri, koja prolaze kroz `Markup.safe_href`, `safe_image` i `safe_video`.
- `{{#ključ}}…{{/ključ}}`: kad polje nije prazno, a za listu jednom za svaki red: `{{.}}` za `items`, `{{picture}}` i `{{caption}}` za `pictures`.
- `{{^ključ}}…{{/ključ}}`: kad je prazno.
- Nema sirovog HTML-a iz polja ni izraza, a sekcije idu najviše tri u dubinu. Šablon koji pominje polje koje nema, nepoznat filter ili nezatvorenu sekciju ne može da se sačuva.

## Jedan renderer, na serveru

`PotokIdeWeb.PostTemplates.Custom` je jedino mesto gde šablon grupe postaje HTML. Uredi grupu ga zove direktno, FeedCreator preko App API-ja:

- `listTemplates()` daje katalog za grupu aplikacije, sa sličicom svakog šablona (njegov HTML sa primerima, posle sanitizera).
- `renderTemplate(id, polja)` daje `description` (komentar i HTML, za čuvanje), `name`, `html` (kako se prikazuje) i `missing`.
- `uploadMedia(fajl)` šalje sliku ili video aplikacije u njenu javnu grupu fajlova.
- `openGroup(id, {tab: "templates"})` vodi na karticu Šabloni, i u samoj grupi aplikacije.

Sva tri poziva traže `edit_group`, a `renderTemplate` se broji kao upis. Ugrađeni šabloni ostaju napisani dva puta, kao i pre ([feed-i-feedcreator.md](feed-i-feedcreator.md)).

## Objave

- Komentar opisa nosi `"template": "custom:<id>"` i `"rev"`, ispred polja i otiska (`PostTemplates.Post`). `Post.decode/1` prepoznaje takav id po obliku, bez čitanja baze.
- Opis zadržava svoj HTML kad se šablon promeni; nova verzija ulazi tek kad se opis ponovo sačuva.
- Opis čiji je šablon obrisan, ili ga ova grupa ne vidi, otvara se kao tekst, uz napomenu, i čuva se kakav jeste. FeedCreator ga otvara kao slobodan tekst, bez komentara.

## Slike i video

Slika ili video sa uređaja u Uredi grupu ide u chat grupe kao poruka sa fajlom, a u FeedCreatoru u podgrupu Fajlovi aplikacije. Obe adrese su potpisane i otvaraju se bez prijave, i u privatnoj grupi. Video ide kakav jeste, do veličine bilo kog fajla; sanitizer pušta `<video>` sa `controls`, `playsinline`, `preload` (`none`, `metadata`) i `src`/`poster` samo preko `http` i `https`.

## Bezbednost

Urednici već mogu da napišu bilo kakav HTML koji sanitizer pušta, u slobodnom tekstu. Šabloni im ne daju ništa novo: svaka vrednost je escape-ovana, adresa ulazi samo kroz proveru, a sanitizer i dalje prolazi preko svakog opisa pri prikazu. Sličica šablona grupe, za razliku od ugrađenih, uvek ide kroz sanitizer.

## Šta nije urađeno

- Izvoz i uvoz šablona kao fajla, i biblioteka zajednička grupama koje nisu jedna ispod druge.
- Fajlovi koji nisu slika ni video (PDF i slično): `/app_files` važi 10 minuta, pa bi trajna adresa tražila odluku i u politici privatnosti.
- Deset ugrađenih šablona još nije prešlo u isti format.
