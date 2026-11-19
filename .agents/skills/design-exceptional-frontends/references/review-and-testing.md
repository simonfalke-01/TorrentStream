# Review, visual QA, and release gates

Use this reference before completing any user-facing frontend change. Treat gates as pass/fail. Do not replace visual inspection with static checks.

## Contents

1. Required evidence
2. Preflight review
3. Visual hierarchy review
4. Spacing and alignment review
5. Component-system review
6. Interaction-state matrix
7. Focus and keyboard review
8. Motion review
9. Theme review
10. Responsive review
11. Content and data review
12. Rendering stability review
13. Performance review
14. Automated regression patterns
15. Final scorecard
16. Definition of done

## 1. Required evidence

Collect evidence proportional to risk:

- rendered screenshots at desktop and narrow width;
- screenshots of open modal/menu/select/sheet where changed;
- computed-style checks for cursor, outline, z-index, background, motion, and contrast-sensitive roles;
- pointer and keyboard interaction tests;
- frame samples for reported flicker or timing defects;
- hard-refresh checks for first-paint defects;
- formatting/static checks;
- production build;
- relevant automated tests;
- full suite when shared primitives/tokens change.

If the user reports a visual bug with a screenshot, reproduce the exact state before claiming the root cause. If exact reproduction is unavailable, state the assumption and inspect adjacent states.

## 2. Preflight review

Before coding, record:

- route/surface job;
- dominant object;
- primary action;
- persistent context;
- affected primitives/tokens;
- impacted themes;
- impacted viewport ranges;
- impacted input modalities;
- existing design-language constraints;
- likely failure-ledger entries.

Do not edit until the abstraction level is identified.

## 3. Visual hierarchy review

### Squint test

At 25–50% zoom or with a blurred screenshot, answer:

1. What region is darkest/heaviest?
2. What text is largest/heaviest?
3. What color is most saturated?
4. What has strongest enclosure/elevation?
5. Do these point to the intended primary object/action?

Fail if two or more unrelated regions compete as primary.

### Reading-order test

Without interacting, identify expected gaze order. Require:

- identity/context before actions that depend on it;
- primary content before tertiary metadata;
- one obvious next action;
- recovery located near failure;
- no metadata wall before main content.

### Visual-weight inventory

List every element using:

- accent color;
- bold weight;
- large type;
- elevated surface;
- border/outline;
- animation.

Justify each. Reduce any secondary element using more than two strong-weight techniques.

## 4. Spacing and alignment review

### Edge audit

Capture bounding boxes or overlay guides for:

- route title;
- primary content start;
- section headings;
- control labels and fields;
- modal title/body;
- table header/cells;
- left/right pane edges;
- close/action controls.

Fail if sibling elements intended to align differ by unexplained 1–8px offsets.

### Proximity audit

For each group, verify:

- inner gap < outer gap;
- heading closer to its content than previous content;
- label closer to its control/description than adjacent setting;
- metadata rows form a visible unit;
- sections do not rely on dividers to compensate for equal spacing.

### Optical audit

Inspect:

- title top/bottom perceived balance;
- icon/text baseline;
- chevron center;
- circular/square button padding;
- modal close placement;
- nested radius concentricity;
- shadow influence on perceived bounds.

## 5. Component-system review

Search and fail on unexplained occurrences of:

- raw colors in component styles;
- repeated border/shadow/surface declarations;
- hard-coded z-index values;
- `transition: all`;
- theme selectors inside components;
- raw internal enum values in templates;
- local cursor fixes;
- local focus-ring suppression;
- duplicated modal/menu/select plumbing;
- long option arrays embedded in multiple components;
- motion-library imports added for routine interactions.

### Propagation tests

When changing a shared primitive or token, inspect at least:

- two different consumers;
- one overlay context;
- one narrow viewport;
- light, dark, and any custom/high-contrast theme;
- disabled/focused/pressed/selected state where applicable.

## 6. Interaction-state matrix

For every changed control, verify applicable cells:

