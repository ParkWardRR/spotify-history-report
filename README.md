<p align="center">
  <br>
  <img src="https://img.shields.io/badge/lang-Odin-4a90d9?style=for-the-badge&logo=data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCAyNCAyNCI+PGNpcmNsZSBjeD0iMTIiIGN5PSIxMiIgcj0iMTAiIGZpbGw9IiNmZmYiLz48L3N2Zz4=&logoColor=white" alt="Odin">
  <img src="https://img.shields.io/badge/TUI-Nord%20Theme-88C0D0?style=for-the-badge" alt="Nord">
  <img src="https://img.shields.io/badge/license-Blue%20Oak%201.0-5E81AC?style=for-the-badge" alt="License">
  <img src="https://img.shields.io/badge/platform-macOS%20%7C%20Linux-A3BE8C?style=for-the-badge" alt="Platform">
  <br><br>
</p>

<h1 align="center">
<code>▗▄▄▄▖</code><br>
<code>▐   ▌</code>&ensp;spotify-history-report<br>
<code>▝▀▀▀▘</code>
</h1>

<p align="center">
  <strong>Turn your Spotify data export into a beautiful, interactive HTML report.</strong><br>
  No account access needed. Nothing leaves your machine. One binary, zero dependencies.
</p>

<p align="center">
  <img src="https://img.shields.io/badge/build-passing-A3BE8C?style=flat-square" alt="Build">
  <img src="https://img.shields.io/badge/PRs-welcome-D08770?style=flat-square" alt="PRs">
  <img src="https://img.shields.io/badge/data-stays%20local-BF616A?style=flat-square" alt="Local">
  <img src="https://img.shields.io/badge/zero-dependencies-B48EAD?style=flat-square" alt="Deps">
</p>

---

## What is this?

You ask Spotify for your data. They send you a ZIP file. You run this tool on it. You get a single HTML page you can open in any browser — a full visual breakdown of everything you've ever listened to.

That's it. No Python, no npm, no Docker. Just one compiled binary.

## What's in the report?

| Section | What you'll see |
|:--------|:----------------|
| **Hours per year** | Bar chart of how much you listened, year over year |
| **Key stats** | Most-played song, worst earworm, longest streak, skip rate |
| **Discovery** | Are you exploring new music or replaying favorites? |
| **The lifers** | Artists you've listened to every single year |
| **Top 25 artists** | Horizontal bars ranked by total listening hours |
| **Earworms** | Songs you couldn't stop playing (most plays in any 7-day window) |
| **Session openers** | The songs you reach for first when you hit play |
| **Top albums** | Best albums by total listening time |
| **Never-skipped** | Songs with 15+ plays and zero skips — pure commitment |
| **Genre evolution** | Stacked area chart of genre share over time (requires LLM) |
| **Heatmap** | When you listen — day of week × hour of day |

## Quick start

### 1. Get your data

