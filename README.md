# Miniflux — Omarchy bar widget

The latest unread entries from your [Miniflux](https://miniflux.app) instance, in the
Omarchy bar. Click a title to read it in your browser, mark one entry read, or mark
everything the panel is showing read.

![Miniflux panel in the Omarchy bar](preview.png)

## Install

```sh
git clone <this repo> ~/.config/omarchy/plugins/anavarre.miniflux
omarchy plugin validate ~/.config/omarchy/plugins/anavarre.miniflux
omarchy plugin enable anavarre.miniflux
omarchy-shell shell rescanPlugins
omarchy bar move anavarre.miniflux --section right
```

Requires `curl` and `bash`, both of which Omarchy already has.

Every request goes through `bin/miniflux-api`, one script with a subcommand per
request (`auth`, `entries`, `mark`, `save-entry`, `icon`, `config`, `save`, `forget`); the
panel only passes it arguments, never shell code. It runs `/usr/bin/bash` on the script with `PATH` fixed to `/usr/bin:/bin` and a scrubbed
environment: only `HOME`, `XDG_CONFIG_HOME`, the `MINIFLUX_*` variables below, the
proxy variables (`https_proxy`, `all_proxy`, `no_proxy` and their upper-case forms)
and the CA variables (`SSL_CERT_FILE`, `SSL_CERT_DIR`, `CURL_CA_BUNDLE`) are passed
through. `~/.curlrc` is ignored, URL globbing is off, and the proxy variables are
ignored for a plain `http://` server, which is only ever loopback (see below), so the
cleartext request can never be routed off the machine. To debug a sign-in, run it yourself:
`bin/miniflux-api auth` prints the `/v1/me` answer and its HTTP status, or exits with
one of the codes listed at the top of the script. Its error output is cut off after
2 KiB, and the panel shows at most 200 characters of it.

## Usage

The first click opens a sign-in form: the address of your instance, your Miniflux
username and your password. The password is used once, to mint an API key through
`POST /v1/api-keys`; only that key is stored. Instances older than Miniflux 2.2.9 have
no such endpoint, so there the password itself is kept instead.

The plugin keeps its own credentials because Miniflux has no desktop client or CLI
with a sign-in to borrow: the REST API is the only way in, and every call needs a key
or a password. Minting a key of its own gives the plugin one you can revoke on its own
(under Settings → API keys, its description names this machine and when it was made) without touching your password.
The sign-in form's hint names the store actually in use, as described below.

The address must be `https://` (a bare hostname gets it added). Plain `http://` is
refused, since the password and API key would cross the network unencrypted — the one
exception is an instance on this machine (`localhost`, `127.x.x.x`, `[::1]`).

Credentials live in `$XDG_CONFIG_HOME/omarchy/miniflux/` (`~/.config/omarchy/miniflux/`
by default) — a `config` file with the server and username, and `token` plus its
`token-id` (or `password`) alongside it, all `0600` in a `0700` directory. Each file is
written to a temporary name and renamed into place, so an interrupted save never leaves
half a key behind, and a save that fails part-way removes what it had written rather
than leaving one server's address next to another's key. The plugin refuses a store that is a symlink or belongs to another
user, rather than reading or writing through it. Signing in again on the same server mints a fresh key and then
revokes the one it replaces. "Forget credentials" in the panel deletes the local files;
the API key stays on the Miniflux side until you revoke it under Settings → API keys.

Environment variables take precedence over the stored files, if you would rather manage
them yourself: `MINIFLUX_SERVER`, `MINIFLUX_API_KEY`, or `MINIFLUX_USERNAME` plus
`MINIFLUX_PASSWORD`. `MINIFLUX_PLUGIN_DIR` moves the store (point it at the real directory, not a symlink).

On the bar icon, a click opens or closes the panel and a middle-click refreshes the
list without opening it (or re-checks sign-in, when signed out); the tooltip lists
both. Clicks during a fetch fold into one follow-up request.

Each row shows the entry title, with its feed and age underneath. Clicking the title
opens it in your default browser; the check button on the right (unless turned off
in settings) marks that one entry read; "Mark as read" marks the entries currently loaded in the panel and nothing
else — unread entries beyond the list are untouched, so a shorter list is also a
narrower action.

The footer reads **Mark as read**, **Add feed**, **Settings** and **Account**. **Add feed** (or `f`)
opens a form for a feed's address, or a page that links to one. The address is checked
first — it has to answer and be a valid RSS, Atom or JSON feed, as Miniflux accepts — and only then subscribed to, under your
first category. Miniflux fetches the feed as it is created, and the list refreshes
straight after, so its entries are there to read. In the form, `Enter` adds, `↓` moves
onto the **Cancel** and **Add** buttons, `←`/`→` pick one, `Enter` presses it and `↑` goes back to the field.

| key | |
|---|---|
| `j` / `k`, arrows | move the selection |
| `Enter` | open the selected entry |
| `x` | mark the selected entry read |
| `Shift+a` | mark the listed entries read |
| `r` | refresh |
| `f` | add a feed |
| `c` | change credentials |
| `s` | save the selected entry to your Miniflux save integration; its bookmark fills in |
| `,` | open settings |
| `Escape` | close |

## Settings

In the plugin's settings (Omarchy's plugin picker, or its entry in `~/.config/omarchy/shell.json`):

