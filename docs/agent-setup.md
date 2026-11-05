# Set up Oasis (for coding agents)

Read this whole document before you run any command. The user has nothing prepared: no clone of this repository, no Riot, and possibly no compiler tools. Cloning is a step further down. Do not clone, download, or install anything until the step that says to.

This document is the source of truth:

https://raw.githubusercontent.com/vajraimb/oasis/main/docs/agent-setup.md

If you were given that URL, you are already reading the right file. Follow it from the top. When a step says to stop, stop.

You run every command yourself. You stop when the Oasis console is open in the user's browser. The user ticks accounts and presses Save. You do not.

Oasis runs on macOS or Linux. On Windows, stop and tell the user it is not supported. Do not look for a workaround.

## Done when

All three are true:

1. `curl -sf` of the dashboard URL returns success.
2. That URL is open in the user's browser.
3. You sent the one closing message at the bottom of this file, in the user's language. Then you stop.

## Never

- Do not write an API key into `oasis.toml`, git, a log, or your reply.
- Do not ask the user to paste an API key into the chat. The setup page has the field.
- Do not click Save, untick rows, or edit `~/.oasis/oasis.toml` by hand.
- Do not set `OASIS_HOME`. Use the default `~/.oasis`, unless the user already exported `OASIS_HOME`.
- Do not `pkill` anything named oasis. Stop only a gateway you just started, and only with `scripts/oasis.sh stop` from the clone.
- Do not commit, push, or open a pull request.
- Do not send a sample request or reconfigure their editor unless they ask.
- Do not install Riot from Homebrew, npm, opam, or a GitHub release you found yourself. The install below is the one published on https://riot.ml.

## 0. See what this machine already has

Run these and keep the output. Do not install anything in this step.

```bash
uname -s
command -v curl || echo 'MISSING curl'
command -v git || echo 'MISSING git'
command -v patch || echo 'MISSING patch'
command -v perl || echo 'MISSING perl'
test -x "$HOME/.riot/bin/riot" && "$HOME/.riot/bin/riot" --version || echo 'MISSING riot'
test -d "$HOME/oasis/.git" && echo 'oasis clone exists' || echo 'no oasis clone'
test -f "${OASIS_HOME:-$HOME/.oasis}/oasis.pid" && echo 'oasis pid file exists' || true
```

`uname -s` must be `Darwin` or `Linux`. Anything else: stop.

## 1. If Oasis is already running, open it and stop

Skip this step when `~/.oasis` does not exist.

```bash
if [ -x "$HOME/oasis/scripts/oasis.sh" ]; then
  (cd "$HOME/oasis" && scripts/oasis.sh status)
fi
url=$(grep -o 'http://127.0.0.1:[0-9]*/' "${OASIS_HOME:-$HOME/.oasis}/logs/oasis.log" 2>/dev/null | tail -1)
if [ -n "$url" ] && curl -sf -o /dev/null "$url"; then
  echo "ALREADY_UP $url"
fi
```

If that prints `ALREADY_UP`, open that URL (step 9) and send the closing message. Do not clone or rebuild.

## 2. Install the few system tools a blank machine may lack

Oasis needs `curl`, `git`, `patch`, and `perl` on the command path. `scripts/oasis.sh` runs `/usr/bin/perl` specifically, so `perl` must exist at that path. These are operating-system packages, not part of Riot.

**macOS.** `curl` and `perl` are already on the system. `git` and `patch` come with the Xcode command line tools. Check:

```bash
command -v git && command -v patch && test -x /usr/bin/perl && echo 'TOOLS_OK'
```

If that does not print `TOOLS_OK`, run `xcode-select --install`. macOS then opens a dialog. Tell the user to click Install and wait, then run the check again. Do not continue until it prints `TOOLS_OK`.

**Linux.** Install only what the check in step 0 reported missing. If `sudo` asks for a password, stop and give the user the exact command. Do not invent another package manager.

