<!--
The tutorial for the help page's example "A building or a club"
(#primer-zgrada). It follows zgrada.sr.md, which is the reference.
-->

# How to put together a building or a club

Step by step to a building like Cvetna 12 in the example: one chat for all the residents, a smaller one for the house council and a shared profile with which the council speaks with one voice. A club, a choir or a sports team is put together the same way.

## What we build {:#sta-pravimo}

- **Zgrada Cvetna 12**, a chat, private, with a process for reporting a fault
  - **House council**: a chat for the council only

![Zgrada Cvetna 12, finished: minutes, a poll and an event in the same chat](primer-zgrada)

## 1. The building's chat {:#grupa}

1. On the home page, tap **+** at the bottom right and choose **Chat**.
2. Type "Zgrada Cvetna 12". Leave **Public group** off and tap **Create**.

## 2. Residents {:#stanari}

1. Open the **Members** tab and tap **Invite**.
2. Type a neighbour's username or their email and tap **Invite**. The person answers an invitation by email with the profile they pick. Whoever has no account yet gets an invitation to Potok, and is in the building once they make a profile from its link.

The invited accept on the Invitations page, which an icon in the top bar leads to.

## 3. The house council {:#kucni-savet}

1. In the building's chat, open the menu (⋯), choose **Create sub-group**, then **Chat**.
2. Type "Kućni savet" (house council) and turn **Inherit members** off: otherwise every resident would be on the council too.
3. Tap **Create**. For now you are the only one on the council.
4. In the council's menu, choose **Invite profile** and invite the council's members, one by one.

![The house council, without inherited members](zgrada-kucni-savet)

## 4. The council's shared profile {:#deljeni-profil}

A shared profile is used by several accounts together. The residents then see that the council writes, not one of its members, and each council member logs in with their own account.

1. Tap your picture in the top bar, then **Create profile** on the Profiles page.
2. Type a username, say `savet-cvetna`, and a name and picture if you like. On the **Sharing** tab, choose **Shared** and tap **Create profile**.
3. In the list of profiles, open the new profile's menu (⋯), choose **Edit**, then the **Sharing** tab.
4. Under **Invite profile to shared profile**, type the username of another council member's profile and tap **Send invitation**.
5. The other member opens the Profiles page while using exactly that invited profile and taps **Accept shared profile**. The council's profile is now on their account too.

![Sharing the council's profile with another member](zgrada-deljeni-profil)

## 5. The council in the chat {:#savet-u-razgovoru}

1. Invite the profile `savet-cvetna` to Zgrada Cvetna 12: the **Members** tab, **Invite**.
2. On the Profiles page, tap the council's profile in the list: you are using it now.
3. On the Invitations page, accept the invitation to the building.

When you write on the council's behalf, you choose the council's profile on the Profiles page, and when you write in your own name, you switch back to yours. The top bar always shows the picture of the profile you are using.

![Profiles: the current, the default and the shared profile savet-cvetna](profili)

## 6. Minutes and house rules {:#fajlovi}

1. In the building's chat, tap **+** next to the message field, then **Add files**, and choose the minutes or the house rules.
2. Add a message and send it.

All the files of the chat gather on the **Files** tab, so the house rules can be found even after many messages, and a search by name finds them at once.

![Files and a poll under the + button](prilozi) ![The building's files](fajlovi)

## 7. A poll {:#glasanje}

1. Tap **+** next to the message field, then **New poll**.
2. Type the question, say "Koje boje da okrečimo ulaz?" (what colour to paint the entrance?), and the answers. **Add answer** adds another one.
3. Choose a deadline and tap **Start the poll**.

The poll stands in the chat and people vote right from it.

![A new poll](glasanje-forma)

## 8. A work day in the building {:#dogadjaj}

1. Open the **Calendar** tab and tap **+ Event**.
2. Type "Čišćenje podruma" (cleaning the basement), the day and the time.
3. Leave **Announce in the chat** on and tap **Save**.

The announcement arrives in the chat, and residents answer with Going, Maybe or Not going.

![A new event](dogadjaj-forma)

## 9. Reporting a fault {:#kvar}

So that a report of a fault is not buried in the chat, make a process the residents start themselves. It needs no app.

1. In Zgrada Cvetna 12 open the group's menu, choose **Processes** and tap **Draw a process**. Type "Reporting a fault", and under **When** choose **someone starts it**.
2. Tap the start step: under **Who may start it** leave **Everyone**.
3. Tap **+** under the start and choose **Sub-group**. For its name type "Fault: " and tap `start.title` under the field. Under **Who runs it** leave the process's owner and whoever set it going.
4. Tap **+** under the sub-group and choose **Decision**. Name the outcomes "Fixed" and "Calling a repairer".
5. On the arrow of each outcome add a **Message** into the sub-group, say "It is fixed, thanks for the report."
6. Tap **Save**, then **Switch on**.

![Reporting a fault: who may start it](zgrada-proces-okidac)

A resident taps **Start** on the Processes tab, types what is broken and confirms. The process opens a sub-group for that fault, with the resident and you in it, and the decision waits for you on the Processes tab, under **Waiting for you**.

![Reporting a fault from the Processes tab](zgrada-pokreni)

It also works without the button: under **When** choose **someone writes a message** and type the words "leak" and "broken". Every message in the building's chat with one of them starts the process. [Step 14](#forma) shows how such a process asks the resident for the rest.

## 10. The repairer, a process of its own {:#majstor}

Agreeing with a repairer has steps of its own, and other processes need it too, not only the fault report. So draw it as a process of its own, and let the fault report call it and wait.

1. Draw a process "Repairer", and under **When** choose **another process calls it**. On the start step, under **Fields it takes**, type "kvar".
2. Under **Data** make an entity "Termin" with an attribute `napomena`, of the type text. On the Repairer's start step, under **What it hands back**, pick "Termin".
3. Add a **Decision** with the outcomes "Agreed" and "No date". Tap the arrow of the outcome "No date" and under **Leads to** choose **A new end**. Name the ends as the outcomes: tap an end and type its **Name on the drawing**.
4. Tap the end "Agreed" and under **What it hands back to the process that called it**, for `napomena`, tap `task_1.comment`: what the council writes with the decision.
5. Tap **Save**, then **Switch on**.
6. In "Reporting a fault", on the arrow under the message of the outcome "Calling a repairer", add the step **Call a process** and pick "Repairer". Under **What it gets**, for the field `kvar` tap `start.title`. Leave **Wait for it to end** on, and for the deadline type 7 days.
7. Under the call add a **Condition**. Tap its first arrow and under **Goes this way when** type `call_1.outcome = "Agreed"`: that arrow leads to the message "The repairer is coming. " with `call_1.napomena` at its end, and **otherwise** to the message "The repairer has no date yet."

![The Repairer's end hands a Termin back to the process that called it](zgrada-vraca) ![Reporting a fault calls the Repairer](zgrada-proces-poziv)

When you decide "Calling a repairer", the fault report starts the Repairer and waits. The Repairer's decision waits for you on the Processes tab, with the name of the process that called it and the fault. As soon as you pick an outcome, the fault report goes on and tells the fault's sub-group how it went, and "The repairer is coming." carries what the council wrote with the decision, say "Wednesday after 5 pm". If nobody decides within 7 days, the fault report gives up, and the Repairer is cancelled.

## 11. Counting the faults {:#brojac}

To know how many faults there were, let the fault report count them, in a field of the group every process of the building reads.

1. In "Reporting a fault" tap **+** under the start and choose **Group field**.
2. For **Field of the group** type "kvarova", under **What it does** choose **Adds to it**, and for **Number** type 1.
3. If you like, add " It was fault number " to the message "It is fixed, thanks for the report." and tap `group.kvarova` under the field.
4. Tap **Save**.

Every report adds one, and how many there were you see at the bottom of the Processes tab, under **Fields of the group**, where the field "kvarova" stands as a **Number**: the drawing brought it along, as its step adds to it. A process on a schedule can read the same field, say for a monthly report in the building's chat.

![The group's fields on the Processes tab](zgrada-polja)

## 12. A fault as an entity {:#entitet}

A title and a text are enough to begin with. When you want a report to always say the floor too, and whether it is urgent, describe a fault as an **entity**: a name and attributes, each with its type.

1. On the Processes tab, under **Entities**, tap **New entity** and type "Kvar".
2. Add the attributes: `naslov` as **Text**, with **Must be filled in**, `sprat` as a **Number** and `hitno` as **Yes or no**. Tap **Save**.
3. Draw a process "Hitan kvar", and under **When** pick **someone starts it**. Tap the start step and under **What its form asks for** pick "Kvar".
4. Add a **Condition** and on its first arrow, under **Goes this way when**, type `start.hitno`. On that arrow add a **Push** for the Administrator: type "Hitan kvar: " and tap `start.naslov`.
5. Under it add a **Message** in the building's chat, with `start.naslov` and `start.sprat`, then tap **Save** and **Switch on**.

![The entity Kvar: attributes and their types](zgrada-entitet)

A resident who taps **Start** now gets a form with a field for each attribute: the floor takes a number only, and the title must be typed. The steps read it as `{{start.naslov}}` and `{{start.sprat}}`, and Potok checks as you draw that you do not add a text up as a number.

![An urgent fault: the form asks for the entity's attributes](zgrada-hitan-kvar)

A process others call, like the Repairer, can take the same entity: the step **Call a process** then asks for a value for each attribute. If the House council needs the Repairer too, tick **Public process** on its start step: then the processes of the groups above and below the building call it as well.

## 13. A round of the building {:#obilazak}

Once a month someone from the council goes round the building and notes what they found. The process keeps the findings in a **list**, and in the end writes a message for each.

1. Draw a process "Obilazak zgrade", and under **When** pick **someone starts it**. On the start step, under **Who may start it**, leave the Administrator only.
2. While nothing on the drawing is picked, open the **Data of the process**, on a phone with the cube button. Tap **Add a variable**, type "nalazi", leave **Text** and tick **A list**.
3. Add a **Decision** with the outcomes "Dodaj nalaz" and "Gotovo".
4. On the arrow "Dodaj nalaz" add **Set a value**: under **What it sets** pick `nalazi`, under **What it does** pick **Adds an item to its end**, and for the value tap `task_1.comment`. Send the arrow under that step back to the decision: tap it and under **Leads to** pick the decision.
5. On the arrow "Gotovo" add **For each**. Under **List it goes through** tap `nalazi`, and for the **Name of an item** type "nalaz".
6. The step on the arrow **for each** is a message: type "Nalaz " and tap `loop_1.index`, then " od " and `loop_1.count`, then ": " and `nalaz`.
7. Tap **Save**, then **Switch on**.

![A round of the building: a decision fills the list, and For each goes through it](zgrada-obilazak)

Whoever goes round types a comment for each finding on the Processes tab and taps **Dodaj nalaz**, and in the end **Gotovo**. The process then goes through the list and writes each finding in the building's chat, with its number. All that the process has, with names and types, stands under the **Data of the process**. A form can also write the findings, all at once: an entity with an attribute that is a list gives a form with a row for each item and an **Add** button (see [Draw a process](/pomoc#nacrtaj-proces)).

![Data of the process: the list nalazi, the item and the counters](zgrada-podaci)

## 14. A fault from the chat, with a form {:#forma}

A resident need not even look for a button: it is enough to write "kvar" in the building's chat, and the process asks them for the rest, in a form that asks for the entity Kvar of step 12.

1. Draw a process "Kvar iz razgovora", and under **When** pick **someone writes a message**. Tap the start step and type the word "kvar".
2. Tap **+** under the start and pick **Form**. For **Name on the drawing** type "Prijavi kvar", under **What it asks for** pick "Kvar", and under **Who fills it in** leave **Whoever started the run**. For **What it says first** type "Hvala! Proveri naslov i dodaj sprat.", and under **Already filled in**, by `naslov`, tap `start.text`.
3. Under the form add a **Message** in the building's chat: type "Prijavljen kvar: " and tap `form_1.naslov`, then ", sprat " and `form_1.sprat`.
4. Tap **Save**, then **Switch on**.

![The form opens for whoever wrote the message](zgrada-forma)

As soon as a resident sends a message with the word "kvar", the form opens for them. The title already holds the text of their message, so they only check it, and the floor takes a number only. When they tap **Send**, the process goes on and says in the chat what was reported.

If they close the form with **Later**, it waits for them. The building's header then has a **Waiting for you** mark with a number: it leads to the Processes tab, where **Fill in** opens the form. Outside the building the hand in the top bar counts it, and on the **Requests** page, under the **Processes** tab, the form opens with one tap. You see the same mark when a decision waits for you.

![The Waiting for you mark in the building's header](zgrada-ceka-tebe)

Someone else can fill the form in too: under **Who fills it in** pick a role, say the Administrator. Such a form opens by itself for nobody, and waits for the people of that role under **Waiting for you**.

## A club, a choir or a team {:#klub}

A club is put together the same way: one chat for everyone, a sub-group without inherited members for those who run it and a shared profile when they should speak with one voice. Training sessions and rehearsals are events that repeat: under **Repeats**, choose **Weekly**.

## What next {:#dalje}

- [Profiles](/pomoc#profili): unique and shared profiles.
- [Draw a process](/pomoc#nacrtaj-proces): everything that can start a process, and how processes call each other.
- [Messages](/pomoc#poruke): replies, threads, reactions and mentions.
- [Files and tags](/pomoc#fajlovi-i-tagovi): everything from a chat in one place.
