# NUMIDENT Viewer

A native macOS app for searching the National Archives' public-use NUMIDENT files
(NUMSS5, NUMCLM, NUMDEATH) directly from their text files, with no import or database.
It runs on Apple Silicon and Intel, including Intel Macs using OpenCore Legacy Patcher.

The data files are not included. They come from NARA's public-use release, and the app
works with whichever of them you have.

- [`swift/`](swift/README.md): the app, with build and usage instructions.
- [`go/`](go/README.md): an earlier implementation, now deprecated.
- [`gramps-forms/`](gramps-forms/README.md): Gramps forms for NUMIDENT sources.
- [`docs/nara/`](docs/nara): NARA's record layouts.

The code is licensed under the [Unlicense](LICENSE). See [NOTICE.md](NOTICE.md) for the
files that are not original to this project. This project is not affiliated with or
endorsed by SSA or NARA.
