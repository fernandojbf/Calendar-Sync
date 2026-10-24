# Publishing the Homebrew tap

Calendar Sync installs through a personal tap: a public GitHub repository named
`neteinstein/homebrew-tap`. The formula builds the app from source on the user's Mac, so no
Apple Developer account or notarization is needed.

## One-time setup

1. Create a **public** repository called `homebrew-tap` under `neteinstein`.
2. Copy [`calendar-sync.rb`](calendar-sync.rb) into it as `Formula/calendar-sync.rb` and push
   to its default branch. That's the whole tap.
3. Check it works:

   ```bash
   brew tap neteinstein/tap
   brew install calendar-sync
   ```

Users then install with one command: `brew install neteinstein/tap/calendar-sync`
(or `--HEAD` for the latest `main`).

## Releasing a new version

The formula pins a commit of this repository. To release:

1. Bump `CFBundleShortVersionString` in `Support/Info.plist` and merge to `main`.
2. In `Formula/calendar-sync.rb` (in the tap), set:
   - `url` to `https://github.com/neteinstein/Calendar-Sync/archive/<commit>.tar.gz`
     (or `refs/tags/vX.Y.Z.tar.gz` once releases are tagged — then the `version` line can go),
   - `version` to the new version,
   - `sha256` to the output of `curl -L <url> | shasum -a 256`.
3. Keep the copy in this folder in step with the tap, so the two don't drift.

Users update with `brew update && brew upgrade calendar-sync`, and the in-app update check
shows them those commands when the app runs from the Homebrew cellar.
