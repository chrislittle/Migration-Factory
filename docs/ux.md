# docs/ux.md - how this product looks, and who decides

Every rule here has a reason and a check. A rule nothing checks is a
preference, and preferences drift - this file exists because eight pages each
deciding for themselves produced mismatched fonts, clipped cards, three names
for one action and a button that wrapped mid-phrase, all in a single day.

There are **two themes and the person chooses**: dark is **Bootswatch Darkly**,
light is **Bootswatch Spacelab**. Each palette is used as published where it
clears 4.5:1 on the surface it actually sits on, and shifted - hue kept, so red
still reads as red - where it does not. Bootswatch holds itself to 2.65:1 and we
hold 4.5, so both needed work: five of Darkly's colours, four of Spacelab's.

The choice is remembered; with no choice the operating system decides.

## 1. One stylesheet. No page-level CSS.

`src/dashboard/app.css` is the only place a rule may be written. A page carries
markup and behaviour, never appearance. A page's own rules live in that file
too, scoped by the body class it already carries (`.p-waves`, `.p-wizard`).

WHY: 47 selectors were defined identically on three or more pages and 16 had
already drifted - `.wrap` in six variants, `.card .ch` in four. A shared look
with no shared home is not a system; it is a coincidence that decays.

CHECK: `Stylesheet.Tests.ps1` fails when a page contains a style block.

## 2. Tokens only. Never a colour literal.

`app.css` is the only file in `src/dashboard` allowed to contain `#rrggbb`, and
inside it only the `:root` block may. Not the markup, not an inline
`style=""`, not a JavaScript fallback like `var(--bad, #b91c1c)`.

WHY: 42 distinct colour values across eight files, 200 of them outside any
token block, and seven more hiding in inline style attributes where the first
sweep never looked. Nobody could say which grey meant "border".

CHECK: `Stylesheet.Tests.ps1`.

## 3. A meaning has more than one colour, and they are not interchangeable.

On a white ground `--bad` did four jobs at once. On a dark ground they separate,
and each needs its own value:

| job | token | example |
| --- | --- | --- |
| text on a card | `--bad` | a failure message |
| the chip behind a pill | `--bad-soft` | the pill background |
| text on THAT chip | `--bad-on` | the pill's own label |
| a filled control | `--brand-fill` | the primary button |

The fill is the one that catches people out: lightening `--brand` so it reads
as text on a dark card made it *worse* as a button background - white on the
lightened blue is 2.9:1, on Darkly's published `#375a7f` it is 7.2:1. Bootswatch
splits these for the same reason.

Text on the navigation bar is a fifth ground again: `--on-nav`, `--on-nav-dim`.

A chip's text is measured against THE CHIP, never against the card behind it.
`--bad` reads at 4.5 on a card and 3.9 on `--bad-soft` - which is the whole
reason `--bad-on` exists. The run-error message carried the bare token, and no
rendered sweep could see it: the element is `display:none` until a run fails, so
it has no layout at all. **A colour that only appears on a bad day is the one
nobody checks by looking.** Measured by a rule now, not by eye.

CHECK: `Stylesheet.Tests.ps1`.

## 3a. A token is declared AND used.

`--font` and `--mono` sat in `:root` unreferenced while `body` and five `.mono`
rules each restated their own stack. That is a colour literal wearing a
different property: the sheet claims to decide the font and then does not.
A token nothing uses is a comment that looks like a rule.

CHECK: `Stylesheet.Tests.ps1`.

## 3b. The worst surface decides the value, and which surface that is flips.

On dark the page (`#222`) is DARKER than a card (`#303030`), so the card is the
worst case. On light it inverts: the card is pure white and the page is tinted,
so the PAGE is worst - and `--card-2` is worse still. The light tokens were
first derived against the card and four of them passed there and failed on the
page. Check every plain surface, in both themes.

CHECK: `Theme.Tests.ps1`.

