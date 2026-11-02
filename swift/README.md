# NUMIDENT Viewer (Swift / SwiftUI)

A native macOS app for searching NARA's public-use NUMIDENT files (NUMSS5, NUMCLM,
NUMDEATH) **directly from the text files**: no import, no database. Each search
streams the selected files with live progress; SSN lookups use binary search and
finish in about a second.

Runs on macOS 13+ on Apple Silicon and Intel (one universal binary), including Intel
Macs running newer macOS through OpenCore Legacy Patcher.

## Build

Requires Xcode 15+ (Swift 5.10+) on the build machine. No third-party dependencies.

```bash
./build-app.sh
```

This produces:

- `dist/NUMIDENT Viewer.app`: universal (x86_64 + arm64), `LSMinimumSystemVersion` 13.0
- `dist/numident-cli`: universal command-line tool (health check, search, benchmark)

Plain `./build-app.sh` signs ad-hoc. A copy that arrives quarantined then needs
**right-click → Open** (or `xattr -dr com.apple.quarantine "NUMIDENT Viewer.app"`).

### Notarize with Xcode

Open `NUMIDENT Viewer.xcodeproj`, choose **Product → Archive**, then in the Organizer choose
**Distribute App → Direct Distribution**. Xcode signs with Developer ID, submits to Apple and
staples the ticket using the signed-in account, then lets you export the app. This covers the
app only, not `numident-cli`. A new source file in `Sources/NumidentViewer` or `Sources/NumidentCore` must also be added
to its Xcode target, because the project lists its files explicitly.

### Notarize with the script

This also covers `numident-cli`. It needs a paid Apple Developer team and a **Developer ID
Application** certificate. Store a notary profile once (it prompts for an app-specific
password), then build:

```bash
xcrun notarytool store-credentials NUMIDENT-notary --apple-id <apple-id> --team-id <team-id>
SIGN_IDENTITY="Developer ID Application: <name> (<team-id>)" NOTARY_PROFILE=NUMIDENT-notary ./build-app.sh
```

The app needs no entitlements or capabilities. Any certificate other than ad-hoc also
turns on hardened runtime and a secure timestamp. Launch signed builds from Finder or with
`open`: an Apple-signed copy has been seen to exit at once when its inner executable is run
directly.

Development:

```bash
swift build            # debug build of everything
swift test             # 35 unit tests, generate their own synthetic data
swift run NumidentViewer
```

## Use

1. **Data folder.** The default is `/Volumes/TranscBlura/NUMIDENT`; change it in
   *NUMIDENT Viewer → Settings…*. The folder holds `NUMSS5/`, `NUMCLM/` and `NUMDEATH/`,
   with files named `<SET>NN_PU.txt` (any case).
2. **Dataset banner.** On launch and on *Rescan* (⇧⌘R) the app checks every file. When anything
   is missing or suspect, an orange banner at the top says so, e.g.
   *NUMCLM: 10 of 20 files present (missing 02–11)*. *Details* opens a per-set table.
   The checks cover:
   - missing files and folders
   - an unmounted volume
   - empty or unreadable files
   - files much smaller than their siblings
   - a last line with no newline, or a size that isn't a whole number of records (truncated copy)
   - a first line in the wrong format

   The app always works with whatever is present.
3. **Choose what to search.** Tick NUMSS5 / NUMCLM / NUMDEATH in the sidebar (for
   example, untick NUMDEATH if the person was alive at the cutoff). Expand *Files* to
   pick individual files. Only ticked files are read, and the progress total covers
   only them.
4. **Search.** You can search by:
   - SSN
   - first, middle or last name, matched exactly, as a prefix, or by Soundex
     (optionally including SS-5 "other" and "signature" names)
   - birth-year and death-year ranges
   - birth city and state
   - father's and mother's names
   - sex

   Sets that can't contain a field are skipped automatically, with a note (for example,
   SS-5 records have no death date).
5. **Progress.** The panel shows:
   - an overall bar and one bar per set
   - the files being read
   - MB/s, time left, and the match count

   Results appear in the table while the scan runs. **Cancel** (or Esc) stops within one
   4 MB chunk and keeps the matches found so far; the summary says how far the search got.
   A search stops at a result limit (10,000 by default, set in Settings); the table shows
   500 rows at a time with *Load more*.

   Click any column header to sort all results (names sort by last, first, middle; dates by
   their known parts). To narrow the results without reading the drive again, press ⌘F and
   type words into the filter bar above the table:
   - every word must appear, in any order and any case;
   - a plain word matches anywhere in the record, including parents' and other names;
   - a prefix limits a word to one field: `first:` `middle:` `last:` `name:` `father:`
     `mother:` `place:` `born:` `died:` `ssn:` `set:`. For example, `first:joe born:191`.

   Esc clears the filter.

   **Last-name index (optional).** A search with a last name normally reads every file. If you
   click *Build index…* in the sidebar (or run `numident-cli index <data-dir>`), the app reads
   every file once and writes a last-name index of about 0.5 GB to `LASTNAME-INDEX/` in the data
   folder. It is never built automatically. Once built, switch on *Use for last-name searches*:
   searches with a last name then read only the records carrying that name (exact, prefix or
   Soundex, including other/signature names and all death postings), and every candidate is still
   checked by the normal matcher, so results are identical to a full scan. Files added or changed
   after the build are read in full until you rebuild; the sidebar says how many. When a name is
   so common that fetching each record would be slower than reading a file straight through, the
   app reads that file instead. `numident-cli search --no-index` skips the index for comparison.
