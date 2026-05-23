"""
Dynamic playlist artwork generator.

Renders a 500x500 JPEG cover for the daily Spotify playlist using Playwright +
HTML/CSS. The artwork is themed as the broadcast slate for a futuristic pirate
radio show — dark, purple, cinematic — with the playlist's creation date
stamped vertically in the format:

    MAY
    22
    26

Public API:
    generate_artwork(date: datetime.datetime, output_path: str) -> str
"""

import bootstrap  # noqa: F401  (ensures playwright is installed)
import datetime
import os
import random
from playwright.sync_api import sync_playwright


ARTWORK_SIZE = 500


def _build_html(date: datetime.datetime) -> str:
    """Return the full HTML document for the artwork at the given date."""
    month = date.strftime("%b").upper()       # e.g. "MAY"
    day = date.strftime("%d").lstrip("0") or "0"  # e.g. "22"
    year = date.strftime("%y")                 # e.g. "26"

    # Deterministic randomness so the same date always renders identically.
    rng = random.Random(date.strftime("%Y%m%d"))

    # Scattered starfield
    stars = []
    for _ in range(70):
        x = rng.uniform(0, 100)
        y = rng.uniform(0, 100)
        size = rng.choice([1, 1, 1, 1.5, 2, 2.5])
        opacity = rng.uniform(0.35, 1.0)
        stars.append(
            f'<div class="star" style="left:{x:.2f}%;top:{y:.2f}%;'
            f'width:{size}px;height:{size}px;opacity:{opacity:.2f};"></div>'
        )

    # Glitch / pixel artifact rectangles in the corners (purple data-corruption)
    glitches = []
    for _ in range(22):
        # cluster near the four corners
        corner = rng.choice(["tl", "tr", "bl", "br"])
        if corner == "tl":
            x = rng.uniform(0, 22); y = rng.uniform(0, 22)
        elif corner == "tr":
            x = rng.uniform(78, 100); y = rng.uniform(0, 22)
        elif corner == "bl":
            x = rng.uniform(0, 22); y = rng.uniform(78, 100)
        else:
            x = rng.uniform(78, 100); y = rng.uniform(78, 100)
        w = rng.choice([6, 8, 10, 14, 18, 24])
        h = rng.choice([2, 3, 4, 6, 8])
        shade = rng.choice([
            "rgba(124,58,237,0.55)",
            "rgba(168,85,247,0.45)",
            "rgba(76,29,149,0.7)",
            "rgba(192,132,252,0.35)",
            "rgba(20,5,40,0.85)",
        ])
        glitches.append(
            f'<div class="glitch" style="left:{x:.2f}%;top:{y:.2f}%;'
            f'width:{w}px;height:{h}px;background:{shade};"></div>'
        )

    stars_html = "\n".join(stars)
    glitches_html = "\n".join(glitches)

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8" />
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Black+Ops+One&family=JetBrains+Mono:wght@500;700&display=swap" rel="stylesheet">
<style>
  * {{ margin: 0; padding: 0; box-sizing: border-box; }}
  html, body {{
    width: {ARTWORK_SIZE}px;
    height: {ARTWORK_SIZE}px;
    overflow: hidden;
    background: #000;
  }}

  .artwork {{
    position: relative;
    width: {ARTWORK_SIZE}px;
    height: {ARTWORK_SIZE}px;
    overflow: hidden;
    font-family: 'JetBrains Mono', monospace;
    color: #f4f0ff;
    background:
      radial-gradient(ellipse 60% 45% at 50% 55%, rgba(139,92,246,0.45) 0%, rgba(76,29,149,0.25) 35%, transparent 70%),
      radial-gradient(ellipse 90% 60% at 50% 100%, rgba(91,33,182,0.55) 0%, transparent 60%),
      radial-gradient(ellipse 40% 30% at 20% 15%, rgba(124,58,237,0.25) 0%, transparent 60%),
      radial-gradient(ellipse 35% 25% at 85% 20%, rgba(168,85,247,0.18) 0%, transparent 60%),
      linear-gradient(180deg, #06030f 0%, #140828 45%, #1c0a3a 70%, #08030f 100%);
  }}

  /* Subtle vignette tightens the frame */
  .vignette {{
    position: absolute; inset: 0;
    background: radial-gradient(ellipse at 50% 50%, transparent 55%, rgba(0,0,0,0.75) 100%);
    pointer-events: none;
    z-index: 60;
  }}

  /* Procedural noise overlay for grain */
  .noise {{
    position: absolute; inset: 0;
    opacity: 0.12;
    mix-blend-mode: overlay;
    background-image: url("data:image/svg+xml,%3Csvg viewBox='0 0 200 200' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.85' numOctaves='3' stitchTiles='stitch'/%3E%3CfeColorMatrix values='0 0 0 0 0.55  0 0 0 0 0.35  0 0 0 0 0.95  0 0 0 0.9 0'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)'/%3E%3C/svg%3E");
    pointer-events: none;
    z-index: 50;
  }}

  /* CRT scanlines */
  .scanlines {{
    position: absolute; inset: 0;
    background: repeating-linear-gradient(
      0deg,
      rgba(0,0,0,0) 0px,
      rgba(0,0,0,0) 2px,
      rgba(0,0,0,0.18) 3px,
      rgba(0,0,0,0) 4px
    );
    pointer-events: none;
    mix-blend-mode: multiply;
    z-index: 55;
  }}

  /* Stars */
  .star {{
    position: absolute;
    background: #fff;
    border-radius: 50%;
    box-shadow: 0 0 6px rgba(255,255,255,0.85), 0 0 12px rgba(216,180,254,0.5);
    z-index: 3;
  }}

  /* Glitch pixel chunks near corners */
  .glitch {{
    position: absolute;
  }}

  /* Concentric signal rings emanating from antenna tip */
  .signal {{
    position: absolute;
    left: 50%; top: 50%;
    transform: translate(-50%, -50%);
    width: 480px; height: 480px;
    border-radius: 50%;
    background:
      radial-gradient(circle at 50% 50%,
        transparent 0%, transparent 6%,
        rgba(192,132,252,0.55) 6.4%, rgba(192,132,252,0.55) 6.8%, transparent 7.2%,
        transparent 13%,
        rgba(192,132,252,0.42) 13.4%, rgba(192,132,252,0.42) 13.8%, transparent 14.2%,
        transparent 21%,
        rgba(168,85,247,0.32) 21.4%, rgba(168,85,247,0.32) 21.8%, transparent 22.2%,
        transparent 30%,
        rgba(168,85,247,0.22) 30.4%, rgba(168,85,247,0.22) 30.8%, transparent 31.2%,
        transparent 40%,
        rgba(168,85,247,0.14) 40.4%, rgba(168,85,247,0.14) 40.8%, transparent 41.2%,
        transparent 100%
      );
    z-index: 5;
    filter: blur(0.5px);
    opacity: 0.85;
  }}

  /* Soft purple core glow centred on the tower base */
  .core-glow {{
    position: absolute;
    left: 50%; top: 50%;
    transform: translate(-50%, -50%);
    width: 280px; height: 280px;
    border-radius: 50%;
    background: radial-gradient(circle, rgba(192,132,252,0.4) 0%, rgba(124,58,237,0.18) 35%, transparent 70%);
    z-index: 4;
    filter: blur(8px);
  }}

  /* Vinyl ripple ground */
  .vinyl {{
    position: absolute;
    left: 50%;
    bottom: -110px;
    transform: translateX(-50%);
    width: 720px; height: 220px;
    border-radius: 50%;
    background:
      radial-gradient(ellipse at center,
        rgba(192,132,252,0.55) 0%,
        rgba(124,58,237,0.45) 15%,
        transparent 18%,
        transparent 24%,
        rgba(168,85,247,0.30) 26%,
        transparent 30%,
        transparent 38%,
        rgba(168,85,247,0.20) 40%,
        transparent 44%,
        transparent 56%,
        rgba(168,85,247,0.12) 58%,
        transparent 62%,
        transparent 100%
      );
    z-index: 8;
    filter: blur(0.6px);
  }}

  /* Radio tower SVG container */
  .tower {{
    position: absolute;
    left: 50%;
    top: 50%;
    transform: translate(-50%, -45%);
    width: 100px;
    height: 360px;
    z-index: 6;
    opacity: 1;
    filter: drop-shadow(0 0 12px rgba(192,132,252,0.6));
  }}
  .tower svg {{ width: 100%; height: 100%; display: block; }}

  /* Stacked date display — fills the entire canvas, big & bold for sidebar legibility */
  .date {{
    position: absolute;
    inset: 0;
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    z-index: 20;
    font-family: 'Black Ops One', sans-serif;
    color: #ffffff;
    line-height: 0.85;
    text-align: center;
    text-shadow:
      0 0 2px rgba(255,255,255,0.95),
      0 0 22px rgba(192,132,252,0.7),
      0 0 48px rgba(124,58,237,0.55);
  }}
  .date .line {{
    display: block;
  }}
  .date .month {{
    font-size: 168px;
    letter-spacing: 0.005em;
  }}
  .date .day,
  .date .year {{
    font-size: 200px;
    letter-spacing: 0.08em;  /* widen 2-char lines toward MAY's width */
  }}
</style>
</head>
<body>
  <div class="artwork">
    {stars_html}

    <div class="signal"></div>
    <div class="core-glow"></div>

    <div class="tower">
      <svg viewBox="0 0 80 320" xmlns="http://www.w3.org/2000/svg" preserveAspectRatio="none">
        <defs>
          <linearGradient id="towerGrad" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stop-color="#1a0830" stop-opacity="0.95"/>
            <stop offset="100%" stop-color="#0a0420" stop-opacity="0.98"/>
          </linearGradient>
          <linearGradient id="towerEdge" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0%" stop-color="#c084fc" stop-opacity="0.95"/>
            <stop offset="100%" stop-color="#7c3aed" stop-opacity="0.4"/>
          </linearGradient>
        </defs>
        <!-- antenna mast -->
        <line x1="40" y1="0" x2="40" y2="40" stroke="url(#towerEdge)" stroke-width="1.4"/>
        <circle cx="40" cy="0" r="2.4" fill="#f0abfc"/>
        <!-- tower body (silhouette + lattice) -->
        <polygon points="40,40 18,320 62,320" fill="url(#towerGrad)" stroke="url(#towerEdge)" stroke-width="0.9"/>
        <!-- horizontal cross-braces -->
        <line x1="33" y1="90"  x2="47" y2="90"  stroke="url(#towerEdge)" stroke-width="0.7"/>
        <line x1="29" y1="140" x2="51" y2="140" stroke="url(#towerEdge)" stroke-width="0.7"/>
        <line x1="26" y1="180" x2="54" y2="180" stroke="url(#towerEdge)" stroke-width="0.7"/>
        <line x1="22" y1="230" x2="58" y2="230" stroke="url(#towerEdge)" stroke-width="0.7"/>
        <line x1="20" y1="275" x2="60" y2="275" stroke="url(#towerEdge)" stroke-width="0.7"/>
        <!-- X-braces -->
        <line x1="33" y1="90"  x2="51" y2="140" stroke="url(#towerEdge)" stroke-width="0.5" opacity="0.7"/>
        <line x1="47" y1="90"  x2="29" y2="140" stroke="url(#towerEdge)" stroke-width="0.5" opacity="0.7"/>
        <line x1="29" y1="140" x2="54" y2="180" stroke="url(#towerEdge)" stroke-width="0.5" opacity="0.7"/>
        <line x1="51" y1="140" x2="26" y2="180" stroke="url(#towerEdge)" stroke-width="0.5" opacity="0.7"/>
        <line x1="26" y1="180" x2="58" y2="230" stroke="url(#towerEdge)" stroke-width="0.5" opacity="0.7"/>
        <line x1="54" y1="180" x2="22" y2="230" stroke="url(#towerEdge)" stroke-width="0.5" opacity="0.7"/>
        <line x1="22" y1="230" x2="60" y2="275" stroke="url(#towerEdge)" stroke-width="0.5" opacity="0.6"/>
        <line x1="58" y1="230" x2="20" y2="275" stroke="url(#towerEdge)" stroke-width="0.5" opacity="0.6"/>
      </svg>
    </div>

    <div class="vinyl"></div>

    {glitches_html}

    <div class="date">
      <div class="line month">{month}</div>
      <div class="line day">{day}</div>
      <div class="line year">{year}</div>
    </div>

    <div class="scanlines"></div>
    <div class="noise"></div>
    <div class="vignette"></div>
  </div>
</body>
</html>
"""


def generate_artwork(date: datetime.datetime, output_path: str) -> str:
    """Render the playlist artwork for `date` to `output_path` (JPEG).

    Returns the absolute path of the file written.
    """
    html = _build_html(date)
    output_path = os.path.abspath(output_path)
    os.makedirs(os.path.dirname(output_path) or ".", exist_ok=True)

    with sync_playwright() as p:
        browser = p.chromium.launch()
        context = browser.new_context(
            viewport={"width": ARTWORK_SIZE, "height": ARTWORK_SIZE},
            device_scale_factor=1,
        )
        page = context.new_page()
        page.set_content(html, wait_until="networkidle")
        # Give web fonts an extra beat to settle even after networkidle.
        page.wait_for_timeout(400)
        page.screenshot(
            path=output_path,
            type="jpeg",
            quality=92,
            clip={"x": 0, "y": 0, "width": ARTWORK_SIZE, "height": ARTWORK_SIZE},
            omit_background=False,
        )
        browser.close()

    return output_path


if __name__ == "__main__":
    # Allow running this file directly to preview the artwork for any date.
    # Usage:  python3 generate_artwork.py                 -> uses today
    #         python3 generate_artwork.py 2026-05-22      -> uses that date
    import sys
    if len(sys.argv) > 1:
        d = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%d")
    else:
        d = datetime.datetime.now()

    out = os.path.join("generated-artwork", f"preview_{d.strftime('%m-%d-%y')}.jpg")
    path = generate_artwork(d, out)
    print(f"Wrote {path}")
