# Unsub

Unsubscribe from the email selected in Apple Mail with one keypress. Unsub
uses the sender's own unsubscribe mechanism, so you don't hand your inbox to a
third-party service.

It covers what Clean Email or Leave Me Alone do for a single message, without
an account, a subscription, or mailbox access for anyone else. Unsub never
moves, archives, or deletes mail.

## How it works

Select one message in Mail and press **Caps+U**. Unsub reads the message's
headers and tries each method in turn, stopping at the first that works:

1. **One-click** — if the message supports RFC 8058 one-click unsubscribe (an
   `https` `List-Unsubscribe` link plus `List-Unsubscribe-Post`), Unsub sends
   that POST.
2. **Unsubscribe email** — if `List-Unsubscribe` has a `mailto:` address, Mail
   sends the unsubscribe email from the account that received the message.
   With `mailtoMode = "compose"`, the draft opens instead and you press Send.
3. **Web page** — Unsub fetches the `List-Unsubscribe` web link (or, if the
   message has none, an unsubscribe link from the body), picks the
   "unsubscribe from everything" choice, and submits the form, following up to
   three pages until one confirms you're unsubscribed. With an OpenAI key
   stored, a model judges unfamiliar pages; otherwise simple heuristics press
   an obvious unsubscribe or confirm button.
   Unsub only starts automatically from a public `https` link; plain `http`
   and local-network links open in your browser instead.
4. **Browser** — anything it can't finish (captchas, logins, pages built
   entirely in JavaScript, unreachable sites, ambiguous or risky choices)
   opens in your browser.

An alert reports the result. The work runs in the background, so Hammerspoon
never blocks.

| Key | Action |
| --- | --- |
| `Caps+U` | Unsubscribe from the selected Mail message |
| `Ctrl+Alt+Cmd+U` | Fallback when QuickShots' Caps tap is unavailable |

Rebind Caps+U from Palette (Caps+K → Unsubscribe).

### Dry run

```sh
open -g "hammerspoon://unsub"
```

The URL always runs a dry run: Unsub reads the selected message and reports
the method it would use, but sends no request, email, or page fetch. Because
any app can open the URL, it can never unsubscribe for real.

## Requirements

- Complete Loadout's [base-app prerequisites](../../PREREQUISITES.md#base-hammerspoon-apps) first.
- macOS 13 or later with [Hammerspoon](https://www.hammerspoon.org) 1.1.1 or later.
- Apple Mail, with the message you want to leave selected.
- `/usr/bin/python3`, which comes with the Xcode Command Line Tools
  (`xcode-select --install`). Unsub uses only the standard library.
- Optional: an OpenAI API key for judging unsubscribe pages.

## Install

```sh
git clone https://github.com/josephvore/loadout.git ~/loadout
cd ~/loadout
apps/unsub/install.sh
open -a Hammerspoon
```

The installer links `unsub.lua` and `unsub.py` into `~/.hammerspoon/`, backing
up anything it would replace. Reload Hammerspoon afterward. Keep the clone where you
cloned it because it is the live symlink target.

### OpenAI key (optional)

Unsub shares Hone's OpenAI key (Keychain service `openai-refine`). Store it
with:

```sh
apps/hone/setup-keys.sh
```

Without a key, Unsub still handles one-click, unsubscribe emails, and simple
pages.

## Permissions

The first run asks to let Hammerspoon control Mail. Allow it, or enable it
later under System Settings → Privacy & Security → Automation → Hammerspoon →
Mail. Unsub needs it to read the selected message and to send or draft the
unsubscribe email.

## Configuration

Open Caps+K → Unsubscribe → Settings:

- **Unsubscribe emails** (`mailtoMode`) — `send` (default) sends the email
  automatically; `compose` opens a draft for you to send.
- **Use AI on unsubscribe pages** (`useAI`) — on by default; it only takes
  effect when an OpenAI key is stored.
- **AI model** (`aiModel`) — the OpenAI model that judges pages.

Saved values live in `~/.hammerspoon/settings/unsub.json`. You can also set
`require("unsub").config` fields in `~/.hammerspoon/loadout.local.lua` (see
[local configuration](../../SETUP.md#local-configuration)).

## Privacy

Unsub reads the selected message's source from Mail on your Mac. What leaves
your Mac depends on the method:

- **One-click and web pages** — requests go to the unsubscribe URL in the
  message, which is on the sender's site (or its mailing provider). If a form
  asks for your email address, Unsub fills in the address that received the
  message. It never enters other personal data, passwords, or free-text
  reasons.
- **Unsubscribe email** — Mail sends a short email to the sender's
  unsubscribe address from your account. A copy stays in your Sent mailbox.
- **AI page judging** — with `useAI` on and an OpenAI key stored, the page's
  host, title, visible text, form fields, and your receiving address go to
  OpenAI. Turn `useAI` off to keep page content local; Unsub then uses simple
  heuristics. OpenAI's billing and data policies apply.

The message itself is never uploaded. Unsub logs the sender, the sites it
contacted, and the result to `~/.hammerspoon/logs/unsub.log`, which stays on
your Mac.

## Verify and test

Select a newsletter in Mail and run the dry run above; the alert should name
the method Unsub would use. Run `./test.sh` from the repo root for source and
installer checks.

Suite-wide update and safe-uninstall guidance is in the
[Loadout README](../../README.md#update-and-uninstall).

## About

Unsub is part of the [Loadout](../../README.md) suite. See the
[changelog](../../CHANGELOG.md) and [contributor guide](../../CONTRIBUTING.md).
Licensed under [MIT](./LICENSE).