| State | Visual | Semantic | Geometry |
|---|---|---|---|
| default | recognizable, quiet | correct name/role | stable |
| hover | restrained preview | no false selection | stable |
| focus-visible | keyboard-visible | correct focus target | stable |
| pressed | visible during contact | disabled ignored | exact same bounds |
| selected/on | persistent, distinct | ARIA/data state correct | stable |
| disabled | identifiable | native/ARIA disabled | stable |
| loading | action protected | busy status where needed | label/width stable |
| error | actionable | associated description | nearby targets stable |

Do not test only click result. Hold pointer down. Navigate by keyboard. Inspect disabled behavior.

## 7. Focus and keyboard review

### Required paths

- Tab forward/back through route;
- open every changed menu/select/dialog with keyboard;
- Arrow/Home/End/typeahead behavior where primitive supports it;
- Space/Enter activation;
- Escape dismissal;
- focus trap inside modal;
- focus restoration to launcher;
- skip link;
- Back/navigation restoration if applicable.

### Modality tests

1. Hard refresh, immediately pointer-click launcher: no keyboard ring.
2. Close overlay with pointer: restored launcher has no random ring.
3. Tab to launcher: ring visible.
4. Open with keyboard: menu item managed highlight visible.
5. Move pointer over item: no second white outline.
6. Switch high-contrast theme: results remain intentional.

Inspect `document.activeElement`, `:focus-visible`, modality dataset/state, `outline`, and `box-shadow` when a ring defect exists.

## 8. Motion review

For each changed transition, record:

- purpose;
- trigger event;
- start time;
- duration token;
- easing token;
- animated properties;
- interrupt behavior;
- reduced-motion behavior;
- final cleanup.

Fail if:

- purpose is decorative;
- child motion begins more than one frame after its plane without intentional sequence;
- pressed feedback begins after release;
- wide controls change bounds;
- responsive anatomy changes while visible;
- more than one independent child animation is unnecessary;
- duration exceeds 300ms for routine work;
- temporary styles remain;
- reduced motion still waits on animation timer.

### Frame sampling protocol

Sample every `requestAnimationFrame` for at least total duration + 100ms. Store:

- time;
- plane tracks/bounds;
- reported child bounds;
- opacity/translate/scale;
- display/visibility;
- motion state attributes.

Require monotonic, synchronized behavior and stable final geometry.

## 9. Theme review

Capture each theme in this matrix:

| Surface/state | Required capture |
|---|---|
| page | default route |
| support plane | toolbar/rail/table header |
| control | field/select resting and hover |
| modal | open settings/dialog |
| floating | menu/select open above modal |
| selection | selected nav/filter/option |
| semantics | success/warning/danger |
| switch | off/on |
| press | pointer held |
| focus | keyboard focus |
| error | error/empty state |

Verify semantic token completeness and WCAG contrast. Fail if a custom theme visibly inherits an unrelated theme's accent/material language unless that inheritance is intentional.

### Scalable preference test

Add or simulate:

- fourth/fifth option;
- long label;
- localized label;
- 200% zoom.

Fail if segmented items clip or selected identity is truncated. Switch to select/combobox.

## 10. Responsive review

Inspect at minimum 360, 390, 768–900, 1024, and 1440px widths. Inspect immediately above/below component breakpoints.

For each width verify:

- no document horizontal overflow;
- one primary task remains obvious;
- touch targets remain usable;
- critical identity/action/state remains;
- deferred metadata remains accessible;
- overlays fit viewport with inset;
- one scroll owner per region;
- tables/lists do not enter clipped intermediate widths;
- long text does not collide with actions;
- opening transitions do not cross visible anatomy states.

Use geometry assertions (`scrollWidth === clientWidth`, bounds inside viewport) in regression tests.

## 11. Content and data review

Test:

- no data;
- one item;
- hundreds/thousands of items;
- long English;
- CJK;
- RTL;
- large numbers;
- null/unrated/missing values;
- multiple authors/tags;
- all statuses;
- invalid persisted/query value;
- filtered empty state;
- stale/offline/partial state.

Fail on:

- leaked internal IDs;
- stale hard-coded totals;
- duplicated identity;
- vague status;
- essential hover-only metadata;
- fake recommendation/progress/difficulty/activity;
- real/private names in fixtures without authorization.

