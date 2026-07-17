#!/usr/bin/env python3
"""Build the versioned Beers SVG and 4K PNG logo pack.

The original Beers artwork exists as raster-only PNGs. This exporter turns
their visible shapes into editable SVG paths, applies the canonical palette,
and renders paired PNGs whose longest edge is exactly 4096 pixels.
"""

from __future__ import annotations

import colorsys
import math
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterable, Sequence

from PIL import Image, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "Beers-Brand-Assets"
SOURCES = ASSETS / "source-raster-v2"
OUTPUT = ASSETS / "exports-v1"
SVG_DIR = OUTPUT / "svg"
PNG_DIR = OUTPUT / "png-4k"
LEGACY_SVG_DIR = OUTPUT / "legacy" / "svg"
LEGACY_PNG_DIR = OUTPUT / "legacy" / "png-4k"
PREVIEW_DIR = OUTPUT / "preview"

PRIMARY_SOURCE = SOURCES / "logo-b-small.png"
BADGE_SOURCE = SOURCES / "beers-b-badge.png"
FRAMED_SOURCE = SOURCES / "logo-framed-source.png"
WORDMARK_SOURCE = SOURCES / "wordmark-source.png"
LEGACY_SOURCE = PRIMARY_SOURCE

RSVG = shutil.which("rsvg-convert")


PALETTE = {
    "navy": "#0A1735",
    "navy_deep": "#061128",
    "cream": "#FFF7DF",
    "cream_shadow": "#F6EBCF",
    "orange": "#F04A1A",
    "orange_deep": "#DD3914",
    "yellow": "#FFB51B",
    "yellow_light": "#FFD25C",
    "red": "#9B111E",
    "red_deep": "#780B14",
    "sage": "#78AA94",
}


Point = tuple[float, float]
Mask = bytearray


@dataclass
class Component:
    area: int
    bbox: tuple[int, int, int, int]
    pixels: list[int]

    @property
    def centre(self) -> tuple[float, float]:
        left, top, right, bottom = self.bbox
        return ((left + right) / 2, (top + bottom) / 2)


@dataclass
class Artwork:
    name: str
    title: str
    width: int
    height: int
    body: str
    legacy: bool = False


def image_pixels(path: Path) -> tuple[Image.Image, list[tuple[int, int, int, int]]]:
    image = Image.open(path).convert("RGBA")
    return image, list(image.get_flattened_data())


def alpha_mask(pixels: Sequence[tuple[int, int, int, int]], minimum: int = 64) -> Mask:
    return bytearray(1 if alpha >= minimum else 0 for _, _, _, alpha in pixels)


def colour_mask(
    pixels: Sequence[tuple[int, int, int, int]],
    predicate: Callable[[float, float, float, int, int, int], bool],
    minimum_alpha: int = 64,
) -> Mask:
    mask = bytearray(len(pixels))
    for index, (red, green, blue, alpha) in enumerate(pixels):
        if alpha < minimum_alpha:
            continue
        hue, saturation, value = colorsys.rgb_to_hsv(red / 255, green / 255, blue / 255)
        if predicate(hue, saturation, value, red, green, blue):
            mask[index] = 1
    return mask


def components(mask: Mask, width: int, height: int) -> list[Component]:
    seen = bytearray(width * height)
    found: list[Component] = []
    for start, value in enumerate(mask):
        if not value or seen[start]:
            continue

        stack = [start]
        seen[start] = 1
        pixels: list[int] = []
        min_x = width
        min_y = height
        max_x = 0
        max_y = 0

        while stack:
            index = stack.pop()
            pixels.append(index)
            x = index % width
            y = index // width
            min_x = min(min_x, x)
            min_y = min(min_y, y)
            max_x = max(max_x, x)
            max_y = max(max_y, y)

            if x and mask[index - 1] and not seen[index - 1]:
                seen[index - 1] = 1
                stack.append(index - 1)
            if x + 1 < width and mask[index + 1] and not seen[index + 1]:
                seen[index + 1] = 1
                stack.append(index + 1)
            if y and mask[index - width] and not seen[index - width]:
                seen[index - width] = 1
                stack.append(index - width)
            if y + 1 < height and mask[index + width] and not seen[index + width]:
                seen[index + width] = 1
                stack.append(index + width)

        found.append(Component(len(pixels), (min_x, min_y, max_x + 1, max_y + 1), pixels))

    return sorted(found, key=lambda component: component.area, reverse=True)


