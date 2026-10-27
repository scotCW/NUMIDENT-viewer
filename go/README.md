# NUMIDENT Viewer (Go)

A local search tool for NARA's public-use NUMIDENT files (NUMSS5, NUMCLM,
NUMDEATH). It reads the original text files directly: there is no import step
and no database. Every search streams the selected files with a live progress
bar, and SSN lookups binary-search the files in milliseconds.

It is a single universal binary for both Intel and Apple Silicon Macs. It runs
a small web server on `127.0.0.1` only and opens the interface in your browser.

## Requirements

- macOS 13 Ventura or later, on Intel or Apple Silicon. This includes Intel
  Macs running a newer macOS through OpenCore Legacy Patcher, such as a Mac Pro
  6,1 on Sonoma.
- The data folder holding `NUMSS5/`, `NUMCLM/` and `NUMDEATH/` (default
  `/Volumes/TranscBlura/NUMIDENT`). Files can also sit directly in the folder.
- To build: Go 1.22 or later and Xcode command-line tools (for `lipo` and
  `codesign`).

## Build

```sh
make test             # go vet + all tests
make build-universal  # bin/numident-viewer (x86_64 + arm64)
make app              # bin/NUMIDENT Viewer.app (ad-hoc signed)
```

## Run

```sh
./bin/numident-viewer                       # opens Safari at http://127.0.0.1:8765/
./bin/numident-viewer -data /path/to/NUMIDENT -concurrency 1
./bin/numident-viewer -browser default      # use your default browser instead
./bin/numident-viewer -no-browser           # just print the URL
```

You can also double-click `NUMIDENT Viewer.app`. It has no Dock icon; use
**Quit** in the page to stop it.

If the app was copied from another Mac and macOS refuses to open it, run
`xattr -dr com.apple.quarantine "NUMIDENT Viewer.app"`.

Settings (data folder, files read at once, default match limit) are kept in
`~/Library/Application Support/NUMIDENT Viewer/config.json`.

### Why Safari

The interface is plain HTML and CSS: no WebGL, no canvas, no blur, no
animation. It opens in **Safari** by default. Chromium-based browsers and
Electron apps use their own GPU rendering path, and on OCLP Macs with patched
AMD graphics (such as the FirePro D300) that path tends to glitch. Firefox
also works. Pass `-browser default` to use your default browser instead.

## Using it

- **Missing-data banner.** On start, and whenever you click **Rescan**, the
  viewer checks every expected file (`<SET>01_PU` to `<SET>20_PU`) and shows
  an amber banner if anything is wrong. Click **Details** for a per-set table.
  It reports:
  - missing files (for example `NUMCLM: 10 of 20 files present (missing 02–11)`)
  - empty files
  - unusually small files
  - files cut off mid-record
  - files whose size is not a whole number of records
  - unreadable files
  - a disconnected drive

  Everything still works with the files that are present. The person view
  also notes when a missing file means a negative result is not conclusive.
  macOS metadata files (`._*`, `.DS_Store`) are ignored.
- **Datasets.** Untick a set to skip it. For example, if the person was alive
  at the cutoff, untick NUMDEATH and searches read about 40 GB instead of 62 GB.
  **Individual files** lets you pick single files.
- **Search fields:**
  - SSN
  - first, middle and last name, matched exactly, by prefix, or by Soundex
  - sex
  - birth-year range and death-year range
  - birthplace city and state
  - father's and mother's names
  - optionally, the SS-5 "other name used" and signature names

  Death-year filters skip SS-5 files. Birthplace and parent filters skip
  NUMDEATH, because those fields don't exist there.
- **Progress.** You get an overall bar and one bar per set, plus bytes read,
  MB/s, time remaining, match count and the files being read. Matches appear
  while the scan runs. **Cancel** (or Esc) stops at once and keeps what was
  found. A search stops at the match limit (1,000 by default) and offers to run
  again with a higher limit.
