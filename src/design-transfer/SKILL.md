---
name: design-transfer
description: Transfer a reference site's visual craft onto your own pages and iterate until the transfer is dry. Use when the user names a reference to match ("make it look like X", "as good as this site"), asks to bring one page up to another's standard, or wants repeated screenshot-and-fix rounds on a surface. Covers frame-by-frame capture at every width, motion and state capture, the wet/dry finding loop, and the rubric that stops it.
---

# Design transfer

Copying a reference is not copying its CSS. It is finding the **devices** the reference
uses, deciding which ones your subject earns, and then grinding your own surface until
no part of it is worse than the part beside it.

The work is a loop, and the loop's only honest stop condition is **dry**: a pass that
adds no new findings. Two consecutive dry passes end it. A score does not.

## Vocabulary

- **Wet** — parts still inconsistent with each other or with the reference's standard.
- **Dry** — a pass that surfaces nothing new.
- **Frame** — one 1:1 slice of the page, viewport-sized. The unit of review.
- **The glass** — what the reader actually sees. Distinct from what the source declares,
  and the only thing that counts.

## 1. Read the reference for devices, not decoration

Name what the reference *does*, as rules you could apply to different content. "Section
heads are large display under a small mono label" is a device. "Uses Bricolage" is not.

Write the devices down before touching your own page. You will otherwise import a
surface impression and lose the mechanism.

**Check each device against your own thesis before adopting it.** A device that fights
your subject makes the page worse in a way that looks like progress. When the project
has a design spec, the spec outranks the reference.

## 2. Capture before you judge

Three properties decide whether a capture is worth reviewing.

**Production, never the dev server.** Dev toolbars and overlays sit on top of the page.
An injected toolbar over a prose column invalidated two full review rounds here before
anyone noticed the frames were lying.

**1:1 frames, never a full-page screenshot.** A full-page shot of a 16,000px article is
a thumbnail, and a thumbnail hides every defect worth finding. Slice the page into
viewport-height frames at native resolution and read them in order.

**Every width, every state.** A loop that only captures 1280 static reduced-motion is
blind to most of the site by construction:

| Mode | What it is the only way to see |
| --- | --- |
| frames, each width | layout, measure, figure legibility, rhythm |
| motion | the intro handoff and every scroll reveal |
| states | hover and keyboard focus |

Reduced motion is right for static frames — it settles reveals and makes two passes
comparable — and it is *definitionally blind* to motion. Capture motion separately or
never see it. Three rounds of "thorough" review here never looked at the intro once.

Sample motion across each transition, not after it. A reveal captured at rest is a
still frame, so park each section below the fold, bring it up, and sample the curve.

## 3. Grade two kinds of row, never mixed

**Machine rows** assert a measurable fact and live in a script: a rendered size, a
contrast ratio, a bounding box, an absence of overflow. **Eyes rows** name one artifact
and one question, and a human answers.

When a row could be either, make it machine. A model grading its own aesthetic output
converges on "looks good to me", so it never awards the aesthetic grade.

**Measure the glass, not the declaration.** This is where the expensive misses hide. An
SVG label declared 12px inside a scaled viewBox rendered 3.0px on a phone — the computed
style still said 12px, the desktop screenshot looked right, and axe does not check SVG
text at all. Only the CTM scale showed it, and it was wrong on 147 of 230 labels for
four rounds. Whenever a value passes through a scale, a transform, or a container query,
the declared number is not evidence.

## 4. Record findings before fixing them

Everything noticed becomes a row in the rubric **first**, then gets fixed. A finding
that goes straight to a fix is a finding the next pass rediscovers.

Keep closed rows. They are how you notice a regression returning.

## 5. Fix at the class, and default to the safe direction

Two failure modes recur hard enough to plan around.

**Fix at the class, not the element.** A chart shipped invisible because one `<text>`
forgot `fill` and SVG text defaults to black. Fixing that element leaves every future
chart able to repeat it; putting `fill` on the label class ends the whole category.

**A global fix becomes a global regression.** A label size calibrated for one scale
factor, applied where the factor differs, broke five charts while fixing two. When a
value depends on context, make the *default* the safe direction — so an unmarked case
fails legible rather than illegible, and only the exceptional case opts out.

Watch the cascade. A base element rule outranks a utility class: `.cs-body p` (0,1,1)
beat `.label-mono` (0,1,0) and silently rendered every subhead at body size, larger than
the label governing it. The same shape bit three times here in different clothes.

## 6. Verify a reported finding before acting on it

Reviewers — human, agent, or your own earlier notes — report defects that measurement
does not support. A "third typeface" was one weight step. A "misaligned rail" was two
elements at the same x. "Dead links" were a bug in the checker.

Reproduce the claim as a number before you change code for it. The diagnosis being
wrong does not make the finding wrong, and the reverse also holds: confirm which.

## 7. Loop until dry

Each pass: rebuild → capture every mode and width → read **every** frame in order →
write findings → fix → repeat.

Never sample frames. The defects cluster in the parts nobody thought to look at, which
is exactly what sampling skips.

Expect the find-rate to rise when the method sharpens. Going from full-page shots to 1:1
frames raised it here from 4 to 8. That is the method working, not the page rotting —
but it means the first pass under a new method resets the count, and only passes under
the *same* method compare.

## Completion criteria

1. Two consecutive passes add no new rows.
2. Every frame at every captured width has been read, in order, at 1:1 — not sampled.
3. Motion and interaction states have each been captured and graded at least once.
4. Every machine row passes, and each was measured on the glass rather than the source.
5. Every finding is a rubric row, including the closed ones.
6. No device was adopted from the reference that the project's own spec contradicts.

## Boundaries

This skill owns the transfer loop and its verification. It does not own implementation
sequencing — a lifecycle owner does — and it does not replace a project's design spec,
which outranks the reference on every disagreement.
