# Redesign notes (v1.1.0)

## References (Godly)
- **Endel Manifesto** (manifesto.endel.io, Godly › Health): very dark warm-black fields, large serif type, little else on screen. That is where the bedtime and tracking screens come from.
- **Augen** (augen.pro, Godly › Health): restrained wellness/health-tech, one big statement per screen, plenty of space. Used for the morning hierarchy: score first, then one line, then the details.
- **Lovi** (lovi.care, Godly › Health): calm app landing page with a soft palette and clear type steps. Used for the lighter morning theme and the install hint.

## Palette (Realtime Colors method: text / background / primary / secondary / accent, ~60-30-10)
Night (dark, default): text #F1E6D6 · background #100D0B (surface #1A1612, #25201B) · primary #E8A765 (ember) · secondary #7FA88F (sage, settled sleep) · accent #D98A6A (awake / cost). Tracking screen: #000000 with #9C6B45 text and #7E5A3C for the 30px clock and edges (no blue at all).
Morning (light, prefers-color-scheme: light): text #1E1915 · background #F4EFE7 (surface #FBF8F3) · primary #8C4A12 · secondary #3F6650 · accent #A3452A.

WCAG contrast, computed against bg / surface / surface-2:
- Dark: text 15.25 / 14.16 / 12.71; dim #B3A797 7.05 / 6.55 / 5.88; primary 9.45 / 8.77 / 7.87; secondary 8.85 / 8.21 / 7.37; accent 7.22 / 6.70 / 6.02; button text #1A120A on primary 9.0.
- Light: text 14.85 / 16.04 / 13.34; dim 5.64 / 6.09 / 5.06; primary 5.51 / 5.95 / 4.95; secondary 5.68 / 6.14 / 5.11; accent 5.60 / 6.05 / 5.03; button text on primary 5.99.
- Tracking (on #000): body text #9C6B45 4.60; large clock (30px) and button edge #7E5A3C 3.41.
- Strong UI borders: 3.19 (dark) / 3.11 (light).

## Motion
Spring easing via CSS `linear()`, transform and opacity only, all inside `@media (prefers-reduced-motion: no-preference)`. The one hero moment is the score reveal on the morning screen. The only motion on the tracking screen is a 6 px dot fading between 18% and 55% opacity over 12 s.
