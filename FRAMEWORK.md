# LLM Framework for Spotify Listening History Reports

A structured prompt framework for LLMs generating self-contained HTML infographics from Spotify GDPR data exports.

## Input specification

The LLM receives Spotify Extended Streaming History JSON files (GDPR export). Each record has:

```json
{
  "ts": "2024-03-15T18:32:01Z",
  "ms_played": 234567,
  "master_metadata_track_name": "Song Title",
  "master_metadata_album_artist_name": "Artist Name",
  "master_metadata_album_album_name": "Album Name",
  "platform": "OS X 15.2.0",
  "skipped": false
}
```

**Qualifying play**: `ms_played >= 30000` and both track name and artist name are present.

## Analysis layers

### Layer 1: Core metrics (always compute)

| Metric | Definition |
|--------|-----------|
| Total plays | Count of qualifying plays |
| Total hours | Sum of `ms_played` / 3,600,000 over qualifying plays (so it matches the sum of hours by year) |
| Unique artists | Distinct artist names in qualifying plays |
| Unique tracks | Distinct (track, artist) pairs |
| Date range | Min/max timestamps in the configured timezone |

### Layer 2: Behavioral patterns

| Analysis | Method |
|----------|--------|
| Most played song | Max count of (track, artist) |
| Earworm detection | Sliding 7-day window per track, report max plays in any window |
| Longest streak | Consecutive calendar days (configured timezone) with ≥1 play |
| Skip rate trend | Two measures, never combined: **explicit skips** (`skipped: true`, as a share of rows where the field is not null; null is unknown, not false) and **short listens** (`ms_played < 30000`, as a share of all rows with a track and artist) |
| Session detection | Over every music row, short listens included, sorted by end time. A row starts at `ts − ms_played`; more than 30 minutes between that start and the latest end so far = new session |
| Session openers | First qualifying play in each session, ranked by frequency |
| Never-skipped songs | ≥15 total plays, no explicit skip and no play under 30 seconds |

### Layer 3: Temporal analysis

| Dimension | Granularity |
|-----------|------------|
| Hours by year | Annual totals |
| Hour of day heatmap | 24 bins, hours summed |
| Day of week | 7 bins, hours summed |
| Peak hour / peak day | Argmax of above |
| Biggest listening day | Max plays in a single calendar day |
| Average track length | Mean `ms_played` per qualifying play, by year |

### Layer 4: Discovery and loyalty

| Analysis | Method |
|----------|--------|
| New artists per year | Count artists whose first qualifying play falls in that year |
| Explore vs. obsess | % of year's listening, as disjoint buckets: top-10 all-time / other artists first heard that year / rest |
| Concentration index | % of total hours in top 1 / 5 / 10 / 25 / 50 / 100 artists |
| Songs for 50% | How many top tracks account for half of all plays |
| Loyal artists | Artists with qualifying plays in every active year |

### Layer 5: Genre classification (manual + LLM)

Genre classification cannot be derived from the data alone. Approach:

1. Rank artists by total play count, descending
2. Classify the top N artists into genres manually or with LLM assistance
3. Use a fixed genre order for consistent colors
4. Track the Unclassified percentage (listening time with no genre) — target < 5% for a meaningful chart; `Other` is a genre label, not a measure of coverage
5. Subgenre breakdown: for top genres, further classify key artists into 3-4 subcategories

**Annotation format**: records of `{artist, title?, namespace, value, source, model, confidence, observed}`, so a genre can be about an artist or a single track, can have several sources, and can be corrected by the user. A flat `{ "Artist Name": "Genre Label" }` map is still accepted as a legacy import. Artists with no annotation are *Unclassified*, never `Other`.

### Layer 6: Album and platform analysis

| Analysis | Method |
|----------|--------|
| Top albums | Sum hours by (album, artist) |
| Platform breakdown | Categorize `platform` field into iPhone/Android/Mac/Windows/Web |
| Top artists per year | Top 5 by hours, per year |

## Output specification

The report must be a **single self-contained HTML file** — no external dependencies except Chart.js CDN (optional). Requirements:

- Embedded CSS with CSS custom properties for theming
- Inline SVG for custom visualizations (stacked area charts, heatmaps)
- JavaScript for interactivity (hover scrub, dynamic legends, tooltips)
- Responsive layout (flex/grid, mobile breakpoints)
- Data embedded as `const DATA = { ... }` in a script tag

### Visual hierarchy

1. **Title + subtitle** with total stats
2. **Genre stacked area chart** (interactive, with era labels)
3. **Key stats row** (4 stat tiles: most played, earworm, streak, skip rate trend)
4. **Secondary stats row** (biggest day, peak hour, track length trend, loyal count)
5. **Hours by year** bar chart
6. **Discovery section** (explore vs. obsess stacked bars, new artists per year, lifers)
7. **Top 25 artists** horizontal bar chart
8. **Earworms table** (7-day window analysis)
9. **Session openers** list
10. **Top albums** list
11. **Never-skipped songs** list
12. **Heatmap** (day × hour)
13. **Subgenre breakdown** (horizontal stacked bars per genre)
14. **Source attribution** footer

### Color system

- Genre colors: 8-10 categorical colors, fixed order, accessible
- Subgenre colors: ordinal ramps (lightness steps within parent genre's hue)
- Text contrast: luminance check for labels inside colored segments
- Consistent assignment: genre → color mapping defined once, used everywhere

### Interactivity spec

- **Genre chart scrub**: vertical line follows mouse/touch, legend percentages update to show that quarter's values
- **Touch support**: touchstart/touchmove track finger, touchend holds values for 1.5s before resetting
- **Subgenre bars**: hover dims siblings, tooltip shows name/pct/hours
- **Heatmap**: hover shows exact value

## Prompt template

```
You are building a self-contained HTML infographic from Spotify Extended Streaming History data.

Input: {N} JSON files totaling {M} records from {start_date} to {end_date}.

Phase 1 — Data processing:
- Load all JSON files, filter to qualifying plays (≥30s, has track+artist)
- Compute all Layer 1-4 metrics listed in the framework
- Apply the provided GENRE_MAP for Layer 5 classification
- Convert all timestamps to the listener's timezone (a named IANA zone, DST-aware)

Phase 2 — HTML generation:
- Single self-contained HTML file
- Follow the visual hierarchy: genre chart → stats → discovery → artists → earworms → heatmap → subgenres
- Use CSS custom properties, system font stack
- SVG for the stacked area chart (Catmull-Rom spline interpolation)
- Chart.js for simple bar charts (optional)
- Interactive genre chart with hover/touch scrub

Phase 3 — Quality checks:
- Verify "Other" genre < 5% (if not, classify more artists)
- Verify text contrast on all colored segments
- Test mobile layout at 375px width
- Verify all stats are plausible (total hours ≈ sum of year hours, etc.)
```

## Calibration data

Typical ranges for a multi-year listener:

| Metric | Low | Typical | High |
|--------|-----|---------|------|
| Annual hours | 100 | 300 | 600 |
| Unique artists | 500 | 2000 | 5000+ |
| Earworm (7d max) | 15 | 30 | 60+ |
| Longest streak | 30 | 90 | 365 |
| Top-1 artist concentration | 3% | 5% | 15% |
| Never-skipped (≥15 plays) | 5 | 30 | 100+ |
