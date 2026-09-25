#!/usr/bin/env python3
"""Posts a release's changelog to Discord, in the format DPIP uses (ExpTechTW/DPIP, tool/release/discord.py).

    DISCORD_WEBHOOK=... scripts/discord.py 26w39a
    scripts/discord.py 26w39a --dry-run             # prints the message instead of posting it

The note is written for GitHub and has to be cut down for Discord, which stops an embed's description at 4,096
characters and renders neither `<details>` nor HTML comments. So only the 繁體中文 half is posted, commit links keep
just their short hash, and the release page is linked at the end.
"""

import json
import os
import pathlib
import re
import sys
import time
import urllib.error
import urllib.request

REPO = os.environ.get("GITHUB_REPOSITORY", "ExpTechTW/FreeAudio")
DESCRIPTION_LIMIT = int(os.environ.get("FREEAUDIO_DISCORD_LIMIT", 4096))

# The colours of the app's own badges, which tell the two apart at a glance in a busy channel.
PRERELEASE_COLOUR = 0xE8A33D
RELEASE_COLOUR = 0x3BA55D


def api(path: str) -> dict:
    """A release, read back from the API.

    Retried on 404: this runs seconds after `gh release create`, and the API can answer 404 for a moment for a
    release that certainly exists.
    """
    fixture = os.environ.get("FREEAUDIO_RELEASE_JSON")
    if fixture:
        return json.loads(pathlib.Path(fixture).read_text())

    for attempt in range(3):
        try:
            return _get(path)
        except urllib.error.HTTPError as error:
            if error.code != 404 or attempt == 2:
                raise
            time.sleep(2 * (attempt + 1))
    raise AssertionError("unreachable")


def _get(path: str) -> dict:
    request = urllib.request.Request(
        f"https://api.github.com/repos/{REPO}/{path}",
        headers={"Accept": "application/vnd.github+json"},
    )
    token = os.environ.get("GITHUB_TOKEN")
    if token:
        request.add_header("Authorization", f"Bearer {token}")
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


def to_discord(body: str) -> str:
    """The 繁體中文 half of a release note, in what Discord can actually show."""
    # Every other language is folded in a `<details>`, which Discord doesn't render; the compare link follows them.
    body = re.split(r"^<details>|^---$", body, maxsplit=1, flags=re.M)[0]
    body = re.sub(r"\(\[`([0-9a-f]{7,8})`\]\([^)]*\)\)", r"`\1`", body)
    # GitHub hides an HTML comment, such as the build code the app reads; Discord prints it.
    body = re.sub(r"<!--.*?-->", "", body, flags=re.S)
    return re.sub(r"\n{3,}", "\n\n", body).strip()


def sections(body: str) -> list[tuple[str, list[str]]]:
    """The note split at its category headings, each as a list of entries."""
    out: list[tuple[str, list[str]]] = []
    for block in re.split(r"(?=^### )", body, flags=re.M):
        block = block.strip()
        if not block:
            continue
        title, _, rest = block.partition("\n") if block.startswith("### ") else ("", "", block)
        items = [line for line in rest.strip().splitlines() if line.strip()]
        out.append((title[4:].strip(), items))
    return out


def share(parts: list[tuple[str, list[str]]], room: int) -> list[list[str]]:
    """Splits [room] between the categories, evenly and without waste.

    Evenly, because filling from the top spends everything on 新功能 and posts 錯誤修正 as an empty heading. Without
    waste, because an equal share is a floor, not a quota: a category that needs less hands the rest back, round
    after round, until a whole round adds nothing. Only then is anything cut.
    """
    keep: list[list[str]] = [[] for _ in parts]
    left = room
    while left > 0:
        hungry = [i for i in range(len(parts)) if len(keep[i]) < len(parts[i][1])]
        if not hungry:
            break
        quota = max(left // len(hungry), 1)
        spent = 0
        for i in hungry:
            used = 0
            for item in parts[i][1][len(keep[i]) :]:
                if used + len(item) + 1 > quota:
                    break
                used += len(item) + 1
                keep[i].append(item)
            spent += used
        if spent == 0:
            break
        left -= spent
    return keep


def fit(text: str, room: int) -> str:
    """The backstop for one embed, cut between entries: a cut inside one reads as a bug in that entry."""
    if len(text) <= room:
        return text
    cut = text.rfind("\n", 0, room - 20)
    return text[: cut if cut > 0 else room - 20].rstrip() + "\n…"


def main() -> int:
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry_run = "--dry-run" in sys.argv
    if not args:
        print("usage: scripts/discord.py <tag> [--dry-run]", file=sys.stderr)
        return 2
    tag = args[0]

    release = api(f"releases/tags/{tag}")
    link = f"\n\n[在 GitHub 上檢視完整更新日誌 →]({release['html_url']})"
    colour = PRERELEASE_COLOUR if release["prerelease"] else RELEASE_COLOUR
    footer = "測試版" if release["prerelease"] else "正式版"
    heading = f"# {release['name'] or tag}"
    body = to_discord(release["body"] or "")

    parts = sections(body)
    # Each line of the notice is in italics of its own.
    intro = " ".join(line.strip("_ ") for line in parts[0][1]) if parts and not parts[0][0] else ""
    header = f"{heading}\n-# {intro}" if intro else heading
    if intro:
        parts = parts[1:]
    # Everything in the description that isn't an entry, measured rather than guessed. When the entries don't fit,
    # they're cut evenly across the categories; every entry that's posted keeps its commit.
    overhead = len(header) + len(link) + sum(len(f"\n\n### {name}\n") for name, _ in parts)
    kept = share(parts, DESCRIPTION_LIMIT - overhead)
    blocks = [header]
    for (name, items), shown in zip(parts, kept):
        block = f"### {name}\n" + "\n".join(shown)
        if len(shown) < len(items):
            # Says how much is missing, so a cut reads as a long release rather than a quiet one.
            block += f"\n… ({len(shown)}/{len(items)})"
        blocks.append(block)

    embed = {
        "description": fit("\n\n".join(blocks), DESCRIPTION_LIMIT - len(link)) + link,
        "color": colour,
        "footer": {"text": footer},
        "timestamp": release["published_at"],
    }
    payload = {"username": "FreeAudio", "embeds": [embed]}

    if dry_run:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        shown = sum(len(k) for k in kept)
        total = sum(len(items) for _, items in parts)
        print(f"\n描述 {len(embed['description'])} / {DESCRIPTION_LIMIT}，條目 {shown}/{total}", file=sys.stderr)
        return 0

    webhook = os.environ.get("DISCORD_WEBHOOK")
    if not webhook:
        print("DISCORD_WEBHOOK is not set", file=sys.stderr)
        return 1
    request = urllib.request.Request(
        webhook,
        data=json.dumps(payload).encode(),
        headers={
            "Content-Type": "application/json",
            # Discord answers 403 to urllib's default agent, with nothing that says why.
            "User-Agent": f"FreeAudio-release-notifier (+https://github.com/{REPO})",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=20) as response:
            print(f"discord: HTTP {response.status}")
        return 0
    except urllib.error.HTTPError as error:
        # Discord says in the body which field it rejected; the status alone doesn't.
        print(f"discord: HTTP {error.code}", file=sys.stderr)
        print(error.read().decode(errors="replace")[:800], file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
