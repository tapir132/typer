# Design System

## Direction

Late-night hackathon control desk: near-black working canvas, crisp instrument typography, saturated indigo for the primary action, and a small electric-lime signal color for live status. Dense enough for repeated use, but calm enough to keep the source text central.

## Color

- Background: `oklch(0.095 0 0)`
- Surface: `oklch(0.145 0.012 268)`
- Raised surface: `oklch(0.19 0.014 268)`
- Ink: `oklch(0.96 0.006 268)`
- Muted: `oklch(0.70 0.018 268)`
- Primary: `oklch(0.59 0.22 268)`
- Primary strong: `oklch(0.51 0.22 268)`
- Signal: `oklch(0.86 0.19 128)`
- Danger: `oklch(0.67 0.20 28)`

## Typography

Use San Francisco for native interface text and SF Mono for keystrokes, timing values, status labels, and the editor. Preserve native macOS text rendering and control behavior.

## Layout

A compact top bar sits above a two-column workbench. The source editor owns most of the width; the control rail remains narrow and scan-friendly. At tablet sizes the rail drops beneath the editor. On mobile, navigation becomes horizontally scrollable and all controls stack.

## Components

- Controls use 10px radii; larger working surfaces use 14px.
- Primary actions are solid indigo with white text.
- Selection and live state use lime sparingly.
- Inputs use raised neutral fills without decorative shadows.
- Focus rings are explicit and high contrast.
- Motion communicates arming, running, saved, or stopped states and is disabled under reduced-motion.
