# Motion, interaction feedback, and rendering stability

Use this reference for animations, press feedback, overlays, responsive transitions, hydration, font loading, flicker, and layout stability.

## Contents

1. Motion purpose test
2. Default motion budget
3. First-party motion layer
4. Press contract
5. Hover and selection
6. Flyouts, dialogs, sheets, and disclosures
7. Structural layout transitions
8. Responsive reflow during animation
9. Interruption and cleanup
10. Reduced motion
11. First paint and hydration
12. Font stability
13. Async rendering
14. Frame-level verification
15. Prohibited motion patterns

## 1. Motion purpose test

Add motion only if it performs at least one function:

- acknowledges direct contact;
- explains where a surface came from or went;
- preserves spatial orientation through a layout change;
- connects cause and effect;
- communicates state progression that cannot be understood instantly;
- reduces perceived discontinuity without delaying the task.

Remove motion if it:

- decorates an already clear change;
- delays content or feedback;
- exposes responsive breakpoints or duplicate render trees;
- makes controls feel elastic, toy-like, or imprecise;
- causes layout shift, raster blur, or text flicker;
- exists only because a motion library is available.

Write the purpose in one clause before implementing. If the clause is “make it feel premium,” do not implement yet; define the actual continuity or feedback function.

## 2. Default motion budget

Use these as strict defaults, then tune only with visual evidence:

| Pattern | Duration | Distance/geometry | Easing |
|---|---:|---:|---|
| press contact | 0ms material response | no layout movement | immediate |
| press release | 70–110ms | no bounce | standard out |
| hover/color | 100–160ms | none | standard |
| tooltip/flyout enter | 120–160ms | 2–4px or 0.985–1 surface scale, never both if busy | emphasized out |
| flyout exit | 90–130ms | reverse enter | accelerated in |
| dialog enter | 160–220ms | opacity plus at most 0.985–1 surface scale | emphasized out |
| sheet enter | 160–220ms | 8–16px or edge travel if spatially necessary | emphasized out |
| disclosure | 160–220ms | measured content height | standard/emphasized out |
| structural layout | 160–240ms | actual plane movement | emphasized out |
| content reveal with plane | 140–200ms | 4–8px maximum | start same frame as plane |

Do not exceed 300ms for routine application interaction. Do not use a spring for routine controls. Do not use independent one-off easing curves.

Recommended cubic-bezier roles:

- standard: `cubic-bezier(0.2, 0, 0, 1)`;
- emphasized enter: `cubic-bezier(0.16, 1, 0.3, 1)`;
- exit: `cubic-bezier(0.4, 0, 1, 1)`.

## 3. First-party motion layer

Prefer native CSS and Web Animations API behind a small product-owned layer. Avoid adding a large motion dependency for ordinary application transitions.

The layer should provide:

- centralized duration/easing/distance tokens;
- named CSS presence patterns;
- animation channels per element;
- cancellation/interruption;
- sequence and parallel orchestration when genuinely needed;
- reduced-motion resolution;
- delegated pointer/keyboard press state;
- cleanup on unmount and blur;
- no framework-specific requirement where possible.

### Channel contract

Store active animations per element and channel (`press`, `presence`, `layout`, etc.). Starting a new animation on the same channel must cancel the old one before sampling a new start state. Do not cancel unrelated channels.

### CSS contract

Use named classes such as:

- `motion-flyout`;
- `motion-dialog`;
- `motion-sheet-right`;
- `motion-disclosure`;
- `motion-layout`;
- `motion-content-reveal`.

Do not author slightly different keyframes in every component.

## 4. Press contract

### Required event timing

- Pointer: enter pressed state on capture-phase primary-button `pointerdown`.
- Pointer: leave on `pointerup`, `pointercancel`, window blur, or cleanup.
- Keyboard: enter on non-repeated Space/Enter keydown.
- Keyboard: leave on Space/Enter keyup or blur.
- Ignore disabled, `aria-disabled`, and primitive-disabled controls.

### Required visual behavior

