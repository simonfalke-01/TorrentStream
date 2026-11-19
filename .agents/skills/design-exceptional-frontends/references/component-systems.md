# Component and design-system contracts

Use this reference when implementing or reviewing frontend architecture, tokens, controls, overlays, themes, focus, or component reuse.

## Contents

1. Abstraction order
2. Required semantic token schema
3. Theme completeness
4. Shared surface contracts
5. Control contracts
6. Composite widgets
7. Layering system
8. Focus and input modality
9. Pointer and disabled behavior
10. Value-to-label boundaries
11. Component API rules
12. CSS rules
13. Refactor triggers
14. Implementation audit

## 1. Abstraction order

Repair design defects at the highest valid shared level:

1. **Product rule:** vocabulary, state model, information priority.
2. **Semantic token:** material, color, spacing, type, radius, motion, layer.
3. **Primitive:** button, icon button, select, field, switch, menu item, surface.
4. **Pattern:** settings row, toolbar, data row, modal header, filter group.
5. **Composition:** page-specific arrangement.
6. **One-off correction:** only when geometry or meaning is genuinely unique.

If the same property appears in three components, stop and determine whether it is a missing token or primitive. If a user asks to “abstract all styling,” audit shared causes before editing visible instances.

Do not abstract coincidental similarity. Two blocks that look alike but have different semantic/state contracts should not share a component merely to reduce lines.

## 2. Required semantic token schema

Use semantic roles. Names may differ, but the system must cover these responsibilities.

### Color and material

| Role | Required meaning |
|---|---|
| canvas | Outermost application background |
| surface | Main task plane |
| raised | Content plane above canvas |
| sunken/support | Toolbar, rail, recessed, or structural support plane |
| control | Resting input/select/secondary-control material distinct from parent |
| control-hover | Perceptible hover step from control |
| floating | Menu, popover, or tooltip plane distinct from its launcher plane |
| active | Stronger momentary state where needed |
| overlay | Modal/sheet scrim |
| text | Primary readable foreground |
| text-muted | Supporting copy with AA contrast at its actual size |
| text-subtle | Tertiary metadata, still readable |
| text-on-accent | Foreground on primary action/selection |
| accent-subtle | Selected navigation/filter surface |
| accent | Primary action or strong selection |
| accent-hover | Hovered primary action |
| accent-text | Text used with accent-subtle |
| success/warning/danger | Semantic state families with subtle, border, solid, and text roles as needed |
| focus | High-contrast keyboard focus indicator |

Never make `control` equal to its immediate parent material when that makes the affordance disappear. Never make `floating` equal to the modal beneath it when borders are absent.

### Geometry

Define:

- a 4px-based or similarly disciplined spacing scale;
- compact, default, and touch control heights;
- one small and one medium radius before adding more;
- border width;
- information rail width if the product has one;
- content/readable measure;
- page maximum width where appropriate;
- standard panel widths;
- row heights for repeated data.

Default guidance:

- compact controls: 32–36px;
- ordinary pointer controls: 36–40px;
- touch controls: at least 40px, preferably 44px when density allows;
- body line length: 45–75 characters;
- metadata line height: at least 1.3;
- body line height: 1.4–1.6;
- inner group spacing : outer group spacing ratio: at least 1 : 1.5, usually 1 : 2.

Do not use arbitrary 5px, 13px, 19px, and 27px gaps across sibling components without an explicit optical reason.

### Typography

Define roles for:

- route/page title;
- section title;
- body/control;
- caption/metadata;
- code or machine output.

Define numeric alignment behavior. Apply `font-variant-numeric: tabular-nums` to comparable numeric values.

### Motion

Define named durations and easing roles, not per-component magic numbers. Required roles:

- press release;
- fast color/state change;
- overlay exit;
- popover enter;
- dialog/sheet enter;
- structural layout.

### Layers

Define named layers. A practical ordering is:

1. local row highlight;
2. sticky page chrome;
3. sheet scrim;
4. sheet;
5. modal scrim;
6. modal;
7. popover/select/menu/tooltip;
8. skip link or critical accessibility escape.

Use tokens or a centralized map. Do not scatter `z-index: 50`, `70`, `80`, and `81` across components.

## 3. Theme completeness

Treat a theme as a full semantic mapping, not a background toggle.

For each theme, verify every token category:

- canvas and all surface roles;
- control and control-hover;
- floating surface;
- primary, muted, subtle, and inverse text;
- accent family;
- success, warning, and danger families;
- focus ring;
- scrim;
- shadow/elevation;
- logo/icon treatment;
- selection color;
- press feedback;
- browser `color-scheme` and `theme-color`.

### Contrast requirements

- Body text: at least 4.5:1.
- Large text: at least 3:1.
- Essential graphical/control boundaries: at least 3:1 against adjacent colors when the boundary is needed to identify the control.
- Focus indicators: clearly visible against both the control and surrounding surface; target at least 3:1 change of contrast.
- Disabled state: may reduce contrast but must remain identifiable and must not be the only explanation for unavailability.

