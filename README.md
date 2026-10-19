# zammad-avito

An [Avito](https://www.avito.ru) Messenger channel for [Zammad](https://zammad.org): chats from one or more
Avito accounts become tickets, agent replies go back to the chat, and messages written in Avito's own
interface show up in the ticket as well.

**Status: work in progress.** The Avito API core (`lib/avito_messenger/`) is written and tested; the Zammad
side (channel admin, webhook endpoint, jobs, reply action) is next. Target: Zammad 7.2.

## Requirements

- An Avito account with the Messenger API subscription. Without it the API lists chats but answers
  `402` to every message request.
- Client credentials (`client_id`, `client_secret`) for each account, from the account's API settings.
- A public HTTPS URL for Zammad that Avito can reach, for the webhook.

## Layout

The repository mirrors Zammad's source tree, so its files can be copied into a Zammad image or bundled into
a package.

| Path | What |
|---|---|
| `lib/avito_messenger/` | Avito API client and the decisions that need no database. Plain Ruby |
| `spec_standalone/` | Specs for that core, run without Zammad |
| `docs/DESIGN.md` | How accounts, message sync, echo detection and delivery work |

## Tests

```bash
bin/test
```

Runs the standalone specs in Docker on Ruby 3.4.9, the version Zammad 7.2 uses.
