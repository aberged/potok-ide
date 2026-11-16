<!--
Tekst stranice /pomoc. Srpska latinica je referenca: posle izmene pokreni
`mix potok.sr_cyrl` (piše ćirilicu), a engleski u HELP.en.md prati ovaj tekst.

Pravila (PotokIdeWeb.HelpMarkdown):
- Tekst počinje naslovom (# ...) i jednim pasusom ispod njega.
- Naslov odeljka ima oznaku, istu u svim jezicima: ## Poruke {:#poruke}
  Link na odeljak: [poruke](#poruke).
- Slika se navodi imenom, u pasusu za sebe: ![Šta slika pokazuje](poruke)
  Više slika u istom pasusu stoji jedna pored druge. Slike pravi help_shots/.
-->

# Kako se koristi Potok

Sve što ti treba da počneš: kako Potok radi, kako u njemu da organizuješ svoju zajednicu i gde je šta u aplikaciji. Slike su iz izmišljenog kraja Topolik i njegovih komšija.

## Prvi koraci {:#prvi-koraci}

### Ulazak u Potok {:#ulazak}

Za sada se u Potok ulazi uz pozivnicu. Neko ko je već tu upiše tvoj imejl, a tebi stigne poruka sa linkom koji važi sedam dana. Kad ga otvoriš, nalog je tvoj: postavi lozinku u podešavanjima ili se svaki put prijavljuj magičnim linkom koji ti stiže na imejl i važi petnaest minuta.

Na stranici za prijavu upišeš imejl i lozinku. Ako uključiš „Ostavi me prijavljenim na ovom uređaju“, Potok te pamti dve nedelje.

![Prijava lozinkom; ispod je link za prijavu magičnim linkom](prijava)

### Na telefonu i na računaru {:#telefon}

Potok radi u pregledaču, na računaru i na telefonu, a postoji i aplikacija za telefon. Možeš ga instalirati i pravo iz pregledača, pa se otvara kao aplikacija. Svuda je isti nalog sa istim grupama i porukama.

### Snalaženje {:#snalazenje}

Gornja traka je uvek ista. Kućica vodi na početnu stranu i broji nepročitane poruke. Zvono vodi na obaveštenja grupa koje pratiš, # na tagove, a dve ikone desno od njega na pozivnice i zahteve za pristup. Tvoja slika vodi na profile.

Dugme sa tri crte otvara meni: svi delovi aplikacije, podešavanja naloga, jezik (latinica, ćirilica ili engleski), svetla ili tamna tema, ova pomoć i koliko Potok košta. Na širokom ekranu meni stoji levo i ne treba ga otvarati. Dve strelice na njegovom vrhu ga sklanjaju kad ti treba više mesta, a tri crte ga vraćaju.

![Početna strana: grupe, sa brojem nepročitanih poruka i poslednjom porukom](pocetna) ![Meni sa svim delovima aplikacije](meni)

## Kako Potok funkcioniše {:#kako-radi}

Potok je napravljen od nekoliko jednostavnih delova koji se slažu jedan u drugi. Kad ih upoznaš, svaka zajednica se u njemu može složiti onako kako zaista radi.

### Nalog i profili {:#nalog-i-profili}

Nalog si ti: imejl i lozinka kojima se prijavljuješ. U grupama te drugi vide kao profil, sa imenom i slikom. Jedan nalog može imati više profila, na primer lični i profil udruženja, i biraš kojim se trenutno služiš.

Profil je jedinstven ili deljen. Deljeni profil koristi više naloga zajedno, pa kućni savet ili porodica govore jednim glasom, a svako se prijavljuje svojim nalogom.

### Grupe u stablu {:#grupe}

Sve se dešava u grupama, a svaka grupa može imati svoje podgrupe, koliko god duboko treba. Na vrhu je početna strana, a ispod nje grupe u kojima jesi. Mesna zajednica tako ima grupu za obaveštenja, grupu za zbor i mapu kraja, a mapa ima po jednu grupu za svaki problem u kraju.

Razgovor u četiri oka je takođe grupa, sa samo dva člana. Nit, duži razgovor otvoren iz jedne poruke, je grupa ispod one u kojoj je poruka napisana.

Grupa iz dubine stabla može da stoji i na još jednom mestu, kao prečica: među podgrupama druge grupe ili na samoj početnoj strani. Dodir na prečicu otvara grupu tamo gde stoji, kao prečica na računaru.

![Podgrupe kao fascikle: Mapa kraja otvorena, sa grupom za svaki problem](podgrupe-folderi)

### Šta se deli u grupi {:#sadrzaj}

U grupi se pišu poruke, šalju fajlovi, zakazuju događaji i pokreću glasanja, a grupa može imati i opis: tekst, stranicu ili malu aplikaciju. Sve to ostaje u grupi i vide ga oni koji grupu smeju da vide.

### Članstvo i nasleđivanje {:#clanstvo}

U grupu se ulazi na poziv ili zahtevom koji neko odobri. Podgrupa može da nasleđuje članove: ko je član grupe iznad, član je i nje, sa istim ulogama. Tako zbor i mapa kraja odmah imaju sve članove mesne zajednice, a ko više nije član mesne zajednice, nije ni njihov.

### Uloge i dozvole {:#uloge-i-dozvole}

Šta ko sme da radi u grupi određuju uloge. Svaka grupa ima ulogu Administrator, koja sme sve, i ulogu Svi, koju ima svaki član. Možeš dodati i svoje uloge, recimo savet ili moderatori. Za svaku od 20 dozvola uloga kaže „Dozvoli“, „Zabrani“ ili „Nije podešeno“, a zabrana je jača od dozvole.

Podgrupa preuzima uloge od grupe iznad. Ako joj trebaju drugačije, dobija sopstveni manifest, svoj spisak uloga i dozvola.

### Javno, privatno i otvoreno {:#vidljivost}

Privatnu grupu vide samo njeni članovi. Javnu grupu vidi svako ko je prijavljen i može da zatraži pristup, a njen naziv, slika i kratak deo opisa vide se i van Potoka, svakome ko ima link.

Javna grupa može da otvori i ceo opis onima bez naloga: Uredi grupu, Pristup, „Opis vidljiv i bez prijave“. Ko otvori njen link tada čita opis, i alternativne opise označene „Vidljiv i bez prijave“, a aplikacija u opisu, kao Feed ili Mapa, za njega samo čita: pokazuje javne grupe ispod sebe, ali ne piše, ne glasa i ne reaguje. Razgovor, članovi i ko je reagovao ostaju iza prijave, a pretraživači tu stranu ne prikazuju.

![Javna grupa kako je vidi neko bez naloga](gost-opis)

Javna grupa može da otvori i razgovor: tada svako ko je prijavljen čita poruke i piše, i bez učlanjenja. Takav posetilac ne šalje fajlove i ne otvara niti.

### Praćenje i obaveštenja {:#pracenje-i-obavestenja}

Grupu koju vidiš možeš da pratiš i kad nisi njen član. Tada ti stižu njena obaveštenja: kratke vesti koje grupa šalje svojim pratiocima, odvojeno od poruka i sa svojim brojačem. Na telefon ti stižu i obaveštenja o porukama, pominjanjima, događajima i glasanjima, ako ih uključiš.

### Aplikacije u grupi {:#aplikacije-ukratko}

Opis grupe ne mora biti samo tekst. Može biti mala aplikacija, recimo forma, vest ili mapa, koja svoje podatke čuva u samoj grupi i poštuje njene dozvole. Nekoliko takvih aplikacija dobijaš gotovo kad praviš grupu.

## Primeri organizacije {:#primeri}

Tri zajednice, svaka složena kao stablo grupa. Ne moraš da kopiraš nijednu: uzmi ono što ti odgovara i promeni kad zajednica poraste. Grupe se uvek mogu preurediti, a uloge dopuniti. Za svaku postoji i posebna stranica, koja korak po korak pokazuje kako se složi.

### Zbor mesne zajednice {:#primer-mz}

Mesna zajednica Topolik je javna grupa sa svojim područjem na mapi, pa je vidi i ko još nije član.

- **MZ Topolik**, fascikla, javna, sa područjem na mapi
  - **Zbor građana**: razgovor, glasanja i događaj zbora u kalendaru
  - **Mapa kraja**: mapa na kojoj je svaki problem grupa sa svojim pinom i razgovorom
  - **Molbe**: forma kroz koju komšije pišu savetu; svaka molba dobija svoju podgrupu, a savet odlučuje u formi

Grupa ima sopstveni manifest i ulogu savet, koja sme da šalje obaveštenja pratiocima, objavljuje događaje i upravlja glasanjima. Zbor i mapa nasleđuju članove, pa ih niko ne poziva posebno.

Jedna nedelja izgleda ovako: komšinica stavi rupu u ulici na mapu, sa slikom. U zboru se o tome razgovara, a duža rasprava ode u nit. Pre zbora savet pokrene glasanje sa kvorumom i zakaže zbor kao javni događaj u Domu kulture. Ko prati MZ, dobije obaveštenje i na telefon.

[Korak po korak: kako da složiš mesnu zajednicu](/pomoc/mesna-zajednica)

![MZ Topolik: zbor i mapa kraja](primer-mz) ![Mapa kraja: problemi kao pinovi i staza uz kanal](primer-mz-mapa)

### Zadruga i zajednička nabavka {:#primer-zadruga}

- **Zadruga Livada**, fascikla, privatna, sa mestom preuzimanja na mapi
  - **Porudžbine**: forma koju svaki član popuni jednom i menja do roka
  - **Dogovor**: razgovor o preuzimanju i zamenama

Šta ima ove nedelje i do kada se poručuje, zadruga javlja obaveštenjem svima koji je prate. Preuzimanje je događaj koji se ponavlja svake subote, sa podsetnikom. Organizator u formi vidi sve porudžbine i njihov rezime, a preuzima ih kao tabelu. Posebna aplikacija u opisu grupe može voditi i ture nabavke, vozača i podelu troškova.

[Korak po korak: kako da složiš zadrugu](/pomoc/zadruga)

![Zadruga Livada: porudžbine i dogovor](primer-zadruga)

### Stambena zgrada ili klub {:#primer-zgrada}

Za malu zajednicu dovoljna je jedna grupa za razgovor.

- **Zgrada Cvetna 12**, razgovor, privatna
  - **Kućni savet**: razgovor samo za savet

U razgovoru stoje zapisnici i pravila kućnog reda (svi su i u kartici Fajlovi), glasanje o boji ulaza i događaj za čišćenje podruma. Kućni savet odgovara deljenim profilom, pa stanari znaju ko piše u ime saveta. Klub, hor ili ekipa za rekreaciju slažu se isto.

[Korak po korak: kako da složiš zgradu ili klub](/pomoc/zgrada)

![Zgrada Cvetna 12: zapisnik, glasanje i događaj u istom razgovoru](primer-zgrada)

## Profili {:#profili}

Na stranici Profili vidiš trenutni i podrazumevani profil i spisak svih svojih profila. Dodirom na profil u spisku menjaš onaj kojim se služiš, a „Kreiraj profil“ pravi novi.

Korisničko ime ima od 2 do 16 slova, brojeva i znakova `_`, `.` i `-`. Slika profila se smanjuje na 200 × 200, a fajlovi veći od 5 MB se odbijaju. Profil ima i opis i javne tagove.

Deljeni profil deliš sa drugim profilom: u delu Deljenje upišeš njegovo korisničko ime. Poziv se vidi na stranici Profili dok je pozvani profil trenutni, a kad ga prihvati, oba naloga koriste deljeni profil.

![Profili: trenutni, podrazumevani i deljeni profil savet-cvetna](profili) ![Uređivanje profila: ime, slika, opis, deljenje i tagovi](profil-uredi)

## Početna i pronalaženje grupa {:#pocetna}

Početna strana ima dve kartice: Razgovori, sa razgovorima u četiri oka, i Grupe. Svaka grupa pokazuje broj nepročitanih poruka, poslednju poruku, broj članova i podgrupa i svoje tagove. Katanac znači da je grupa privatna, a globus da je javna.

Iznad spiska su filteri: javne grupe u kojima nisi član, niti, grupe u kojima si član, koje si napravio ili koje pratiš, vrsta grupe i pretraga po nazivu. Grupe koje pratiš ostaju na spisku i kad sakriješ javne grupe. Pretraga nalazi grupu i kad kucaš bez kvačica, latinicom ili ćirilicom. Grupe se mogu prikazati kao spisak ili kao fascikle.

Na početnoj su i Moj kalendar, sa događajima svih tvojih grupa, Mapa grupa i Moja glasanja.

![Filter po vrsti grupe](pocetna-filteri)

## Stranica grupe {:#grupa}

Na vrhu grupe su njen naziv, putanja do nje i kartice: Poruke, Fajlovi, Kalendar, Glasanja, Obaveštenja, Podgrupe i Članovi. Glasanja se pojave sa prvim glasanjem, a kad za sve nema mesta, Obaveštenja su u meniju grupe. Desno su zvono za praćenje, pretraga poruka i meni grupe.

![Zaglavlje grupe sa karticama](grupa-zaglavlje)

Meni grupe ima opis grupe, deljenje linka javne grupe, tagove, obaveštenja, uloge, pravljenje podgrupe, pozivanje i uređivanje grupe. Šta od toga vidiš, zavisi od tvojih dozvola.

Opis grupe može biti tekst, stranica iz šablona ili aplikacija. Ispod njega su reakcije na grupu i mesto grupe na mapi.

![Meni grupe](grupa-meni) ![Opis grupe, reakcije i područje na mapi](o-grupi)

## Poruke {:#poruke}

Poruku pišeš u polje na dnu i šalješ strelicom. Na telefonu, dok kucaš, gornje trake se sklanjaju, da bi se videlo što više poruka.

![Razgovor: odgovor sa citatom, nit, reakcije i privatni tag](poruke)

- **Odgovor**: poruka sa citatom onoga na šta odgovaraš. Dodirom na citat skačeš na originalnu poruku.
- **Nit**: duži razgovor o jednoj poruci, da ne zatrpava glavni razgovor. Ispod poruke stoji koliko ima nepročitanih poruka u niti.
- **Reakcije**: jedan emoji na poruku. Dodirom na reakciju dodaješ ili skidaš svoju.
- **Pominjanje**: napiši @ i ime člana ili uloge, a @everyone pominje sve. Pomenutom se poruka istakne i stiže mu obaveštenje.
- **Izmena i brisanje**: svoje poruke možeš da izmeniš i obrišeš, a ko ima dozvolu, briše i tuđe.
- **Linkovi** dobijaju pregled, a dugačke poruke se skupljaju dok ih ne otvoriš.

Na telefonu dugo pritisni poruku: otvara se list sa brzim reakcijama i svim radnjama. Na računaru se iste radnje pojavljuju kad pređeš mišem preko poruke.

![Dugi pritisak na poruku](poruka-meni) ![Odgovor: citat je iznad polja za pisanje](poruke-odgovor) ![Nit otvorena iz poruke](nit)

Dugme + pored polja dodaje fajlove ili pokreće glasanje. Jedna poruka nosi do 10 fajlova, do 100 MB svaki. Slike, video i zvuk otvaraju se pravo u razgovoru, a fajlove možeš i da prevučeš u prozor. U aplikaciji za Android GIF ili nalepnicu šalješ pravo sa tastature.

Kad se vratiš u razgovor, linija pokazuje odakle počinju nepročitane poruke. Lupa u zaglavlju pretražuje poruke grupe, i u nitima, i kad kucaš bez kvačica, latinicom ili ćirilicom.

![Fajlovi i glasanje ispod dugmeta +](prilozi) ![Pretraga poruka](pretraga-poruka) ![Linija pokazuje gde počinju nepročitane poruke](neprocitano)

## Nove grupe i podešavanja {:#nove-grupe}

Podgrupu praviš dugmetom + na kartici Podgrupe ili iz menija grupe. Prvo biraš kakva grupa ti treba:

- **Chat**: otvara se na porukama, a pisati mogu svi članovi.
- **Folder**: drži podgrupe na okupu.
- **Feed**: vesti koje se listaju prevlačenjem, sa delom u kome ih urednici pišu.
- **Glasanja**: sva glasanja grupe na jednom mestu.
- **Forma**: pitanja, odgovori i njihov rezime.
- **Mapa**: podgrupe kao pinovi na mapi. Ne nudi se na početnoj strani, nego unutar grupe.
- **Stranica**: tekst koji se prvi vidi, napravljen iz šablona.

U drugom koraku upišeš naziv i biraš da li je grupa javna i da li nasleđuje članove. „Podesi sve ručno“ otvara pun obrazac.

![Kakva grupa ti treba?](kreiraj-podgrupu) ![Naziv, javnost i nasleđivanje članova](kreiraj-korak)

### Prečice {:#precice}

Na dnu istog izbora je **Prečica**. Ona ne pravi novu grupu, nego ovde stavlja grupu koja stoji negde drugde, recimo zbor građana iz mesne zajednice na početnu stranu. Bez pretrage nudi grupe u kojima si član, a pretraga po nazivu nalazi svaku grupu koju vidiš. Dodir na grupu postavlja prečicu.

Prečica ima strelicu i natpis Prečica, a pokazuje samu grupu: njenu poslednju poruku i nepročitane poruke. Brojači iznad nje ih ne broje dvaput. Prečicu vide svi koji vide i grupu u kojoj stoji i originalnu grupu, pa privatna grupa ostaje skrivena od onih koji u njoj nisu. Ukloniti je mogu onaj ko ju je postavio i admin grupe u kojoj stoji, iz menija reda, a originalna grupa ostaje kakva je.

![Prečica na početnoj strani vodi do zbora u mesnoj zajednici](precica) ![Prečica: grupe u kojima si član, i pretraga po nazivu](precica-izbor)

Uredi grupu ima sve ostalo: naziv i sliku, pristup i članstvo (javna grupa, opis vidljiv i bez prijave, razgovor otvoren nečlanovima, nasleđivanje), šta se otvara prvo, opis, alternativne opise, lokaciju i opasnu zonu za brisanje. Za javnu grupu tu vidiš i kako link ka njoj izgleda kad se podeli van Potoka.

![Uredi grupu: pristup i članstvo, sa izgledom linka van Potoka](uredi-grupu)

## Članovi i uloge {:#clanovi}

Kartica Članovi pokazuje sve članove, njihove uloge i ko je na mreži. Odatle se odobravaju zahtevi za pristup, dodeljuju uloge, uklanjaju i blokiraju članovi. Nasleđeni članovi su označeni, a dodirom na člana otvaraš razgovor u četiri oka.

Pozvati možeš profil po korisničkom imenu ili nekoga po imejlu: ako još nema nalog, dobija pozivnicu za Potok.

![Članovi i zahtevi za pristup](clanovi) ![Pozivanje u grupu](pozovi)

U Ulogama vidiš da li grupa ima sopstveni manifest ili ga nasleđuje, dodaješ svoje uloge i za svaku dozvolu biraš „Dozvoli“, „Nije podešeno“ ili „Zabrani“. Uloga Svi može samo da dozvoli.

![Uloge i njihove dozvole](uloge)

Aplikacija u grupi može da ima i procese, koji u grupi rade umesto ljudi. Oni su na dnu kartice Članovi, u odeljku Procesi, pod imenom koje im daje aplikacija, sa svojim ulogama, i ne broje se među članove. U porukama ih prepoznaješ po oznaci Proces, uz ime onoga ko je proces pokrenuo, a u podgrupi koju je proces napravio njegovo ime vodi na aplikaciju. Ko uređuje aplikaciju, tu vidi koja prava procesu fale, a administrator mu ih daje ulogom.

Kako procesima ide, vidiš na kartici Procesi, u meniju grupe: uz svaki proces piše koliko njegovih pokretanja radi, čeka, završeno je ili je palo. Urednik aplikacije vidi i gde je i zašto pokretanje palo, i odatle ga pokreće ponovo ili otkazuje. Na dnu kartice vidi i polja grupe koja procesi čuvaju, ko ih je poslednji upisao i kada, i može da ih obriše. Ispod njih su entiteti, kojima urednik opisuje podatke procesa: entitet ima ime i atribute, a svaki atribut tip, i to tekst, broj, da ili ne, datum, datum i vreme, izbor iz liste ili drugi entitet grupe. Atribut može da bude i lista, i može da bude obavezan.

Na vrhu kartice, pod Čeka tebe, stoje odluke koje čekaju neku od tvojih uloga, iz procesa nacrtanih u Potoku: vidiš ko je poslao vrednost i kada, a i podgrupu koju je proces za nju otvorio. Izabereš ishod i, ako želiš, dodaš komentar.

![Kartica Procesi: odluke koje čekaju i procesi grupe](procesi)

### Sve dozvole {:#dozvole}

Grupa ima 20 dozvola. Uloga Svi na početku ima one označene u poslednjoj koloni.

| Dozvola | Šta dozvoljava | Svi |
|---|---|---|
| Pisanje poruka | Poruke i odgovori; u otvorenom razgovoru i posetioci | da |
| Kačenje fajlova | Fajlovi u porukama | da |
| Reakcije | Emoji na porukama i na grupi | da |
| Otvaranje niti | Nit iz poruke | da |
| Kreiranje podgrupa | Nove grupe unutar ove | da |
| Pozivanje članova | Pozivi profilima i imejlom | da |
| Pominjanje uloga | Pominjanje uloga i @everyone | da |
| Upravljanje zahtevima za pristup | Prihvatanje i odbijanje zahteva | |
| Uklanjanje članova | Uklanjanje članova; u otvorenom razgovoru i blokiranje | |
| Brisanje poruka | Brisanje tuđih poruka | |
| Dodavanje događaja | Novi događaji u kalendaru | da |
| Upravljanje događajima | Izmena i otkazivanje tuđih događaja | |
| Objavljivanje događaja | Javni događaji | |
| Pokretanje glasanja | Nova glasanja | da |
| Glasanje | Glasanje, gde pravila glasanja dozvoljavaju | da |
| Upravljanje glasanjima | Završavanje, izmena i brisanje tuđih glasanja; rezultati uvek | |
| Otvaranje glasanja nečlanovima | Javna glasanja | |
| Slanje obaveštenja | Obaveštenja pratiocima | |
| Upravljanje tagovima | Javni tagovi na porukama, fajlovima, događajima i grupi | |
| Uređivanje grupe | Podešavanja, opis i podaci aplikacije | |

## Kalendar {:#kalendar}

Kalendar grupe pokazuje mesec ili spisak događaja, a može da uključi i podgrupe. Moj kalendar na početnoj strani skuplja događaje svih tvojih grupa, a ako hoćeš, i javne događaje.

Događaj može biti jednokratan, celodnevni ili da se ponavlja svaki dan, nedelju, mesec ili godinu. Mesto mu daješ rečima, kao grupu koja stoji na mapi, ili ga crtaš na mapi kao tačku, područje ili rutu. Uz događaj idu podsetnici za članove, najava u razgovoru i obaveštenje ako se promeni vreme ili mesto.

Na događaj odgovaraš sa Dolazim, Možda ili Ne dolazim i vidiš ko dolazi. „Dodaj u moj kalendar“ ga prenosi u Google, Apple ili Outlook kalendar. Javni događaj se vidi i van grupe.

![Moj kalendar](kalendar) ![Događaj: vreme, mesto, ko dolazi i podsetnici](dogadjaj) ![Novi događaj](dogadjaj-forma)

## Glasanja {:#glasanja}

Glasanje pokrećeš iz razgovora (dugme +, pa Novo glasanje) ili na kartici Glasanja. Upišeš pitanje i odgovore, ili izabereš gotove „Da / Ne“ i „Za / Protiv / Uzdržan“, i rok.

Pod „Više podešavanja“ su:

- jedan ili više odgovora, i koliko najviše;
- tajno glasanje, promena glasa i odgovori koje dodaju članovi;
- javno glasanje, u kome glasaju i nečlanovi;
- ko glasa, ko vidi rezultate i ko vidi ko je za šta glasao;
- pravilo odluke (najviše glasova, više od polovine glasova, dve trećine glasova ili više od polovine onih koji imaju pravo glasa) i kvorum.

![Novo glasanje](glasanje-forma) ![Glasanje u razgovoru, posle glasanja](glasanje-kartica)

Glasa se pravo iz razgovora. Kartica Glasanja pokazuje otvorena, ona koja čekaju tvoj glas i završena, a u detaljima su odziv, ko je za šta glasao (ako to sme da se vidi), ko nije glasao i rezultati za preuzimanje.

U tajnom glasanju niko, ni administrator ni aplikacija, ne vidi ko je za šta glasao. Brojevi se ne vide pre kraja, a završeno tajno glasanje se ne može ponovo otvoriti.

![Detalji glasanja: odziv i ko je za šta glasao](glasanje-detalji)

## Mapa i mesta {:#mapa}

Mapa grupa na početnoj strani pokazuje svaku grupu sa mestom koju smeš da vidiš. Bliske grupe se skupljaju u krug sa brojem. Sužavaš je istim filterima kao spisak, i još vremenom i pinom, a slojevi uključuju i isključuju mesta, područja i rute. Dodir na pin otvara karticu grupe.

![Mapa grupa, sa područjem mesne zajednice](mapa-grupa) ![Kartica grupe na mapi](mapa-kartica)

Mesto grupi daješ u Uredi grupu, pod Lokacija:

- **Tačka**: dodir na mapu, ili tvoja lokacija.
- **Područje**: granica koju crtaš temenima, kao mesna zajednica, ili koju doneseš iz GeoJSON fajla. Mapa onda pokazuje šta je u području. Kad se u području vide i granice manjih područja, kao mesnih zajednica u opštini, njegova granica dobija širok providan pojas, da se vidi i tamo gde se poklapa sa njihovim.
- **Ruta**: šetnja, trka ili biciklistička staza, nacrtana ili donesena iz GPX, KML ili GeoJSON fajla. Mapa pokazuje i kroz koja područja prolazi.

Za pin biraš jednu od 33 ikone ili sliku grupe, a u uglu pina stoji vrsta grupe. Grupa sa mapom (Mapa) pokazuje svoje podgrupe kao pinove, a „Dodaj mesto“ pravi novu.

![Lokacija: područje mesne zajednice](lokacija-podrucje)

## Fajlovi i tagovi {:#fajlovi-i-tagovi}

Kartica Fajlovi skuplja sve fajlove iz poruka grupe, kao spisak ili po fasciklama podgrupa, a sa svakog fajla se ide na poruku u kojoj je poslat. Fajlove preuzimaju samo članovi, osim slika u opisu grupe i fajlova iz otvorenog razgovora.

Tag stavljaš na grupe, profile, događaje, poruke i fajlove, dugmetom #. Javni tag vide svi koji vide i stvar na kojoj je, a privatni, sa katancem, samo ti. Jedna stvar nosi do 10 javnih i 10 privatnih tagova. Na stranici Tagovi biraš jedan ili više tagova i vidiš sve što ih nosi.

![Fajlovi grupe](fajlovi) ![Tagovi: privatni i javni](tagovi)

## Praćenje, obaveštenja i push {:#obavestenja}

Zvono u zaglavlju grupe je praćenje. Jedan dodir i pratiš grupu. Posle toga zvono otvara izbor: push obaveštenja za ovu grupu, kartica Obaveštenja i prestanak praćenja. Početna strana, razgovori u četiri oka i niti se ne prate.

Ko ima dozvolu, na kartici Obaveštenja šalje obaveštenje svim pratiocima, do 2000 znakova. Link u obaveštenju dobija pregled kao u razgovoru, a ko sme da obriše obaveštenje, može da ukloni i pregled. Stranica Obaveštenja (zvono u gornjoj traci) ima primljena obaveštenja i spisak grupa koje pratiš. Na početnoj strani i na mapi grupa filter „Grupe koje pratim“ ostavlja samo njih.

![Praćenje grupe](pracenje) ![Primljena obaveštenja](obavestenja)

Push obaveštenja uključuješ u Podešavanjima naloga, posebno za svaki pregledač ili telefon. Stižu za nove poruke, pominjanja, odgovore i reakcije, pozive i odobrene zahteve, događaje i podsetnike, glasanja i odgovore na forme. Tu je i poseban prekidač za obaveštenja grupa koje pratiš.

![Podešavanja: push obaveštenja](podesavanja-push)

## Aplikacije u grupi {:#aplikacije}

Neke vrste grupa dobijaju gotovu aplikaciju:

- **Feed** je niz vesti koje se listaju prevlačenjem, sa reakcijama i komentarima. Urednici ih pišu u podgrupi `.feed`, iz šablona, čuvaju kao nacrt i objavljuju. Da bi vesti čitali i oni bez naloga, uključi „Opis vidljiv i bez prijave“ i u Feedu i u `.feed`: nova vest taj izbor preuzima od `.feed`.
- **Forma** ima pitanja raznih vrsta, pravila (ko popunjava, jednom ili više puta, do kog roka, anonimno), rezime odgovora, kviz i prilaganje fajlova. U podešavanjima, „Kad stigne odgovor“, uključuješ proces za svaki odgovor: najavu u razgovoru, podgrupu za odgovor i odluku jedne uloge, sa podsetnikom. Ko ima tu ulogu, odlučuje pravo u pregledu odgovora. Za proces sa više koraka, [nacrtaj ga](#nacrtaj-proces) u Potoku.
- **Glasanja** pokazuju sva glasanja grupe na jednom mestu.
- **Mapa** pokazuje podgrupe kao pinove, područja i rute.

![Feed: vest iz kraja](feed) ![Forma za porudžbine, kako je vidi član](forma)

Opis bilo koje grupe možeš da napišeš iz šablona: vest, slika, citat, događaj, lista, link, obaveštenje, pitanje ili slobodan tekst. Grupa može imati i do 20 alternativnih opisa, a svaki od njih sme da vidi samo određene uloge, ili i posetioci bez naloga, kad grupa za njih otvori opis.

Ko piše HTML, može od opisa da napravi svoju aplikaciju (Uredi grupu, Opis, „Opis je aplikacija (API)“). Takva aplikacija može da vodi i proces: kad stigne odgovor, objavi ga u razgovoru, otvori podgrupu za njega i čeka da neko sa ulogom odluči, a podseti ga kad kasni. Šta aplikacija sme, a šta ne, opisano je u [mapi domena](/domain#domain-apps).

![Šabloni za opis grupe](opis-sablon)

### Nacrtaj proces {:#nacrtaj-proces}

Proces možeš da nacrtaš i bez pisanja koda, pravo u Potoku, i u grupi bez aplikacije. To sme ko sme da uređuje grupu.

1. U meniju grupe otvori **Procesi**, dodirni **Nacrtaj proces** i upiši ime procesa.
2. Pod **Kad** izaberi šta ga pokreće, a na početnom koraku crteža ga podesi.
3. Dodirni **+** na strelici i izaberi korak: poruku, podgrupu, odluku, push, čekanje, uslov, polje grupe, poziv drugog procesa, signal ili čekanje signala. Dodirom na korak ili strelicu menjaš ih: tekst, ulogu koja odlučuje, ishode, rok, kuda strelica vodi.
4. Dodirni **Sačuvaj**, pa **Uključi**.

Proces može da pokrene:

- **nova vrednost u aplikaciji**, recimo odgovor na formu;
- **poruka** u razgovoru grupe sa nekom od reči koje upišeš, recimo „kvar“, ili koja pominje ulogu. Odgovori u niti i poruke procesa se ne računaju;
- **nova podgrupa**, recimo mesto dodato na mapi, a po želji samo ona sa mestom. Zapisi i niti se ne računaju;
- **zadato vreme**: svakog dana, svake nedelje u izabrane dane ili svakog meseca, u satu koji izabereš;
- **neko ručno**: oni kojima to dozvoliš dobijaju na kartici Procesi dugme **Pokreni**, uz naslov i tekst;
- **drugi proces** grupe, korakom **Pozovi proces**: na početnom koraku, pod **Polja koja prima**, upišeš šta mu pozivalac predaje;
- **signal** koji pošalje neki proces grupe, sa poljima koja signal nosi.

Tekst koraka može da ubaci ono što proces ima, u duplim vitičastim zagradama: `{{start.title}}` je naslov ručnog pokretanja, gde je `start` početni korak. Imena se nude ispod polja za tekst. Na širokom ekranu korake prevlačiš gde ti odgovaraju, a strelicu crtaš od tačke ispod koraka do drugog koraka. Crtež koji instanca ne bi mogla da završi ne može da se sačuva, a traka iznad crteža kaže šta fali. Aplikacija nacrtan proces ne vidi i ne menja, a njen sopstveni proces, ako ga ima, radi pored njega. Izmena važi za pokretanja posle nje. Kako to izgleda, pokazuju tutorijali za [zadrugu](/pomoc/zadruga#proces) i [zgradu](/pomoc/zgrada#kvar).

U tim zagradama može da stoji i izraz: `{{group.kvarova + 1}}` računa, `{{upper(start.title)}}` piše velikim slovima, a `{{if(group.kvarova > 10, "mnogo", "malo")}}` bira jedan od dva teksta. Uslov je jedan izraz koji je tačan ili netačan, recimo `group.kvarova > 10 and start.title != ""`: porediš sa `=`, `!=`, `<`, `>`, `<=` i `>=`, spajaš sa `and`, `or` i `not`, tekst pišeš pod navodnicima, a broj sa tačkom. Funkcije su `if`, `empty`, `length`, `contains`, `first`, `last`, `sum`, `join`, `text`, `number`, `round`, `today`, `now`, `lower`, `upper`, `trim` i `add_days`. Potok izraze proverava dok crtaš: ako imena nema ili sabiraš tekst, traka iznad crteža kaže šta ne valja. Crtež napravljen ranije Potok sam prevede na ovaj zapis kad ga otvoriš, pa ga samo pregledaj i sačuvaj.

Ishod odluke koraci posle nje čitaju kao `{{odluka.outcome}}`, a ko je odlučio kao `{{odluka.by}}`, gde je `odluka` ime koraka sa crteža; i to se nudi ispod polja za tekst. Tako i korak **Pozovi proces** pokreće drugi nacrtani proces grupe i predaje mu polja. Ako ostaviš **Čekaj da se završi**, proces čeka dok pozvani ne stigne do kraja, a ime tog kraja na crtežu koraci posle poziva čitaju kao `{{poziv.outcome}}`, pa po njemu može da grana uslov. Rok kaže koliko najviše čeka: kad prođe, odustaje i otkazuje pozvani proces. Ono što proces napiše ne pokreće druge procese, pa razgovaraju samo kad ih tako nacrtaš. Procesi se pozivaju najviše tri nivoa duboko, a proces koji drugi poziva ne može da se obriše. Kako to izgleda, pokazuje [zgrada](/pomoc/zgrada#majstor).

Korak **Polje grupe** čuva vrednost koju čita svaki proces grupe: pod **Šta radi** biraš da li polje postavlja na vrednost, recimo poslednji prijavljen kvar, ili mu dodaje broj, kao brojaču. Polje `kvarova` drugi koraci, i u drugim procesima, čitaju kao `{{group.kvarova}}`, a uslov može da grana po njemu, recimo kad pređe 10. [Zgrada](/pomoc/zgrada#brojac) broji kvarove.

Korak **Pošalji signal** javlja svim procesima grupe da se nešto desilo, recimo da je subota, uz polja koja upišeš. Proces koji je baš tada na koraku **Čekaj signal** sa istim imenom ide dalje, a ko je poslao signal i šta nosi čita kao `{{prijem.from}}` i `{{prijem.mesto}}`. Signal pokreće i procese kojima je okidač taj signal. Signal se ne čuva: proces koji tek posle stigne do čekanja, čeka sledeći. Uz **Samo od procesa na istoj vrednosti ili podgrupi** čekanje prima samo signal poslat o istom predmetu, recimo uplatu za baš tu porudžbinu. [Zadruga](/pomoc/zadruga#subota) tako javlja kupcima da je dan preuzimanja.

### Deljenje u Potok {:#deljenje}

Tekst, link ili fajl iz druge aplikacije na telefonu podeliš u Potok. Izabereš grupu ili razgovor, a deljeno te čeka u polju za pisanje. Isto radi i Potok instaliran iz pregledača.

Link ka javnoj grupi ili javnom događaju deliš iz menija grupe ili iz događaja. Van Potoka se vide naziv, slika i kratak deo opisa, a ceo opis kad ga grupa otvori i za posetioce bez naloga. Kad podeliš vest iz Feed-a ili nešto drugo iz aplikacije, kartica pokazuje baš to, a ime i slika aplikacije stoje u uglu. Isto važi i za adresu strane, koja prati vest na ekranu.
