---
name: verify-site
description: Verify a web surface against its own spec — screenshot matrix, console and hydration, axe at every width, Lighthouse floors, and the capture-grade-repeat loop that decides when to stop. Use after any visual or functional change and before a deploy. A project with its own verify-site skill overrides this one; this carries the method, that carries the project's ports, scripts and widget names.
---

# Verify site

A gate that exits 0 has proved the checks it has, not that the page is right. The
work is to keep adding checks until the ones you have would have caught what you
just found by looking.

## The order that matters

Run the cheap machine stages first, then look at the images. A stage that exits
green has not told you the page is good; it has told you one specific way it is
not bad.

| Stage | Catches |
| --- | --- |
| console | page errors, hydration mismatches |
| a11y (axe) | roles, labels, contrast **on DOM text** |
| responsive | horizontal overflow, tap-target floors |
| no-JS | a page that never appears when a bundle fails |
| screenshots | everything the above cannot express |

**Sweep every width, not just the desktop one.** Mobile-only surfaces are
`display: none` on desktop, so a desktop-only axe run never sees them. A
contrast failure survived nine green sweeps here for exactly that reason.

## Measure the glass, not the declaration

The expensive misses all live in the gap between what the source says and what
the reader sees.

- An SVG label declared `12px` inside a scaled viewBox rendered **3.0px** on a
  phone. Computed style still said 12px; the desktop screenshot looked right;
  axe does not check SVG text at all. Only the CTM scale showed it, and it was
  wrong on 147 of 230 labels.
- Contrast resolved from DOM ancestors reports the page ground, not the **bar
  the label sits on**. Resolve the shape geometrically and sample a gradient at
  the label's own position.
- A build can silently drop CSS. Range-syntax media queries (`width <= Npx`)
  compiled fine and vanished from the output, so two responsive rules had never
  applied in production.

Whenever a value passes through a scale, a transform, a container query or a
minifier, the declared number is not evidence.

## Grade two kinds of row, never mixed

**Machine rows** assert a measurable fact and live in a script: a rendered size,
a contrast ratio, a bounding box, an absence of overflow. **Eyes rows** name one
artifact and one question, and a human answers.

When a row could be either, make it machine. A model grading its own aesthetic
output converges on "looks good to me", so it never awards the aesthetic grade.

Write every new finding into the rubric **before** fixing it, and keep the closed
rows — a closed row is how a returning regression gets noticed. One row here was
recorded as fixed for weeks while the fix sat on a class no page rendered.

## Stop when the loop goes dry

Two consecutive passes that add no new rows. Not a score, and not one clean pass.

Expect the find-rate to rise when the method sharpens — going from full-page
shots to 1:1 frames, or adding a width, finds things the old method could not
see. That is the method working, and it means only passes run under the *same*
method compare.

## Verify the evidence before reading the verdict

A capture can fail in ways that read as success.

- A tile that comes back **one flat colour** captured nothing, but downstream it
  looks like an empty page and gets reported clean.
- `screenshot({ clip, fullPage: true })` sends Chromium down its
  capture-beyond-viewport path, which **re-rasterises without device
  emulation** — every `(pointer: coarse)` and `(hover: hover)` rule renders in
  its desktop form whatever the context said. Scroll the band into view and clip
  relative to the viewport instead.
- A dev toolbar sits on top of the page and invalidates a whole review round.
  Capture from a production build.
- Set `hasTouch` and `isMobile` on phone contexts, or the media queries lie.

Count the tiles and check for flat ones before anyone reads a frame.

## Lighthouse

Split the floors by whether the local number means anything.

**Hard, stable locally:** accessibility 100, best-practices 100, CLS < 0.001.
**Advisory, because machine load swings them 10+ points:** performance, TBT.

Audit more than the landing page. Each template is a new way to be slow, and a
route list of one says nothing about the others. Read the main-thread breakdown
rather than the score: `styleLayout` dominating means style invalidation, not
script — an inheriting registered property written on a large subtree
invalidates all of it every frame.

## Split touch targets by role

WCAG 2.5.8's 24px is the floor and applies to everything. A larger design target
applies to the controls a visitor **must** hit to finish a task. Reporting one
flat number makes the primary navigation control and a suggestion chip the same
failure, which is a row that stays red for months telling nobody which matters.

## Playwright, the parts that waste an hour

- `video.saveAs()` copies rather than moves; the hash-named original stays
  behind. Call `await video.delete()` after, and guard it.
- A video only finalizes on `context.close()`. Take the handle with
  `page.video()` first, close the context, then `saveAs`.
- Close every context, or the run never exits and reads as a hang.
- `javaScriptEnabled: false` breaks `page.evaluate` but not locators — the
  injected utility script runs in an isolated world. Write no-JS assertions with
  locators only.
- A fresh context is a fresh session, so anything gated on `sessionStorage`
  replays. That is how a once-per-session intro gets filmed.
- Kill the old dev server, then poll until the new one answers. Never sleep a
  fixed count — and give a cold production build minutes, not seconds.
- macOS has no `timeout`.
- Never rebuild while a gate is running. The asset hashes change underneath it
  and every lazy import 404s, which reads as a page defect.

## Cost

Local dev servers bill nothing; run them freely. A deploy spends, so it happens
only when the user asks for it in those words, and a production flag never runs
without approval in the same message.

## Boundaries

This skill owns the verification method. A project's own `verify-site` overrides
it and owns that project's ports, scripts, route list and widget drills. The
design spec, where one exists, decides what the screenshots are judged against.
