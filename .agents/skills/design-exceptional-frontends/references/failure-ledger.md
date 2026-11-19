# Failure ledger: defects to prevent before the user sees them

This reference converts recurring frontend failures into mandatory preflight rules. Apply every relevant entry before presenting work. Do not wait for user feedback to discover these defects.

## Contents

1. How to use this ledger
2. Hierarchy and visual weight failures
3. Redundancy and copy failures
4. Border, material, and surface failures
5. Component abstraction failures
6. Control and cursor failures
7. Focus and selection-highlight failures
8. Motion failures
9. Responsive and rendering flicker failures
10. Overlay and layering failures
11. Theme-system failures
12. Settings and account-surface failures
13. Collection/detail workspace failures
14. Data and demo-content failures
15. Completion claims that are forbidden

## 1. How to use this ledger

For every user-facing change:

1. Mark each relevant defect class as **not applicable**, **prevented by design**, or **verified**.
2. Inspect the rendered state that could expose it.
3. Fix the highest shared cause: vocabulary → tokens → primitive → pattern → composition.
4. Add a regression check when the defect is behavioral, cross-theme, responsive, or likely to recur.
5. Never rely on “I intended it to look/behave correctly.” Use computed styles, geometry, screenshots, or interaction tests.

## 2. Hierarchy and visual weight failures

### Failure: information vomited into one vertical stack

**Symptoms**

- title, status, metadata, description, and controls appear as equally spaced rows;
- the eye has no obvious first destination;
- every block starts at the same edge and uses similar weight;
- a detail view reads like a database dump.

**Prevent**

- name the dominant object and next action before layout;
- keep identity/status compact in the header;
- give primary content the largest spatial claim;
- move decision-support metadata into a compact aligned region;
- group metadata with a definition list, two-column matrix, or table rather than prose stacking;
- cap hierarchy at three tiers in one region.

**Verify**

- perform a squint test;
- identify first, second, and third visual destinations in under three seconds;
- confirm metadata does not compete with title or primary content.

### Failure: zero alignment and arbitrary padding

**Symptoms**

- modal title does not align with body content;
- close control feels vertically detached;
- left and right columns begin at unrelated edges;
- top/bottom padding looks unequal despite equal numeric values.

**Prevent**

- define a small set of alignment anchors;
- align modal title, section content, and primary controls intentionally;
- account for icon/glyph optical bounds;
- adjust title padding optically after screenshot review;
- ensure nested radii and padding are concentric.

**Verify**

- overlay vertical guide lines on screenshots or compare bounding-box coordinates;
- compare perceived top and bottom mass, not only computed padding;
- inspect at 1x and high-density rendering.

### Failure: poor use of space disguised as minimalism

**Symptoms**

- large empty regions have no compositional purpose;
- content is cramped inside one corner of a large modal;
- important content is too small while decorative emptiness dominates;
- a layout removes useful information merely to look sparse.

**Prevent**

- use empty space to separate groups or emphasize the primary object;
- increase the spatial claim of primary content before adding decoration;
- recompose into columns when scanning improves;
- preserve useful density in comparative/operational surfaces.

**Verify**

- ask what each major empty region accomplishes;
- inspect whether primary content owns more area than secondary chrome;
- test sparse and dense data.

## 3. Redundancy and copy failures

### Failure: unnecessary identity or repeated labels

**Example classes**

- username repeated inside Settings opened from the user's avatar;
- section title repeated immediately as a field label;
- object identity shown in header, card title, and metadata again;
- status expressed by rail, icon, badge, and text simultaneously.

**Prevent**

- show identity once per context unless disambiguation is necessary;
- remove content that does not change a decision;
- prefer one strong status mechanism plus accessible text;
- run a dedicated deletion pass.

**Verify**

- list every repeated noun and identity string on the screen;
- justify each repetition or delete it.

### Failure: vague state language

**Symptoms**

- “In progress” could mean attempted, running, partially complete, queued, or active;
- “Done” hides success versus partial completion;
- “Error” gives no recovery.

**Prevent**

- name exact user-relevant state: Attempted, Partial score, Uploading, Judging, Awaiting approval;
- define aggregation semantics when one filter includes several internal states;
- use factual labels and recovery copy.

**Verify**

- ask whether two engineers could map the label to different states;
- test screen-reader names and URL restoration.

### Failure: raw implementation values leak into UI

**Examples**

- `score-desc`, `created_at`, `in-progress`, enum keys, database IDs;
- fallback rendering uses the raw stored value when lookup fails.

**Prevent**

- centralize typed `{ value, label }` registries;
- validate persisted/query values;
- render only the mapped label;
- use a deliberate fallback that does not expose the value.

**Verify**