def select_components(
    mask: Mask,
    width: int,
    height: int,
    selector: Callable[[Component, int], bool],
) -> Mask:
    selected = bytearray(width * height)
    for rank, component in enumerate(components(mask, width, height)):
        if selector(component, rank):
            for index in component.pixels:
                selected[index] = 1
    return selected


def dilate(mask: Mask, width: int, height: int, radius: int = 1) -> Mask:
    if radius <= 0:
        return mask
    image = Image.frombytes("L", (width, height), bytes(255 if value else 0 for value in mask))
    expanded = image.filter(ImageFilter.MaxFilter(radius * 2 + 1))
    return bytearray(1 if value >= 128 else 0 for value in expanded.get_flattened_data())


def soften(mask: Mask, width: int, height: int, radius: float = 1.0, threshold: int = 128) -> Mask:
    """Remove source-pixel stair steps before fitting vector curves."""
    image = Image.frombytes("L", (width, height), bytes(255 if value else 0 for value in mask))
    softened = image.filter(ImageFilter.GaussianBlur(radius))
    return bytearray(1 if value >= threshold else 0 for value in softened.get_flattened_data())


def union_masks(*masks: Mask) -> Mask:
    return bytearray(1 if any(mask[index] for mask in masks) else 0 for index in range(len(masks[0])))


def mask_edges(mask: Mask, width: int, height: int) -> set[tuple[Point, Point]]:
    edges: set[tuple[Point, Point]] = set()
    for index, value in enumerate(mask):
        if not value:
            continue
        x = index % width
        y = index // width
        if y == 0 or not mask[index - width]:
            edges.add(((x, y), (x + 1, y)))
        if x + 1 == width or not mask[index + 1]:
            edges.add(((x + 1, y), (x + 1, y + 1)))
        if y + 1 == height or not mask[index + width]:
            edges.add(((x + 1, y + 1), (x, y + 1)))
        if x == 0 or not mask[index - 1]:
            edges.add(((x, y + 1), (x, y)))
    return edges


def direction(start: Point, end: Point) -> int:
    dx = int(end[0] - start[0])
    dy = int(end[1] - start[1])
    return {(1, 0): 0, (0, 1): 1, (-1, 0): 2, (0, -1): 3}[(dx, dy)]


def edge_loops(mask: Mask, width: int, height: int) -> list[list[Point]]:
    remaining = mask_edges(mask, width, height)
    outgoing: dict[Point, set[Point]] = {}
    for start, end in remaining:
        outgoing.setdefault(start, set()).add(end)

    loops: list[list[Point]] = []
    while remaining:
        start_edge = next(iter(remaining))
        first, current = start_edge
        previous = first
        loop = [first]
        remaining.remove(start_edge)
        outgoing[first].remove(current)

        while current != first:
            loop.append(current)
            candidates = [end for end in outgoing.get(current, ()) if (current, end) in remaining]
            if not candidates:
                break
            previous_direction = direction(previous, current)
            turn_order = {1: 0, 0: 1, 3: 2, 2: 3}
            next_point = min(
                candidates,
                key=lambda candidate: turn_order[(direction(current, candidate) - previous_direction) % 4],
            )
            remaining.remove((current, next_point))
            outgoing[current].remove(next_point)
            previous, current = current, next_point

        if current == first and len(loop) >= 4:
            loops.append(loop)
    return loops


def perpendicular_distance(point: Point, start: Point, end: Point) -> float:
    dx = end[0] - start[0]
    dy = end[1] - start[1]
    if dx == 0 and dy == 0:
        return math.dist(point, start)
    return abs(dy * point[0] - dx * point[1] + end[0] * start[1] - end[1] * start[0]) / math.hypot(dx, dy)


def rdp(points: Sequence[Point], epsilon: float) -> list[Point]:
    if len(points) <= 2:
        return list(points)
    start = points[0]
    end = points[-1]
    farthest_distance = 0.0
    farthest_index = 0
    for index in range(1, len(points) - 1):
        distance = perpendicular_distance(points[index], start, end)
        if distance > farthest_distance:
            farthest_distance = distance
            farthest_index = index
    if farthest_distance <= epsilon:
        return [start, end]
    left = rdp(points[: farthest_index + 1], epsilon)
    right = rdp(points[farthest_index:], epsilon)
    return left[:-1] + right