- Show contact while the pointer/key is still down.
- Keep bounding box unchanged.
- Keep text rasterization stable.
- Use one restrained material response: tonal overlay, surface change, or subtle inset—not a stack.
- Remove contact with a 70–110ms release.
- Separate contact from persistent selected/toggled state.

### Prohibit

- changing state only on `click`;
- easing slowly into `:active`;
- scale on full-width rows or ordinary buttons;
- 1.5% shrink followed by a spring return;
- an imprint that appears after release;
- press motion on disabled controls;
- pointer-only feedback.

### Required tests

During pointer hold, assert:

- pressed data/state is present;
- computed contact material is visible;
- bounding rect exactly matches resting rect;
- release has not started.

After release, assert:

- pressed state is removed;
- release settles within the token duration;
- persistent selection is correct.

Repeat with keyboard.

## 5. Hover and selection

Hover is preview, not commitment. Selection is persistent state. Press is contact. Never make these visually indistinguishable.

- Hover: small material/foreground change.
- Press: immediate transient contact.
- Selected: durable accent or structural indicator.
- Focus-visible: neutral high-contrast navigation indicator.

Do not animate selection through a delayed imprint. Do not use a selected border if the system uses filled rounded controls. Do not add both selection rail and selected slab unless both encode different information.

## 6. Flyouts, dialogs, sheets, and disclosures

### Flyout

Use opacity plus either 2–4px origin-aware translation or very slight surface scale. Set transform origin from the positioning primitive. Content should move as one plane.

### Dialog

Fade scrim and dialog as coordinated but independent layers. Keep dialog center stable. Use at most slight surface scale; do not bounce. Trap focus and restore it on close.

### Sheet

Enter from the edge that owns it. Use a short, controlled translation. Do not simultaneously fade every internal section.

### Disclosure

Animate measured content height and opacity as one content region. Preserve header geometry. Rotate chevron once. Do not cascade child options.

### Exit

Exit faster than enter. Keep content mounted until the exit pattern finishes when the primitive supports presence. Avoid leaving invisible focusable content.

## 7. Structural layout transitions

Use structural motion only when it helps the user track a pane, list, or detail surface.

Before animating, identify:

- start track geometry;
- final track geometry;
- which inner content anatomy is valid at each width;
- whether any container-query threshold will be crossed;
- which plane owns overflow/clipping;
- what happens when interrupted or reversed.

### Preferred strategies, in order

1. **Stable inner canvas, animated outer clip/track:** pin the inner content to final geometry and reveal it through the moving parent.
2. **FLIP:** resolve final layout, then animate visual transform from previous bounds to final bounds.
3. **Plane-level fade plus direct layout:** change geometry directly, fade one parent plane if continuity remains adequate.
4. **Delayed whole-plane reveal:** use only when content cannot remain stable; do not delay individual fields.
5. **No animation:** choose this when all animated strategies expose reflow or delay the task.

Do not animate a grid track from zero while allowing the inner responsive component to reclassify publicly.

## 8. Responsive reflow during animation

### Failure mechanism

An element whose container grows from 0 to 1200px may cross multiple container-query breakpoints. Its content can render as:

1. narrow stacked anatomy;
2. intermediate anatomy;
3. wide columns.

This produces flickering metadata, sudden number appearance, and jumping source labels even if opacity is animated.

### Stabilization protocol

1. Compute or know the final content width.
2. Choose the final anatomy before the first visible frame.
3. Fix/pin the inner canvas width during the outer transition, or keep the whole content plane hidden.
4. Animate the outer track/clip and content plane in sync.
5. Remove the pin only after the outer geometry matches it.
6. Ensure removing the pin changes no bounding boxes.

If the final sidebar can have multiple widths, measure rather than guess. Do not hard-code viewport formulas when a ResizeObserver or FLIP measurement is more accurate.

### Duplicate representation protocol

When list rows and detail panes both show the same field:

- never cross-fade the same word/number in unrelated locations unless intentional shared-element motion exists;
- hide/collapse the source plane as a whole;
- keep one accessible representation visible at a time where possible;
- avoid staged classes that separately fade difficulty, source, and solves.

## 9. Interruption and cleanup