- enumerate every select/filter/sort state;
- search templates for internal values;
- test invalid and newly added values.

## 4. Border, material, and surface failures

### Failure: borders added one by one in a soft borderless product

**Symptoms**

- white outline around main view, modal, select, segmented item, or button;
- each new component invents another edge;
- fixes require removing borders component by component.

**Prevent**

- define shared control, floating, overlay, and structural surfaces;
- separate with whitespace, alignment, and luminance first;
- keep borders zero by default in soft material primitives;
- reserve information-bearing lines and true structural edges.

**Verify**

- search all component CSS for border declarations;
- inspect every visible edge in every theme;
- justify each line by information or affordance.

### Failure: divider language contradicts the product

**Symptoms**

- decorative horizontal lines appear in a product whose header and controls use soft surface shifts;
- dividers proliferate because grouping is weak;
- a request for one divider becomes a new global design language.

**Prevent**

- treat the latest established product language as the system;
- use spacing and alignment for semantic grouping;
- use lines only when they report data, connect state, or separate genuinely adjacent planes;
- never extrapolate a one-off divider request into decorative repetition.

**Verify**

- remove each line temporarily; if comprehension is unchanged, delete it;
- compare to sibling surfaces.

### Failure: jarring rectangular side panel

**Symptoms**

- a sidebar is differentiated by a sharply darker rectangle unrelated to surrounding materials;
- the panel feels pasted on rather than structurally integrated;
- radius or background changes at an arbitrary seam.

**Prevent**

- use structural grid placement, shared support material, and whitespace;
- reserve hard surface changes for true spatial planes;
- align the panel with existing shell edges;
- avoid black-on-near-black rectangles as the only separation cue.

**Verify**

- inspect the seam at full brightness and in grayscale;
- compare its surface role with toolbar/header/ledger support planes.

### Failure: borderless control becomes invisible

**Symptoms**

- select looks like plain text plus a chevron;
- control surface equals modal surface;
- user cannot tell where to click.

**Prevent**

- define a distinct semantic control fill and control-hover fill;
- preserve a confident control silhouette and padding;
- use familiar disclosure iconography;
- add a border only if material shift cannot meet affordance/contrast requirements.

**Verify**

- compare computed control and parent background colors;
- inspect at a glance without hover;
- confirm the entire silhouette is clickable.

## 5. Component abstraction failures

### Failure: repeated local patches

**Symptoms**

- same border, cursor, z-index, press, or theme fix repeated in multiple files;
- a new theme requires component edits;
- changing one button leaves other buttons inconsistent.

**Prevent**

- audit all occurrences before editing;
- repair semantic token or shared primitive;
- give composite items, surfaces, and controls shared classes/contracts;
- add regression coverage against multiple consumers.

**Verify**

- search for duplicate property/value pairs;
- demonstrate that one shared change updates at least two consumers;
- add a new theme/option in one registry and confirm propagation.

### Failure: abstraction exists but at the wrong level

**Examples**

- button component exists, but cursor behavior is missing from role-based controls;
- floating surface exists, but local z-index overrides hide modal selects;
- theme tokens exist, but controls still use hard-coded dark-mode colors;
- motion engine exists, but component `transition` shorthands delay active state.

**Prevent**

- define behavior by semantic role, including non-native primitives;
- audit cascade priority and portal behavior;
- inspect actual consumers, not only the abstraction file;
- test computed results.

**Verify**

- use browser-computed style for cursor, z-index, background, transition, outline;
- test one native and one role-based consumer;
- test inside and outside an overlay.

## 6. Control and cursor failures

### Failure: clickable element uses default cursor

**Prevent**

- centrally cover `button`, `a[href]`, `select`, and role-based `button`, `menuitem`, `option`, `checkbox`, `radio`, and `switch`;
- centrally cover disabled states with not-allowed cursor;
- avoid setting pointer cursor on noninteractive containers.

**Verify**

- test computed cursor for native button, select trigger, option, menu item, checkbox, switch, and disabled variant.

### Failure: pressed feedback occurs after release

**Cause**

- background/box-shadow transitions ease into `:active`;
- state is changed only by `click`, which fires after pointer release;
- selected state is mistaken for contact state.

**Prevent**

- set contact state on capture-phase `pointerdown` and keydown;
- make contact material immediate (0ms into contact);
- use a 70–110ms release only;
- separate transient pressed state from persistent selected state.

**Verify**

- hold pointer down without releasing;
- assert pressed attribute and visual material while down;
- assert release begins only after pointerup;
- repeat with Space/Enter.

### Failure: press motion feels rubbery or janky

**Symptoms**

- 1–2% scale on a wide row visibly shifts edges and blurs text;
- instant scale-down plus slow spring-back feels disconnected;
- multiple effects (scale, tint, inset border, translate) stack.