def simplify_closed(points: list[Point], epsilon: float) -> list[Point]:
    if len(points) < 8:
        return points
    first_index = min(range(len(points)), key=lambda index: (points[index][0], points[index][1]))
    rotated = points[first_index:] + points[:first_index]
    split_index = max(range(1, len(rotated)), key=lambda index: math.dist(rotated[0], rotated[index]))
    first_half = rdp(rotated[: split_index + 1], epsilon)
    second_half = rdp(rotated[split_index:] + [rotated[0]], epsilon)
    simplified = first_half[:-1] + second_half[:-1]
    return simplified if len(simplified) >= 3 else points


def number(value: float) -> str:
    rendered = f"{value:.2f}".rstrip("0").rstrip(".")
    return "0" if rendered == "-0" else rendered


def smooth_loop(points: list[Point], tension: float = 0.58) -> str:
    count = len(points)
    if count < 3:
        return ""
    commands = [f"M{number(points[0][0])} {number(points[0][1])}"]
    for index in range(count):
        previous = points[(index - 1) % count]
        start = points[index]
        end = points[(index + 1) % count]
        following = points[(index + 2) % count]
        control_1 = (
            start[0] + (end[0] - previous[0]) * tension / 6,
            start[1] + (end[1] - previous[1]) * tension / 6,
        )
        control_2 = (
            end[0] - (following[0] - start[0]) * tension / 6,
            end[1] - (following[1] - start[1]) * tension / 6,
        )
        commands.append(
            "C"
            f"{number(control_1[0])} {number(control_1[1])} "
            f"{number(control_2[0])} {number(control_2[1])} "
            f"{number(end[0])} {number(end[1])}"
        )
    commands.append("Z")
    return " ".join(commands)


def vectorise(mask: Mask, width: int, height: int, epsilon: float) -> str:
    paths: list[str] = []
    for loop in edge_loops(mask, width, height):
        simplified = simplify_closed(loop, epsilon)
        path = smooth_loop(simplified)
        if path:
            paths.append(path)
    return " ".join(paths)


def path_element(path: str, fill: str, *, transform: str | None = None) -> str:
    transform_attribute = f' transform="{transform}"' if transform else ""
    return f'<path d="{path}" fill="{fill}" fill-rule="evenodd"{transform_attribute}/>'


def defs() -> str:
    return f"""
  <defs>
    <linearGradient id="navy" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#13203F"/><stop offset="1" stop-color="{PALETTE['navy_deep']}"/>
    </linearGradient>
    <linearGradient id="cream" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#FFFBEA"/><stop offset="1" stop-color="{PALETTE['cream_shadow']}"/>
    </linearGradient>
    <linearGradient id="orange" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#F65B20"/><stop offset="1" stop-color="{PALETTE['orange_deep']}"/>
    </linearGradient>
    <linearGradient id="yellow" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="{PALETTE['yellow_light']}"/><stop offset="1" stop-color="#F3A30E"/>
    </linearGradient>
    <linearGradient id="red" x1="0" y1="0" x2="1" y2="1">
      <stop offset="0" stop-color="#AA1823"/><stop offset="1" stop-color="{PALETTE['red_deep']}"/>
    </linearGradient>
  </defs>""".strip()


def svg_document(artwork: Artwork) -> str:
    return f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {artwork.width} {artwork.height}" role="img" aria-labelledby="title">
  <title id="title">{artwork.title}</title>
  {defs()}
  {artwork.body}