Every motion must survive:

- repeated click before completion;
- open then immediate close;
- selection of a different item mid-transition;
- viewport resize during transition;
- reduced-motion preference change;
- route navigation/unmount;
- window blur during press.

On interruption:

1. sample current computed visual state;
2. cancel the active channel;
3. animate from the sampled state to the new target;
4. remove temporary inline geometry or data attributes at completion;
5. ensure final DOM/accessibility state matches the target.

Never leave inline `scale`, `translate`, `opacity`, `transition-duration`, `inert`, or `aria-hidden` state after cancellation.

## 10. Reduced motion

Reduced motion is not “make durations 1ms and hope.” Resolve intentionally:

- contact feedback remains immediate but nonmoving;
- layout reaches final geometry immediately;
- dialogs/flyouts may use a direct opacity change or instant presence;
- disclosures open without animated height;
- loading progress that conveys actual time may remain if necessary;
- no content is delayed by a timer whose animation was disabled.

Test with emulated `prefers-reduced-motion: reduce`. Assert final geometry immediately after activation.

## 11. First paint and hydration

### Server-render the first useful state

Avoid rendering empty shells that hydrate into content for routes whose data is already available. Match server and client state for:

- theme;
- selected item;
- filters/sort/query state;
- error status;
- user preferences needed for layout;
- deterministic IDs and labels.

### Prevent first-interaction races

Install critical pre-hydration state when required:

- theme dataset;
- color scheme;
- input modality capture;
- persisted layout preference if it changes first paint.

Do not wait for component mount if the user can click before the behavior exists.

### Hydration stability

Verify:

- no text replacement;
- no theme flash;
- no focus ring flash;
- no control changes from unstyled to styled;
- no list count or selected label correction after hydration;
- no duplicate modal/sheet mount.

## 12. Font stability

Choose one strategy deliberately:

- preload critical local font;
- use `font-display: optional` when fallback stability matters more than guaranteed custom font;
- use metric-compatible fallback with size/metric overrides;
- use system font for critical error/utility routes when brand font is not worth replacement risk.

Do not use `swap` blindly for large headlines if the width change is visibly disruptive.

Test cached and uncached hard reload. Measure text box x/y/width/height over several animation frames and after `document.fonts.ready`.

## 13. Async rendering

- Do not flash a spinner for work below the perception threshold (roughly 200ms).
- Use skeletons for known longer layouts, matching final geometry.
- Preserve trustworthy previous data during refresh or reconnection.
- Distinguish initial load, incremental load, stale, partial, offline, and error.
- Reserve space for delayed values to avoid layout shift.
- Do not animate each arriving number independently.

## 14. Frame-level verification

When a user reports flicker or late motion, do not rely on watching once. Instrument it.

### Capture per animation frame

Record:

- elapsed time;
- relevant data-state/data-motion attributes;
- opacity, transform/translate/scale;
- container width and grid tracks;
- bounding boxes of reported labels/values;
- visibility/display;
- active element and input modality;
- computed font family/weight if text flickers.

### Pass criteria

- contact state visible before release;
- panel and content start within one frame unless intentionally sequenced;
- siblings share the same reveal timeline;
- inner field geometry does not reclassify while visible;
- no more than one monotonic path for each animated property;
- final temporary styles are removed;
- reduced motion has no waiting timer;
- no bounding-box movement for pressed buttons.

Use slow-motion recording or screenshots only as supplements; computed frame data identifies the actual cause.

## 15. Prohibited motion patterns

Reject by default:

- `transition: all`;
- per-child stagger in routine application UI;
- spring/bounce on buttons, toggles, or settings;
- animated imprints after release;
- simultaneous scale, translate, tint, and shadow on one press;
- wide-control scale;
- layout animation with publicly changing container-query anatomy;
- content reveal that begins after its panel has already arrived;
- separate fades for individual metadata fields;
- motion that changes target location while pointer is down;
- animations longer than 300ms for routine operations;
- timers not derived from shared motion tokens;
- motion-library dependency added for simple CSS/WAAPI behavior;
- inaccessible animation with no reduced-motion path.
