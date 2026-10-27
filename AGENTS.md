# AGENTS.md

Notes for coding agents working in this repository.

## Every change is a release

Every change that lands on `main` ships as a new version, and Homebrew users only get it once
the tap serves it. So every PR:

1. Bumps the version in the same PR: raise the last number of `X.Y.Z` by one (`1.0.1` to
   `1.0.2`) unless asked for a bigger bump, and raise the build number by one.
2. Is followed by a PR on [neteinstein/homebrew-tap](https://github.com/neteinstein/homebrew-tap)
   that feeds the new version to Homebrew, as described next.

## Bumping the version

The version is `CFBundleShortVersionString` (and the `CFBundleVersion` build number) in
[`Support/Info.plist`](Support/Info.plist). Homebrew users only get a new version when the
formula in the tap changes, so **every version bump must be followed by a PR on
[neteinstein/homebrew-tap](https://github.com/neteinstein/homebrew-tap)** that updates
`Formula/calendar-sync.rb`. A bump isn't done until the tap serves it.

1. Cut the bump's branch from the current `main` and push it before touching the tap. The
   formula pins a commit archive, so the pinned commit has to exist on GitHub. Pin the branch
   head (`git rev-parse HEAD`): PRs here are merged with merge commits, not squashed, so that
   commit ends up on `main`. If the branch gets more commits before it merges, re-pin.
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
4. In the tap, commit as `calendar-sync <version>` on a branch `calendar-sync-<version>`, push
   it, and open a PR against the tap's `main` that links the app PR. Merge the app PR first,
   then the tap PR.

The copy in `packaging/homebrew/` keeps an older pin. The tap's copy is authoritative for
`url`/`version`/`sha256`.

If the formula has to change without a version bump (for example, a build fix), update the tap the
same way. If users may already have that version installed, also add or bump `revision` so that
`brew upgrade` picks the change up.
