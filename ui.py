"""
Futuristic-dark terminal UI for the DX broadcast pipeline.

A small wrapper around `rich` that gives the scraper + Spotify exporter a single,
cohesive "progress screen": a HUD-style banner, phase/section rules, live progress
bars, and colour-coded status lines that narrate every key activity as it happens.

Aesthetic: Cyan-Circuit + Electric-Violet on near-black — the same palette the
playlist artwork is rendered in. Readability first: generous spacing, bold
high-contrast labels, no cramped output.

IMPORTANT — all UI is written to **stderr**. stdout is reserved for the single
machine-readable `SPOTIFY_URI:` line that the AppleScript launcher parses, so the
rich animations never pollute the data channel.
"""

import bootstrap  # noqa: F401 — ensures `rich` (and friends) are installed first

from rich import box
from rich.console import Console
from rich.panel import Panel
from rich.table import Table
from rich.text import Text
from rich.progress import (
    Progress,
    SpinnerColumn,
    BarColumn,
    TextColumn,
    MofNCompleteColumn,
    TimeElapsedColumn,
)

# ── Palette (from the futuristic-dark design system) ─────────────────────────
ACCENT = "#00f0ff"   # cyan circuit — primary accent
VIOLET = "#c084fc"   # electric violet — secondary accent (matches artwork)
MAGENTA = "#ff4fd8"  # hot magenta — explicit / highlight
PRIMARY = "#e8e8f0"  # primary text — high contrast, used for anything readable
MUTED = "#8888a0"    # secondary text — metadata only
GHOST = "#555570"    # tertiary — de-emphasised
OK = "#00ff88"       # status: success
WARN = "#f5a623"     # status: warning
ERR = "#ff3366"      # status: error
BAR_BACK = "#222230"  # unfilled progress track

# Single shared console on stderr (keeps stdout clean for SPOTIFY_URI).
console = Console(stderr=True, highlight=False, emoji=False)


# ── Banner & structural rules ────────────────────────────────────────────────
def banner() -> None:
    """Print the HUD title card for the run."""
    title = Text("D X   B R O A D C A S T   S Y S T E M", style=f"bold {ACCENT}")
    subtitle = Text("NEW MUSIC RESEARCH  ·  TIDAL → SPOTIFY PIPELINE", style=VIOLET)
    body = Text("\n").join([title, subtitle])
    body.justify = "center"
    console.print()
    console.print(
        Panel(
            body,
            box=box.HEAVY,
            border_style=ACCENT,
            padding=(1, 6),
            expand=False,
        )
    )


def phase(index: int, total: int, title: str) -> None:
    """Top-level pipeline phase — a heavy violet rule, e.g. 'PHASE 1/3 · SCRAPE'."""
    console.print()
    console.rule(
        Text(f" PHASE {index}/{total}  ·  {title} ", style=f"bold {VIOLET}"),
        style=VIOLET,
        characters="━",
    )


def section(title: str) -> None:
    """A lighter cyan sub-rule for steps inside a phase (used by the exporter)."""
    console.print()
    console.rule(
        Text(f" {title} ", style=f"bold {ACCENT}"),
        style=GHOST,
        characters="─",
        align="left",
    )


# ── Status lines ─────────────────────────────────────────────────────────────
def step(msg: str) -> None:
    console.print(f"[{ACCENT}]▸[/] [{PRIMARY}]{msg}[/]")


def ok(msg: str) -> None:
    console.print(f"[{OK}]✓[/] [{PRIMARY}]{msg}[/]")


def warn(msg: str) -> None:
    console.print(f"[{WARN}]▲[/] [{WARN}]{msg}[/]")


def err(msg: str) -> None:
    console.print(f"[{ERR}]✕[/] [{ERR}]{msg}[/]")


def info(msg: str) -> None:
    console.print(f"[{GHOST}]·[/] [{MUTED}]{msg}[/]")


def found(src: str, dst: str, explicit: bool) -> None:
    """Log a confidently matched track (src = scraped, dst = what Spotify returned)."""
    tag = "EXPLICIT" if explicit else "CLEAN"
    tag_style = MAGENTA if explicit else MUTED
    console.print(
        f"  [{OK}]✓[/] [{tag_style}]{tag:<8}[/] "
        f"[{PRIMARY}]{src}[/]  [{GHOST}]→[/]  [{MUTED}]{dst}[/]"
    )


def omitted(src: str) -> None:
    """Log a track that couldn't be confidently matched on Spotify."""
    console.print(f"  [{ERR}]✕[/] [{ERR}]{'OMITTED':<8}[/] [{MUTED}]{src}[/]")


# ── Progress bars ────────────────────────────────────────────────────────────
def progress() -> Progress:
    """A themed Progress instance. Tasks should pass a `detail=""` field.

    Use as a context manager; add tasks with
    `p.add_task("label", total=N, detail="")`.
    """
    return Progress(
        SpinnerColumn(style=ACCENT, finished_text=f"[{OK}]✓[/]"),
        TextColumn("[" + PRIMARY + "]{task.description}"),
        BarColumn(
            bar_width=None,
            style=BAR_BACK,
            complete_style=ACCENT,
            finished_style=OK,
            pulse_style=VIOLET,
        ),
        MofNCompleteColumn(),
        TextColumn("[" + MUTED + "]{task.fields[detail]}"),
        TimeElapsedColumn(),
        console=console,
        expand=True,
    )


# ── Final summary card ───────────────────────────────────────────────────────
def summary(title: str, rows: dict) -> None:
    """Print a closing stats panel with label/value rows."""
    table = Table.grid(padding=(0, 3))
    table.add_column(justify="right", style=MUTED, no_wrap=True)
    table.add_column(justify="left", style=f"bold {PRIMARY}")
    for label, value in rows.items():
        table.add_row(f"{label}", str(value))
    console.print()
    console.print(
        Panel(
            table,
            title=Text(f" {title} ", style=f"bold {OK}"),
            box=box.HEAVY,
            border_style=OK,
            padding=(1, 4),
            expand=False,
        )
    )
