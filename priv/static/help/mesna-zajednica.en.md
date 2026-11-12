<!--
The tutorial for the help page's example "A local community's assembly"
(#primer-mz). It follows mesna-zajednica.sr.md, which is the reference.
-->

# How to put together a local community

Step by step, from an empty home page to a local community with its council, its assembly and a map of the neighbourhood, like MZ Topolik in the example. All you need is an account: whoever creates a group is its administrator and may do everything written here.

## What we build {:#sta-pravimo}

- **MZ Topolik**, a folder, public, with an area on the map and the role council
  - **Council notices**: the council writes, the others read and react
  - **Citizens' assembly**: a chat, polls and the assembly's event
  - **Neighbourhood map**: each problem in the neighbourhood is a group with its own pin

The order matters in one place: create the role council before the sub-groups. The council's notices get their own list of roles when they are created, as a copy of the list of the group above, so the council must already be on it.

![MZ Topolik, finished: council notices, the assembly and the neighbourhood map](primer-mz)

## 1. The community's group {:#grupa}

1. On the home page, tap the **+** button at the bottom right (Create sub-group).
2. To "What kind of group do you need?", answer **Folder**: it keeps sub-groups together.
3. Type the name "MZ Topolik" and turn on **Public group**, so the neighbours find it and ask to join. The name, picture and a short part of the description of a public group can be seen outside Potok too, by anyone with the link.
4. Tap **Create**. The new group opens, on its empty Sub-groups tab.

![A folder on the home page: its name and public group](mz-nova-grupa)

## 2. The area on the map {:#podrucje}

1. In the group's header, open the menu (⋯), choose **Edit group**, then the **Location** card.
2. Choose **Area** and tap the map along the community's border: each tap is a vertex. You move a vertex by dragging it and add a new one by tapping the dot between two vertices. If you have the border as a file, choose **GeoJSON file**.
3. Under **Pin on the map**, choose **Local community**.
4. Tap **Save changes** on the bar at the bottom.

The group map now shows MZ Topolik with its border and everything within the area. In the same menu, on the **Description** card, write what the group is for: **Change template** offers ready-made shapes. For neighbours without an account to read the description too, turn on **Description open to guests** on the **Access** card and save.

![An area drawn with vertices](lokacija-podrucje)

## 3. The role council {:#savet}

1. In the group's menu, choose **Roles**. A new group uses the default roles, so tap **Create own manifest**.
2. Type "savet" (council) in the field for a new role, without spaces, and tap **Add role**.
3. For the role, choose **Allow** for Send notices, Publish events, Manage events, Manage polls and Delete messages. Each choice is saved at once. On a phone the choices are icons: ✓ is "Allow", – is "Not set" and ⊘ is "Deny".

The council has the other permissions like every member, through the role Everyone, so you leave them alone here.

![The roles of MZ Topolik: Admin, Everyone and the council](uloge)

## 4. Neighbours and the council {:#clanovi}

1. In the group's menu, choose **Invite profile**. Type a neighbour's username, or their email if they have no account yet: then they get an invitation to Potok. Tap **Invite**.
2. A public group also takes access requests. The number on the **Members** tab says how many are waiting, and in the Access requests part you tap **Accept**.
3. On the **Members** tab, tap the shield next to a council member and turn on the council's role. Do the same for every council member.

![Inviting by username or email](pozovi) ![The shield next to a member: the council's role is on](mz-uloga-clana)

## 5. Council notices {:#obavestenja-saveta}

1. On the **Sub-groups** tab, tap **+** and choose **Announcements**.
2. Type "Obaveštenja saveta" (council notices). Leave **Inherit members** on: every member of the community is a member of this group too, with the same roles, and nobody is invited separately.
3. Tap **Create**.
4. In this group only administrators write, and the council doesn't yet. In the new group's menu, choose **Roles** and, for the council, allow **Post messages** and **Attach files**.

![An announcements group: its name and inherited members](mz-obavestenja-saveta) ![The roles in the council's notices: the council may write](mz-pisanje-saveta)

## 6. The citizens' assembly {:#zbor}

1. Go back to MZ Topolik (the path at the top of the group) and, on the **Sub-groups** tab, tap **+**, then **Chat**.
2. Type "Zbor građana" (citizens' assembly), leave **Inherit members** on and tap **Create**.

This is where people talk, vote and schedule the assembly. Move a longer discussion of one message into a thread: long-press the message and choose **Thread**.

## 7. The neighbourhood map {:#mapa}

1. In MZ Topolik, tap **+** and choose **Map**. A map is offered only inside a group, not on the home page.
2. Type "Mapa kraja" (neighbourhood map) and tap **Create**. An empty map opens.
3. Tap **Add a place**, move the map until the pin stands right on the problem's spot and tap **Here**.
4. Type a name, say "Rupa u Ulici lipa" (a pothole in Lipa Street), leave the kind at **Chat** and tap **Create**. The place is a new group with its own chat, and its pin is on the map.
5. You change the pin's icon in the place's group: **Edit group**, **Location**, **Pin on the map**, say **Problem to report**. A path or a walk is drawn there too, as a **Route**.

Add the community hall, where the assembly meets, the same way. Every member who may create sub-groups can add places, and the role Everyone may until you change it. That is why a neighbour puts the pothole on the map herself.

![A new place on the neighbourhood map](mz-dodaj-mesto) ![The neighbourhood map with problems and a path along the canal](primer-mz-mapa)

## 8. Scheduling the assembly {:#dogadjaj}

1. In the assembly, open the **Calendar** tab and tap **+ Event**.
2. Type the title, the day and the times it starts and ends.
3. Tap **Pick a location** and choose the community hall: the event then stands at that group's place on the map. Type the hall's name in the **Location** field too, because whoever can't see the place's group sees only that text.
4. Turn on **Public event**: every user sees it in their calendar and may answer. Only those who may publish events, like the council, see this switch.
5. Under **Reminders for members**, choose, say, **1 day before** and **1 hour before**. Leave **Announce in the chat** on.
6. Tap **Save**. The announcement arrives in the chat, and members answer with Going, Maybe or Not going.

![A new event: its location, public event and reminders](mz-javni-dogadjaj)

## 9. A poll with a quorum {:#glasanje}

1. In the assembly, tap **+** next to the message field, then **New poll**.
2. Type the question and pick the ready answers **For / Against / Abstain**. For the deadline, choose, say, **3 days**.
3. Open **More settings**. Under **Decision**, choose **More than half of the votes**, and type 30 for the quorum: the decision holds if at least 30% of those who may vote take part.
4. Tap **Start the poll**. People vote right from the chat, and the result and turnout are on the Polls tab.

![A poll with a decision rule and a quorum](mz-kvorum)

## 10. Notices to followers {:#pratioci}

The group of council notices is for members. To everyone else, those who are not members too, the community sends notices: short news for those who follow it.

1. Whoever wants them taps the bell in the header of MZ Topolik. Anyone logged in can follow a public group.
2. A council member chooses **Notices** in the menu of MZ Topolik, types the text in **New notice**, up to 2000 characters, and taps **Send**. The notice reaches the followers, on their phones too, and can't be changed afterwards.

![A new notice to the followers of MZ Topolik](mz-obavestenje)

## What next {:#dalje}

- [All permissions](/pomoc#dozvole): what each permission allows.
- [Map and places](/pomoc#mapa): points, areas and routes.
- [Polls](/pomoc#glasanja): secret polls, results and every setting.
