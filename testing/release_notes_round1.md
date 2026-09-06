# Release notes — test round 1

Paste the block below into `--release-notes`. Keep it short: this is the
only instruction most testers read, and it is read on a phone.

---

```
Round 1. Open your test pack — you each have a different one.

Please: use a real phone, run everything twice (English and Bangla),
and do at least one run outdoors with street noise.

Not in scope this round: the emergency button. If it ever goes off by
accident it is safe — practice mode, nothing is sent to anyone — just
say "cancel" and carry on.

Known: caretaker screens are still English-only. No need to report.

Report the exact words you said. That matters more than anything else
you can tell us.
```

---

## Why each line is there

**"you each have a different one"** — the packs are scoped on purpose, and
the first thing four testers do with one app is all test the same screen.

**"twice, English and Bangla"** — they fail differently, and Bangla fails in
ways English never will. Left implicit, nobody does the second pass.

**"outdoors with street noise"** — quiet-room speech results tell us almost
nothing. This is the single instruction most likely to be skipped and most
likely to find something.

**The emergency line** is reassurance, not an invitation. Module 9 is not
in any of the four packs this round, so nobody should be spending time on
it — but Volume Down held three seconds is a gesture people make by
accident, and a tester who hears "Emergency mode. Sending alerts." with no
warning will assume they have done something bad and stop testing to sort
it out. One sentence prevents that, without asking anyone to go looking.

Deliberate testing of it comes in a later round, once it has been fired on
real hardware and switched out of practice mode.

**The known-issue line** buys back the time four people would each spend
writing up the same bilingual gap.

**"the exact words you said"** — a voice bug without the transcript is
usually not actionable, and this is the habit that has to form in round 1.

## Later rounds

Replace the body with what changed and what you want tested. Never leave it
empty: a build with no notes gets installed and not exercised, which costs a
whole round.