- **Entries to show** — how many entries the panel lists, 1 to 100 (default 10).
  Also in the panel's **Settings** section, which steps by one up to ten and by
  ten above it; the plugin's settings form takes any value in the range. Changing
  it refetches the list.
- **Refresh every (minutes)** — how often the list refreshes on its own: 30
  minutes, 1, 2, 3, 6, 12 or 24 hours (default 30 minutes). Also reachable from
  the panel's **Settings** button, which writes the same setting.
- **Text size** — Small, Medium, Large or Extra large; scales every piece of
  text in the panel. Also in the panel's **Settings** section, where picking a
  size redraws the panel at that size straight away.
- **Mark new entries on the bar** — on by default. When a background refresh
  turns up entries that were not in the previous list, a dot appears on the bar
  icon; opening the panel clears it. The first fetch after signing in only sets
  the baseline, so it never starts out dotted. Also in the panel's **Settings**
  section, as a switch.
- **Save button on each entry** — on by default: every entry carries a bookmark,
  left of the mark-read check, that saves it to your Miniflux save integration.
  The bookmark fills in once the entry is saved, and a saved entry shows it even
  with this off, so saving with `s` is never silent. Miniflux keeps no saved flag
  on an entry, so this only covers what was saved since the shell started, and a
  saved entry is not sent again. Also in the panel's **Settings** section, as a
  switch.
- **Mark-read button on each entry** — on by default: every entry carries a check,
  on the right, that marks it read. Off, `x` still marks the selected entry read,
  and "Mark as read" still marks the listed entries. Also in the panel's
  **Settings** section, as a switch.
