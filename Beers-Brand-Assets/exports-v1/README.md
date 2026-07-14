# Beers logo pack v1

This is the production-ready Beers logo pack. Every canonical asset is supplied as a true, editable SVG path and as a high-resolution PNG whose longest edge is exactly 4096 pixels. No SVG embeds a raster image or depends on a font.

## Canonical assets

| Asset | Use | PNG dimensions | Background |
|---|---|---:|---|
| `beers-b-primary` | Standalone canonical B | 3351×4096 | Transparent |
| `beers-b-badge` | Scalloped app/site badge | 3864×4096 | Transparent |
| `beers-b-framed` | Decorative framed B | 4096×3507 | Transparent |
| `beers-wordmark` | Complete red Beers wordmark | 4096×1302 | Transparent |
| `beers-lockup-horizontal` | B replaces the B in Beers | 4096×1175 | Transparent |
| `beers-b-one-colour-ink` | Single-colour navy mark | 3351×4096 | Transparent |
| `beers-b-one-colour-cream` | Single-colour reverse mark | 3351×4096 | Transparent; dark backgrounds |
| `beers-b-reversed` | Cream B on rounded navy tile | 4096×4096 | Transparent outer corners |

SVG masters live in `svg/`; paired PNG exports live in `png-4k/`.

## Which mark to use

- Use `beers-b-badge` for the app icon and primary product identity.
- Use `beers-lockup-horizontal` when the full name is needed: the B mark replaces the letter B.
- Use `beers-b-primary` only where the badge would be too busy, such as compact navigation, favicons, avatars, stickers, and small print.
- Use the one-colour files for embroidery, stamps, vinyl, laser work, and single-ink print.
- Keep clear space around a mark equal to at least one quarter of the B's width. Do not stretch, recolour, rotate, outline, or rearrange it.

## Legacy

`legacy/beers-ear-b-legacy` is the older orange-ear/yellow-inner-ear B. It is included because it existed in the project, but it is not the current product mark and must not replace the scalloped badge or canonical cream-ear B.

## Palette

| Name | Hex |
|---|---|
| Ink navy | `#0A1735` |
| Cream | `#FFF7DF` |
| Pour orange | `#F04A1A` |
| Golden yellow | `#FFB51B` |
| Wordmark red | `#9B111E` |
| Accent sage | `#78AA94` |

The SVG masters use restrained gradients within this palette to retain the warmth of the original artwork. The one-colour versions use flat fills.

## Rebuild

From the repository root:

```sh
python3 scripts/export-brand-assets.py
```

Requirements: Python 3 with Pillow and `rsvg-convert`. The two raster-only wireframe sources used for vector reconstruction are preserved in `../source-raster-v1/`.
