# zammad-avito

An [Avito](https://www.avito.ru) Messenger channel for [Zammad](https://zammad.org): chats from one or more
Avito accounts become tickets, agent replies go back to the chat, and messages written in Avito's own
interface show up in the ticket as well.

**Status: tested against the live Avito API from a local Zammad (polling, replies, images both ways); the
webhook has not run against Avito yet.** Target: Zammad 7.2, legacy (CoffeeScript) agent interface. See
`docs/DESIGN.md` for how it works and what was checked live.

## What it does

- **Several accounts**, each a channel of its own (Admin → Channels → Avito): own credentials, group, webhook
  and polling. Adding, disabling or deleting one leaves the others alone. A disabled account is off both
  ways: no import, and replies from its tickets fail with "account is disabled" instead of going out.
- **Incoming**: Avito's webhook for speed, plus a poll every few minutes for whatever the webhook missed. One
  ticket per chat, titled after the listing; the buyer becomes a customer. Images and voice messages arrive as
  attachments.
- **Messages written in Avito itself** (the website, the app, autoresponders) are added to the ticket as agent
  replies marked as coming from Avito, and never sent back. They are filed under a service user per account,
  named after the shop and wearing its Avito avatar; customers get their Avito avatars too.
- **Replies**: the "reply" action on an Avito message; long replies go out as several 1000-character
  messages, images as images. Other attachments are refused with a clear delivery error, before anything
  is sent.

## Requirements

- An Avito account with the Messenger API subscription ("Максимальный" for goods and jobs, "Расширенный" or
  "Максимальный" for services). Without it the API lists chats but answers `402` to everything else.
- Client credentials (`client_id`, `client_secret`) for each account, from the account's API settings.
- A public HTTPS address of Zammad that Avito can reach, for the webhook. It defaults to Zammad's own
  `http_type://fqdn`; each account can set another one.
- Outbound HTTPS to `api.avito.ru`. The client uses Ruby's `Net::HTTP`, which honours the `http_proxy`
  environment variable but not Zammad's proxy setting.

## Installing

The repository mirrors Zammad's source tree. To build it into a Zammad image, copy `app/`, `config/`, `db/`
and `lib/` over `/opt/zammad`, recompile the assets (`rake assets:precompile`), and let `db:migrate` run
(the Zammad docker image's init container does). `dev/preview/Dockerfile` is a working example.

No upstream file is changed: the reply observer is attached from `config/initializers/avito_channel.rb`.

## Layout

| Path | What |
|---|---|
| `lib/avito_messenger/` | Avito API client and the decisions that need no database. Plain Ruby |
| `lib/avito_channel/`, `app/`, `config/`, `db/` | The Zammad side: accounts, webhook, import, replies, polling, admin page |
| `spec_standalone/` | Specs for the API core, run without Zammad |
| `spec/` | Specs run inside Zammad's own test environment |
| `dev/` | Docker setups for those specs and for a local preview |
| `docs/DESIGN.md` | How it works, and what the live API still has to confirm |

## Development

```bash
bin/test          # API core specs, Ruby 3.4.9 in Docker
bin/zammad-spec   # Zammad-side specs; needs .zammad/ (see the script's header)
bin/preview       # local Zammad with the package at http://127.0.0.1:8080
```

The preview is cut off from the real Avito API (its demo accounts would send made-up credentials there).
