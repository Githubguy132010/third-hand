# Third Hand

A small macOS menu bar assistant. Focus an app, press **Control–Space**, and tell it what to do.

Third Hand reads accessible controls, types, clicks, and checks the result. Press **Control–Space** again or click **×** to stop.

## Download

[Download the latest release](https://github.com/shhivv/third-hand/releases/latest) for Apple Silicon Macs running macOS 14 or newer. Unzip the archive, move **Third Hand.app** to Applications, and open it. Release builds are Developer ID-signed and notarized by Apple. A TypeSafe API key is required.

## Build from source

You’ll need **Xcode 15 or newer**, an Apple Development or Developer ID signing certificate, and a [TypeSafe API key](https://typesafe.ai).

```sh
git clone git@github.com:shhivv/third-hand.git
cd third-hand
./rebuild.sh
open "Third Hand.app"
```

In the setup window:

1. Enable **Accessibility** so Third Hand can read and control apps.
2. Enable **Screen Recording** for local text recognition when an app’s controls aren’t accessible.
3. Add your **TypeSafe API key**. It’s saved in macOS Keychain.

Switch to an app, press **Control–Space**, and try a specific task, such as “Search for Adele.”

The app runs on macOS 14+. Jev is the only model; Apple Intelligence is not required.

## How it works

- **Accessibility** reads controls and their current values.
- **Apple Vision** reads screen text locally when needed. Screenshots aren’t uploaded.
- **Jev** chooses actions from text descriptions. Your request, app name, screen labels and values, and recent action history are sent to TypeSafe. Third Hand is **not fully offline**.
- **Structured text entry** lets Jev select search phrases or literal text from your current request. Free-form writing and arbitrary command generation are not supported.

No bundled model weights or extra runtime dependencies. Third Hand never restarts the apps it controls.

## Development

```sh
./rebuild.sh       # Build, sign, and update Third Hand.app
swift test         # Run tests without calling the live API
```

Always run the repository-root `Third Hand.app`. The build script keeps the same signing identity to preserve macOS permissions and retains the previous app in `.build/install.*`. Keep `.thirdhand-signing-identity` on your machine; it is excluded from Git. If no certificate is available, create an Apple Development certificate in Xcode before building.

Setup shows current permission status. If macOS asks you to quit and reopen after granting access, reopen this same copy.

Diagnostic logs are written to `~/Desktop/thirdhand.log`. They include action status, timing, and bounded API rejection messages. Review logs before sharing: service error messages can contain request details. API keys are redacted from those messages.

For terminal entry, focus a shell prompt and provide the exact command, such as `type "ls -la"`. Third Hand preserves the supplied command and submits only when Jev selects Return. It does not construct commands from navigation requests or append verification commands. It will not retype a terminal command automatically. Interactive editors and non-shell terminal programs are not supported by this entry mode.

## Status

An early, experimental project. Some apps expose incomplete controls; icon-only interfaces, custom editors, and complex gestures may not work. A task can stop without completing, and reported completion still needs your judgment. Stay nearby while it works.

Issues and pull requests are welcome. Please include your macOS version, the app involved, and the steps to reproduce. Don’t include API keys or private screen content.

## License

[MIT](LICENSE) — Shiv Shanmugam · [shiv@tryisle.com](mailto:shiv@tryisle.com)
