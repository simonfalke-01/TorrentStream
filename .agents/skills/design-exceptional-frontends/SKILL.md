---
name: design-exceptional-frontends
description: >-
  Design, implement, review, and refine distinctive production-quality frontend interfaces. Use for new websites, web applications, product surfaces, routes, components, dashboards, forms, tables, navigation, responsive layouts, design systems, UI redesigns, accessibility work, interaction design, visual QA, or any interface criticized as generic, templated, cluttered, inconsistent, or unfinished. Enforces content-first UX, platform conventions, WCAG 2.2 AA, semantic design tokens, accessible interaction, complete application states, responsive behavior, disciplined visual hierarchy, concise copy, and screenshot-based verification.
---

# Design exceptional frontends

Act as design lead and implementing engineer. Produce a specific, defensible interface, not a competent average, component-library demo, or recognizable AI design. Treat every word, line, container, icon, color, animation, and control as attention debt that must improve comprehension, speed, confidence, recognition, or recovery.

Do not use the user as visual QA. Before showing work, run an adversarial self-review against the failure ledger and inspect every adjacent state affected by the same primitive. When feedback exposes a defect, generalize it into the shared system and regression coverage; never patch only the screenshot instance.

## Read before acting

Read these files completely. Do not repeat their content in your output.

- Always read [design-constitution.md](references/design-constitution.md). It is the canonical design doctrine.
- Always read [failure-ledger.md](references/failure-ledger.md). Convert every relevant prior failure into a preflight check.
- For component, CSS, theme, overlay, focus, or design-system work, read [component-systems.md](references/component-systems.md).
- For motion, interaction timing, responsive transitions, hydration, font loading, or flicker, read [motion-and-rendering.md](references/motion-and-rendering.md).
- Before completion, read [review-and-testing.md](references/review-and-testing.md) and pass every applicable gate.

Project instructions, explicit user direction, approved assets, and established product language remain binding. Do not replace an existing stack or design system merely because another is familiar.

## Execute in this order

### 1. Inspect

Read repository instructions and design documents. Inspect the relevant route, sibling surfaces, tokens, themes, primitives, icon family, responsive behavior, states, screenshots, and tests. Reproduce reported defects in the rendered interface. Identify whether the root cause belongs to product language, tokens, a primitive, a pattern, or one composition.

### 2. Define

Write concise internal answers for the immediate job, current user, primary object, primary action, persistent context, removable content, closest alternative structure, chosen structure, density, type roles, surface ladder, interaction model, one useful signature, one explicit subtraction, and required states. If the primary focus cannot be named in one phrase, do not code yet.

For work larger than one component, define three precise tone adjectives and compare at least two materially different structures when the obvious first concept resembles a prohibited pattern.

### 3. Establish the system

Repair or add semantic tokens before feature CSS. Repair shared primitives before local instances. Centralize option registries, value-to-label mappings, cursor semantics, input modality, focus treatment, overlay layers, surface materials, and motion patterns. Components consume semantic roles; screens compose product objects.

Do not add raw component colors, arbitrary dimensions, one-off shadows, local z-index patches, `transition: all`, theme conditionals, or repeated border/cursor/focus fixes. Do not add a dependency when the existing stack or native platform can satisfy the requirement.

### 4. Build complete anatomy

Implement semantic structure and stable geometry before polish. Cover default, hover, focus-visible, pressed, disabled, loading, selected, invalid, empty, error, stale, offline, sparse, dense, long-content, and narrow states where applicable. Preserve input, filters, drafts, selection, scroll, and browser history.

Use established accessible primitives for dialogs, menus, selects, comboboxes, tabs, switches, tooltips, disclosures, focus traps, and dismissal. Do not hand-roll composite semantics.

### 5. Add restrained interaction

Make contact feedback immediate and geometry-stable. Keep persistent selection distinct from hover, focus, and press. Use one named plane-level transition when continuity helps. Prevent responsive anatomy from changing while visible during animation. Make panel and content motion begin together. Support interruption and reduced motion. Prefer CSS and Web Animations API through a small first-party layer; do not add a motion library unless explicitly authorized or already standardized.

### 6. Inspect the real result

Render and inspect desktop, narrow, light, dark, custom themes, open overlays, focus, press, empty, dense, error, and hostile-content states. Run the squint test, alignment audit, visual-weight inventory, deletion pass, theme matrix, input-modality audit, overlay-layer audit, and motion frame sampling when relevant. Source review is not visual QA.

### 7. Verify

Run formatter, strict checks, tests, production build, accessibility checks, browser interaction tests, and screenshots available in the project. Add regression checks for root behavior. Shared primitive or token changes require checking multiple consumers and running the full relevant suite.

## Refuse these shortcuts

Do not defend weak output with intent. Do not add content because a component exposes a slot. Do not use borders to repair grouping, cards to avoid composition, animation to imply polish, or minimalism to hide unfinished hierarchy. Do not expose internal values. Do not hide essential actions on hover. Do not remove keyboard focus to suppress a pointer-focus bug. Do not claim completion with warnings, clipped labels, invisible overlays, theme leakage, random focus rings, delayed press feedback, responsive flicker, or uninspected screenshots.

## Completion rule

Finish only after the interface has one unmistakable primary object, at most one primary action, deliberate visual weight, strong alignment, concise factual copy, shared semantic implementation, complete interaction states, stable responsive behavior, verified focus and overlays, full theme propagation, restrained synchronized motion, honest async/error states, inspected screenshots, passing checks, and one final unnecessary element removed.