### Theme registry

Centralize theme ID, visible label, and metadata. Persist only valid IDs. Map IDs to labels at the boundary.

Use a segmented control only for at most 3–4 short, fixed theme names that fit without truncation in every supported locale. Use a scrollable select or searchable picker when themes can grow. Never clip a theme name to preserve a segmented layout.

### High-contrast themes

Increase contrast through the entire semantic ladder. Do not only set canvas to black and text to white while leaving dark-theme teal/gray component tokens unchanged. Verify popovers, selected items, switches, control surfaces, pressed overlays, and focus indicators in the high-contrast theme.

## 4. Shared surface contracts

Create three surface primitives or equivalent roles:

### Control surface

Must provide:

- foreground color;
- distinct resting fill;
- distinct hover fill;
- shared radius;
- no default decorative border;
- keyboard focus hook;
- disabled material behavior.

Apply to text fields, searches, selects, and secondary controls. A control surface must remain visible inside a modal that uses the raised surface.

### Floating surface

Must provide:

- popover layer above every modal and sheet that can launch it;
- floating material distinct from the underlying plane;
- radius;
- real overlay shadow or other depth cue;
- no browser outline on the container;
- theme propagation.

Apply to menus, select lists, combobox results, and tooltips. Do not assign lower z-index values inside individual components.

### Overlay surface

Must provide:

- modal/sheet material;
- appropriate radius for its presentation;
- real elevation;
- no decorative border;
- constrained width and max-height;
- internal overflow ownership.

Do not use floating-surface layer values for the modal itself.

## 5. Control contracts

### All interactive targets

Provide:

- semantic element or correct role;
- accessible name;
- pointer cursor for enabled pointer-operable controls;
- not-allowed cursor for disabled controls;
- default, hover, pressed, focus-visible, disabled, and selected state as applicable;
- no layout movement between these states;
- target size appropriate to pointer/touch context;
- visible but restrained affordance.

Apply cursor semantics centrally to native buttons, links, selects, and role-based controls (`button`, `menuitem`, `option`, `checkbox`, `radio`, `switch`). Do not depend on every component author remembering `cursor: pointer`.

### Button

Use at most one primary button per task region.

Required tones:

- primary: advances the task;
- secondary: useful alternative;
- quiet: low-weight utility;
- destructive: only for destructive actions, if needed.

Do not use a border to create secondary affordance if a filled control surface matches the product language. Do not scale or bounce wide buttons on press. Keep labels active and terse.

### Icon button

Require an accessible label. Use a tooltip when the icon is not universally clear, but do not let a nested tooltip consume Escape before a parent modal. Allow tooltip opt-out inside dismissible overlays when the accessible label is sufficient.

Keep icon size and button target independent. Center icons optically.

### Select

Require:

- visible or screen-reader label;
- visible current label, never raw value;
- chevron or familiar disclosure affordance;
- filled control material distinct from parent;
- popover above the launching overlay;
- selected indicator;
- highlighted keyboard/pointer state;
- max-height with internal scrolling;
- long-label handling without clipping the only identifying words;
- disabled option semantics.

The trigger and popover must use shared control/floating surfaces automatically.

### Switch

Use only for immediate binary settings. Apply immediately unless the surrounding form explicitly batches changes. Put the label and consequence beside the switch. Do not add a Save button for local immediate preferences.

Do not animate an imprint after release. Move the thumb on state change with one short transition. Maintain contrast in all themes.

### Checkbox and radio

Use checkbox for independent selection and radio for one-of-many choice. Make the label clickable. Keep check control alignment stable with one-line and multi-line labels. Communicate disabled state and reason where necessary.

### Disclosure

Make the entire header target clickable. Expose `aria-expanded`. Keep structural headers visually structural; do not turn the whole row into a nested pill. Animate the content plane once, not each child.

## 6. Composite widgets

Use a proven accessible primitive for menu, dialog, select, combobox, tabs, tooltip, and disclosure behavior. Do not recreate roving focus, focus trapping, outside-click dismissal, typeahead, or ARIA semantics casually.

Separate responsibilities:

- primitive library: semantics, state machine, keyboard, focus, portal, dismissal;
- product primitive: tokens, shape, density, icons, motion classes;
- composition: task-specific content and actions.

### Managed item highlight

Menu items and options commonly receive programmatic focus. Use the widget's managed highlighted state as the visible focus treatment. Suppress a second standalone outline on those items only. Preserve a keyboard focus indicator for standalone controls.

### Escape priority

Nested dismissible layers consume Escape from innermost to outermost. Avoid opening a tooltip on auto-focused modal controls if that would force two Escape presses to close the modal.

### Focus restoration

Restore focus to the launcher when an overlay closes, unless navigation makes that target irrelevant. Use `preventScroll` where restoration would move the page.

## 7. Layering system

Portals leave local stacking contexts. Therefore, local DOM nesting does not guarantee visual order.

Enforce:

- sheet < modal < popover/tooltip;
- a select opened inside a modal must appear above the modal;
- a tooltip inside a modal must appear above the modal but must not break dismissal;
- scrims must stay below their owned surface and above the application;
- skip links must remain reachable above ordinary overlays when required by the product.

Test actual computed z-index and visibility. An open chevron with an invisible list usually indicates a portal-layer defect, not missing component markup.

## 8. Focus and input modality

Do not rely exclusively on browser `:focus-visible` heuristics when the application performs programmatic focus restoration.

Implement a centralized modality state:

1. Default to keyboard-safe behavior before hydration.
2. On capture-phase `pointerdown`, set modality to pointer before focus changes.
3. On meaningful capture-phase `keydown`, set modality to keyboard before focus changes.
4. Ignore pure modifier keys.
5. Show standalone focus rings only in keyboard modality.
6. Use managed highlight for composite items.
7. Install the earliest listener before hydration if first-interaction races are possible.

Do not remove all outlines globally. Do not allow pointer-opened menus or pointer-closed dialogs to leave a random bright ring on their launcher.

Test:

- pointer opens and closes menu: no standalone ring;
- Tab reaches launcher: ring visible;
- Arrow keys move menu highlight: highlighted item visible;
- Escape closes overlay and restores focus correctly;
- focus restoration after pointer close does not change modality;
- hard refresh then immediate click behaves correctly.

## 9. Pointer and disabled behavior

Use one global interaction selector or primitive contract for cursor behavior. Cover native and role-based controls. Exclude non-interactive containers that merely contain a clickable child.

Disabled controls must:

- use `disabled`, `aria-disabled`, or primitive-specific disabled state correctly;
- use not-allowed cursor when pointer interaction is exposed;
- ignore press motion;
- remain legible;
- state why they are disabled when the reason is not obvious.

Do not attach click handlers to visually disabled elements.

## 10. Value-to-label boundaries

Maintain separate types for internal value and visible label.

```ts
type Option<T extends string> = {
  value: T;
  label: string;
  disabled?: boolean;
};
```

Render `label`. Serialize `value`. Validate persisted and URL values against the registry. Provide a deliberate fallback such as “Select an option”; never fall back to rendering the raw value.

Apply this to themes, sort modes, filters, statuses, roles, plans, regions, and feature modes.

## 11. Component API rules

Prefer APIs that express meaning:

- `tone="primary"`, not `blue`;
- `surface="floating"`, not `shadow="lg"`;
- `status="warning"`, not `color="#f90"`;
- `label`, not unlabeled children for icon-only controls;
- `open/onOpenChange`, not internal state when the composition must coordinate;
- typed option arrays, not ad hoc string maps;
- slots/snippets for stable compositional regions, not dozens of boolean props.

Forward native attributes and primitive props. Preserve `class`, ARIA, data attributes, event handlers, refs, and disabled semantics.

Avoid:

- boolean-prop matrices (`rounded`, `outlined`, `elevated`, `compact`, `flat`, `ghost`, ...);
- components that own unrelated product state;
- wrappers that obscure accessible primitive behavior;
- styling a component through deep DOM selectors that depend on library internals.

## 12. CSS rules

### Require

- semantic custom properties in components;
- logical properties where writing direction matters;
- stable box sizing;
- `min-width: 0` on grid/flex children that truncate;
- deliberate overflow owner;
- tabular numeric alignment;
- named motion classes or tokens;
- theme-specific values only in theme definitions.

### Prohibit by default

- `transition: all`;
- raw hex/rgb colors inside product components;
- one-off z-index values;
- per-component duplicate floating-surface declarations;
- decorative borders on every container;
- scale press effects on wide controls;
- global `outline: none` without a modality/focus replacement;
- ellipsis on the only visible identity of a choice when another control can fit it;
- fixed heights on variable text content without overflow behavior;
- animating `height: auto` without a measured primitive;
- mixing layout transforms with virtualized-row transforms on the same element.

## 13. Refactor triggers

Refactor immediately when:

- the same defect appears in more than one component;
- a new theme requires editing component CSS;
- a popover layer is fixed with a local z-index;
- a raw internal value reaches UI;
- a cursor/focus rule is added to a single role-based control;
- multiple controls invent separate press feedback;
- modal/sheet headers duplicate icon-button markup;
- adding the fifth option clips a segmented control;
- responsive behavior requires duplicating the same content in two visible trees;
- a component's state change moves neighboring targets.

## 14. Implementation audit

Before completion, search for:

- raw colors outside token files;
- border and outline declarations in component files;
- hard-coded z-index values;
- `transition: all`;
- duplicate shadows and floating backgrounds;
- role-based controls without pointer cursor;
- `outline: none` without replacement;
- raw enum or query strings in templates;
- segmented controls with long/growing option sets;
- theme conditionals inside components;
- direct motion-library imports;
- duplicated dialog/menu/select behavior;
- controls without disabled or focus-visible state.

For each match, either move it to the shared system or document why the instance is semantically unique.