</svg>
"""


def source_paths() -> dict[str, dict[str, str]]:
    result: dict[str, dict[str, str]] = {}

    primary_image, primary_pixels = image_pixels(PRIMARY_SOURCE)
    width, height = primary_image.size
    primary_base = soften(
        select_components(alpha_mask(primary_pixels, 128), width, height, lambda _, rank: rank == 0), width, height, 0.9
    )
    primary_cream_raw = colour_mask(
        primary_pixels,
        lambda hue, saturation, value, *_: value >= 0.62 and saturation <= 0.33 and (hue <= 0.18 or hue >= 0.95),
    )
    primary_cream = soften(
        dilate(
            select_components(primary_cream_raw, width, height, lambda component, rank: rank == 0 and component.area > 1000),
            width,
            height,
        ),
        width,
        height,
        0.75,
    )
    primary_warm_raw = colour_mask(
        primary_pixels,
        lambda hue, saturation, value, *_: (hue <= 0.19 or hue >= 0.97) and saturation >= 0.42 and value >= 0.45,
    )
    primary_warm = soften(
        dilate(select_components(primary_warm_raw, width, height, lambda component, _: component.area >= 40), width, height),
        width,
        height,
        0.65,
    )
    primary_yellow_raw = colour_mask(
        primary_pixels,
        lambda hue, saturation, value, *_: 0.075 <= hue <= 0.19 and saturation >= 0.42 and value >= 0.45,
    )
    primary_yellow = soften(
        dilate(select_components(primary_yellow_raw, width, height, lambda component, _: component.area >= 20), width, height),
        width,
        height,
        0.6,
    )
    primary_ear = soften(union_masks(primary_cream, primary_warm, primary_yellow), width, height, 1.2)
    result["primary"] = {
        "base": vectorise(primary_base, width, height, 2.4),
        "cream": vectorise(primary_cream, width, height, 1.8),
        "warm": vectorise(primary_warm, width, height, 1.55),
        "yellow": vectorise(primary_yellow, width, height, 1.35),
        "ear": vectorise(primary_ear, width, height, 1.8),
    }

    badge_image, badge_pixels = image_pixels(BADGE_SOURCE)
    width, height = badge_image.size
    badge_base = soften(
        select_components(alpha_mask(badge_pixels, 128), width, height, lambda _, rank: rank == 0), width, height, 1.0
    )
    badge_yellow_raw = colour_mask(
        badge_pixels,
        lambda hue, saturation, value, *_: 0.075 <= hue <= 0.19 and saturation >= 0.42 and value >= 0.45,
    )
    badge_yellow_components = components(badge_yellow_raw, width, height)
    scallop_indexes = set(badge_yellow_components[0].pixels)
    scallop = soften(
        dilate(bytearray(1 if index in scallop_indexes else 0 for index in range(width * height)), width, height),
        width,
        height,
        0.9,
    )
    badge_body_raw = colour_mask(
        badge_pixels,
        lambda hue, saturation, value, *_: 0.52 <= hue <= 0.76 and saturation >= 0.32 and value <= 0.55,
    )
    badge_body = soften(
        dilate(select_components(badge_body_raw, width, height, lambda _, rank: rank == 0), width, height),
        width,
        height,
        0.8,
    )
    badge_cream_raw = colour_mask(
        badge_pixels,
        lambda hue, saturation, value, *_: value >= 0.62 and saturation <= 0.33 and (hue <= 0.18 or hue >= 0.95),
    )
    badge_cream = soften(
        dilate(select_components(badge_cream_raw, width, height, lambda _, rank: rank == 0), width, height),
        width,
        height,
        0.7,
    )
    badge_red_raw = colour_mask(
        badge_pixels,
        lambda hue, saturation, value, *_: (hue <= 0.075 or hue >= 0.97) and saturation >= 0.42 and value >= 0.35,
    )
    badge_ear_red = soften(
        dilate(
            select_components(
                badge_red_raw,
                width,
                height,
                lambda component, _: 50 <= component.area <= 2000
                and 70 <= component.centre[0] <= 140
                and 45 <= component.centre[1] <= 165,
            ),
            width,
            height,
        ),
        width,
        height,
        0.65,
    )
    badge_ear_yellow = soften(
        dilate(
            select_components(
                badge_yellow_raw,
                width,
                height,
                lambda component, rank: rank > 0
                and component.area >= 20
                and 70 <= component.centre[0] <= 140
                and 45 <= component.centre[1] <= 165,
            ),
            width,
            height,
        ),
        width,
        height,
        0.6,
    )
    result["badge"] = {
        "base": vectorise(badge_base, width, height, 2.4),
        "scallop": vectorise(scallop, width, height, 1.8),
        "body": vectorise(badge_body, width, height, 2.2),
        "cream": vectorise(badge_cream, width, height, 1.6),
        "warm": vectorise(badge_ear_red, width, height, 1.4),
        "yellow": vectorise(badge_ear_yellow, width, height, 1.2),
    }

    framed_image, framed_pixels = image_pixels(FRAMED_SOURCE)
    width, height = framed_image.size
    framed_alpha = alpha_mask(framed_pixels)
    framed_body = soften(select_components(framed_alpha, width, height, lambda _, rank: rank == 0), width, height, 1.2)
    framed_cream_raw = colour_mask(
        framed_pixels,
        lambda hue, saturation, value, *_: value >= 0.62 and saturation <= 0.33 and (hue <= 0.18 or hue >= 0.95),
    )
    framed_cream = soften(
        dilate(
            select_components(framed_cream_raw, width, height, lambda component, rank: rank == 0 and component.area > 10000),
            width,
            height,
        ),
        width,
        height,
        1.0,
    )
    framed_red_raw = colour_mask(
        framed_pixels,
        lambda hue, saturation, value, *_: (hue <= 0.075 or hue >= 0.97) and saturation >= 0.42 and value >= 0.35,
    )
    framed_red = soften(
        dilate(select_components(framed_red_raw, width, height, lambda component, _: component.area >= 20), width, height),
        width,
        height,
        0.9,
    )
    framed_yellow_raw = colour_mask(
        framed_pixels,
        lambda hue, saturation, value, *_: 0.075 <= hue <= 0.19 and saturation >= 0.42 and value >= 0.45,
    )
    framed_yellow = soften(
        dilate(select_components(framed_yellow_raw, width, height, lambda component, _: component.area >= 20), width, height),
        width,
        height,
        0.9,
    )
    framed_teal_raw = colour_mask(
        framed_pixels,
        lambda hue, saturation, value, *_: 0.32 <= hue <= 0.55 and saturation >= 0.18 and value >= 0.3,
    )
    framed_teal = soften(
        dilate(select_components(framed_teal_raw, width, height, lambda component, _: component.area >= 20), width, height),
        width,
        height,
        0.8,
    )
    result["framed"] = {
        "body": vectorise(framed_body, width, height, 3.2),
        "cream": vectorise(framed_cream, width, height, 2.6),
        "red": vectorise(framed_red, width, height, 2.1),
        "yellow": vectorise(framed_yellow, width, height, 2.0),
        "teal": vectorise(framed_teal, width, height, 1.6),
    }

    wordmark_image, wordmark_pixels = image_pixels(WORDMARK_SOURCE)
    width, height = wordmark_image.size
    wordmark_alpha = alpha_mask(wordmark_pixels)
    wordmark_base = soften(
        select_components(wordmark_alpha, width, height, lambda component, _: component.area >= 1000 and component.bbox[0] >= 20),
        width,
        height,
        1.0,
    )
    wordmark_eers = soften(
        select_components(wordmark_alpha, width, height, lambda component, _: component.area >= 1000 and component.bbox[0] >= 170),
        width,
        height,
        1.0,
    )
    wordmark_cream_raw = colour_mask(
        wordmark_pixels,
        lambda hue, saturation, value, *_: value >= 0.62 and saturation <= 0.33 and (hue <= 0.18 or hue >= 0.95),
    )
    wordmark_cream = soften(
        dilate(select_components(wordmark_cream_raw, width, height, lambda component, _: component.area >= 1000), width, height),
        width,
        height,
        0.85,
    )
    wordmark_eers_cream = soften(
        dilate(
            select_components(
                wordmark_cream_raw,
                width,
                height,
                lambda component, _: component.area >= 500 and component.bbox[0] >= 170,
            ),
            width,
            height,
        ),
        width,
        height,
        0.85,
    )
    wordmark_red_raw = colour_mask(
        wordmark_pixels,
        lambda hue, saturation, value, *_: (hue <= 0.075 or hue >= 0.97) and saturation >= 0.42 and value >= 0.35,
    )
    wordmark_ear_red = soften(
        dilate(
            select_components(
                wordmark_red_raw,
                width,
                height,
                lambda component, _: 100 <= component.area <= 1000 and component.bbox[0] < 150,
            ),
            width,
            height,
        ),
        width,
        height,
        0.75,
    )
    wordmark_yellow_raw = colour_mask(
        wordmark_pixels,
        lambda hue, saturation, value, *_: 0.075 <= hue <= 0.19 and saturation >= 0.42 and value >= 0.45,
    )
    wordmark_yellow = soften(
        dilate(
            select_components(
                wordmark_yellow_raw,
                width,
                height,
                lambda component, _: component.area >= 20 and component.bbox[0] < 150,
            ),
            width,
            height,
        ),
        width,
        height,
        0.7,
    )
    result["wordmark"] = {
        "base": vectorise(wordmark_base, width, height, 2.9),
        "cream": vectorise(wordmark_cream, width, height, 2.2),
        "warm": vectorise(wordmark_ear_red, width, height, 1.7),
        "yellow": vectorise(wordmark_yellow, width, height, 1.45),
        "eers": vectorise(wordmark_eers, width, height, 2.9),
        "eers_cream": vectorise(wordmark_eers_cream, width, height, 2.2),
    }

    result["legacy"] = dict(result["primary"])

    return result


def artworks(paths: dict[str, dict[str, str]]) -> list[Artwork]:
    primary = paths["primary"]
    badge = paths["badge"]
    framed = paths["framed"]
    wordmark = paths["wordmark"]
    legacy = paths["legacy"]

    primary_layers = "\n  ".join(
        [
            path_element(primary["base"], "url(#navy)"),
            path_element(primary["cream"], "url(#cream)"),
            path_element(primary["warm"], "url(#orange)"),
            path_element(primary["yellow"], "url(#yellow)"),
        ]
    )
    badge_layers = "\n  ".join(
        [
            path_element(badge["base"], "url(#orange)"),
            path_element(badge["scallop"], "url(#yellow)"),
            path_element(badge["body"], "url(#navy)"),
            path_element(badge["cream"], "url(#cream)"),
            path_element(badge["warm"], "url(#orange)"),
            path_element(badge["yellow"], "url(#yellow)"),
        ]
    )
    framed_layers = "\n  ".join(
        [
            path_element(framed["body"], "url(#navy)"),
            path_element(framed["cream"], "url(#cream)"),
            path_element(framed["red"], "url(#orange)"),
            path_element(framed["yellow"], "url(#yellow)"),
            path_element(framed["teal"], PALETTE["sage"]),
        ]
    )
    wordmark_layers = "\n  ".join(
        [
            path_element(badge["base"], "url(#orange)"),
            path_element(badge["scallop"], "url(#yellow)"),
            path_element(badge["body"], "url(#navy)"),
            path_element(badge["cream"], "url(#cream)"),
            path_element(badge["warm"], "url(#orange)"),
            path_element(badge["yellow"], "url(#yellow)"),
            path_element(wordmark["eers"], "url(#red)"),
            path_element(wordmark["eers_cream"], "url(#cream)"),
        ]
    )
    lockup_layers = "\n  ".join(
        [
            path_element(primary["base"], "url(#navy)"),
            path_element(primary["cream"], "url(#cream)"),
            path_element(primary["warm"], "url(#orange)"),
            path_element(primary["yellow"], "url(#yellow)"),
            path_element(wordmark["eers"], "url(#red)", transform="translate(-115 -20)"),
            path_element(wordmark["eers_cream"], "url(#cream)", transform="translate(-115 -20)"),
        ]
    )
    monochrome_path = f"{primary['base']} {primary['ear']}"
    monochrome_ink_layers = "\n  ".join(
        [path_element(monochrome_path, PALETTE["navy"]), path_element(primary["warm"], PALETTE["navy"])]
    )
    monochrome_cream_layers = "\n  ".join(
        [path_element(monochrome_path, PALETTE["cream"]), path_element(primary["warm"], PALETTE["cream"])]
    )
    reversed_layers = "\n  ".join(
        [
            f'<rect width="205" height="205" rx="38" fill="{PALETTE["navy"]}"/>',
            path_element(primary["base"], PALETTE["cream"], transform="translate(35 20)"),
            path_element(primary["cream"], PALETTE["navy"], transform="translate(35 20)"),
            path_element(primary["warm"], PALETTE["orange"], transform="translate(35 20)"),
            path_element(primary["yellow"], PALETTE["yellow"], transform="translate(35 20)"),
        ]
    )
    legacy_layers = "\n  ".join(
        [
            path_element(legacy["base"], "url(#navy)"),
            path_element(legacy["cream"], "url(#cream)"),
            path_element(legacy["warm"], "url(#orange)"),
            path_element(legacy["yellow"], "url(#yellow)"),
        ]
    )

    return [
        Artwork("beers-b-primary", "Beers primary B mark", 135, 165, primary_layers),
        Artwork("beers-b-badge", "Beers scalloped app badge", 200, 212, badge_layers),
        Artwork("beers-b-framed", "Beers framed B mark", 765, 655, framed_layers),
        Artwork("beers-wordmark", "Beers complete wordmark", 645, 212, wordmark_layers),
        Artwork("beers-lockup-horizontal", "Beers horizontal B and eers lockup", 575, 165, lockup_layers),
        Artwork(
            "beers-b-one-colour-ink",
            "Beers one-colour ink B mark",
            135,
            165,
            monochrome_ink_layers,
        ),
        Artwork(
            "beers-b-one-colour-cream",
            "Beers one-colour cream B mark",
            135,
            165,
            monochrome_cream_layers,
        ),
        Artwork("beers-b-reversed", "Beers reversed B tile", 205, 205, reversed_layers),
        Artwork("beers-ear-b-legacy", "Beers standalone B compatibility mark", 135, 165, legacy_layers, legacy=True),
    ]


def render_4k(svg_path: Path, png_path: Path, width: int, height: int) -> tuple[int, int]:
    if not RSVG:
        raise RuntimeError("rsvg-convert is required to render the PNG exports")
    if width >= height:
        rendered_width = 4096
        rendered_height = round(4096 * height / width)
    else:
        rendered_height = 4096
        rendered_width = round(4096 * width / height)
    subprocess.run(
        [RSVG, "--width", str(rendered_width), "--height", str(rendered_height), str(svg_path), "--output", str(png_path)],
        check=True,
    )
    return rendered_width, rendered_height


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    candidates = [
        Path("/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else "/System/Library/Fonts/Supplemental/Arial.ttf"),
        Path("/System/Library/Fonts/SFNS.ttf"),
    ]
    for candidate in candidates:
        if candidate.exists():
            return ImageFont.truetype(str(candidate), size)
    return ImageFont.load_default()


def checkerboard(size: tuple[int, int], dark: bool = False) -> Image.Image:
    light = (19, 34, 66, 255) if dark else (255, 250, 237, 255)
    shade = (10, 23, 53, 255) if dark else (245, 237, 218, 255)
    image = Image.new("RGBA", size, light)
    draw = ImageDraw.Draw(image)
    tile = 24
    for y in range(0, size[1], tile):
        for x in range(0, size[0], tile):
            if (x // tile + y // tile) % 2:
                draw.rectangle((x, y, x + tile - 1, y + tile - 1), fill=shade)
    return image


def contact_sheet(generated: Sequence[tuple[Artwork, Path]]) -> None:
    canvas = Image.new("RGB", (2400, 1840), (255, 247, 225))
    draw = ImageDraw.Draw(canvas)
    title_font = font(70, bold=True)
    body_font = font(30)
    label_font = font(33, bold=True)
    small_font = font(24)

    draw.text((100, 62), "Beers logo asset pack", fill=PALETTE["navy"], font=title_font)
    draw.text((100, 148), "True SVG masters + longest-edge 4096px transparent PNG exports", fill=(75, 69, 60), font=body_font)

    card_width = 700
    card_height = 460
    x_positions = [100, 850, 1600]
    y_positions = [235, 735, 1235]

    labels = {
        "beers-b-primary": "Primary B",
        "beers-b-badge": "Scalloped badge",
        "beers-b-framed": "Framed mark",
        "beers-wordmark": "Complete wordmark",
        "beers-lockup-horizontal": "Horizontal lockup",
        "beers-b-one-colour-ink": "One-colour ink",
        "beers-b-one-colour-cream": "One-colour cream",
        "beers-b-reversed": "Reversed tile",
        "beers-ear-b-legacy": "Legacy ear B",
    }

    for index, (artwork, png_path) in enumerate(generated):
        column = index % 3
        row = index // 3
        x = x_positions[column]
        y = y_positions[row]
        dark = artwork.name == "beers-b-one-colour-cream"
        card = checkerboard((card_width, card_height), dark=dark)
        card_draw = ImageDraw.Draw(card)
        card_draw.rounded_rectangle(
            (0, 0, card_width - 1, card_height - 1),
            radius=28,
            outline=(223, 209, 179) if not dark else (61, 77, 112),
            width=3,
        )

        with Image.open(png_path).convert("RGBA") as asset:
            asset.thumbnail((card_width - 100, card_height - 120), Image.Resampling.LANCZOS)
            asset_x = (card_width - asset.width) // 2
            asset_y = 30 + (card_height - 115 - asset.height) // 2
            card.alpha_composite(asset, (asset_x, asset_y))

        label_colour = (255, 247, 225) if dark else PALETTE["navy"]
        suffix = " · legacy" if artwork.legacy else ""
        card_draw.text((28, card_height - 72), labels[artwork.name] + suffix, fill=label_colour, font=label_font)
        canvas.paste(card.convert("RGB"), (x, y))

    draw.text(
        (100, 1740),
        "Canonical v2 · Clean Imagen masters · One coherent badge and B geometry",
        fill=(75, 69, 60),
        font=small_font,
    )
    PREVIEW_DIR.mkdir(parents=True, exist_ok=True)
    canvas.save(PREVIEW_DIR / "beers-logo-pack-contact-sheet.png", optimize=True)


def write_readme(dimensions: dict[str, tuple[int, int]]) -> None:
    rows = [
        ("beers-b-primary", "Standalone canonical B", "Transparent"),
        ("beers-b-badge", "Scalloped app/site badge", "Transparent"),
        ("beers-b-framed", "Decorative framed B", "Transparent"),
        ("beers-wordmark", "Complete red Beers wordmark", "Transparent"),
        ("beers-lockup-horizontal", "B replaces the B in Beers", "Transparent"),
        ("beers-b-one-colour-ink", "Single-colour navy mark", "Transparent"),
        ("beers-b-one-colour-cream", "Single-colour reverse mark", "Transparent; dark backgrounds"),
        ("beers-b-reversed", "Cream B on rounded navy tile", "Transparent outer corners"),
    ]
    table = "\n".join(
        f"| `{name}` | {purpose} | {dimensions[name][0]}×{dimensions[name][1]} | {background} |"
        for name, purpose, background in rows
    )
    readme = f"""# Beers logo pack v2

