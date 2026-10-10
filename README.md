# RedOS

[![CI](https://github.com/Carassale/redos/actions/workflows/ci.yml/badge.svg)](https://github.com/Carassale/redos/actions/workflows/ci.yml)

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

Press **⌥ Space** (or menu bar > Command…) and type a command, in English or Italian.
Or **hold ⌃⌥ Space and speak**: release to send. Speech is recognized on this Mac (SpeechAnalyzer) and
answers can be read aloud (Settings > General > Voice). With **Listen for “Hey Red”** on, say “Hey Red”
and then the command: it is sent when you pause. The wake word runs on this Mac too ([openWakeWord](https://github.com/dscripka/openWakeWord)
models on ONNX Runtime).

| Example | Action |
|---|---|
| `apri Safari` / `open Safari` | `app.open` |
| `chiudi Slack` / `quit Slack` | `app.quit` |
| `scrivi "ciao"` / `type hello` | `text.type` |
| `scrolla giù 10` / `scroll up` | `scroll` (under the pointer) |
| `muovi il mouse a 300 400` / `move mouse to 300 400` | `mouse.move` |
| `clicca` / `click at 100 200` | `mouse.click` |
| `clicca su Salva` / `press the Login button` / `apri il menu File` | `ui.press` (by name, Accessibility) |
| `scrivi mario nel campo Utente` / `type pizza in the Search field` | `ui.fill` |
| `leggimi lo schermo` / `read the screen` | `ui.read` |
| `esegui il comando git status` / `run the command ls` | `shell.run` (always confirmed) |
| `apri il primo menu` / `open the second result` | screen agent (looks, acts, repeats) |
| `a chi è assegnata questa MR?` / `what does this page say about pricing?` | answer from the screen (never acts) |

While RedOS drives the Mac a HUD shows each step: **Stop** or **⌃⌥⎋** (kill switch) halts it at once.
The agent only presses, fills, reads, scrolls and opens apps or links: it never types into the focused
app, runs dangerous actions (shell) or follows instructions found on screen. Questions about what is on
screen ("questa pagina", "this MR") are answered by reading it, without acting; System Two also knows
the frontmost app and window title.

| Routines, memory, selection | |
|---|---|
| `crea la routine buongiorno: apri Mail e Calendario` / `create routine focus: open Xcode` | saved as validated steps |
| `avvia la routine buongiorno` / `run routine focus` | runs without any model |
| `programma la routine buongiorno alle 9 nei giorni feriali` / `schedule routine focus at 2 pm` | daily trigger |
| `avvia la routine focus quando apro Xcode` / `run routine focus when I open Xcode` | app-launch trigger |
| `ricorda che il mio editor è Visual Studio Code` → `apri il mio editor` | memory, given to System Two |
| `traduci in inglese il testo selezionato` / `summarize the selected text` | answer about the selection |
| `2+2`, `quanto fa 3,5 per 4`, `20% di 150` | instant, exact (no model) |
| `converti 10 miglia in km`, `100 °F in °C`, `100 dollari in euro` | instant (currencies: ECB rates) |
| `che tempo fa domani a Milano?`, `ultime notizie su Apple`, `chi ha diretto Dune parte due?` | web research with sources, charts and images |
| `disegna il flusso di login con 2FA`, `grafico a barre: gennaio 10, febbraio 15` | diagram window (HTML/SVG) |

Questions go through an orchestrator: arithmetic and conversions are computed locally; System Two answers
stable knowledge directly and sends anything current to a research agent that searches the web (DuckDuckGo),
reads pages, news (Google News), weather (Open-Meteo) and exchange rates (ECB), then answers with sources.
No API keys needed; web content is treated as data and remembered facts are never sent to it.

Triggered routines ask for confirmation when a step is above `safe`. Routines, memory and cloud usage are
in `~/Library/Application Support/RedOS/` and in **Settings**, which also has an offline-only switch and a
daily cloud request limit (beyond it System Two uses the local model).

Every command is recorded in `~/Library/Application Support/RedOS/audit.jsonl` (typed text is redacted).

## System One (local, offline)

Commands that the fast path does not recognize are routed by a local model through Ollama:

```sh
brew install ollama && brew services start ollama
make models       # pulls gemma4:e4b-it-qat (decisions, ~6 GB) and gemma4:e2b-it-qat (arguments, ~4 GB)
make ollama-tune  # 2 cache slots per model: much faster (re-run after `brew services restart ollama`)
make test-live    # routing check against the real model
make eval         # accuracy, safety and latency (EVAL_FLAGS="--dataset eval/holdout.jsonl", --system-two M)
```

Model and minimum probability are in **Settings… (⌘,)**. Optional Jev-compatible backend (LocalJev):

```sh
make localjev-run
defaults write dev.redos.RedOS systemOne.jevURL http://127.0.0.1:8080  # then restart RedOS
```

## System Two (multi-step tasks, questions)

What System One does not run goes to System Two, which returns a plan (always confirmed) or a short
answer. Choose the provider in **Settings…**: Ollama (local, default), GitHub Copilot (a persistent
`copilot --acp` process, no tools: ~1–2 s per call), OpenAI, Anthropic Claude, Google Gemini. API keys
are stored in the Keychain. **Priority: Accuracy** (default) sends unsure commands, plans and the screen
agent to this provider; **Speed** keeps plans and the agent on the local model.

```sh
make test-live-copilot COPILOT_MODEL=claude-haiku-5.5   # check Copilot as System Two
```

## Updates and releases

RedOS updates itself with [Sparkle](https://sparkle-project.org) from `appcast.xml` in this repo
(menu bar > Check for Updates…, Settings > Updates; beta channel is opt-in). Archives are signed with
an EdDSA key kept in the maintainer's Keychain (account `redos`) and the app with the same
certificate on every release, so macOS permissions survive updates.

```sh
# bump VERSION and commit, then:
make release            # zip + dmg in build/release, EdDSA signature, appcast item (CHANNEL=beta for betas)
make publish            # GitHub release with zip and dmg, then commit and push appcast.xml
```

Or from GitHub Actions: CI (lint, tests, app bundle) runs on every push and pull request; the **Release**
workflow does `make release` + `make publish` on a macOS runner with the same signing identity and
Sparkle key, stored once as secrets:

```sh
# Keychain Access > My Certificates > "RedOS Development" > Export… > RedOS.p12 (only this identity)
scripts/setup-release-secrets.sh ~/Desktop/RedOS.p12
# bump VERSION, commit, push, then:
gh workflow run release.yml -f channel=beta     # or channel=stable
```

The app is not notarized: on first install open it with right click > Open (or System Settings >
Privacy & Security > Open Anyway). Updates through Sparkle do not ask again.

## License

[MIT](LICENSE). Diagrams follow [diagram-design](https://github.com/cathrynlavery/diagram-design) by Cathryn
Lavery (MIT), bundled in `Resources/DiagramDesign` with its [license](Resources/DiagramDesign/LICENSE).
The wake word uses openWakeWord's feature models (Apache 2.0, `Resources/WakeWord`) and
[ONNX Runtime](https://github.com/microsoft/onnxruntime) (MIT).
