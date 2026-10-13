cask "foxcycle" do
  version "@VERSION@"
  sha256 "@SHA256@"

  url "https://github.com/hongzio/foxcycle/releases/download/v#{version}/FoxCycle-#{version}.zip"
  name "FoxCycle"
  desc "Cycles windows across all Firefox profiles with Cmd+`"
  homepage "https://github.com/hongzio/foxcycle"

  depends_on macos: :sonoma

  app "FoxCycle.app"

  preflight_steps do
    # Self-signed and not notarized: Gatekeeper would refuse to open a quarantined copy.
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{staged_path}}/FoxCycle.app"]
  end

  # Also runs on upgrade. Matches installed copies only, not a development build elsewhere.
  uninstall script: {
    executable:   "/usr/bin/pkill",
    args:         ["-f", "Applications/FoxCycle.app/Contents/MacOS/FoxCycle"],
    must_succeed: false,
  }

  zap trash: "~/Library/Preferences/com.hongzio.foxcycle.plist"

  caveats <<~EOS
    Start FoxCycle after installing or upgrading:
      open -a FoxCycle
    It needs Accessibility access: allow it when asked, or in
    System Settings > Privacy & Security > Accessibility.
    To start it at login, turn on Start at Login in its menu bar menu.
  EOS
end
