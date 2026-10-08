# RedOS

AI assistant for macOS that lives in the menu bar: voice or text commands, local decision model
(Jev via LocalJev + Ollama), full control of your Mac. See [docs/PLAN.md](docs/PLAN.md).

## Requirements

- macOS 26+, Apple Silicon
- Swift 6.2 (Command Line Tools or Xcode)
- `brew install swiftlint`

## Getting started

```sh
make cert      # once: stable self-signed signing identity (keeps privacy permissions across builds)
make run       # build, bundle, sign and launch build/RedOS.app
make install   # install into /Applications
make test
make lint
```

Version is read from `VERSION`; build number is the git commit count.

## Usage

Press **⌥ Space** (or menu bar > Command…) and type a command, in English or Italian:

| Example | Action |
|---|---|
| `apri Safari` / `open Safari` | `app.open` |
| `chiudi Slack` / `quit Slack` | `app.quit` |
| `scrivi "ciao"` / `type hello` | `text.type` |
| `scrolla giù 10` / `scroll up` | `scroll` (under the pointer) |
| `muovi il mouse a 300 400` / `move mouse to 300 400` | `mouse.move` |
| `clicca` / `click at 100 200` | `mouse.click` |

Every command is recorded in `~/Library/Application Support/RedOS/audit.jsonl` (typed text is redacted).

## System One (local, offline)

Commands that the fast path does not recognize are routed by a local model through Ollama:

```sh
brew install ollama && brew services start ollama
make models     # pulls gemma4:e4b-it-qat (~6 GB)
make test-live  # routing check against the real model
```

Settings (until the Settings window exists):

```sh
defaults write dev.redos.RedOS systemOne.model gemma4:12b-it-qat     # another Ollama model
defaults write dev.redos.RedOS systemOne.threshold -float 0.7         # minimum probability to act
defaults write dev.redos.RedOS systemOne.jevURL http://127.0.0.1:8080  # use LocalJev (`make localjev-run`)
```

Restart RedOS after changing them.

## License

[MIT](LICENSE)