6. **Person view.** Double-click a row (or select it and click *Open person*) to look up
   that SSN in every selected file. The view shows:
   - names, dates of birth, sex, birthplace, parents and death dates, each with the
     record it came from
   - conflicts between records, highlighted in red
   - a timeline of applications, claims and death postings (all three death postings)
   - each raw line with a column ruler and field-by-field decoding
   - coverage notes, e.g. *a missing claim record is not conclusive* when NUMCLM files
     are missing

## How it reads the files

Format facts, verified on the real files:

| Set      | Characters per line | Terminator | Record size |
|----------|--------------------:|------------|------------:|
| NUMSS5   | 500                 | LF         | 501 bytes   |
| NUMCLM   | 499                 | LF         | 500 bytes   |
| NUMDEATH | 487                 | CRLF       | 489 bytes   |

- **Full scans.** Each worker reads 4 MB chunks with `read()` into one reusable buffer.
  It splits lines with `memchr` and carries any partial line over to the next chunk,
  handling either terminator. It compares fixed columns directly in the buffer, with no
  per-line allocation, and builds a record only for a match. Readers run on a TaskGroup
  pool; the number at once is set in Settings (default 2).
- **SSN lookups.** The files are *not* globally sorted. Each one is a short
  out-of-order leading block (17–54 records) followed by one long run sorted by SSN, with
  all-`Z` separator records between batches. The leading block's SSNs can fall *inside* the
  main run's range, so sampling alone can't see it. On first use the app finds each file's
  sorted runs:
  1. Read the first 16,384 records (about 8 MB) in full and record every SSN drop exactly.
  2. Sample the rest at 1,024 points. Wherever the SSN drops between two samples, read that
     window to find the exact boundary.
  3. Cache the result in `~/Library/Caches/NumidentViewer/runmaps-v2.json`. The version is
     bumped whenever detection changes.

  Lookups then binary-search each run by record index (record *i* starts at
  *i* × record size), skipping separator records. Files with too many runs, or
  variable-length lines, fall back to newline-resync search or a full scan.
- **Partial dates.** Values like `06XX1974` or `193611XX` are kept, shown as `1974-06-??`,
  and still match year searches.

Layouts and code tables come from NARA's AAD technical documentation (`../docs/nara/`).

## Speed and concurrency

| Drive | Setting | Full scan of all 66 GB |
|-------|---------|------------------------|
| Spinning hard disk | **1 file at a time** (parallel reads make the head seek and are slower) | ~8 min at ~140 MB/s |
| USB 3 / Thunderbolt SSD | **2** (default); 3–4 rarely helps | ~3 min at ~400 MB/s |

On these drives the disk is always the limit, not the parser. With the files already in
memory, the scanner reads 5.4 GB/s on one thread on an M3 Pro, and the x86_64 build reads
8 GB/s on two threads under Rosetta.

| Lookup | Typical time |
|--------|--------------|
| First SSN lookup after launch, no cache yet | ~30–40 s (reads ~9 MB per file across all 50 files) |
| SSN lookups after that | about 1–3 s |

Unticking sets you don't need is the biggest saving. NUMSS5 is 36 GB of the 66 GB.

## OCLP / older Intel Macs

- It's a native AppKit/SwiftUI app with no Electron, web view, Metal, SpriteKit or custom
  drawing, and no animations. It uses only standard controls (Table, ProgressView,
  Grid).
- Progress and new results update the UI at most 4 times a second, so a scan never floods
  the GPU with redraws. That matters on GPUs that need OCLP's root patches, such as the
  Mac Pro 6,1's FirePro D300.
- The work runs on background threads. The window stays responsive during a scan, and
  memory stays around (concurrency × 4 MB) plus the results.

## Command-line tool

```bash
numident-cli health /Volumes/TranscBlura/NUMIDENT
numident-cli ssn    /Volumes/TranscBlura/NUMIDENT 001010601
numident-cli search /Volumes/TranscBlura/NUMIDENT --last SMITH --first EDWARD --sets NUMSS5,NUMDEATH
numident-cli bench  /Volumes/TranscBlura/NUMIDENT --sets NUMCLM --concurrency 2
```

## Synthetic test data

`numident-gen` writes fake data in the exact real format: fixed record sizes, LF or CRLF,
leading out-of-order blocks, `Z` separators, partial dates and multiple death postings.
All the names are made up.

```bash
swift run -c release numident-gen /tmp/fixture --fixture         # NUMCLM 02–11 missing, NUMDEATH03 truncated
swift run -c release numident-gen /tmp/synth1g --target-gb 1     # ~1 GB for benchmarks
```

## Layout

```
Sources/NumidentCore/     layouts + code tables, partial dates, Soundex, catalog/health,
                          scanner + SSN run index, search engine, person merge, generator
Sources/NumidentViewer/   SwiftUI app (banner, sidebar, progress, results, person sheet, settings)
Sources/numident-cli/     command-line front end
Sources/numident-gen/     synthetic data generator
Tests/NumidentCoreTests/  unit tests (golden real sample lines + synthetic datasets)
```

### Automated UI checks

These environment variables only take effect when set, and are for scripted screenshots:

| Variable | Effect |
|----------|--------|
| `NUMIDENT_DATA` | data folder to use |
| `NUMIDENT_SEARCH_LAST` | last name to search for on launch |
| `NUMIDENT_PERSON` | SSN to open in the person view |
| `NUMIDENT_EXPAND` | expand the raw records in the person view |
| `NUMIDENT_SNAPSHOT` | PNG path to save the window to |
| `NUMIDENT_SNAPSHOT_DELAY` | seconds to wait before the snapshot |
| `NUMIDENT_QUIT` | quit after the snapshot |
