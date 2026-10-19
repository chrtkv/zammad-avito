# Design

An Avito Messenger channel for Zammad: chats from one or more Avito accounts become tickets, agent replies go
back to the chat, and messages a manager writes in Avito itself show up in the ticket too.

Target: Zammad 7.2.x. Agents use the legacy (CoffeeScript) UI; the new desktop/mobile views are out of scope
for the first version.

## Shape of the code

The repository mirrors the Zammad source tree, so the same files can be copied into a Zammad image or bundled
into a `.szpm` package.

| Layer | Where | Depends on |
|---|---|---|
| Avito API core | `lib/avito_messenger/` | Ruby stdlib only. Tested standalone (`spec_standalone/`) |
| Zammad glue | `app/`, `config/`, `db/` | Zammad models, jobs, controllers. Tested in a Zammad dev container (`spec/`) |
| Legacy UI | `app/assets/javascripts/app/...` | Zammad's `App.Config` registries |

Everything Avito-specific that can be decided without Zammad lives in the core: the HTTP client, token
handling, payload parsing, the rule for which side wrote a message, reply splitting, and the reconciliation
plan. The glue only maps those results onto users, tickets and articles.

No upstream file is patched:

- the article observer is attached from an initializer (`Ticket::Article.include ...`) instead of editing
  `app/models/ticket/article.rb`;
- secrets live under `options.auth.client_secret` and `options.auth.access_token`, paths that Zammad's
  `Channel::SENSITIVE_FIELDS` already masks;
- the channel area is `Avito::Account`, which puts it in `Channel.fetchable` (`area LIKE '%::Account'`), so
  Zammad's existing "Check channels" scheduler (every 30 s) drives polling through `Channel::Driver::Avito`.

## Accounts

One Zammad `Channel` per Avito account, fully independent:

```
area:    Avito::Account
group:   destination group for new tickets
options:
  adapter: avito
  auth:    { client_id, client_secret, access_token, access_token_expires_at }
  user_id: Avito account id (from /core/v1/accounts/self)
  name:    account name, for display
  callback_token: random secret, part of the webhook URL
  sync:    { backfill_days, poll_interval }
preferences:
  last_fetch, chats_cursor (max chat.updated seen)
```

- Each account has its own client credentials, token, webhook URL and subscription. Adding, disabling or
  deleting one never touches another.
- The same Avito `user_id` cannot be connected twice (checked on save).
- Webhook URL: `/api/v1/channels_avito_webhook/<callback_token>`. The token identifies the channel; the
  payload's `value.user_id` ("always the account the webhook is registered for") must also equal the
  channel's `user_id`, otherwise the event is rejected.

## Who wrote a message

A message has an `author_id`; the account is `user_id`. Three cases:

| Case | Rule | Zammad article |
|---|---|---|
| Customer wrote | `author_id != user_id` | sender Customer |
| Zammad sent it (agent reply) | own message whose id is already on an article | nothing: it is the echo of our own send |
| Someone wrote in Avito itself (web, app, autoresponder, another integration) | own message with an unknown id | sender Agent, marked `preferences.avito.origin = 'avito'`, never sent back |

The outbound job stores the Avito message id on the article right after sending (`message_id`
`avito.<user_id>.<chat_id>.<message_id>`). The echo can arrive before that save commits, so own messages are
not imported straight from the webhook: they are deferred by a minute and re-checked, and an own message whose
text equals a reply Zammad sent to the same chat in the last ten minutes is linked to that article instead of
imported.

Whether Avito's webhook delivers own messages at all is not documented. It does not matter for correctness:
the reconciliation poll below sees them in `/messenger/v3/.../messages` with `direction: out` either way.

## Getting messages in

Two paths, both idempotent by Avito message id:

1. **Webhook** (`POST /messenger/v3/webhook`), for speed. Avito wants a 200 within 2 s, so the controller
   checks the token and the account and enqueues a job; parsing and ticket work happen in the job. Avito
   checks the URL by POSTing `{}`; that probe gets a plain 200.
2. **Reconciliation poll** via `Channel::Driver::Avito#fetch`, every few minutes per account: list chats,
   take those with `updated` newer than the stored cursor, read their recent messages and import whatever
   is missing. This covers lost webhooks, downtime, and own messages, and does the initial backfill when an
   account is connected.

API limits shape the poll: `limit` is at most 100 and `offset` at most 1000 for both chats and messages, so
only the latest ~1100 of each are reachable.

## Message types

| Avito type | Article |
|---|---|
| `text` | body |
| `image` | attachment (largest size), body empty or caption |
| `voice` | attachment via `getVoiceFiles` |
| `item`, `link`, `location` | rendered as text (title, URL, price / address) |
| `call` (missed) | short text "missed call" |
| `system` | internal note (Avito's own notices, bots) |
| `deleted` | internal note on the ticket; the original article stays |
| `file`, `video`, `appCall` | Avito sends no content: a placeholder text naming the type |

## Ticket mapping

- One ticket per Avito chat per account: `ticket.preferences = { channel_id, avito: { user_id, chat_id,
  chat_type, item_id, item_url, item_title } }`. A closed ticket gets a new one on the next customer message,
  as with Telegram.
- Customer: a Zammad user per Avito user id (login `avito.<id>`), named from the chat's `users[].name`. Avito
  gives no phone or e-mail. Avito notes that user ids are hashed; whether they are stable across our accounts
  is unverified, so a buyer writing to two accounts may become two users.
- The item (listing) a chat is about goes into the ticket title and preferences.

## Getting replies out

- Text limit is 1000 characters per message: longer replies are split on paragraph, then sentence, then word
  boundaries, and sent as consecutive messages.
- Images: `uploadImages` then `messages/image`. Avito accepts no other files; an article with non-image
  attachments fails delivery with a clear message rather than dropping them silently.
- Delivery status, retries and the "unable to send" note follow Zammad's Telegram job.

## Tokens and errors

- `client_credentials`; a token lives 24 h. It is cached in the channel and refreshed five minutes before
  expiry, or once when Avito refuses it: 401, or 403 with `{"result": {"message": "invalid access token"}}`
  (that is what the live API answered on 2026-10-20). Any other 403 is reported without a retry.
- `/token` answers HTTP 200 with `{"error": ...}` on failure, so success is judged by `access_token` in the
  body, never by the status.
- 402 means the account has no Messenger API subscription ("Максимальный" for goods and jobs, "Расширенный"
  or "Максимальный" for services). It is surfaced as such, not as a generic error.
- 429 carries a retry delay; the job backs off instead of retrying immediately.

## To verify against the live API

These are not settled by the documentation and need a subscribed account:

1. Does the webhook deliver own messages (`author_id == user_id`)?
2. Is the id returned by `send` the same id the webhook and the message list report?
3. In what order does the chat list come back (by `updated`, descending)?
4. How are array query parameters (`chat_types`, `voice_ids`) encoded: repeated keys or comma-separated?
5. Are buyer ids stable across two of our accounts?
6. The webhook sender's user agent and source addresses (for firewalls and fail2ban rules on the way in).