## 3c. A chip that hosts secondary text REDEFINES the token.

Anything with a `--*-soft` background is a ground of its own, so `--muted`
inside it reads 3.3 to 4.0, not 4.5. Three of these turned up in one sweep: an
alert metric card, a selected run row, a selected search result.

Do not list the three selectors - that fixes three and waits for the fourth.
Set `--muted: var(--bad-on)` **on the chip**: a custom property inherits, so
every descendant that already asks for `--muted` follows, including ones added
later. That is what a token set is for.

CHECK: `Theme.Tests.ps1`.

## 4. Semantic colour is not brand colour.

Good, warning and critical carry meaning and never change to match an accent.
The accent may change with the theme; a failure is the same red to the person
reading it.

## 5. Components come from the shared sheet, with every state they need.

Use its card, table, pill, button, form control. A component the sheet does not
have gets added to it WITH its states - hover, focus, disabled, empty - or it is
not a component, it is one page's exception.

"Its states" includes the ones the BROWSER supplies when you say nothing. A
`.btn` is an `<a>` on most of these pages, and an anchor is underlined by
default: every page's own CSS used to say `text-decoration:none`, and
collapsing eight copies into one sheet dropped it, so "Assess an estate" and
"Review" shipped underlined inside their own blue boxes. Nothing in the source
looked wrong.

CHECK: `Stylesheet.Tests.ps1`.

## 5a. A surface must differ from the surface behind it.

A control painted `--card` inside a card is the colour of the thing under it;
the only edge left is one border pixel. Six page rules had each restated the
input background as `--card`, all six inside cards, which is also how the wave
name field came to "highlight" on hover by painting itself the colour it was
already sitting on.

WHY: this is the failure a dark ground invites. On white, "background: white"
inside a white card was invisible in the same way, but every control had a
border and nobody noticed.

CHECK: `Stylesheet.Tests.ps1`.

## 6. Anything that opens must offer a way back.

A menu, panel, dialog or revealed form needs a visible way back AND an Escape
handler. One button with two states is the cheapest correct shape: open /
Close when the open part only shows information, open / Cancel when it holds
a choice that is not saved and closing throws it away. Escape does the same as
the button (CLOSE-NOT-CANCEL-1).

WHY: raised three times before it became a rule. A control you can
only commit to is a trap.

CHECK: `AccessRoles.Tests.ps1`, `tests/js/close-not-cancel.test.js`; CLAUDE.md hard rule 11.

## 7. Every word is ASD-STE100.

Short sentences, active voice, one meaning per word. Use the product's own nouns
and Azure's technical names; never invent a softer word for something that
already has one. "NVMe", not "the new disk type". "Assess and migrate", not
"Look and change".

CHECK: `tools/Test-SimplifiedEnglish.ps1`, in CI; CLAUDE.md hard rule 10.

## 8. One action, one name, everywhere.

If two pages offer the same action they use the same words. A narrower action
may have its own name, and then it must genuinely be narrower.

WHY: "Assess an estate", "Scan for machines" and "New assessment" were three
names for one thing, on three pages.

CHECK: `SharedNav.Tests.ps1`.

## 9. Controls are styled, not inherited.

Font AND surface. `font: inherit` was only half of it: an input with no
background falls back to the browser's white, which on a dark ground is the
most visible sign that nobody owns the styling. Darkly ships light inputs on
purpose; we do not follow it there, because a wizard with nineteen white boxes
reads as a rendering fault.

The sheet decides the surface; a page may change size and width, never colour.
`--bg` on a `--card` ground gives a recessed field with a real edge.

CHECK: `SharedNav.Tests.ps1`, `Stylesheet.Tests.ps1`.

## 10. Text lives inside its container.

Card copy goes in `.cardbody`, never straight into `.card`. A card with
`overflow:hidden` and no padding clips its own content at the right edge.

CHECK: `SharedNav.Tests.ps1`.