This is the production-ready Beers logo pack. Every canonical asset is supplied as a true, editable SVG path and as a high-resolution PNG whose longest edge is exactly 4096 pixels. No SVG embeds a raster image or depends on a font.

## Canonical assets

| Asset | Use | PNG dimensions | Background |
|---|---|---:|---|
{table}

SVG masters live in `svg/`; paired PNG exports live in `png-4k/`.

## Which mark to use

- Use `beers-b-badge` for the app icon and primary product identity.
- Use `beers-lockup-horizontal` when the full name is needed: the B mark replaces the letter B.
- Use `beers-b-primary` only where the badge would be too busy, such as compact navigation, favicons, avatars, stickers, and small print.
- Use the one-colour files for embroidery, stamps, vinyl, laser work, and single-ink print.
- Keep clear space around a mark equal to at least one quarter of the B's width. Do not stretch, recolour, rotate, outline, or rearrange it.

## Compatibility

`legacy/beers-ear-b-legacy` now carries the clean standalone B geometry so old consumers no longer receive the rough retired artwork.

## Palette

| Name | Hex |
|---|---|
| Ink navy | `{PALETTE['navy']}` |
| Cream | `{PALETTE['cream']}` |
| Pour orange | `{PALETTE['orange']}` |
| Golden yellow | `{PALETTE['yellow']}` |
| Wordmark red | `{PALETTE['red']}` |
| Accent sage | `{PALETTE['sage']}` |