Debian or Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y curl git ca-certificates patch perl
```

Fedora:

```bash
sudo dnf install -y curl git ca-certificates patch perl
```

Arch:

```bash
sudo pacman -S --needed curl git ca-certificates patch perl
```

Confirm `/usr/bin/perl` exists. If `perl` is installed somewhere else, stop and tell the user. Do not edit `scripts/oasis.sh`.

## 3. Install Riot from riot.ml

Riot is the build tool. Its page is https://riot.ml. The page states that Riot supports macOS and Linux and installs the `riot` command to `~/.riot/bin`. The installer published there is:

```bash
curl -sSL https://get.riot.ml | sh
```

Run that only if `"$HOME/.riot/bin/riot" --version` does not already print a version. The installer downloads the `riot` command and nothing else. It does not download the OCaml compiler. That is a separate step after the repository is on disk.

The installer does not always change the shell you are in. For every later command in this session:

```bash
export PATH="$HOME/.riot/bin:$PATH"
"$HOME/.riot/bin/riot" --version
```

The version line must appear. If the installer fails, stop and show its output. Do not try a different install method. The user can read https://riot.ml.

So that a later login shell can find `riot`, add the same `PATH` line to the user's shell startup file once, if it is not already there. Use `~/.zshrc` when `$SHELL` ends in `zsh` (the macOS default), otherwise `~/.bashrc`. Add exactly this line:

```bash
export PATH="$HOME/.riot/bin:$PATH"
```

## 4. Clone the repository

This is the first time you clone. The user does not have the files yet.

```bash
git clone https://github.com/vajraimb/oasis.git "$HOME/oasis"
cd "$HOME/oasis"
```

If `$HOME/oasis` already exists and contains `scripts/oasis.sh` and `riot.toml`, use that directory. Do not delete it and do not clone a second copy. If `$HOME/oasis` exists and is not this repository, stop and ask where to put the clone.

Leave the clone on the default branch. Do not create a branch.

## 5. Download the OCaml compiler, then build

Still in `$HOME/oasis`. The compiler version is pinned in `ocaml-toolchain.toml`. `riot toolchain install` reads that file and downloads the compiler into `~/.riot/toolchains`. On a blank machine this is a few minutes. Let it finish.

`riot plan` then downloads the package registry into `~/.riot/registry`. The patch script only works after that download. It is safe to run more than once. `riot build` compiles Oasis. The first build also compiles Riot's standard library and can take several minutes. Do not cancel it and do not start a second build.

```bash
export PATH="$HOME/.riot/bin:$PATH"
cd "$HOME/oasis"
riot toolchain install
riot plan > /dev/null
scripts/patch-riot.sh
riot build
scripts/oasis.sh --self-test
```

The self-test needs no API key. It starts mock servers and checks routing, fallback, and streaming. It must end with failures at zero.

If `riot build` fails with a missing-outputs or cache error, run this once and then repeat the self-test:

```bash
riot clean --force
riot plan > /dev/null
scripts/patch-riot.sh
riot build
scripts/oasis.sh --self-test
```

If the self-test still fails, stop and show the failing lines. Do not start the gateway.

## 6. Start Oasis so it can see the user's keys

API keys the user keeps in `~/.zshrc` or `~/.bashrc` are invisible to the shell you have been using. Start Oasis through a login shell. `scripts/oasis.sh` daemonizes the process, so that login shell exiting does not stop Oasis.

From any directory, pick the block that matches `$SHELL`:

```bash
# zsh, including the macOS default
zsh -lic 'export PATH="$HOME/.riot/bin:$PATH"; cd "$HOME/oasis" && scripts/oasis.sh start'

# bash
bash -lc 'export PATH="$HOME/.riot/bin:$PATH"; cd "$HOME/oasis" && scripts/oasis.sh start'
```

The line `Oasis 已启动` means the process is alive, not that it is ready. On a first start there is no `~/.oasis/oasis.toml` yet. Oasis probes every provider key it can see in the environment, local Ollama, and installed agent CLIs. That probe takes up to about 40 seconds, and only then does it listen.

## 7. Wait until the console answers

```bash
url=""
for _ in $(seq 1 45); do
  url=$(grep -o 'http://127.0.0.1:[0-9]*/' "${OASIS_HOME:-$HOME/.oasis}/logs/oasis.log" 2>/dev/null | tail -1)
  if [ -n "$url" ] && curl -sf -o /dev/null "$url"; then
    echo "READY $url"
    break
  fi
  sleep 2
done
```

You need a line `READY http://127.0.0.1:<port>/`. The port is `9899` unless the user already had a config with a different port.

If the loop ends without `READY`, show the last 40 lines of `${OASIS_HOME:-$HOME/.oasis}/logs/oasis.log` and stop. A line `Failed to bind` means some Oasis is already listening on that port. Open `http://127.0.0.1:9899/` (or the port in the error) instead of starting another copy.

While you wait, you can tell the user one short sentence: Oasis is testing the accounts already on this machine. Do not ask them questions.

## 8. See whether the setup page will show

```bash
curl -s "${url}api/setup/scan"
```

Read `needs_setup`, and count `accounts` and `agents`. Do not paste this JSON to the user. It names accounts and environment variables. It does not contain key values. Keep it that way.

## 9. Open the browser, tell the user, stop

macOS:

```bash
open "$url"
```

Linux with a desktop:

```bash
xdg-open "$url"
```

If neither command exists, give the user the URL and ask them to open it. That is the only question you ask.

Then send one message and do nothing else.

If `needs_setup` is true, or this was the first start and `~/.oasis/oasis.toml` was just created:

- 中文：Oasis 已经在运行，控制台已打开：`<url>`。页面上的配置层会列出这台机器上测过的账户和 agent。勾选要留下的，缺的 key 粘贴在那一页里，点「保存并开始」。不用改配置文件，也不用把 key 发给我。
- English: Oasis is running and the console is open: `<url>`. The setup panel lists the accounts and agents it already tested on this machine. Tick what you want, paste any missing key on that page, and press Save & start. You do not edit a config file, and you do not send a key here.

If `needs_setup` is false:

- 中文：Oasis 已经在运行，控制台已打开：`<url>`。账户已经配好，在输入框里直接用。
- English: Oasis is running and the console is open: `<url>`. Accounts are already configured; type a task in the box.
