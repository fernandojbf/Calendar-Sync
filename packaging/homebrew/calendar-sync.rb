# Homebrew formula for Calendar Sync. Lives in the neteinstein/homebrew-tap repository as
# Formula/calendar-sync.rb; the copy here is the source it's updated from. The tap's copy is
# authoritative for url/version/sha256: a release can only be pinned there, after the commit
# it points at exists, so this copy's pin is one release behind by nature.
#
# Install:
#   brew install neteinstein/tap/calendar-sync         # pinned version below
#   brew install --HEAD neteinstein/tap/calendar-sync  # latest main
#
# Releasing a new version: point `url` at the new commit (or tag) archive, update `version`
# to match Support/Info.plist, and set `sha256` to the output of
#   curl -L <url> | shasum -a 256
class CalendarSync < Formula
  desc "Menu bar app that copies client-calendar meetings into your main calendar"
  homepage "https://github.com/neteinstein/Calendar-Sync"
  url "https://github.com/neteinstein/Calendar-Sync/archive/6553dc30bd4f34ec333225ebf7e69f61c05e402d.tar.gz"
  version "0.1.0"
  sha256 "6a692331352ba3412d1231a98ef53c2d75e3c1d1a1671d696cd00dba0758039f"
  license "PolyForm-Noncommercial-1.0.0"
  head "https://github.com/neteinstein/Calendar-Sync.git", branch: "main"

  depends_on macos: :sonoma

  def install
    # Builds with the system Swift toolchain (Xcode 15+ command line tools are enough)
    # and ad-hoc signs, exactly like a manual source build.
    system "scripts/build-app.sh"
    prefix.install "build/Calendar Sync.app"
  end

  def caveats
    <<~EOS
      Calendar Sync is a menu bar app. Start it with:
        open "#{opt_prefix}/Calendar Sync.app"

      If you use "Open at login", copy it into /Applications instead, so the
      login item survives upgrades:
        cp -a "#{opt_prefix}/Calendar Sync.app" /Applications/

      The build is ad-hoc signed, so macOS asks for calendar access again
      after each upgrade. Your settings are kept.
    EOS
  end

  test do
    assert_path_exists prefix/"Calendar Sync.app/Contents/MacOS/CalendarSync"
  end
end
