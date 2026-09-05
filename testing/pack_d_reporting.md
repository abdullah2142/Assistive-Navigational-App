# Pack D — Asking for help, and flagging trouble

**Modules 2 and 5 · hazard reporting, passer-by helper, caretaker side**

## What you own

Hazard reporting, the passer-by helper screen, and the caretaker half of the
app — the paired dashboard, remote settings, and the alert list.

Everything here is either **shown to a stranger or sent to another person**,
so the cost of getting it wrong is different from the rest of the app. A
wrong hazard report closes a road for every other user; a garbled passer-by
message is held up to someone in the street by the one person present who
cannot see what it says.

## Runs

1. File a hazard by voice, start to finish, **without touching the screen**.
   Say `send` to submit it.
2. File one where you **name the hazard up front** — `there's an open
   manhole` — and check it skips straight past the menus.
3. When the read-back plays, say `cancel`. Nothing should be filed.
4. Do it again and say `change it`. You should get another go at describing
   it, with the old text cleared.
5. Now say **nothing at all** during the read-back. It should send on its
   own after a few seconds.
6. Describe a hazard using the word "send" **in the middle of a sentence**
   and confirm it does not submit early.
7. Open the passer-by helper and **actually show it to someone who doesn't
   know the app**. Watch whether they understand what to do — **their
   reaction is the result**, not your opinion of the screen.
8. On a paired caretaker phone, change a setting remotely and confirm it
   lands on the other device.
9. Report the same hazard from two different phones and see whether it
   escalates.

## Hunt for

- A command word ending up **inside the description text** instead of acting
  on it.
- Anything filed that you did not confirm, or a `cancel` that did not
  cancel. Either is serious.
- The stranger hesitating, looking confused, or handing the phone straight
  back. Note exactly what they did and where their eyes went.
- Caretaker screens still in English when the profile is set to Bangla.
- A report you filed that you cannot find anywhere afterwards.

## Passes if

You filed and cancelled reports entirely by voice, and a stranger with no
explanation understood what the passer-by screen was asking of them.

## Before you start

Get the app through **Firebase App Distribution** — you need an Android
phone, the email you were invited on, and a network connection. No computer,
no cable, no developer mode. Details in the [root README](../README.md).

Ground rules for every run:

- **A real phone, not an emulator.** Check with the others that you are all
  on different handsets — the worst bug found so far appeared on one GPU
  family only.
- **At least one run outdoors, with street noise.** Quiet-room results tell
  us almost nothing about speech.
- **Everything twice** — once in English, once in Bangla. They fail
  differently.
- **Say it wrong on purpose.** Half your value is mumbling, rephrasing and
  stopping mid-sentence. Perfect diction finds nothing.
- **Stay in your pack.** Anything you notice outside it: one line, then move
  on. Don't chase it.

## How to report what you find

One entry per problem, in this shape. The exact words you spoke matter more
than anything else you can give us — a voice bug without the transcript is
usually not actionable.

```
PACK:      C
PHONE:     Redmi 10C, Android 13, MIUI 14
LANGUAGE:  Bangla
WHERE:     Walking, Mohammadpur, ~9pm, light rain

I SAID:    "আমি মোহাম্মদপুর যেতে চাই"
EXPECTED:  Route starts
HAPPENED:  "I don't know where that is"
AGAIN?:    Yes, 3 of 3 tries

NOTES:     Worked when I said just "মোহাম্মদপুর"
```

**Always include the phone model and whether it repeats.** The blank-map bug
existed on one GPU family only and would have been dismissed as "works on
mine" without the model written down. A bug that happens once and a bug that
happens every time are different bugs.