- **Feed icon on each entry** — off by default. On, every entry leads with its
  feed's icon, the one Miniflux already stores for it, fetched from your instance
  (never from the feed's own site) once per feed listed and dropped when the feed
  leaves the list. Raster icons (PNG, JPEG, GIF, WebP, BMP, ICO) are checked by their
  first bytes rather than their declared type. A PNG is rewritten with only its
  drawing chunks (text, ICC profile and unknown chunks are cut out) and skipped if
  malformed or larger than 1024 pixels a side. An SVG icon is a document written by the feed's site and
  Qt's SVG renderer would run it inside the shell, so only a small plain drawing is
  shown (shapes and gradients: no images, links, styles, scripts, entities or
  animation); any other SVG is skipped. A feed with no icon, or one that is skipped, shows a dim
  RSS glyph instead. Also in the panel's **Settings** section, as a switch.
- **Oldest entries first** — off by default, so the most recent entries lead. On,
  the oldest lead instead. In `shell.json` this is `"sortOrder": "newest"` or
  `"oldest"`. Also in the panel's **Settings** section, as a switch.
- **Group entries by feed** — off by default. On, each feed's entries are listed
  together (the feed's name follows the age on every row instead of a header), feeds in the order they first appear in the list
  and entries in the chosen order. Only the entries fetched are grouped, so the
  entry limit still applies to the list as a whole. Also in **Settings**.
- **Unread entries only** — off also lists entries you have already read.

The arrow at the bottom left of the Settings section opens the settings page of
your own instance in the browser, for everything the panel does not cover.

## How it runs

A background service (`Service.qml`) owns sign-in, the entry list and the refresh
timer, once for the whole shell: with the bar on several monitors there is still one
fetch per interval, and marking an entry read on one screen takes it off every
screen. It checks the stored sign-in when the shell starts, so the new-entry dot works
before the panel has ever been opened.

It reconnects on its own. When a request never reaches the server (offline, DNS, a
timeout) or the server answers 5xx or 429, the list on screen stays, the panel shows
why under the header, and the request is retried after 10, 20, 40 and 80 seconds,
then every 2 minutes until it goes through. A failed sign-in check made while offline
is not treated as a credential problem, so the sign-in form does not take over. After
a suspend or hibernate the list is refreshed a few seconds after wake, without waiting
for the next interval. A rejected credential or a missing setting still waits for you.

Under a third-party bar that provides no plugin
services, the panel says so instead of listing entries.

The service also answers to `omarchy-shell anavarre.miniflux <method>`, for a hotkey
or a status script:

| method | does | answers |
|---|---|---|
| `refresh` | fetches the list now (or re-checks sign-in when signed out) | `ok`, or `throttled` within 10 s of the previous call |
| `toggle` | opens or closes the panel, as a click on the bar icon would | `ok`, or `unavailable` with no live bar widget |
| `status` | nothing | `{"auth":"ok","loading":false,"error":false,"listed":10,"unread":10,"total":42,"new":false}` |

`auth` is `unknown`, `checking`, `ok`, `offline` (the server could not be reached; retrying) or `error`; `listed` and `unread` count the
entries the panel holds, `total` those matching its filter on the instance. No answer
carries the server address, username, entry titles or error text.

```sh
# Hyprland: Super+Alt+M toggles the panel
bind = SUPER ALT, M, exec, omarchy-shell -q anavarre.miniflux toggle
```

## Tests

```sh
tests/run
```

runs the checks that need neither Omarchy nor a display: Node unit tests for
`Model.js`; `bin/miniflux-api` against a fake Miniflux on `127.0.0.1` (argument
checks, the plain-http refusal, the size and stderr caps, sign-in, key rotation and
the store checks), with fictional credentials in a temporary store; QtTest cases for
`Service.qml` (`tests/qml/service`), where a fake `Quickshell.Io` Process never runs
anything and each test finishes requests by hand — sign-in checks, refreshes folding
into one follow-up, late answers dropped after a settings change or a forget, the
mark-read queue and its failure path, the new-entry dot, saved-entry bookmarks, notices on panel close,
and the IPC throttle and status; `shellcheck`;
and `qmllint` against stub `qs.Ui`, `qs.Commons` and `Quickshell` modules in
`tests/qml/imports`. The Omarchy stubs are generated from the upstream revision named
at the top of each one by `tests/qml/stubgen.py`. It needs `node`, `python3` and
`curl`; a missing `shellcheck` or `qmllint` (or `pyside6-qmllint`, or `QMLLINT=path`),
or a `python3` without PySide6 (or `QMLTEST_PYTHON=path`), is skipped, unless `CI` is
set. `tests/qml/service/run.py -functions test_name` runs one service test.
`.github/workflows/tests.yml` runs the same script with `CI` set on every push to
`main` and every pull request, with `pyside6-essentials` pinned for the Qt checks.

Passing says nothing about the live shell: loading under Omarchy's real imports,
panel placement, focus and IPC still have to be tried on Omarchy itself.

## Remove

```sh
omarchy plugin disable anavarre.miniflux
rm -rf ~/.config/omarchy/plugins/anavarre.miniflux ~/.config/omarchy/miniflux
```

## License

[MIT](LICENSE).
