# macOS Builder Notes

Current European builder:

- Region: `eu-central-1`
- AZ: `eu-central-1c`
- Dedicated Host: `h-0fe6b0782f40a6c69`
- Instance: `i-092d7452a5deac519`
- Type: `mac2-m2.metal`
- AMI: `ami-039876db2ebd24e4e` (`amzn-ec2-macos-15.7.4-20260217-233754-arm64`)
- Source path: `/Users/ec2-user/Work/WebKit`
- Bootstrap path: `/Users/ec2-user/ng-bootstrap`

The initial goal is to learn the native macOS WebKit build requirements, then fold
the reliable dependency and build steps back into `setup-deps.sh` and `build.sh`.

## 2026-04-14 Inventory

- SSM is online.
- macOS: 15.7.4 (`24G517`).
- Disk: 500 GiB root volume, about 477 GiB free before source checkout.
- Developer tools: Command Line Tools only at `/Library/Developer/CommandLineTools`.
- `xcodebuild` currently fails because full Xcode is not installed.
- Present: Apple clang 17, Apple Git 2.50.1, Python 3.9.6, Ruby 2.6.10, Perl 5.34.1.
- Missing before bootstrap: Homebrew, CMake, Ninja.
- No Amazon-owned Xcode arm64 AMI was found in `eu-central-1` by name search.
- Homebrew installed successfully under `/opt/homebrew`.
- Installed core tools: CMake, Ninja, pkg-config, gperf, Ruby, Python 3.12, Git, Git LFS.

Open question: native WebKit/MiniBrowser may require full Xcode rather than CLT.
The exploration path is to install command-line build tools, clone WebKit, and run
a small native build probe to identify the first hard blocker.

## 2026-04-14 Build Probe

- WebKit cloned successfully to `/Users/ec2-user/Work/WebKit`.
- Current WebKit commit: `71471a58fedd5b39f591f59fd35b13e35827e915`.
- `Tools/Scripts/update-webkit` completed and reported already up to date.
- `Tools/Scripts/build-jsc --release` fails immediately because `xcodebuild`
  requires full Xcode and the active developer directory is CLT.
- WebKit's script prints: `Xcode 26.2 or later is required to build WebKit.`
- `softwareupdate --list` does not offer Xcode, only Safari and macOS updates.

Conclusion: macOS is now in the orchestration/dependency/change pipeline, but
native builds are blocked until full Xcode 26.2+ is installed or the host is
replaced with an image that includes it.

---