## 12. Rendering stability review

### Hard-refresh matrix

Test normal route, detail route, modal preference restoration, and error/404 route with:

- warm cache;
- disabled/empty cache;
- throttled load where practical;
- light/dark/custom persisted theme.

Measure from first paint through settled state:

- headline/content bounds;
- font family/weight;
- theme dataset;
- control label;
- selected state;
- overlay presence;
- layout tracks.

Fail if text, theme, selection, or layout visibly swaps after first paint without necessary async cause.

### Layout-shift review

Reserve geometry for known async content. Do not allow loading indicators, validation, or metadata to move primary targets unexpectedly. Use stable row and button dimensions.

## 13. Performance review

Check:

- no large dependency added for trivial behavior;
- no duplicated render tree for desktop/mobile without a strong reason;
- virtualize genuinely large lists;
- no unbounded DOM growth;
- avoid expensive filters/blur on large fixed regions;
- animate opacity/transform-like properties when possible;
- use layout animation only when measured and necessary;
- images/fonts have dimensions or stable metrics;
- no repeated event listeners without cleanup;
- motion engine cancels and releases references.

## 14. Automated regression patterns

### Cursor contract

Assert computed cursor for native button, role button, menu item, option, checkbox/switch, and disabled variant.

### Press contract

Move pointer to target, call mouse down, assert contact state/material and unchanged bounding box, then mouse up and assert release.

### Focus-modality contract

Use pointer to open/close and assert no outline. Use Tab to focus and assert visible outline. Inspect composite highlighted item separately.

### Overlay-layer contract

Open a select inside a modal. Assert list visible, bounding box within viewport, computed z-index above modal, and selected option visible.

### Theme contract

Select each theme through UI, assert persisted ID, root theme attribute, and distinct semantic token values. Open floating surface and check propagation.

### Motion synchronization

Install frame sampler before activation. Assert plane/content start within one frame and reported metadata geometry does not jump between responsive anatomies.

### First-paint stability

Observe element bounds with `requestAnimationFrame` from navigation through fonts ready. Assert expected tolerance (usually 0–1px depending rendering).

### Collection preservation

Set filter/search/sort and scroll, open detail, use Back/close, assert state and scroll restored.

## 15. Final scorecard

Score each 0, 1, or 2:

- task clarity;
- primary hierarchy;
- visual-weight discipline;
- alignment;
- spacing/grouping;
- copy precision;
- component consistency;
- theme completeness;
- control affordance;
- pointer behavior;
- keyboard/focus behavior;
- responsive composition;
- motion restraint/continuity;
- rendering stability;
- empty/error/loading states;
- accessibility;
- performance/dependency discipline;
- verification evidence.

Interpretation:

- **36/36:** ready to present.
- **33–35:** fix remaining defects before presenting unless they are explicitly out of scope.
- **30–32:** not polished; continue.
- **below 30:** structural redesign required.

No category may score 0. A perfect total is not a substitute for user-specific instructions.

## 16. Definition of done

Do not finish until all applicable statements are true:

- Job, focus, primary action, and persistent context are explicit.
- One dominant object survives the squint test.
- No unnecessary element survives the deletion pass.
- Alignment edges and spacing groups are intentional.
- Components consume semantic roles.
- Shared defects are fixed at shared level.
- Controls look interactive without arbitrary outlines.
- Pointer cursors and disabled cursors are automatic.
- Pointer focus does not create random keyboard rings.
- Keyboard focus remains visible.
- Overlay layering works inside other overlays.
- Themes propagate through controls, floats, selection, semantics, and press.
- Long/growing option sets use scalable controls.
- Press feedback exists during contact, not after release.
- Button geometry stays fixed.
- Panel/content motion is synchronized.
- Responsive anatomy does not flicker publicly.
- Hard refresh has no text/theme/layout flash.
- Empty/loading/error/stale/offline states are honest.
- 360px and desktop screenshots are inspected.
- Formatting and static checks have zero warnings.
- Production build passes.
- Relevant regression tests pass.
- Full suite passes after shared primitive/token changes.
