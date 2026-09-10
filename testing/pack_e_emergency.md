# Pack E — The Magic Button

**Read the safety section before you do anything else.** This is the one pack
where getting it wrong costs somebody other than you.

## What you own

Module 9 — the emergency escalation. Volume Down held, and the spoken cries
that mean the same thing. What it says, what it sends, what it does when it
cannot send, and — the part nobody has tested — what stops it.

This pack did not exist in round 1. The feature landed the day after the
packs were written, so the only instruction anyone has had about it is "if it
goes off by accident, say cancel". Everything here is therefore first contact.

---

## Safety — read this first

**The build you have is in rehearsal mode.** The whole sequence runs, speaks,
routes and writes the caretaker alert, but **no SMS is sent and no call is
placed**. You will hear it say so.

That is what makes this pack safe to run at all. It also means:

- **Put real numbers in.** The rehearsal will not dial them, and testing with
  fake numbers tests nothing about how the sequence reads a real contact list.
- **Tell whoever you list what you are doing anyway**, before you start. If a
  build is ever handed to you that is *not* in rehearsal mode, that
  conversation is the only thing standing between a test and a family
  emergency.
- **If you hear it say it has actually sent something, stop the pack and tell
  us immediately.** That means the build is live and it should not be.
- Do not run this pack in a public place where shouting "help me" will be
  taken at face value. A quiet street, a park, your own home.

---

## Part 1 — The gesture

1. Hold **Volume Down for three seconds**. Note what you hear first, and how
   long after the hold it starts.
2. Do it with the **screen off**.
3. Do it with the **phone in a pocket**, which is how it will actually happen.
4. Do it while the app is in the **background**, and while another app is in
   front.
5. Press Volume Down **normally, several times** — changing the volume — and
   confirm it does **not** fire. A false trigger here is a **BLOCKS**.
6. Hold it for **one second** and release. It should not fire.

## Part 2 — The words

The spoken triggers are deliberately split: some words fire on their own,
some only when the whole sentence is short or distressed.

7. `emergency`, `SOS`, `save me` — each on its own.
8. `help me` on its own. Then `can you help me with the volume` — the second
    must **not** fire. This distinction is the whole design; if it is wrong in
    either direction, say which.
9. `বাঁচাও`, `বিপদে পড়েছি`, `হেল্প হেল্প`.
10. Shout one of them **outdoors, with traffic**. Recognition under stress and
    noise is the case that matters and the one we have no data on.
11. Say `help` as part of an ordinary sentence — "help me choose a route" —
    and confirm it does not fire.

## Part 3 — Cancelling (the least-tested path in the app)

The window **defaults to proceeding**. Silence sends. Only a deliberate word
stops it.

12. Trigger it and say `cancel`. Confirm it stops and says so.
13. Trigger it and say `ক্যান্সেল` / `বাতিল`.
14. Trigger it and say **nothing**. It should proceed. Time how long you had.
15. Trigger it and say `stop` — this **should not cancel it**. "Stop" and
    "wait" are what people shout at an attacker, so they were deliberately
    removed from the emergency vocabulary. Confirm they do not stop it, and
    tell us if you think that is wrong.
16. Trigger it and say something panicked and unrelated — "he is pushing me",
    "get away from me". It must **not** cancel.
17. Trigger it **twice in quick succession**. The second should skip the
    cancel window entirely rather than starting a second round of messages.

## Part 4 — What it says, in order

18. Let one run all the way through, in a quiet room, and **write down every
    sentence in order**. That transcript is the main deliverable of this pack.
19. Confirm it **speaks before it sends anything** — you should know it
    understood you before anything leaves the phone.
20. Confirm it tells you plainly that it is a **practice run**.
21. Run it with **no emergency contacts saved** and confirm it says so rather
    than failing silently.
22. Run it with **airplane mode on**. Every failure must be spoken. A user who
    believes help is coming and stops trying to get it is worse off than one
    who knows the phone could not reach anyone.
23. Run it with **location permission denied**.

## Part 5 — Where it sends you

24. After a trigger, confirm it offers a route to a **safe place** and that
    the route actually starts.
25. Confirm the escape route **appears on the map**, not just in the voice.
    This is new and has never been tested.
26. If it cannot find a route, confirm it still tells you **which direction
    and how far** the safe place is.
27. Do one run with your **home address saved** and one with only a safe-place
    address, and note which it picks.

## Part 6 — The caretaker end

Needs the second phone. Agree a time with whoever owns Pack D.

28. Trigger it and confirm an **alert appears on the caretaker's phone**, with
    a location.
29. Confirm the caretaker sees the **live location update** as you move.
30. Confirm the alert says it was a rehearsal.

---

## Hunt for

- **Any false trigger.** Volume keys during music, a shouted word in
  conversation, the phone in a bag. This is the failure that makes people
  uninstall.
- The cancel window being **too short to use** while frightened.
- A step failing **silently** — anything the phone could not do that it did
  not say out loud.
- The sequence running **twice**.
- It claiming to have sent something in rehearsal mode.
- Speech that is too fast or too quiet to follow under stress.

## Passes if

You ran the full sequence at least **six times** — including once outdoors,
once with the screen off and the phone pocketed, once with no signal, and once
cancelled — and you can hand back the complete spoken transcript in order.

## Coverage — tick what you actually did

- [ ] Volume hold: screen on
- [ ] Volume hold: screen off
- [ ] Volume hold: in a pocket
- [ ] Volume hold: app backgrounded
- [ ] Ordinary volume presses did NOT fire it
- [ ] Each strong spoken trigger, English
- [ ] Each strong spoken trigger, Bangla
- [ ] "help me" fired, "can you help me with X" did not
- [ ] Shouted outdoors with traffic
- [ ] Cancelled by voice, English
- [ ] Cancelled by voice, Bangla
- [ ] Said nothing — it proceeded. Window length: ______ s
- [ ] "stop" did NOT cancel
- [ ] Panicked unrelated speech did NOT cancel
- [ ] Triggered twice — no second round of messages
- [ ] Full spoken transcript written down, in order
- [ ] No contacts saved
- [ ] Airplane mode
- [ ] Location denied
- [ ] Safe-haven route offered and started
- [ ] Escape route visible on the map
- [ ] Caretaker received the alert (with Pack D)
- [ ] Caretaker saw live location
- [ ] It never claimed to have really sent anything

---

## Before you start

- Use a **real phone**, not an emulator.
- Run everything **twice — once in English, once in Bangla**. They fail
  differently.
- **Say it wrong on purpose.** Mumble, trail off, shout.
- Tell your listed contacts what you are doing first.

## How to report what you find

One entry per problem. The exact words you spoke matter more than anything
else you can give us.

```
PACK:      E
PHONE:     Redmi 10C, Android 13, MIUI 14
LANGUAGE:  Bangla
WHERE:     Quiet room / street / pocket

I DID:     Held Volume Down 3s with the phone in my pocket
EXPECTED:  "Emergency mode..." within a second
HAPPENED:  Nothing for 6 seconds, then it started
AGAIN?:    Yes, 4 of 5 tries

NOTES:     Worked immediately with the screen on
```

### Severity

- **BLOCKS** — a false trigger, a failure it did not speak, or anything sent
  for real in rehearsal mode.
- **MAJOR** — cancel not working, the sequence running twice, no safe route.
- **MINOR** — wording, pacing, a voice that is hard to follow.
