# Sajt u Potoku: tema, jezik i pozivi za sajt u okviru aplikacije

Sajt objavljen na drugoj adresi može da stoji u opisu grupe, u okviru, i da se tamo ponaša kao deo Potoka: da prati njegovu temu i jezik i da poziva isti API koji pozivaju aplikacije. Referenca API-ja je u [README-u](../README.md#windowpotok), a poruke između SDK-a i sajta u njegovom odeljku [A site in the app's frame](../README.md#a-site-in-the-apps-frame). Ovde je opisano kako se sajt za to piše.

## Ideja

Opis grupe koji je aplikacija radi u zatvorenom okviru (sandbox). Sajt u tom opisu je okvir u okviru:

```
stranica Potoka  ⇄  okvir aplikacije (potok_app_sdk.js)  ⇄  sajt
```

| Sajt u okviru | Šta to znači |
|---|---|
| roditelj mu je okvir aplikacije | do stranice Potoka ne može sam; odgovara mu SDK u okviru aplikacije |
| nasleđuje sandbox | nema poreklo, pa ni `localStorage`, `sessionStorage` ni kolačiće: svaki pristup baca grešku |
| razgovara porukama | `postMessage` ka `window.parent`, u omotaču `{potok: 1, …}` |
| kôd mu nije u grupi | okvir izvršava ono što adresa servira u tom trenutku |

Sajt koji ne šalje ništa Potok ne dira: prikazuje se kao i do sada, u temi uređaja.

## Postavljanje

U **Uredi grupu** uključi **Opis je aplikacija (API)**, pa u opis stavi okvir sa adresom sajta:

```html
<iframe src="https://adresa-sajta/" title="Naziv sajta" data-potok-api="" style="width: 100%; height: 100vh; border: none;" loading="lazy"></iframe>
```

- Sajt mora da dozvoli prikaz u okviru: bez zaglavlja `X-Frame-Options` i bez `frame-ancestors`.
- Gost vidi sajt kad je opis otvoren gostima (**Pristup**, „Opis vidljiv i bez prijave“).
- Pozive sajt dobija tek kad ih opis nabroji na okviru: `data-potok-api="current_profile list_values"`. Bez tog atributa dobija temu i jezik, i ništa više.
- Okvir sa atributom `data-potok-api`, makar i praznim, Potok pamti: stranicu na kojoj je čitalac stao otvara i kad se okvir napravi iznova, a link sa `?page=` otvara poglavlje (vidi [Stranica i poglavlje](#stranica-i-poglavlje)).

## Poruke

Sajt se javlja pri učitavanju svake svoje stranice, a SDK mu odgovara istim porukama kojima stranica odgovara SDK-u.

| Smer | Poruka | Kada |
|---|---|---|
| sajt → SDK | `{potok: 1, event: "hello"}` | pri učitavanju svake stranice sajta |
| SDK → sajt | `{potok: 1, event: "ready", theme, lang, methods, app}` | odgovor na `hello` |
| SDK → sajt | `{potok: 1, event: "theme", theme}` | kad se tema Potoka promeni |
| SDK → sajt | `{potok: 1, event: "reconnected"}` | posle prekida i obnove veze |
| sajt → SDK | `{potok: 1, event: "page", page}` | posle `hello` i kad god čitalac pređe na drugu stranicu ili deo stranice |
| sajt → SDK | `{potok: 1, id, method, params}` | poziv |
| SDK → sajt | `{potok: 1, id, ok, …}` | odgovor na poziv |

- `theme` je `"light"`, `"dark"` ili `null`, kad Potok prati uređaj. Potok je postavlja atributom `data-theme` na `<html>`, pa sajt koji radi isto ne mora da menja stil.
- `lang` je `"sr"` (latinica), `"sr-Cyrl"` ili `"en"`. Promena jezika u Potoku učitava celu stranicu, pa jezik stiže samo u `ready`.
- `methods` je lista sa okvira, a `app` oznaka aplikacije (prazna za podrazumevani opis, inače `id` alternativnog). Vrednosti drugih aplikacija iste grupe nose drugi `description_id`.
- Sajt prima samo poruke čiji je pošiljalac `window.parent`. Šalje sa `"*"`, jer okvir aplikacije nema poreklo.

## Pozivi

`method` i `params` su ono što SDK sam šalje stranici: funkcija `insertValue` šalje `insert_value`, `getGroup` šalje `get_group`. Imena i parametri vide se u `assets/js/potok_app_sdk.js`, a šta koji poziv radi i ko ga sme u [README-u](../README.md#windowpotok).

| Poziv | `params` | Odgovor |
|---|---|---|
| `current_profile` | – | `{ok: true, profile}` |
| `get_group` | – | `{ok: true, group}` |
| `list_values` | kao `listValues`, sa imenima sa donjom crtom (`limit`, `order_dir`, `after_id`…) | `{ok: true, values, has_more, total}` |
| `insert_value` | `{data: "<JSON kao tekst>", content_format: "markdown"}` | `{ok: true, value}` |
| `list_personal` | – | `{ok: true, items: [{key, value, updated_at}]}` |
| `get_personal` | `{key}` | `{ok: true, value}` (`null` kad ključa nema) |
| `set_personal` | `{key, value}` | `{ok: true}` |
| `delete_personal` | `{key}` | `{ok: true}` |

- `id` je broj koji sajt sam dodeljuje; odgovor ga vraća. Zakasneli odgovor stiže stranici koja je tada u okviru, pa brojevi ne treba da kreću od 1 na svakoj stranici.
- Poziv koji nije na listi dobija `{ok: false, error: "not_listed"}` i ne stiže do stranice. Poziv na koji stranica ne odgovori za 10 sekundi dobija `{ok: false, error: "timeout"}`.
- Sve ostale greške su iste kao za aplikaciju (`forbidden`, `not_a_member`, `rate_limited`…): server proverava svaki poziv, ko god da ga šalje.
- `upload_file` i `upload_image` nose fajl kao `file` uz `params`, a napredak stiže kao `{potok: 1, event: "upload_progress", id, progress}`.

`*_personal` su lična memorija: ono što sajt čuva samo za tog čitaoca, isto na svakom uređaju, recimo beleške ili urađene zadatke. Ne vidi je niko drugi, ni urednici grupe, a čitalac je vidi i briše u podešavanjima naloga. Ključ ima od 1 do 64 slova, cifara i znakova `_ . : -`, vrednost je bilo šta što JSON drži, do 16 KB, a jedan sajt čuva najviše 100 ključeva po osobi. Gost bez naloga dobija iste pozive, ali mu se memorija čuva samo u pregledaču.

Ono što stranica šalje sama stiže sajtu samo ako sme da pročita isto to:

| Događaj | Stiže sajtu koji na listi ima |
|---|---|
| `new_value`, `app_value` | `list_values` |
| `poll_changed` | `list_polls` ili `get_poll` |
| `children_changed` | `list_children`, `list_subgroups` ili `list_places` |
| `waiting_changed` | `list_waiting` |
| `group_sheet_closed` | `show_group` |

## Stranica i poglavlje

Sajt javlja na kojoj je stranici čitalac: `{potok: 1, event: "page", page}`, gde je `page` `location.pathname + location.search + location.hash`. Potok to pamti za taj okvir, u kopiji `localStorage`-a koju stranica čuva za aplikaciju, i kad napravi okvir iznova (druga kartica grupe, promena jezika, obnova veze), otvara ga tamo. Dok ne zna kuda, okvir čeka bez adrese, najviše tri sekunde, da prva stranica sajta ne bi bljesnula.

- Pamti se samo putanja na istom sajtu: drugi host, `//host`, šema, obrnuta kosa crta ili više od 1024 znaka se odbacuju.
- Link na poglavlje: `?page=/poglavlja/03.html#clan-12` na adresi grupe otvara prvi takav okvir tamo, pre zapamćene stranice. Adresa grupe zatim prati čitaoca, bez novih koraka u istoriji, pa adresa koju neko kopira ili podeli otvara isto mesto.
- Sajt koji menja deo adrese bez učitavanja (`history.replaceState`, kao mapa ustava) javlja to sam: `SAJT_POTOK.stranica()`.

## Adapter

Ceo adapter, bez zavisnosti. Sajtovi napravljeni po `PDF-U-SAJT.md` nose ga kao `assets/potok.js`, prvu skriptu svake stranice.

- Ne radi ništa dok ne vidi znak Potoka: stranica je u okviru i roditelj je odgovorio, ili je prethodna stranica u istom okviru ostavila stanje u `window.name`.
- `window.name` ostaje isti dok se u okviru prelazi sa stranice na stranicu. Adapter tu upisuje temu i jezik, pa naredna stranica zna oba odmah, bez čekanja na odgovor. Na prvoj stranici stižu porukom.
- Na `<html>` stavlja klase `potok` i `potok-pismo`. Po njima sajt sakriva svoje dugme za temu, odnosno za pismo: u Potoku se bira u Potoku.
- Ono što Potok odredi ne upisuje u `localStorage`.
- Link ka drugom hostu i ka PDF-u otvara u novoj kartici.
- Posle `hello` javlja stranicu (`page`), i ponovo na `hashchange` i `popstate`; `stranica()` je javlja na zahtev sajta.
- Dodatne funkcije kreću iz `SAJT_POTOK.spremno.then(…)` i zovu `SAJT_POTOK.poziv("ime", parametri)`. Van Potoka se `spremno` nikad ne ispuni, pa sajt bez njih mora da radi.

```js
(function () {
  "use strict";

  var IME = "SAJT_POTOK";
  var DOGADJAJ = "sajt-potok";

  var html = document.documentElement;
  var roditelj = null;
  try { if (window.parent && window.parent !== window) roditelj = window.parent; } catch (e) { /* nema roditelja */ }

  var javiSpremno;
  var cekaju = {};      /* broj poziva -> funkcija koja ispunjava njegovo obećanje */
  var slusaoci = {};    /* događaj -> funkcije */
  /* Odgovor koji zakasni za prethodnu stranicu stiže ovoj, pa brojevi poziva ne kreću od 1. */
  var sledeci = Math.floor(Math.random() * 1e9);

  var P = {
    uPotoku: false,
    tema: undefined,    /* "light" / "dark" / null (sistemska); undefined dok se Potok ne javi */
    jezik: null,        /* "sr" / "sr-Cyrl" / "en" */
    pismo: null,        /* "lat" / "cir"; null kad Potok ne određuje pismo (engleski, van Potoka) */
    metode: [],         /* pozivi koje je opis grupe dozvolio ovom sajtu (data-potok-api) */
    spremno: new Promise(function (ispuni) { javiSpremno = ispuni; }),   /* van Potoka se nikad ne ispuni */
    poziv: poziv,
    na: na,
    stranica: stranica
  };
  window[IME] = P;
  if (!roditelj) return;

  /* ---------- stanje: tema i pismo ---------- */
  function pismoZa(jezik) {
    if (jezik === "sr-Cyrl") return "cir";
    if (jezik === "sr" || jezik === "sr-Latn") return "lat";
    return null;
  }

  function otisak() { return [P.uPotoku, String(P.tema), String(P.pismo)].join("|"); }

  /* stanje: { theme, lang }. Ključ koga nema znači „ne znam“ i ne menja ništa. */
  function primeni(stanje) {
    var pre = otisak();
    P.uPotoku = true;
    if ("theme" in stanje) {
      P.tema = stanje.theme === "light" || stanje.theme === "dark" ? stanje.theme : null;
      if (P.tema) html.setAttribute("data-theme", P.tema);
      else html.removeAttribute("data-theme");
    }
    if (typeof stanje.lang === "string" && stanje.lang) {
      P.jezik = stanje.lang;
      P.pismo = pismoZa(stanje.lang);
    }
    html.classList.add("potok");
    if (P.pismo) html.classList.add("potok-pismo");
    else html.classList.remove("potok-pismo");
    try { window.name = JSON.stringify({ potok: 1, theme: P.tema, lang: P.jezik }); } catch (e) { /* bez pamćenja */ }
    if (otisak() !== pre) document.dispatchEvent(new Event(DOGADJAJ));
  }

  /* Odmah, pre nav.js: ono što je prethodna stranica u ovom okviru upisala u window.name. */
  try {
    var seme = JSON.parse(window.name);
    if (seme && seme.potok === 1) primeni(seme);
  } catch (e) { /* window.name nije naš */ }

  /* ---------- poruke ---------- */
  function obavesti(dogadjaj, poruka) {
    (slusaoci[dogadjaj] || []).slice().forEach(function (fn) {
      try { fn(poruka); } catch (e) { if (window.console) console.error(e); }
    });
  }

  window.addEventListener("message", function (e) {
    var m = e.data;
    if (e.source !== roditelj || !m || m.potok !== 1) return;

    if (m.event === "ready") {
      if (Array.isArray(m.methods)) P.metode = m.methods.slice();
      primeni({ theme: m.theme, lang: m.lang });
      javiSpremno(m);
      return;
    }
    if (m.event === "theme") { primeni({ theme: m.theme }); return; }
    if (typeof m.event === "string") { obavesti(m.event, m); return; }

    var ispuni = cekaju[m.id];
    if (!ispuni) return;
    delete cekaju[m.id];
    var odgovor = {};
    for (var k in m) if (m.hasOwnProperty(k) && k !== "potok" && k !== "id") odgovor[k] = m[k];
    ispuni(odgovor);
  });

  roditelj.postMessage({ potok: 1, event: "hello" }, "*");

  /* ---------- stranica ---------- */
  /* Potok pamti gde je čitalac stao, a adresa grupe ga prati, pa link vodi na isto mesto. */
  function stranica() {
    if (!roditelj) return;
    roditelj.postMessage({ potok: 1, event: "page", page: location.pathname + location.search + location.hash }, "*");
  }
  stranica();
  window.addEventListener("hashchange", stranica);
  window.addEventListener("popstate", stranica);

  /* ---------- linkovi ---------- */
  /* Strana stranica ne sme da se učita u ovaj okvir, jer bi dobila iste pozive kao sajt, a PDF se u
     njemu ne prikazuje. Takvi linkovi zato idu u novu karticu. */
  document.addEventListener("click", function (e) {
    if (!P.uPotoku || e.button !== 0) return;
    var a = e.target && e.target.closest ? e.target.closest("a[href]") : null;
    if (!a || typeof a.host !== "string" || !/^(https?|file):$/.test(a.protocol)) return;
    if (a.host !== window.location.host || /\.pdf$/i.test(a.pathname)) {
      a.target = "_blank";
      a.rel = "noopener";
    }
  }, true);

  /* ---------- pozivi i događaji (za dodatne funkcije sajta) ---------- */
  /* poziv("current_profile") -> obećanje sa odgovorom Potoka ({ok: true, …} ili {ok: false, error}).
     Ime i parametri su oni koje Potokov SDK šalje stranici. Poziv koji opis grupe nije dozvolio vraća
     {ok: false, error: "not_listed"}. Van okvira obećanje se odmah odbija. */
  function poziv(metod, parametri, fajl) {
    if (!roditelj) return Promise.reject(new Error("Sajt nije u Potoku."));
    return P.spremno.then(function () {
      return new Promise(function (ispuni) {
        var id = ++sledeci;
        var poruka = { potok: 1, id: id, method: metod, params: parametri || {} };
        if (fajl) poruka.file = fajl;
        cekaju[id] = ispuni;
        roditelj.postMessage(poruka, "*");
      });
    });
  }

  /* na("new_value", fn) -> fn(poruka) za svaki takav događaj iz Potoka; vraća funkciju koja ga odjavljuje.
     „reconnected“ stiže posle prekida i obnove veze: ko prikazuje podatke iz Potoka, tada ih čita ponovo. */
  function na(dogadjaj, fn) {
    if (typeof fn !== "function") return function () {};
    (slusaoci[dogadjaj] = slusaoci[dogadjaj] || []).push(fn);
    return function () {
      var lista = slusaoci[dogadjaj] || [];
      var i = lista.indexOf(fn);
      if (i >= 0) lista.splice(i, 1);
    };
  }
})();
```

## Šta je drugačije nego kod aplikacije

- **Sajt nema `localStorage`.** Aplikaciji ga SDK zamenjuje kopijom koju čuva stranica; sajtu ne. Ono što treba da traje sajt čuva u ličnoj memoriji (`set_personal`), a tema i jezik idu kroz `window.name`.
- **Stranica se pamti** kad okvir ima `data-potok-api` i sajt javlja `page`: kad Potok napravi okvir iznova, sajt se otvara tamo gde je čitalac stao, a ne na prvoj stranici. Bez toga se vraća na prvu.
- **Posle prekida i obnove veze okvir ostaje.** Aplikacija se tada učitava iznova. Opis koji drži takav sajt i nema svojih skripti ne: sajt dobija `reconnected` i ostaje na stranici na kojoj je čitalac. Sajt koji prikazuje podatke iz Potoka tada ih čita ponovo.
- **PDF se u zatvorenom okviru često ne prikazuje**, pa takav link ide u novu karticu.

## Bezbednost

- **Poziv se izvršava u ime onoga ko gleda**, sa njegovim pravima u grupi. Kod urednika to uključuje izmenu opisa i podgrupa, ako su ti pozivi na listi.
- **SDK ne zna koja je stranica u okviru.** Sandbox sajtu ne ostavlja poreklo, pa se ono ne može proveriti: šta god da se u tom okviru otvori, dobija iste odgovore i iste pozive. Zato lista treba da bude najkraća koja radi, a sajt ne sme da pusti stranu stranicu u svoj okvir (adapter linkove ka drugim hostovima otvara u novoj kartici).
- **Kôd sajta nije zamrznut** kao otpremljena aplikacija. Ko drži adresu sajta, odlučuje šta članovi grupe vide i šta se sa liste poziva u njihovo ime. Opis sa adresom ide u Potok tek kad je sajt na adresi koju držiš; ime na besplatnom hostingu koje napustiš može zauzeti neko drugi.
- **Sajt ne veruje roditelju više nego što mora.** Tema i jezik od lažnog „Potoka“ ne mogu da naškode, ali sajt roditelju ne šalje ništa poverljivo i ne učitava skripte sa adrese koju mu roditelj kaže: ko god stavi sajt u svoj okvir, mogao bi tako da mu podmetne kôd.
- **Host sajta vidi posetioce.** Pregledač svakog člana i gosta koji otvori opis šalje zahtev hostu sajta, sa IP adresom i vremenom.

## Provera

- Bez Potoka: `alati/potok-proba.html` u sajtovima napravljenim po `PDF-U-SAJT.md` igra ulogu SDK-a. Sa diska radi sa otvorenim okvirom; verno, sa zatvorenim, uz `python -m http.server` u korenu sajta.
- U Potoku: grupa čiji je opis okvir sa adresom sajta. Promena teme stiže odmah, a promena jezika gradi okvir iznova, na istoj stranici sajta. Posle prekida veze sajt ostaje na otvorenoj stranici. Kartica grupe pa povratak vraća istu stranicu, adresa grupe nosi `?page=`, a ta adresa u novoj kartici otvara isto poglavlje. Poziv sa liste vraća odgovor, a poziv van nje `not_listed`.
