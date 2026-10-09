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
make eval       # accuracy, safety and latency on eval/commands.jsonl (SYSTEM_ONE_MODEL=..., EVAL_FLAGS=...)
```

Model and minimum probability are in **Settings… (⌘,)**. Optional Jev-compatible backend (LocalJev):

```sh
make localjev-run
defaults write dev.redos.RedOS systemOne.jevURL http://127.0.0.1:8080  # then restart RedOS
```

## System Two (multi-step tasks, questions)

What System One does not run goes to System Two, which returns a plan (always confirmed) or a short
answer. Choose the provider in **Settings…**: Ollama (local, default), GitHub Copilot (via the
official `copilot` CLI, tools disabled), OpenAI, Anthropic Claude, Google Gemini. API keys are stored
in the Keychain.

```sh
make test-live-copilot COPILOT_MODEL=claude-haiku-5.5   # check Copilot CLI as System Two
```

## License

[MIT](LICENSE)