**Prevent**

- keep geometry fixed for ordinary buttons and wide controls;
- use one low-opacity material imprint or tonal shift;
- use no bounce and no spring by default;
- preserve exact bounding box during press;
- make release short and interruptible.

**Verify**

- compare bounding boxes before and during press; require equality;
- sample contact and release frames;
- inspect small icon, primary, secondary, full-width, and selected controls.

## 7. Focus and selection-highlight failures

### Failure: random white outline appears after pointer interaction

**Cause**

- programmatic focus restoration triggers `:focus-visible` heuristics;
- modality listener installs after first interaction;
- menu item uses both managed highlight and global outline;
- Tux/high-contrast theme makes a subtle ring enormous.

**Prevent**

- install pointer/keyboard modality capture before hydration;
- default to keyboard-safe modality;
- pointerdown sets pointer before focus moves;
- meaningful keydown sets keyboard before focus moves;
- show standalone ring only for keyboard modality;
- remove duplicate outlines from managed menu/option items;
- preserve data-highlighted background for keyboard use.

**Verify**

- hard refresh and immediately click avatar/menu;
- open/close dialog with pointer and inspect restored trigger;
- open with keyboard and confirm ring/highlight;
- inspect computed `outline`, `box-shadow`, modality attribute, and active element;
- test every high-contrast theme.

### Failure: focus is removed everywhere to hide the bug

**Prevent**

- never apply unconditional global `outline: none`;
- scope suppression to pointer modality or managed composite items;
- keep a 2px or similarly perceivable neutral keyboard ring with offset;
- test Tab order and focus restoration.

## 8. Motion failures

### Failure: animation diarrhea

**Symptoms**

- every dropdown item, button child, icon, and label animates independently;
- decorative cascades and springs compete with content;
- inconsistent durations and easing curves proliferate.

**Prevent**

- animate one parent plane;
- use one named pattern for each category: press, flyout, dialog, sheet, disclosure, layout;
- cap ordinary duration at 90–220ms;
- prohibit decorative cascades;
- use motion only for continuity or feedback.

**Verify**

- count simultaneously animated elements;
- identify the purpose of every animation;
- remove each animation and keep it only if comprehension or continuity worsens.

### Failure: motion removed so aggressively that continuity disappears

**Symptoms**

- detail panel snaps open with no orientation cue;
- overlays appear/disappear abruptly despite spatial origin;
- fixing flicker removes all motion instead of repairing sequence.

**Prevent**

- retain one restrained plane-level transition;
- resolve final responsive anatomy before public reveal;
- synchronize panel and content instead of delaying one after the other;
- use direct change only when continuity adds less value than instability.

**Verify**

- confirm opening communicates origin and destination;
- confirm content begins with the panel, not 200ms later;
- confirm no child flicker.

### Failure: content fades or slides after its panel

**Prevent**

- start content reveal in the same frame as panel motion unless sequencing is explicitly meaningful;
- use shared duration/easing roles;
- do not wait for a full layout animation and then animate content left;
- keep opacity and translation subtle (typically 4–8px, 140–200ms) and concurrent.

**Verify**

- record timestamps for panel start and content opacity/translation start; require same frame or less than one frame difference.

## 9. Responsive and rendering flicker failures

### Failure: metadata flickers while detail opens

**Cause**

- detail track animates from zero width;
- container queries switch one-column/two-column anatomy mid-transition;
- the same difficulty/source exists in both collapsing list and opening detail;
- child opacity fades and layout transition overlap.

**Prevent**

- remove per-field fades;
- animate one parent plane;
- pin inner detail canvas to final width while outer track reveals it, or hide until final geometry and reveal the whole plane;
- avoid simultaneously rendering duplicate visible representations;
- choose final compact/wide ledger anatomy once, not through staged intermediate classes.

**Verify**

- sample difficulty/source bounding boxes each animation frame;
- confirm their internal relative geometry does not jump;
- confirm opacity is plane-level and synchronized;
- test widths just above/below container thresholds.

### Failure: number or label suddenly appears

**Cause**

- element mounts after container transition;
- visibility toggles independently of parent reveal;
- font or data arrives after paint without reserved geometry.

**Prevent**

- mount stable content with the plane when safe;
- reveal parent content as one unit;
- reserve geometry for delayed data;
- preload/choose font strategy that preserves metrics;
- do not animate individual metadata late.

**Verify**

- record first visible frame for every sibling field;
- require the field to follow the same opacity timeline as its group.

### Failure: text flickers on hard refresh or 404

**Prevent**

- use a stable font loading strategy (`optional`, preload, or metric-compatible fallback as appropriate);
- server-render first useful content;
- avoid hydration-only replacement of error text;
- reserve exact headline geometry;
- keep error copy deterministic.