The SVG masters use restrained gradients within this palette to retain the warmth of the original artwork. The one-colour versions use flat fills.

## Rebuild

From the repository root:

```sh
python3 scripts/export-brand-assets.py
```

Requirements: Python 3 with Pillow and `rsvg-convert`. The clean Imagen source masters used for vector reconstruction are preserved in `../source-raster-v2/`.
"""
    (OUTPUT / "README.md").write_text(readme, encoding="utf-8")


def main() -> None:
    missing = [path for path in (PRIMARY_SOURCE, BADGE_SOURCE, FRAMED_SOURCE, WORDMARK_SOURCE, LEGACY_SOURCE) if not path.exists()]
    if missing:
        raise SystemExit("Missing source artwork:\n" + "\n".join(str(path) for path in missing))

    for directory in (SVG_DIR, PNG_DIR, LEGACY_SVG_DIR, LEGACY_PNG_DIR, PREVIEW_DIR):
        directory.mkdir(parents=True, exist_ok=True)

    vector_paths = source_paths()
    generated: list[tuple[Artwork, Path]] = []
    dimensions: dict[str, tuple[int, int]] = {}

    for artwork in artworks(vector_paths):
        svg_directory = LEGACY_SVG_DIR if artwork.legacy else SVG_DIR
        png_directory = LEGACY_PNG_DIR if artwork.legacy else PNG_DIR
        svg_path = svg_directory / f"{artwork.name}.svg"
        png_path = png_directory / f"{artwork.name}.png"
        svg_path.write_text(svg_document(artwork), encoding="utf-8")
        dimensions[artwork.name] = render_4k(svg_path, png_path, artwork.width, artwork.height)
        generated.append((artwork, png_path))

    contact_sheet(generated)
    write_readme(dimensions)
    print(f"Built {len(generated)} SVG/PNG pairs in {OUTPUT}")


if __name__ == "__main__":
    main()
