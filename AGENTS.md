# AGENTS.md

Notes for coding agents working in this repository.

## Bumping the version

The version is `CFBundleShortVersionString` (and the `CFBundleVersion` build number) in
[`Support/Info.plist`](Support/Info.plist). Homebrew users only get a new version when the
formula in the tap changes, so **every version bump must be followed by updating the formula in
[neteinstein/homebrew-tap](https://github.com/neteinstein/homebrew-tap)** (`Formula/calendar-sync.rb`).
A bump isn't done until the tap serves it.

1. Merge the bump into `main` first. The formula pins a commit archive, so the commit has to
   exist on GitHub before it can be pinned.
2. In the tap's `Formula/calendar-sync.rb`, set:
   - `url` to `https://github.com/neteinstein/Calendar-Sync/archive/<commit on main>.tar.gz`
   - `version` to the new `CFBundleShortVersionString`
   - `sha256` to the output of `curl -sSL <url> | shasum -a 256`

   Also carry over anything else that changed in
   [`packaging/homebrew/calendar-sync.rb`](packaging/homebrew/calendar-sync.rb) since the last
   update: apart from the header comment and the `url`/`version`/`sha256` pin (plus `revision`,
   which belongs to the pin and lives only in the tap), the two files are identical.
3. Check that the archive builds the way the formula builds it: extract it into an empty
   directory and run `scripts/build-app.sh --disable-sandbox` there.
4. Commit to the tap's `main` as `calendar-sync <version>` and push.

The copy in `packaging/homebrew/` keeps an older pin. The tap's copy is authoritative for
`url`/`version`/`sha256`.

If the formula has to change without a version bump (for example, a build fix), update the tap the
same way. If users may already have that version installed, also add or bump `revision` so that
`brew upgrade` picks the change up.