Go to [spotify.com/account/privacy](https://www.spotify.com/account/privacy/) and request your **Extended Streaming History**. Spotify sends it within a few days as a ZIP containing `Streaming_History_Audio_*.json` files.

### 2. Build the tool

```bash
git clone https://github.com/ParkWardRR/spotify-history-report
cd spotify-history-report
odin build src/ -out:spotify-history-report -o:speed
```

> Requires [Odin](https://odin-lang.org/) — `brew install odin` on macOS, or grab a release from [odin-lang.org/docs/install](https://odin-lang.org/docs/install/).

### 3. Run it

```bash
./spotify-history-report ~/Downloads/my_spotify_data/
```

That's it. Open `spotify_report.html` in your browser.

### 4. Configure an LLM API key

Genre classification requires an LLM. Provide an API key via environment variable, CLI flag, or config file:

```bash
# Environment variable (easiest)
ANTHROPIC_API_KEY=sk-ant-... ./spotify-history-report ~/Downloads/my_spotify_data/

# CLI flag
./spotify-history-report ~/Downloads/my_spotify_data/ --anthropic-key sk-ant-...

# Interactive config setup (saves to ~/.config/spotify-history-report/config.json)
./spotify-history-report --setup
```

Supported providers: **Anthropic** (Claude), **OpenAI** (GPT-4o-mini), **OpenRouter** (any model). The tool auto-detects which key is available if you set multiple. Classifications are cached in `.genre_cache.json` alongside your data so subsequent runs are instant.

---

<details>
<summary><strong>Try it with sample data first</strong></summary>

The repo includes sample data with fictional artists so you can see what the output looks like before using your own data:

```bash
./spotify-history-report sample/ sample_report.html
open sample_report.html
```

All artist and track names in the sample are made up — no real listening data is included.

</details>

---

## The TUI

The tool shows a live terminal dashboard while it works, styled with the [Nord](https://www.nordtheme.com/) color palette:

```
  ▗▄▄▄▖
  ▐   ▌  spotify-history-report
  ▝▀▀▀▘  Generate listening infographics from GDPR data

  Scanning ─
  8 files found

  Loading ─
  Loading...  ████████████████████████████████████████ 100%
  58318 records, 43961 qualifying plays

  Computing ─
  Done

  ──────────────────────────────────────────────────────────────────

  Dashboard ─

  │ Total plays              43961
  │ Total hours              2185
  │ Unique artists           4366
  │ Unique tracks            10574
  │ Loyal artists            35 (8 years)
  │ Peak hour                18:00 (194h total)
  │ Most played              "Warm Static" (139×)
  │ Genres mapped            3842 artists (2.3% Other)

  Top artists ─

  Neon Dusk      ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓ 72.5 h
  Velvet Signal  ▓▓▓▓▓▓▓▓▓▓▓▓▓                  31.5 h
  Coastal Haze   ▓▓▓▓▓▓▓▓▓▓▓▓                   29.6 h
  Phantom Choir  ▓▓▓▓▓▓▓▓▓                      23.2 h
  Solar Draft    ▓▓▓▓▓▓▓▓▓                      21.9 h

  ──────────────────────────────────────────────────────────────────

  Generating report ─

  ✓ Report written to:
    report.html
```

## Architecture

```
src/
├── main.odin      entry point, CLI flags, guided setup, LLM orchestration
├── nord.odin      Nord palette constants (Polar Night → Aurora)
├── tui.odin       terminal rendering: progress bars, stat cards, mini charts
├── parser.odin    Spotify JSON deserialization, timestamp parsing (UTC→PST)
├── stats.odin     all metric computation (sessions, streaks, heatmap, genre share)
├── config.odin    config file (~/.config), provider resolution, genre cache
├── llm.odin       LLM genre classification (Anthropic/OpenAI/OpenRouter via curl)
└── html.odin      HTML report generation (template embed + JSON injection)

template/
└── report.html    self-contained HTML/CSS/JS template, renders from a DATA blob
```

The HTML template is embedded at compile time via Odin's `#load` directive — the binary is fully self-contained. At runtime, the tool computes all metrics, serializes them as JSON, injects the blob into the template at a marker, and writes the result.

### How metrics are computed

| Metric | Method |
|:-------|:-------|
| Qualifying play | `ms_played >= 30000` and both track + artist present |
| Session detection | Gap > 30 minutes between consecutive plays |
| Earworm | Sliding 7-day window per track, report max plays |
| Longest streak | Consecutive calendar days with at least one qualifying play |
| Skip | `ms_played < 30000` counts as a skip |
| Loyalty | Artist has qualifying plays in every active year |
| Heatmap | Hours summed per (day-of-week, hour-of-day) bucket, Pacific time |
| Explore vs. obsess | Per year: % of time on new artists / top-10 all-time / rest |

All timestamps are adjusted to Pacific time (UTC−8) before bucketing.

## Genre classification

When an LLM API key is available, the tool sends your unique artist names to the LLM in batches of 150 and asks it to classify each into one of 14 genres (Hip-hop & Rap, Indie pop, Funk & Soul, Electronic, Rock, R&B, Jazz, Latin, Classical, Pop, Country, Metal, World, Other).

Results are cached in `.genre_cache.json` next to your data files. The cache is additive — new artists from future exports get classified and merged in.

The genre data powers a stacked area chart in the report showing how your listening taste evolved quarter by quarter.

| Provider | Default model | How to get a key |
|:---------|:--------------|:-----------------|
| Anthropic | `claude-sonnet-4-20250514` | [console.anthropic.com/settings/keys](https://console.anthropic.com/settings/keys) |
| OpenAI | `gpt-4o-mini` | [platform.openai.com/api-keys](https://platform.openai.com/api-keys) |
| OpenRouter | `anthropic/claude-sonnet-4-20250514` | [openrouter.ai/keys](https://openrouter.ai/keys) |

Priority: Anthropic > OpenAI > OpenRouter (auto-detected from env vars or config).

## LLM framework

See [`FRAMEWORK.md`](FRAMEWORK.md) for a structured prompt framework if you want an LLM to help you extend or customize the report. It covers the full analysis pipeline: data specification, six analysis layers, visualization hierarchy, color system, and interactivity patterns.

## Privacy

- **Your data never leaves your machine.** The tool reads local JSON files and writes a local HTML file. The only network calls are to the LLM API — and those only send artist names, not your listening history.
- **The HTML report is self-contained.** No analytics, no external requests, no tracking pixels. Open it offline.
- **The sample data uses fictional artists.** No real listening history is included in this repository.

## License

[Blue Oak Model License 1.0.0](LICENSE.md) — a modern, readable, permissive license.

---

<p align="center">
  <sub>Built with <a href="https://odin-lang.org">Odin</a> · Styled with <a href="https://www.nordtheme.com">Nord</a> · Data stays local</sub>
</p>
