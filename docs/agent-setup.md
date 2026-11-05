# Set up Oasis (for coding agents)

The user asked you to install Oasis and hand them the console. You run every command. You stop when the console is open in their browser. They tick accounts and press Save themselves.

Do this on macOS or Linux. On Windows, stop and say it is not supported.

## Done when

All three are true:

1. `curl -sf` of the dashboard URL returns success.
2. That URL is open in the user's browser.
3. You told the user, in their language, the one closing message at the bottom of this file. Then you stop.

## Never

- Do not write an API key into `oasis.toml`, git, a log, or your reply.
- Do not ask the user to paste an API key into the chat. The setup page has the field.
- Do not click Save, untick rows, or edit `~/.oasis/oasis.toml` by hand.
- Do not set `OASIS_HOME`. Use the default `~/.oasis`, unless the user already exported `OASIS_HOME`.
- Do not `pkill` anything named oasis. Stop only a gateway you just started, and only with `scripts/oasis.sh stop` from this clone.
- Do not commit, push, or open a pull request.
- Do not send a sample request or reconfigure their editor unless they ask.

## 1. If it is already running, open it and stop

```bash
scripts/oasis.sh status
```

If this clone does not exist yet, skip to step 2. If the command says it is running, take the dashboard URL from the log (the `http://127.0.0.1:<port>/` line) and continue at step 7.

```bash
grep -o 'http://127.0.0.1:[0-9]*/' "${OASIS_HOME:-$HOME/.oasis}/logs/oasis.log" | tail -1
```

## 2. Get the repo

If the current directory contains `scripts/oasis.sh` and `riot.toml`, use it. Otherwise:

```bash
git clone https://github.com/vajraimb/oasis.git "$HOME/oasis"
cd "$HOME/oasis"
```

If `$HOME/oasis` already exists and is not this repo, stop and ask where to clone. Do not delete it.

## 3. Toolchain, build, self-test

`riot` lives at `$HOME/.riot/bin/riot` after install. Put it on `PATH` for this session.

```bash
export PATH="$HOME/.riot/bin:$PATH"
command -v riot >/dev/null || curl -fsSL https://get.riot.ml | sh
export PATH="$HOME/.riot/bin:$PATH"
riot plan > /dev/null && scripts/patch-riot.sh
riot build
scripts/oasis.sh --self-test
```

`scripts/patch-riot.sh` is safe to run more than once. The self-test needs no API key. It must print a pass count and zero failures.

If `riot build` fails with a missing-outputs or cache error, run `riot clean --force`, then `riot plan`, `scripts/patch-riot.sh`, and `riot build` once more. If the self-test still fails, stop and show the user the failing lines. Do not start the gateway.

## 4. Start it with the user's own keys visible

Keys the user keeps in `~/.zshrc` or `~/.bashrc` are invisible to a non-login shell. Start through a login shell so the first run can see them. The process daemonizes; the login shell exiting does not stop it.

```bash
# from the repo root; zsh users (default on macOS):
zsh -lic 'cd "'"$PWD"'" && scripts/oasis.sh start'
# bash users:
# bash -lc 'cd "'"$PWD"'" && scripts/oasis.sh start'
```

Use whichever matches `$SHELL`. "Oasis 已启动" only means the process is alive. On a first start it then probes providers for up to about 40 seconds before it listens.

## 5. Wait until the console answers

Default port is `9899`. If `~/.oasis/oasis.toml` already existed, read `port` from it. After the banner is in the log, prefer the URL printed there.

```bash
url=$(grep -o 'http://127.0.0.1:[0-9]*/' "${OASIS_HOME:-$HOME/.oasis}/logs/oasis.log" | tail -1)
[ -z "$url" ] && url="http://127.0.0.1:9899/"
for _ in $(seq 1 45); do
  curl -sf -o /dev/null "$url" && break
  sleep 2
done
curl -sf -o /dev/null "$url"
```

The last `curl` must succeed. If it does not, show the last 40 lines of `${OASIS_HOME:-$HOME/.oasis}/logs/oasis.log` and stop. A line `Failed to bind` means another Oasis is already on that port: open that port's dashboard instead of starting a second copy.

## 6. See whether the setup page will open

```bash
curl -s "${url}api/setup/scan"
```

Read `needs_setup` and how many `accounts` and `agents` are listed. Do not paste this JSON to the user. It names accounts and environment variables, not key values.

## 7. Open the browser, tell the user, stop

macOS: `open "$url"`

Linux: `xdg-open "$url"`

Then send one message and do nothing else.

If `needs_setup` is true, or this was a first start:

- 中文：Oasis 已经在运行，控制台已打开：`<url>`。页面上的配置层会列出这台机器上测过的账户和 agent。勾选要留下的，缺的 key 粘贴在那一页里，点「保存并开始」。不用改配置文件，也不用把 key 发给我。
- English: Oasis is running and the console is open: `<url>`. The setup panel lists the accounts and agents it already tested on this machine. Tick what you want, paste any missing key on that page, and press Save & start. You do not edit a config file, and you do not send a key here.

If `needs_setup` is false:

- 中文：Oasis 已经在运行，控制台已打开：`<url>`。账户已经配好，在输入框里直接用。
- English: Oasis is running and the console is open: `<url>`. Accounts are already configured; type a task in the box.
