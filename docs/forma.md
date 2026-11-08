# Forma: forma za unos na podacima aplikacije

Forma radi kao Google Forms, a izgleda kao ostatak Potoka: urednik piše pitanja, ispitanici popunjavaju, a oni kojima je dozvoljeno vide odgovore, rezime i tabelu. Kod je u projektu `potok-forme`, napravljenom po šablonu `potok-vite`. Referenca API-ja je u [README-u](../README.md#collections-and-rules), a ovde je opisano kako se ti pozivi slažu u formu.

## Ideja

Sve što forma ima su vrednosti grupe:

| Forma ima | Gde to stoji |
|---|---|
| pitanja, sliku zaglavlja, podešavanja | konfiguracija aplikacije: jedna vrednost kolekcije `config`, menja se u mestu |
| ko popunjava, ko vidi odgovore, jedan odgovor po osobi, rok… | `rules` u konfiguraciji, koje Potok sprovodi pri svakom pozivu |
| tačne odgovore kviza | `secret` u konfiguraciji, koji čitaju samo urednici |
| odgovore | vrednosti kolekcije `responses`, po jedna za svaki poslat odgovor |
| fajlove uz odgovore i slike forme | vrednosti sa fajlom u dve podgrupe forme |
| obaveštenja o odgovorima | pretplate čitalaca, koje vodi Potok |

Server ne zna ništa o pitanjima. Zna samo ko sme da upiše vrednost u koju kolekciju, ko sme da je pročita, koliko puta i do kada. Zato pravila važe i kad neko zove API iz konzole, a sadržaj odgovora proverava aplikacija dok se popunjava.

## Postavljanje

Najkraći put je preset: **Kreiraj podgrupu** pa **Forma**. Grupa počinje zatvorena, sa aplikacijom u opisu. Prvi urednik koji je otvori dobija praznu formu sa imenom grupe i počinje da piše.

Preset uzima kopiju iz `priv/apps/forme.html`, koju `mix potok.sync_apps` osvežava iz build-a projekta. Svaka forma čuva kopiju sa kojom je napravljena, pa nova verzija stiže samo u forme napravljene posle nje.

Ručno: u `potok-forme` pokreni `npm run build`, u **Uredi grupu** uključi **Opis je aplikacija (API)** i u opis nalepi `dist/potok-build.html`.

## Ko šta sme

- **Urednici forme** su oni koji smeju da uređuju grupu, podrazumevano admini. Oni pišu konfiguraciju i uvek vide sve odgovore, jer pravila ionako mogu da promene.
- **Ko popunjava** i **ko vidi odgovore** su uloge grupe, koje urednik bira u podešavanjima i pri objavi. Ostali vide samo svoje odgovore.
- **Urednik popunjava** formu dugmetom **Popuni**: vidi je kao ispitanici, a njegov odgovor se računa kao svaki drugi. Pravila važe i za njega: dok forma nije objavljena, ne prima odgovore ili njegove uloge ne popunjavaju, to je samo pregled, a traka kaže zašto.
- **Javna forma**: u javnoj grupi popunjavaju i prijavljeni nečlanovi, osim blokiranih. Svaki vidi samo svoj odgovor.
- **Ispitanici vide rezime**: one koji popunjavaju Potok pušta samo do zbirnih brojeva, ne do pojedinačnih odgovora.

## Odgovori

Odgovor je `{v, form_rev, a: {pitanje: odgovor}, other: {pitanje: tekst}}`. Pitanja i opcije imaju stalne id-jeve, pa preimenovanje opcije ne kvari ranije odgovore ni statistiku. „Drugo“ je `"__other"`, a tekst ide u `other`.

Rezime broji Potok u bazi (`summarizeValues`): za izbore, skale i mreže korpu po opciji, a za kratke odgovore, datume i vremena iste odgovore zajedno. Tabela, pojedinačni pregled i pregled po pitanju idu stranicu po stranicu, sa ukupnim brojem (`total`). CSV aplikacija pravi u okviru, po 100 odgovora odjednom.

## Fajlovi

Pitanje za otpremanje šalje fajl u jednu od dve podgrupe forme, koje Potok pravi kad zatrebaju:

- **Privatni fajlovi**: zatvorena, ne nasleđuje članove. Fajlove otvaraju samo njeni članovi, na početku urednik koji ju je napravio, a ostale pozivaš kao u svaku grupu.
- **Fajlovi**: nasleđuje članove grupe forme, pa fajlove otvaraju svi njeni članovi. Tu idu i slike forme.

Onaj ko je poslao fajl uvek može da ga otvori. Ako neko otvori privatnu grupu (javna ili sa nasleđivanjem), forma prestaje da prima fajlove i urednik vidi upozorenje. Anonimna forma nema pitanje za otpremanje, jer uz fajl ostaje ime onog ko ga je poslao.

## Kviz

Urednik zadaje bodove i tačne odgovore. Potok boduje svaki odgovor po ključu iz `secret` i upisuje bodove u `managed`. Pasus, datum, vreme, skala i fajl se ocenjuju ručno. Ocene se objavljuju odmah ili posle pregleda, sve odjednom. Kad se objavljuju odmah, odgovor ne može da se menja, a posle objave ne može nikako.

## Granice

- Anonimnost štiti od čitalaca i od API-ja, ne od onoga ko prepiše kod aplikacije. Id i vreme slanja se vide.
- Važi poslednje čuvanje urednika. Ako je neko drugi u međuvremenu sačuvao, urednik bira čiju verziju zadržava.
- Nečlan javne grupe preuzima samo slike forme, ne i ostale javne fajlove.