- **Person view.** Click a result to see every record for that SSN in the
  ticked sets:
  - a summary of names, birth, parents and death
  - fields that disagree between records, in red (partial dates such as
    `1974-06-??` count as agreeing with full ones)
  - a timeline of SS-5 applications, claims and death postings (all three
    postings of a death record)
  - each raw record, with every documented field underlined; hover a field
    for its name, columns and value

## Concurrency: HDD vs SSD

"Files read at once" (Settings, or `-concurrency`) sets how many files are read
in parallel:

| Drive | Setting | Why |
|---|---|---|
| Spinning hard disk | **1** | A second reader makes the head jump between files and slows everything down. |
| USB 3 SSD (e.g. the exFAT TranscBlura drive) | **2** (default) | One file is read while the other is filtered. |
| Thunderbolt or internal NVMe SSD | **3–4** | The drive can serve several streams. |

On a Mac Pro 6,1 expect roughly 300–400 MB/s from a USB 3 SSD, so a full
62 GB scan takes about 3 minutes. Filtering is never the bottleneck: one reader
filters more than 4 GB/s on an Apple M3 Pro, measured on cached synthetic data.

SSN lookups don't depend on drive speed. Each file is binary-searched, which
takes about 30 small reads per file and 1–15 ms per set on the real release.

## How it works

- `internal/layout`: the three record layouts from NARA's PDFs (in
  `../docs/nara/`), with the code tables, partial dates (`XX`), and Soundex.
  Records are fixed-length: NUMSS5 lines are 500 characters + LF, NUMCLM 499 +
  LF, and NUMDEATH 487 + CRLF.
- `internal/catalog`: discovers the files and produces the health report.
- `internal/scan`: the search engine.
  - A pool of workers reads 4 MB chunks, carries any partial line over to the
    next chunk, and filters lines in place without allocating memory.
  - Progress is tracked with atomic counters; cancellation is checked after
    every chunk; a read error is reported for the file it happened in.
  - SSN binary search:
    - The release is *mostly* sorted by SSN. Many files start with a short run
      of higher SSNs, and some records have the masked SSN `ZZZZZZZZZ`.
    - Each file is modelled as a few sorted runs. The first 8 MB is read in
      full, the rest is sampled at 256 points, and each run is binary-searched
      by record index.
    - If sampling finds disorder, the file falls back to a full scan.
    - Any complete scan records the file's exact runs, saved in
      `shapes.json`, so later lookups on that file are binary.
- `internal/api`: JSON and Server-Sent Events endpoints. It refuses requests
  whose Host header is not a loopback address.

| Endpoint | Purpose |
|---|---|
| `GET /api/health`, `POST /api/rescan` | dataset health report |
| `GET/POST /api/settings` | data folder, concurrency, match limit |
| `POST /api/search` | start a search (JSON query) and return its id |
| `GET /api/search/{id}/events` | SSE stream: `progress` every 250 ms, `matches`, `done`. Resume with `?from=N`. A search with no listener for 15 s is cancelled. |
| `DELETE /api/search/{id}` | cancel |
| `GET /api/search/{id}/person` | assemble a person from an SSN search |
| `GET /api/person/{ssn}?sets=…` | synchronous SSN lookup |
| `GET /api/layout` | field definitions |

## Test data

`tools/gen` writes a synthetic release in the exact format (fixed-length lines,
LF/CRLF, sorted runs, partial dates, multiple death postings). All names are
invented.

```sh
go run ./tools/gen -out /tmp/numident -people 650000            # about 940 MB
go run ./tools/gen -out /tmp/partial -people 20000 -missing NUMCLM:2-11 -truncate NUMSS503_PU.txt
./bin/numident-viewer -data /tmp/numident -simulate-mbps 60      # rehearse a slow drive
```

`go test ./...` uses these generators. It also includes golden tests on real
sample lines and, when the real drive is mounted, a few SSN lookups on it
(binary search only, never a full scan).
