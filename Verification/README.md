# Engine verification

A standalone harness that exercises `CompareFolders/Core` against real files on
disk: it builds a fixture tree with known differences, runs the engine over it,
and asserts on every finding.

It lives outside the app target on purpose — the Xcode project synchronizes only
the `CompareFolders/` folder, so nothing here is compiled into the app.

Run it with:

    ./Verification/run.sh

It exits non-zero if any check fails.

## What it covers

- Additions, removals, and one-sided folders (reported as a single row, not expanded)
- File-vs-folder replacement
- Size, modification date, creation date, and permission differences
- Byte-exact mode catching an equal-size, equal-timestamp edit, and a single
  differing byte 900 KB into a file (which also exercises the multi-buffer read loop)
- Symbolic link targets
- Empty files, hidden files, deeply nested files
- Case-insensitive and Unicode-normalization-insensitive name matching
- Natural (numeric) filename ordering
- A regression test for the merge walk: with left `[a, y, z]` and right `[a, b]`,
  the original Objective-C implementation drops `y` entirely. Every item must appear.
- Filter behavior, a missing root folder, and cancellation
