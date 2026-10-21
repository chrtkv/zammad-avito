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
  ticket_title: title template, {listing} — {buyer} when empty
  ticket_tag:   tag for new tickets (the account's name in Latin letters), none when off
preferences:
  last_fetch, avito_cursor (the latest chat change handled, see below)
  avito_webhook_at: when Avito last delivered to the webhook (saved at most once a minute)
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
   checks the token and the account and enqueues a job; parsing and ticket work happen in the job. A `{}`
   probe gets a plain 200 (Avito's documentation mentions one; none came on subscribing, see below).
2. **Reconciliation poll** via `Channel::Driver::Avito#fetch`, every few minutes per account: list chats,
   take those whose last message is newer than the stored cursor, read each of them back to the cursor
   (less a few minutes of clock slack) and import whatever is missing. A message already imported is no
   reason to stop reading: the webhook may have brought the newest one and missed older ones. Only own
   messages younger than a minute wait for the next poll (so the echo of a reply Zammad is sending is
   recognised), and the cursor stops short of them. This covers lost webhooks, downtime and own messages,
   and does the initial backfill when an account is connected.

API limits shape the poll: `limit` is at most 100 and `offset` at most 1000 for both chats and messages, so
only the latest ~1100 of each are reachable.

The admin page can also act on an account outside the schedule:

- **Check connection** asks for a new token, the account, the latest chat and one of its messages, and the
  webhook subscriptions Avito holds (five requests, nothing changed), and says which failed: refused keys,
  no subscription (402 on the list), chats listed but their messages refused (402 on the messages: the
  subscription does not cover the listing's category), rate limit, network, or keys that now open another
  account. With no chat yet it says that reading messages was not checked; a chat of another category can
  still be refused.
- **Sync now** queues one poll (`AvitoSyncJob`, `Channel#fetch(true)`) whatever the poll interval.
- **Load history** imports the chats of N past days for an account already connected (`backfill_days`
  applies to the first poll only). It walks the chat list down from the newest change and reads each chat
  back to the start date, page by page. A job (`AvitoHistoryJob`) makes 10 requests, every one through the
  transport counted (plus the file of the one message it was importing when the budget ran out), and stops
  where that leaves it, between chats or inside a chat's history; the next job goes on from there, in a chat
  by its id. It waits 3 s per request the last job made: about 20 requests a minute and no burst above
  ~10, far below the hundred in a few minutes that set off Avito's throttling. (Batches of 20 whole chats
  made 141 requests in a row on a deep history.) No worker is held between jobs. A chat that gets a message
  during the walk jumps to the top, past it, so a last sweep reads the chats changed since the load began. The ~1100 limit applies: older chats and
  messages cannot be reached. A history message older than what its chat's tickets already hold is filed
  in the chat's ticket as it is, without reopening it or starting a new one; a newer one is a missed
  message and counts as usual. The poll's cursor is left alone. Each load is a row of `avito_history_loads`
  (its place in the walk, its counts, its outcome), kept as the account's record of its loads; the jobs
  carry only its id. Not the channel's preferences, which a running poll writes back as it read them, and
  not Rails' cache, where it lived first: the Docker image's `zammad-init` clears that on every start, and a
  deploy lost the result of a finished load. A unique partial index allows one running load per account,
  even against two starts at once. A running load that has not moved for 30 minutes is closed ("no
  progress"), and another may start. The page shows the latest load and polls it every 10 s while it runs.

## Message types

| Avito type | Article |
|---|---|
| `text` | body |
| `image` | attachment (largest size), body empty or caption |
| `voice` | attachment via `getVoiceFiles` |
| `item`, `link`, `location` | rendered as text (title, URL, price / address) |
| `call` (missed) | short text "missed call" |
| `system` | internal note (Avito's own notices, bots) by the "Avito" user; a note, not an `avito message`: Zammad shows an article from System of any other type as a one-line `"subject" -> "to"` record and hides its text |
| `deleted` | internal note on the ticket; the original article stays |
| `file`, `video`, `appCall` | Avito sends no content: a placeholder text naming the type |

## Ticket mapping

- A chat's tickets are found through its recorded messages, not through the customer, so a corrected
  customer or a merge keeps the chat on its ticket. A merged ticket can therefore hold several chats, while
  its preferences name only its own first one; replies are routed per reply (see below). "Closed" is a state of type closed, merged or removed,
  whatever its name.
- One ticket per Avito chat per account: `ticket.preferences = { channel_id, avito: { user_id, chat_id,
  chat_type, item_id, item_url, item_title } }`. A closed ticket gets a new one on the next customer message,
  as with Telegram.
- Customer: a Zammad user per Avito user id (login `avito.<id>`), named from the chat's `users[].name`. Avito
  gives no phone or e-mail. Avito notes that user ids are hashed; whether they are stable across our accounts
  is unverified, so a buyer writing to two accounts may become two users.
- The item (listing) a chat is about goes into the ticket preferences, and into the title through the account's
  template: `{listing}`, `{buyer}`, `{account}`, by default `{listing} — {buyer}`, so chats about one listing are
  told apart in the ticket list. An account can also tag its new tickets with its name in Latin letters.
- The reply form knows a ticket from Avito by its chat (`preferences.avito.chat_id`), not by its first article's
  type: a chat can open with Avito's notice, an internal note.
- Avito's own notices are created by one user "Avito" (login `avito.system`, with Avito's mark as avatar), neither the shop nor
  Zammad.
- Messages written in Avito itself are created by a service user of the account (login
  `avito.account.<user_id>`, named after the shop), not by Zammad's system user, so they show with
  the shop's Avito avatar. Customers get the avatar of their Avito profile when they are created.

## Getting replies out

- Both are active users without a password or an e-mail: nobody can sign in as them, and Zammad shows their
  avatars, which it greys out almost to nothing for inactive users.
- Text limit is 1000 characters per message: longer replies are split on paragraph, then sentence, then word
  boundaries, and sent as consecutive messages.
- Images: `uploadImages` then `messages/image`. Avito accepts no other files: the reply form refuses a
  non-image attachment before the reply is saved, and delivery refuses one too (an article from the API or
  another interface) with a clear message rather than dropping it silently.
- A reply that fails after some of its messages went out says so: "Sent 2 of 3 messages; …", in the
  delivery status and in the "unable to send" note.
- A reply goes to the chat its first attempt went to (a retry finishes where its first pieces are), else to
  the chat of the message it answers (`in_reply_to`, set by the "reply" action), else to the ticket's one
  chat. A ticket holding several chats (merged) and a reply naming none is not sent: the agent is asked to
  use "reply" on a message of the right chat. Taking the ticket's preferences answered one buyer in another
  buyer's chat.
- Delivery status and the "unable to send" note follow Zammad's Telegram job. Retries of the delivery, the
  webhook import and the history load go through `AvitoChannel::JobRetry`: one counter (ActiveJob's
  executions), four runs in all, each after the delay Avito names in a 429 or a growing one otherwise;
  giving up writes one note and raises nothing. A 402 (the chat is not covered) fails at once. (ActiveJob's
  `retry_on` beside a hand-made 429 retry sent a rate-limited reply seven times with four notes.)
- A piece marked attempted but without an Avito id is first looked for among the chat's latest messages
  written at or after the attempt before it is sent again: a text by its text, an image by an address of the
  image Zammad uploaded for it (an image's upload is saved before `messages/image`, and dropped when Avito
  refuses that with a 4xx; a 5xx keeps it, since a failing gateway does not say the message was not taken). An image that may have gone out (its send got no answer) and is not found
  stops the delivery with a request to look in Avito: sending it again could show it twice, and taking any
  own image for it confirmed a manager's picture as the reply.
- The message record, its article and the link between them are written in one transaction, so an import
  cut short leaves nothing behind that would block the next one.
- An account's keys cannot be swapped for another account's: tickets, records and the webhook belong to it.
  Changing the webhook address unsubscribes the old one and subscribes the new one.

## Tokens and errors

- `client_credentials`; a token lives 24 h. It is cached in the channel and refreshed five minutes before
  expiry, or once when Avito refuses it: 401, or 403 with `{"result": {"message": "invalid access token"}}`
  (that is what the live API answered on 2026-10-20). Any other 403 is reported without a retry.
- `/token` answers HTTP 200 with `{"error": ...}` on failure, so success is judged by `access_token` in the
  body, never by the status.
- 402 means the account has no Messenger API subscription ("Максимальный" for goods and jobs, "Расширенный"
  or "Максимальный" for services). It is surfaced as such, not as a generic error.
- 429 carries a retry delay; the job backs off instead of retrying immediately.

## Checked against the live API

On 2026-10-20, with the Messenger API subscription paid:

- **The subscription covers chats by the listing's category.** On "Расширенный" one chat still answered 402
  with the "subscribe" message; once "Максимальный" was paid, every chat read answered 200. That matches
  Avito's documentation: goods and jobs need "Максимальный", services "Расширенный" or higher. An account on
  a lower tariff can therefore have chats the API lists but will not open. The chat list carries each chat's
  latest message in full, so for a chat that answers 402 the poll imports that message, tags the ticket
  `avito-api-unavailable` and leaves one internal note to read the chat and reply in Avito. The tag goes
  once the chat answers again.
- **List parameters are comma-separated.** `chat_types=u2i,u2u` returns both kinds; repeated keys return
  `u2i` alone.
- **The chat list is sorted by `last_message.created`, newest first.** `updated` also moves on reads and is
  out of that order, so the poll's cursor is the last message's time.
- **An invalid token gets 403** `{"result": {"message": "invalid access token"}}`, not 401.
- **Avito drops new connections from a busy address.** Later the same day connects from our server took
  15 s every other time (the first SYNs dropped) while the rest went through in 0.03 s. The transport keeps
  one connection open per job and poll instead of opening one per request, waits up to 20 s for a connect,
  and opens a timed-out connection once more (nothing was sent on it, so even a POST is safe to repeat).
  A 30-minute watch from the server with our own traffic stopped (one request a minute) showed connects of
  22–34 s for the first 15 minutes, then 0.03 s every time for the remaining 17: the throttling wears off by
  itself and was most likely set off by our own testing (a poll every minute, a new connection per request,
  plus retries). Hence the default poll of 5 minutes and one connection per poll.
- **Bursts get throttled.** After about a hundred requests in a few minutes from one address, connections to
  `api.avito.ru` from that address took over 20 s for a while (another address was unaffected). The poll
  reads only chats with new messages, so it stays far below that.

- **A sent message keeps its id.** The id `send` returns is the id the message list reports for it: after
  replies from a local Zammad on 2026-10-20 the poll read the chat and imported nothing twice. Messages a
  manager wrote in Avito's interface came in through the poll as replies of the account's service user.

## Checked through the webhook

On 2026-10-21, with the channel on a public address and the webhook subscribed:

- **The webhook delivers own messages.** A reply sent from Zammad came back through the webhook within a
  second, and so did the customer's answer two minutes later.
- **The id `send` returns is the id the webhook reports.** The echo of that reply was recognised by its id and
  not imported a second time.
- **The sender:** user agent `Go-http-client/1.1`, from 176.114.121.96 and 176.114.125.105 (that day). The user
  agent is a library's: a fail2ban rule against HTTP libraries on the way in must leave the webhook's path alone.
- **No probe on subscribe.** Avito sent nothing when the webhook was subscribed; the first delivery came with the
  first message.

## Still to verify against the live API

1. Are buyer ids stable across two of our accounts?
2. Do the chats the subscription does not cover reach the webhook at all?
3. Does an image message carry the addresses `uploadImages` gave for that image? Delivery and the echo
   check rely on it to recognise an image whose send answer was lost; if not, such an image always ends in
   the "look in Avito" failure instead of being found.
