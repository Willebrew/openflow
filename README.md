<p align="center">
  <img src="docs/openflow_logo.png" alt="openflow" width="520">
</p>

# openflow

openflow is an AI-powered dictation app for macOS. Hold a hotkey, speak, and the cleaned transcript is typed into the field you were already using.

It stays out of the way so you can dictate into Mail, a browser, a terminal, or any other app without switching windows. Dictionary entries, phrases, and style options help the transcript match how you actually write.

Requires macOS 26 or later on Apple Silicon, plus Microphone and Accessibility.

## Download

Get the current Apple Silicon build:

[Download openflow](https://updates.jottly.ai/v1/apps/openflow/stable/macos-aarch64/download)

Move the app into `/Applications`, open it, and finish onboarding.

## Use

Hold **Fn**, speak, then release. Other hotkeys live in Settings.

The menu bar icon opens the hub. From there you can reach Home, History, Dictionary, Phrases, Style, Apps, and Settings.

On official builds you can sign in to openflow Pro, or use your own Groq API key stored in Keychain.

## Build

Open `openflow.xcodeproj` in Xcode, choose your signing team, and build the `openflow` scheme.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

openflow is released under the MIT License. The full text is in [LICENSE](LICENSE).