## 11. Contrast is measured, not eyeballed.

Every foreground clears 4.5:1 against the surface it actually sits on - 3:1 for
large text. Measured on the RENDERED page with alpha composited, not read off
the stylesheet: `rgba(255,255,255,.14)` on a blue bar is not white.

And not only colour: read the COMPUTED style off the rendered page for
decoration, white-space and surface too. The sweep to Darkly produced five
contrast failures that all looked fine in the source, including a primary
button whose label vanished into its own fill - then a second pass over the
rendered pages found three more that no contrast check would have caught: the
underlined buttons, the six duplicated control surfaces, and a hover that
painted its own ground.

## 12. State is visible in form, not only in colour.

A pill, a stripe, a weight - so a screen still reads for somebody who cannot
separate the reds from the greens, and so status survives a screenshot.

## 13. A page-scoped rule on a bare element outranks every shared class.

`.p-index a { color: ... }` is 0,1,1 and beats `.btn` at 0,1,0 - which is how
one page's link colour repainted the primary button on that page, because the
button is an anchor. Page sections may only scope CLASSES and IDS.

CHECK: `Stylesheet.Tests.ps1`.

## 14. New page = copy the SHELL, not the styles.

Start from the smallest existing page: its topbar container, its script tags,
its `app.css` link, its `p-<name>` body class. If you find yourself copying CSS,
rule 1 has already been broken.

---

## 14a. A shared control cannot ask the page for somewhere to live.

The bar drew the theme button and sign-out into `.topbar .right` and RETURNED
QUIETLY when a page had no such element. Seven pages had it, `access.html` did
not - so the admin page had no theme button, no sign-out, and the signed-in
name sat wherever the navigation left it instead of at the far right.

"Shared" that depends on eight pages having written the same markup is not
shared; it is seven coincidences and a bug. The bar BUILDS what it needs.

The same applied to the text: the signed-in identity was computed six ways
across eight pages, so admin showed a display name and overview showed an
address. One function owns it, and it shows the **address** - two Entra users
can have the same display name, and two test identities here are exactly that
pair. The display name goes in the tooltip.

CHECK: `Theme.Tests.ps1`.

## 15. An alpha is not a colour until you know what is behind it.

`rgba(255,255,255,.85)` reads 5.72 on Darkly's navbar and 4.35 on Spacelab's
lighter one. The active-tab pill LIGHTENS the bar on dark and must DARKEN it on
light, or the white label it contains drops to 3.41. So the nav alphas are
tokens per theme (`--on-nav-dim`, `--nav-hover`, `--nav-active`), not shared
constants - and rule 2 covers `rgba()`, not only hex.

CHECK: `Stylesheet.Tests.ps1`, and measured on the rendered page.

## 16. Anything that signs a person in must sign them out.

Found 2026-09-02: there was no sign-out for a user, and one is needed to test
the RBAC roles one identity at a time. Clearing our own token cache is
not signing out - the Entra session cookie signs them straight back in on the
next click, silently. Use the identity library's own sign-out, and give a
blocked popup a way through.

CHECK: `Theme.Tests.ps1`.

## 17. A document the product hands over has one stylesheet, and the theme reaches it as a mark.

The report and the migration record are documents, not pages: they open in a
frame with no script (SEC-REPORT-1), or as a saved file. Their one stylesheet
is the report's (`$script:VmfReportCss`), with the dashboard's own light and
dark values, and the record reads it from the service - never a copy in a
page. The page that shows the report writes `data-theme` on its root from the
theme it SHOWS; with no mark the operating system decides; print is light; and
every file the product hands over is marked light, because the person who
opens it is not the person who saved it (REPORT-THEME-1).

CHECK: `ReportTheme.Tests.ps1`, `tests/js/report-theme.test.js`.

---

WHEN A RULE IS WRONG: change it here first, with the reason, then change the
code. A rule worked around in one page is a rule that no longer applies to any
page.