**Verify**

- hard reload with cache disabled repeatedly;
- measure headline bounding box from first paint through font settle;
- test actual error routes, not only in-app navigation.

## 10. Overlay and layering failures

### Failure: dropdown exists but cannot be seen inside modal

**Cause**

- portaled dropdown layer below modal content/scrim;
- local z-index assumes DOM nesting controls stacking;
- floating surface has same material as modal.

**Prevent**

- centralize layer tokens;
- order sheet < modal < floating menu/select/tooltip;
- remove local z-index overrides from floating components;
- use floating material distinct from modal;
- test portal output in real overlay.

**Verify**

- open select inside modal;
- assert list bounding box is visible and above modal;
- compare computed z-index and background;
- test escape and focus restoration.

### Failure: tooltip prevents modal from closing with one Escape

**Prevent**

- do not auto-open tooltip on an auto-focused modal close button;
- allow tooltip suppression where accessible label is sufficient;
- test nested dismissal priority.

## 11. Theme-system failures

### Failure: custom theme changes background but not components

**Symptoms**

- high-contrast theme still uses dark theme's teal selected option;
- dropdown material, switch, selected rows, or press overlay use wrong family;
- components contain theme conditionals.

**Prevent**

- define every semantic token for every theme;
- keep components theme-blind;
- include control, floating, selection, inverse text, semantic states, focus, scrim, shadow, logo, and press roles;
- test theme propagation with open overlays and selected/pressed states.

**Verify**

- capture matrix: page, modal, select-open, menu-open, switch-on, selected item, pressed control, focus ring;
- search component CSS for theme selectors and hard-coded colors.

### Failure: growing theme list clips

**Prevent**

- use centralized registry;
- use segmented control only for a tiny fixed short set;
- switch to scrollable select/searchable picker before the fourth long label clips;
- ensure the selected label is fully visible.

**Verify**

- add a deliberately long theme name;
- test localization and 200% zoom;
- assert no truncation of the only identifying label.

## 12. Settings and account-surface failures

### Failure: Settings expands inside avatar menu

**Prevent**

- keep avatar menu compact;
- expose Settings as a menu action;
- open a centered, focus-trapped modal/window for settings;
- close/dismiss menu before or with modal without visible overlap;
- restore focus to avatar trigger on close according to modality.

### Failure: settings looks like stacked labels with no balance

**Prevent**

- use a stable settings-section pattern with section identity/description and aligned control region;
- use a large but bounded centered window;
- align title/body/control edges;
- avoid username/profile repetition;
- avoid Save for immediate local preferences;
- select the correct control for option cardinality.

**Verify**

- inspect title padding and close alignment;
- inspect desktop column balance and mobile reflow;
- ensure every control is connected to persisted behavior.

## 13. Collection/detail workspace failures

### Failure: opening detail always leaves list as sidebar

**Prevent**

- default to focused full-width detail when that is the primary task;
- provide an explicit “Show list” control;
- allow a user preference for default sidebar behavior only if useful;
- preserve list mount, filters, search, sort, selection, and scroll.

### Failure: detail header and metadata overwhelm primary content

**Prevent**

- keep title/status compact;
- give statement/content the dominant plane;
- place metadata once in a bounded overview region;
- remove decorative panels and dividers;
- ensure collapse/list controls are quiet utilities.

### Failure: selected list/sidebar uses a jarring dark slab

**Prevent**

- use shared structural material and grid anatomy;
- differentiate through width, alignment, and support surface;
- avoid arbitrary black rectangular backgrounds.

## 14. Data and demo-content failures

### Failure: real/private/recognizable content leaks into fixtures

**Prevent**

- generate deterministic fictional identifiers and display names;
- keep sources/authors from an approved fictional pool;
- isolate demo data from production fallback;
- type fixtures.

### Failure: demo status distribution looks fake

**Prevent**

- scatter solved, partial, failed/attempted, and untouched states deterministically;
- include varied scores and realistic metadata combinations;
- maintain stated totals accurately;
- test connected state visuals with consecutive and interrupted runs.

## 15. Completion claims that are forbidden

Do not say “fixed,” “premium,” “polished,” “consistent,” or “complete” when any of these remain:

- uninspected screenshots;
- clipped labels;
- warnings in static checks;
- untested pointer-down behavior;
- random focus rings;
- hidden modal dropdowns;
- raw internal labels;
- theme leakage;
- visible responsive reflow during motion;
- late child animation;
- one-off border/cursor/z-index patches;
- no narrow-layout verification;
- no hard-refresh/first-paint check for a reported flicker;
- no regression test for a behavioral root cause.
