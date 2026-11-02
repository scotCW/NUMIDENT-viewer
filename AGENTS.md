# Agent instructions

`swift/` is the maintained app. `go/` is deprecated: don't add features to it. See
`swift/README.md` for how the app works, and the
[wiki](https://github.com/scotCW/NUMIDENT-viewer/wiki) for the code and data format.

## Commands

Run these from `swift/`:

```bash
swift build
swift test
./build-app.sh    # universal app and CLI in dist/, signed ad-hoc by default
./make-icon.sh    # rebuilds AppIcon.icns from AppIcon.svg; needs rsvg-convert
```

## Commits

- Commit agent-written code as `scotCW`, using the identity already set in the repo config.
- Do not GPG-sign commits or tags.

## Constraints

- **Older Intel Macs:** the app must run on Intel Macs using OpenCore Legacy Patcher, and on
  macOS 13+. Don't use Electron, web views, Metal, custom drawing or animations, and keep UI
  updates to at most 4 a second.
- **Dependencies:** the code has no third-party dependencies. Don't add one without asking.
- **Secrets:** the app and repo need none. Notarization runs locally in Xcode.
- **Government marks:** don't add the SSA seal or anything resembling it, in the working tree
  or in history. The app must not imply a connection to SSA or NARA.
- **Personal data:** NUMIDENT records are real people's data. Don't commit data files, and use
  `numident-gen` for test data instead of adding real records.

## Pitfalls

- A new source file in `Sources/NumidentViewer` or `Sources/NumidentCore` must also be added
  to its target in `NUMIDENT Viewer.xcodeproj`, which lists files explicitly.
- The `NUMIDENT_DATA` debug hook saves its folder to the app's defaults. Delete that setting
  after scripted runs.
- Launch Apple-signed builds with `open` or Finder. Running the inner executable directly has
  been seen to exit at once.
- The data files aren't globally sorted, so don't assume a whole file can be binary-searched.
  See "How it reads the files" in `swift/README.md`.
