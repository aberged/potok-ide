<!--
The tutorial for the help page's example "A co-op buying together"
(#primer-zadruga). It follows zadruga.sr.md, which is the reference.
-->

# How to put together a co-op that buys together

Step by step to a co-op like Zadruga Livada in the example: a private group with a pick-up place, notices, a form for orders and a pick-up every Saturday. All you need is an account: whoever creates a group is its administrator.

## What we build {:#sta-pravimo}

- **Zadruga Livada**, a folder, private, with the pick-up place on the map
  - **Orders**: a form each member fills in once and changes until the deadline, with a process that takes every order to packing
  - **Arrangements**: a chat about picking up and swaps

![Zadruga Livada, finished: orders and arrangements](primer-zadruga)

## 1. The co-op's group {:#grupa}

1. On the home page, tap **+** at the bottom right and choose **Folder**.
2. Type "Zadruga Livada". Leave **Public group** off: only members see the co-op and everything in it.
3. Tap **Create**.

## 2. The pick-up place {:#mesto}

1. In the group's menu (⋯), choose **Edit group**, then the **Location** card.
2. Leave **Point** and tap the map at the pick-up place, or tap **My location** if you are right there.
3. Under **Pin on the map**, choose **Market** and tap **Save changes**.

Only its members see a private group's place on the map.

![The pick-up place as a point on the map](zadruga-mesto)

## 3. Members {:#clanovi}

In the group's menu, choose **Invite profile** and type a username or an email. Whoever has no account yet gets an invitation to Potok by email. A private group takes no access requests, so people join it only when invited.

## 4. Notices to buyers {:#obavestenja}

What there is this week and until when to order, the co-op tells in a notice. It reaches everyone who follows the co-op, apart from the messages and on their phones too.

1. Every member taps the bell in the header of Zadruga Livada. Only its members can follow a private group, and nobody follows it on their own.
2. In the group's menu, choose **Notices**, type the text in **New notice** and tap **Send**.

As an administrator, you can send notices from the start. You give it to others with the permission **Send notices** in the group's roles, as to the council in the [local community](/pomoc/mesna-zajednica#savet).

## 5. A form for orders {:#porudzbine}

1. In Zadruga Livada, tap **+** and choose **Form**. Type "Porudžbine" (orders) and tap **Create**.
2. On the **Questions** tab, tap **Add question** for each product. For a quantity, a **Dropdown** or a **Short answer** works well, and for a choice between a few things, **Multiple choice**.
3. On the **Settings** tab, turn on **Limit to 1 response** and **Allow response editing**, and under **Accept responses until** pick the deadline for orders.
4. Tap **Publish**, check who fills in the form and confirm with **Publish**.

Each member now fills in the form once and changes their response until the deadline.

![The form's settings: one response, editing and a deadline](zadruga-forma-pravila) ![The order form, as a member sees it](forma)

## 6. Looking over the orders {:#pregled}

Every order is on the **Responses** tab. **Summary** shows, for each question, how many chose what, and **Individual** and **Table** show each order on its own. For the buying, choose **Download responses (.csv)** in the **More** menu and add up the quantities per product in a spreadsheet: the form counts responses but doesn't add up numbers.

Whoever may edit the group sees the responses, and on the Settings tab, under **Who sees all responses**, you can show them to a role too.

![The form's responses: a summary of the orders](zadruga-odgovori)

## 7. Arrangements {:#dogovor}

In Zadruga Livada, tap **+**, choose **Chat**, type "Dogovor" (arrangements) and tap **Create**. This is where picking up and swaps are arranged.

## 8. A pick-up every Saturday {:#preuzimanje}

1. In Zadruga Livada, open the **Calendar** tab and tap **+ Event**.
2. Type "Preuzimanje porudžbina" (picking up the orders), choose the first Saturday and the time.
3. Under **Repeats**, choose **Weekly** and check that Saturday is marked.
4. Tap **Pick a location** and choose Zadruga Livada: the event stands at the pick-up place.
5. Under **Reminders for members**, choose **1 day before** and tap **Save**.

Members get a reminder before every pick-up, and anyone can choose reminders of their own too.

![A pick-up that repeats every Saturday](zadruga-preuzimanje)

## 9. A process for packing {:#proces}

So that no order is left unpacked, draw a process on the form. For every order it opens a talk with the buyer, waits for someone to pack it and tells the buyer how it went.

1. In Orders open the group's menu, choose **Processes** and tap **Draw a process**. Type "Packing orders"; the collection is **responses**, the form's answers.
2. Tap **+** under the start and choose **Sub-group**. For its name type "Order for Saturday", and under **Who runs it** leave the process's owner and whoever set it going, which is the buyer.
3. Tap **+** under the sub-group and choose **Decision**. Under **Who decides** leave Admin, name the outcomes "Packed" and "Something is missing", and for **Deadline, with a reminder** type 2 days.
4. Tap **+** on the arrow "Packed", choose **Message** and under **Where** pick the sub-group: "It is packed. It waits for you on Saturday from 9 to 11, in the school yard." Do the same for "Something is missing".
5. Tap **Save**, then **Switch on**.

![The packing process, drawn in Potok](zadruga-proces-crtez) ![A decision: who decides, the outcomes and the deadline](zadruga-proces-korak)

From now on every new order gets a talk of its own. The orders waiting to be packed are on the Processes tab, under **Waiting for you**: when you pack one, tap **Packed**, and the buyer reads it at once in their talk. If packing is two days late, the admins get a reminder on their phones.

![Orders waiting to be packed](procesi)

## 10. Pick-up day {:#subota}

Packed orders wait for Saturday. Let one process tell everyone on Saturday morning that it is pick-up day, and let packing wait for that signal and remind the buyer.

1. In Orders draw a process "Pick-up day", and under **When** choose **the set time comes**. On the start step choose **Every week**, the day **Sat**, at 8:00.
2. Tap **+** under the start and choose **Send a signal**. For **Signal** type "subota", tap **Add a field**, name the field "mesto" and type "in the school yard". Save and switch it on.
3. In "Packing orders", on the arrow under the message "It is packed…", add the step **Wait for a signal** and for **Signal** type "subota".
4. Under it add a **Message** into the sub-group: type "Today is pick-up day, from 9 to 11, " and tap `receive_1.mesto` under the field. Tap **Save**.

![Packing waits for the signal subota](zadruga-signal)

Every packed order now waits for Saturday. On Saturday at 8:00 Pick-up day sends the signal, and every buyer whose order waits gets a message in their talk. An order packed after that waits for the next Saturday.

## What next {:#dalje}

- [Apps in a group](/pomoc#aplikacije): everything Form can do.
- [Draw a process](/pomoc#nacrtaj-proces): all the steps a process can have.
- [Calendar](/pomoc#kalendar): events, repeating and reminders.
- [Following, notices and push](/pomoc#obavestenja): notifications on the phone.
