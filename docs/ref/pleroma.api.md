# Pleroma API — digestible reference (for building a Fediverse client on Inferno)

> **Provenance.** This file is *generated*, not hand-written. It is distilled from
> the live OpenAPI 3.0 document a Pleroma server publishes at **`GET /api/openapi`**
> — the same spec Pleroma builds from its source via `open_api_spex`, so it is the
> authoritative surface, **complete with the admin API, chats, and emoji-pack
> management** (the parts the hosted web docs split up and truncate).
>
> - **Source instance:** `nicecrew.digital` — `Pleroma 2.10.2-develop` (vanilla
>   Pleroma `develop`, not Akkoma/other forks).
> - **Captured:** 2026-06-11. 274 operations across 54 tag groups, 114 schemas.
> - **Raw machine-readable spec:** [`pleroma.openapi.json`](pleroma.openapi.json)
>   sits next to this file. **That JSON is the source of truth** — this Markdown is
>   the human/agent-readable index. When in doubt, query the JSON (recipes below).
> - **Upstream prose docs** (less complete, but with extra narrative):
>   <https://docs-develop.pleroma.social/backend/development/API/pleroma_api/>

## Querying the raw spec

The companion JSON is pretty-printed and greppable. Useful `jq`:

```sh
cd docs/ref
# Every endpoint, one per line, grouped nowhere — just method + path:
jq -r '.paths|to_entries[] as $p|$p.value|to_entries[]|"\(.key|ascii_upcase) \($p.key)"' pleroma.openapi.json
# Full detail for one endpoint:
jq '.paths["/api/v1/pleroma/chats/{id}/messages"]' pleroma.openapi.json
# An entity's fields:
jq '.components.schemas.Status.properties' pleroma.openapi.json
# Everything tagged "Chats":
jq -r '.paths|to_entries[] as $p|$p.value|to_entries[]|select(.value.tags[]?=="Chats")|"\(.key|ascii_upcase) \($p.key)"' pleroma.openapi.json
```

## Orientation — what you're building against

- **It's the Mastodon client API + Pleroma extensions.** The bulk of the surface
  (`/api/v1/statuses`, `/api/v1/timelines/*`, `/api/v1/accounts/*`,
  `/api/v1/notifications`, …) is Mastodon-compatible. Pleroma-only additions live
  mostly under **`/api/v1/pleroma/*`** and **`/api/pleroma/*`** (chats, emoji
  reactions, bookmark folders, backups, scrobbles, conversations, etc.). A client
  written to the Mastodon API mostly "just works"; the `pleroma/*` routes are the
  value-add.
- **One host = one instance.** There is no central server; the base URL is whatever
  instance the user logs into (`https://<instance>`). All paths below are relative
  to that origin. `servers: []` in the spec means exactly this.
- **IDs are `FlakeID`s.** Pleroma uses 128-bit ids rendered as lexically-sortable
  **strings** (e.g. `"9tKi3esbG7OQgZ2920"`), not Mastodon's 64-bit ints. Always
  treat ids as opaque strings.
- **Auth is OAuth 2.** The flow:
  1. `POST /api/v1/apps` (register a client → `client_id`/`client_secret`). No auth.
  2. Send the user to `GET /oauth/authorize` (or use the `password` grant for a
     personal client) → obtain a code.
  3. `POST /oauth/token` → bearer access token.
  4. Send `Authorization: Bearer <token>` on every authenticated call.
  Pleroma also accepts a `_pleroma_key` cookie and HTTP Basic, but OAuth is the
  path. **Scopes** are coarse (`read`, `write`, `follow`, `push`) and fine
  (`read:statuses`, `write:chats`, `write:security`, …); each endpoint below lists
  the scope it wants under **Auth**.
- **Pagination** is by `max_id` / `min_id` / `since_id` / `limit` (+ `offset` on
  some), and via RFC 5988 `Link:` response headers — read those headers, don't
  synthesize next-page URLs.
- **Errors** come back as `{"error": "<message>"}` (schema `ApiError`) with a 4xx
  status. Some validation failures use 422.
- **Streaming** (live timelines/notifications) is a **WebSocket** at
  `/api/v1/streaming` plus a `Streaming` Mastodon-API surface — out of scope for a
  first polling client; poll the timeline endpoints instead.
- **Admin endpoints** (`/api/v1/admin/*`, `/api/pleroma/admin/*`,
  `/api/v1/pleroma/emoji/pack*`) always require an admin/moderator token with the
  relevant `admin:read:*` / `admin:write:*` scope. A couple of them
  (e.g. `POST /api/v1/admin/accounts/{id}/approve`) are under-annotated upstream and
  show **Auth: public** below — that is a gap in Pleroma's own spec, not a real
  public route; still send an admin token.
- **Entity caveat.** The generated `Account` entity below is the full account
  object returned across the API; the spec labels its description "Account view for
  admins" because that view is a superset (it adds `is_active`, `is_confirmed`,
  `roles`). The dedicated admin-only shape is `Admin::Account` in the JSON.

## Building blocks already in this tree (Inferno side)

You do **not** need new C for an HTTP/JSON client — the pieces exist:

- **JSON:** [`module/json.m`](../../module/json.m) → `/dis/lib/json.dis`. `JValue`
  is a `pick` adt (`Object`/`Array`/`String`/`Int`/`Real`/`True`/`False`/`Null`);
  parse with `readjson(iobuf)`, navigate with `jv.get("key")` and the `is*`
  predicates, emit with `writejson`. This is your response parser.
- **TLS:** instances are HTTPS-only. Use `Dial->dialtls(addr, nil, servername)`
  (or `pushtls` over an existing fd) from [`module/dial.m`](../../module/dial.m);
  it rides the in-tree mbedTLS `#T` devtls device. See `docs/ON_NETWORK.md`
  § "Modern TLS".
- **URLs:** [`appl/lib/url.b`](../../appl/lib/url.b) for parsing; Charon's
  [`appl/charon/http.b`](../../appl/charon/http.b) is a worked HTTP/1.1 client
  (chunked, gzip, redirects) to crib request/response framing from.
- **Charon** (`docs/ON_CHARON.md`) already does cookies (RFC 6265) and HTTPS end to
  end — a reasonable reference for the transport layer.

---

The rest of this file is generated from the spec: **entity schemas first** (what
you parse), then **endpoints grouped by tag** (what you call). Each endpoint lists
its method, path, required OAuth scope, parameters, request body, and the response
status codes. For exact response *bodies*, look up the entity here or in the JSON.

# Entities

These are the objects you parse out of responses (key ones; the full set of 114 is
in the JSON under `.components.schemas`). Field types reference other entities by
name; `[]` means an array.

### Account
Account view for admins
- `acct` (string)
- `avatar` (string)
- `avatar_description` (string)
- `avatar_static` (string)
- `bot` (boolean)
- `created_at` (string)
- `display_name` (string)
- `emojis` (Emoji[])
- `fields` (AccountField[])
- `follow_requests_count` (integer)
- `followers_count` (integer)
- `following_count` (integer)
- `header` (string)
- `header_description` (string)
- `header_static` (string)
- `id` (FlakeID)
- `is_active` (boolean)
- `is_confirmed` (boolean)
- `local` (boolean)
- `locked` (boolean)
- `nickname` (string)
- `note` (string)
- `pleroma` (object)
- `roles` (object)
- `source` (object)
- `statuses_count` (integer)
- `url` (string)
- `username` (string)

### Status
Response schema for a status
- `account` (Account) — The account that authored this status
- `application` (object) — The application used to post this status
- `bookmarked` (boolean) — Have you bookmarked this status?
- `card` (object) — Preview card for links included within status content
- `content` (string) — HTML-encoded status content
- `created_at` (string) — The date when this status was created
- `edited_at` (string) — The date when this status was last edited
- `emojis` (Emoji[]) — Custom emoji to be used when rendering status content
- `favourited` (boolean) — Have you favourited this status?
- `favourites_count` (integer) — How many favourites this status has received
- `id` (FlakeID)
- `in_reply_to_account_id` (FlakeID) — ID of the account being replied to
- `in_reply_to_id` (FlakeID) — ID of the status being replied
- `language` (string) — Primary language of this status
- `media_attachments` (Attachment[]) — Media that is attached to this status
- `mentions` (object[]) — Mentions of users within the status content
- `muted` (boolean) — Have you muted notifications for this status's conversation?
- `pinned` (boolean) — Have you pinned this status? Only appears if the status is pinnable.
- `pleroma` (object)
- `poll` (Poll) — The poll attached to the status
- `quotes_count` (integer) — How many statuses quoted this status.
- `reblog` (Status) — The status being reblogged
- `reblogged` (boolean) — Have you boosted this status?
- `reblogs_count` (integer) — How many boosts this status has received
- `replies_count` (integer) — How many replies this status has received
- `sensitive` (boolean) — Is this status marked as sensitive content?
- `spoiler_text` (string) — Subject or summary line, below which status content is collapsed until expanded
- `tags` (Tag[])
- `text` (string) — Original unformatted content in plain text
- `uri` (string) — URI of the status used for federation
- `url` (string) — A link to the status's HTML representation
- `visibility` (VisibilityScope) — Visibility of this status

### Notification
Response schema for a notification
- `account` (Account) — The account that performed the action that generated the notification.
- `created_at` (string)
- `group_key` (string) — Group key shared by similar notifications
- `id` (string)
- `pleroma` (object)
- `status` (Status) — Status that was the object of the notification, e.g. in mentions, reblogs, favourites, or polls.
- `type` (string) — The type of event that resulted in the notification. - `follow` - Someone followed you - `mention` - Someone mentioned you in their status - `reblog` - Someo...

### Chat
Response schema for a Chat
- `account` (object)
- `id` (string)
- `last_message` (ChatMessage)
- `pinned` (boolean)
- `unread` (integer)
- `updated_at` (string)

### ChatMessage
Response schema for a ChatMessage
- `account_id` (string) — The Mastodon API id of the actor
- `attachment` (object)
- `card` (object) — Preview card for links included within status content
- `chat_id` (string)
- `content` (string)
- `created_at` (string)
- `emojis` (Emoji[])
- `id` (string)
- `unread` (boolean) — Whether a message has been marked as read.

### Conversation
Represents a conversation with "direct message" visibility.
- `accounts` (Account[]) — Participants in the conversation
- `id` (string)
- `last_status` (Status) — The last status in the conversation, to be used for optional display
- `unread` (boolean) — Is the conversation currently marked as unread?

### Attachment
Represents a file or media attachment that can be added to a status.
- `description` (string) — Alternate text that describes what is in the media attachment, to be used for the visually impaired or when media attachments do not load
- `id` (string) — The ID of the attachment in the database.
- `pleroma` (object)
- `preview_url` (string) — The location of a scaled-down preview of the attachment
- `remote_url` (string) — The location of the full-size original attachment on the remote website. String (URL), or null if the attachment is local
- `text_url` (string) — A shorter URL for the attachment
- `type` (string) — The type of the attachment
- `url` (string) — The location of the original full-size attachment

### Poll
Represents a poll attached to a status
- `emojis` (Emoji[]) — Custom emoji to be used for rendering poll options.
- `expired` (boolean) — Is the poll currently expired?
- `expires_at` (string) — When the poll ends
- `id` (FlakeID)
- `multiple` (boolean) — Does the poll allow multiple-choice answers?
- `options` (object[]) — Possible answers for the poll.
- `pleroma` (object)
- `voted` (boolean) — When called with a user token, has the authorized user voted? Boolean, or null if no current user.
- `voters_count` (integer) — How many unique accounts have voted. Number.
- `votes_count` (integer) — How many votes have been received. Number.

### Emoji
Response schema for an emoji
- `shortcode` (string)
- `static_url` (string)
- `url` (string)
- `visible_in_picker` (boolean)

### ScheduledStatus
Represents a status that will be published at a future scheduled date.
- `id` (string)
- `media_attachments` (Attachment[])
- `params` (object)
- `scheduled_at` (string)

### List
Represents a list of users
- `exclusive` (boolean) — Whether members of the list should be removed from the “Home” feed
- `id` (string) — The internal database ID of the list
- `title` (string) — The user-defined title of the list

### Marker
Schema for a marker
- `last_read_id` (string)
- `pleroma` (object)
- `updated_at` (string)
- `version` (integer)

### Filter
- `context` (string[]) — The contexts in which the filter should be applied.
- `expires_at` (string) — When the filter should no longer be applied. String (ISO 8601 Datetime), or null if the filter does not expire.
- `id` (string)
- `irreversible` (boolean) — Should matching entities in home and notifications be dropped by the server?
- `phrase` (string) — The text to be filtered
- `whole_word` (boolean) — Should the filter consider word boundaries?

### Tag
Represents a hashtag used within the content of a status
- `following` (boolean) — Whether the authenticated user is following the hashtag
- `history` (string[]) — A list of historical uses of the hashtag (not implemented, for compatibility only)
- `name` (string) — The value of the hashtag after the # sign
- `url` (string) — A link to the hashtag on the instance

### ApiError
Response schema for API error
- `error` (string)

# Endpoints (by tag)

## Account actions


### `POST /api/v1/accounts/{id}/pin`
Endorse
- **Auth:** OAuth scope `follow`, `write:accounts`
- **Params:**
    - `id` (path, required, string) — Account ID or nickname
- **Returns:** 200, 400

### `POST /api/v1/accounts/{id}/mute`
Mute
- **Auth:** OAuth scope `follow`, `write:mutes`
- **Params:**
    - `id` (path, required, string) — Account ID or nickname
    - `notifications` (query, BooleanLike) — Mute notifications in addition to statuses? Defaults to `true`.
- **Body:**
    - `duration` (integer) — Expire the mute in `expires_in` seconds. Default 0 for infinity
    - `expires_in` (integer) — Deprecated, use `duration` instead
    - `notifications` (BooleanLike) — Mute notifications in addition to statuses? Defaults to true.
- **Returns:** 200

### `POST /api/v1/pleroma/accounts/{id}/subscribe`  *(deprecated)*
Subscribe
- **Auth:** OAuth scope `follow`, `write:follows`
- **Params:**
    - `id` (path, required, string) — Account ID
- **Returns:** 200, 404

### `POST /api/v1/accounts/{id}/note`
Set a private note about a user.
- **Auth:** OAuth scope `follow`, `write:accounts`
- **Params:**
    - `id` (path, required, string) — Account ID or nickname
    - `comment` (query, string) — Account note body
- **Body:**
    - `comment` (string) — Account note body
- **Returns:** 200

### `POST /api/v1/accounts/{id}/unpin`
Unendorse
- **Auth:** OAuth scope `follow`, `write:accounts`
- **Params:**
    - `id` (path, required, string) — Account ID or nickname
- **Returns:** 200

### `POST /api/v1/accounts/{id}/remove_from_followers`
Remove from followers
- **Auth:** OAuth scope `follow`, `write:follows`
- **Params:**
    - `id` (path, required, string) — Account ID or nickname
- **Returns:** 200, 400, 404

### `POST /api/v1/accounts/{id}/block`
Block
- **Auth:** OAuth scope `follow`, `write:blocks`
- **Params:**
    - `id` (path, required, string) — Account ID or nickname
- **Body:**
    - `duration` (integer) — Expire the mute in `duration` seconds. Default 0 for infinity
- **Returns:** 200

### `POST /api/v1/accounts/{id}/unblock`
Unblock
- **Auth:** OAuth scope `follow`, `write:blocks`
- **Params:**
    - `id` (path, required, string) — Account ID or nickname
- **Returns:** 200

### `POST /api/v1/accounts/{id}/unendorse`
Unendorse
- **Auth:** OAuth scope `follow`, `write:accounts`
- **Params:**
    - `id` (path, required, string) — Account ID or nickname
- **Returns:** 200

### `POST /api/v1/accounts/{id}/unmute`
Unmute
- **Auth:** OAuth scope `follow`, `write:mutes`
- **Params:**
    - `id` (path, required, string) — Account ID or nickname
- **Returns:** 200

### `POST /api/v1/accounts/{id}/unfollow`
Unfollow
- **Auth:** OAuth scope `follow`, `write:follows`
- **Params:**
    - `id` (path, required, string) — Account ID or nickname
- **Returns:** 200, 400, 404

### `POST /api/v1/pleroma/accounts/{id}/unsubscribe`  *(deprecated)*
Unsubscribe
- **Auth:** OAuth scope `follow`, `write:follows`
- **Params:**
    - `id` (path, required, string) — Account ID
- **Returns:** 200, 404

### `POST /api/v1/accounts/{id}/follow`
Follow
- **Auth:** OAuth scope `follow`, `write:follows`
- **Params:**
    - `id` (path, required, string) — Account ID or nickname
- **Body:**
    - `notify` (BooleanLike) — Receive notifications for all statuses posted by the account? Defaults to false.
    - `reblogs` (BooleanLike) — Receive this account's reblogs in home timeline? Defaults to true.
- **Returns:** 200, 400, 404

### `POST /api/v1/follows`
Follow by URI
- **Auth:** OAuth scope `follow`, `write:follows`
- **Body:**
    - `uri` (string), required
- **Returns:** 200, 400, 404

### `POST /api/v1/accounts/{id}/endorse`
Endorse
- **Auth:** OAuth scope `follow`, `write:accounts`
- **Params:**
    - `id` (path, required, string) — Account ID or nickname
- **Returns:** 200, 400

## Account credentials


### `POST /api/pleroma/change_email`
Change account email
- **Auth:** OAuth scope `write:accounts`
- **Body:**
    - `email` (string), required — New email. Set to blank to remove the user's email.
    - `password` (string), required — Current password
- **Returns:** 200, 400, 403

### `GET /api/v1/accounts/verify_credentials`
Verify account credentials
- **Auth:** OAuth scope `read:accounts`
- **Returns:** 200

### `POST /api/pleroma/move_account`
Move account
- **Auth:** OAuth scope `write:accounts`
- **Body:**
    - `password` (string), required — Current password
    - `target_account` (string), required — The nickname of the target account to move to
- **Returns:** 200, 400, 403, 404

### `DELETE /api/pleroma/aliases`
Delete an alias from this account
- **Auth:** OAuth scope `write:accounts`
- **Body:**
    - `alias` (string), required — The nickname of the account to delete from aliases
- **Returns:** 200, 400, 403, 404

### `GET /api/pleroma/aliases`
List account aliases
- **Auth:** OAuth scope `read:accounts`
- **Returns:** 200, 400, 403

### `PUT /api/pleroma/aliases`
Add an alias to this account
- **Auth:** OAuth scope `write:accounts`
- **Body:**
    - `alias` (string), required — The nickname of the account to add to aliases
- **Returns:** 200, 400, 403, 404

### `PATCH /api/v1/accounts/update_credentials`
Update account credentials
- **Auth:** OAuth scope `write:accounts`
- **Body:**
    - `accepts_chat_messages` (BooleanLike) — Whether the user accepts receiving chat messages.
    - `actor_type` (ActorType)
    - `allow_following_move` (BooleanLike) — Allows automatically follow moved following accounts
    - `also_known_as` (string[]) — List of alternate ActivityPub IDs
    - `avatar` (string) — Avatar image encoded using multipart/form-data
    - `avatar_description` (string) — Avatar image description.
    - `birthday` (object) — User's birthday
    - `bot` (BooleanLike) — Whether the account has a bot flag.
    - `default_scope` (VisibilityScope)
    - `discoverable` (BooleanLike) — Discovery (listing, indexing) of this account by external services (search bots etc.) is allowed.
    - `display_name` (string) — The display name to use for the profile.
    - `fields_attributes` (object)
    - `header` (string) — Header image encoded using multipart/form-data
    - `header_description` (string) — Header image description.
    - `hide_favorites` (BooleanLike) — user's favorites timeline will be hidden
    - `hide_followers` (BooleanLike) — user's followers will be hidden
    - `hide_followers_count` (BooleanLike) — user's follower count will be hidden
    - `hide_follows` (BooleanLike) — user's follows will be hidden
    - `hide_follows_count` (BooleanLike) — user's follow count will be hidden
    - `locked` (BooleanLike) — Whether manual approval of follow requests is required.
    - `no_rich_text` (BooleanLike) — html tags are stripped from all statuses requested from the API
    - `note` (string) — The account bio.
    - `pleroma_background_image` (string) — Sets the background image of the user.
    - `pleroma_settings_store` (object) — Opaque user settings to be saved on the backend.
    - `show_birthday` (BooleanLike) — User's birthday will be visible
    - `show_role` (BooleanLike) — user's role (e.g admin, moderator) will be exposed to anyone in the API
    - `skip_thread_containment` (BooleanLike) — Skip filtering out broken threads
- **Returns:** 200, 403, 413

### `POST /api/pleroma/disable_account`
Disable Account
- **Auth:** OAuth scope `write:accounts`
- **Params:**
    - `password` (query, string) — Password
- **Returns:** 200, 403

### `POST /api/v1/accounts`
Register an account
- **Auth:** public
- **Body:**
    - `agreement` (BooleanLike), required — Whether the user agrees to the local rules, terms, and policies. These should be presented to the user in order to allow them to consent before setting this parameter to TRUE.
    - `bio` (string) — Bio
    - `birthday` (object) — User's birthday
    - `captcha_answer_data` (string) — Provider-specific captcha data
    - `captcha_solution` (string) — Provider-specific captcha solution
    - `captcha_token` (string) — Provider-specific captcha token
    - `email` (string) — The email address to be used for login. Required when `account_activation_required` is enabled.
    - `fullname` (string) — Full name
    - `language` (string) — User's preferred language for emails
    - `locale` (string) — The language of the confirmation email that will be sent
    - `password` (string), required — The password to be used for login
    - `reason` (string) — Text that will be reviewed by moderators if registrations require manual approval
    - `token` (string) — Invite token required when the registrations aren't public
    - `username` (string), required — The desired username for the account
- **Returns:** 200, 400, 403, 429

### `POST /api/pleroma/delete_account`
Delete Account
- **Auth:** OAuth scope `write:accounts`
- **Params:**
    - `password` (query, string) — Password
- **Body:**
    - `password` (string) — The user's own password for confirmation.
- **Returns:** 200, 403

### `POST /api/pleroma/change_password`
Change account password
- **Auth:** OAuth scope `write:accounts`
- **Body:**
    - `new_password` (string), required — New password
    - `new_password_confirmation` (string), required — New password, confirmation
    - `password` (string), required — Current password
- **Returns:** 200, 400, 403

### `POST /api/v1/pleroma/accounts/confirmation_resend`
Resend confirmation email
- **Auth:** public
- **Params:**
    - `email` (query, string) — Email of that needs to be verified
    - `nickname` (query, string) — Nickname of user that needs to be verified
- **Returns:** 204

## Announcement management


### `DELETE /api/v1/pleroma/admin/announcements/{id}`
Delete one announcement
- **Auth:** OAuth scope `admin:write`
- **Params:**
    - `id` (path, required, string) — announcement id
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Returns:** 200, 403, 404

### `GET /api/v1/pleroma/admin/announcements/{id}`
Display one announcement
- **Auth:** OAuth scope `admin:read`
- **Params:**
    - `id` (path, required, string) — announcement id
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Returns:** 200, 403, 404

### `PATCH /api/v1/pleroma/admin/announcements/{id}`
Change one announcement
- **Auth:** OAuth scope `admin:write`
- **Params:**
    - `id` (path, required, string) — announcement id
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Body:**
    - `all_day` (boolean)
    - `content` (string)
    - `ends_at` (string)
    - `starts_at` (string)
- **Returns:** 200, 400, 403, 404

### `GET /api/v1/pleroma/admin/announcements`
Retrieve a list of announcements
- **Auth:** OAuth scope `admin:read`
- **Params:**
    - `limit` (query, integer) — the maximum number of announcements to return
    - `offset` (query, integer) — the offset of the first announcement to return
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Returns:** 200, 400, 403

### `POST /api/v1/pleroma/admin/announcements`
Create one announcement
- **Auth:** OAuth scope `admin:write`
- **Body:**
    - `all_day` (boolean)
    - `content` (string), required
    - `ends_at` (string)
    - `starts_at` (string)
- **Returns:** 200, 400, 403

## Announcements


### `POST /api/v1/announcements/{id}/dismiss`
Mark one announcement as read
- **Auth:** OAuth scope `write:accounts`
- **Params:**
    - `id` (path, required, string) — announcement id
- **Returns:** 200, 403, 404

### `GET /api/v1/announcements`
Retrieve a list of announcements
- **Auth:** OAuth
- **Returns:** 200, 403

## Applications


### `GET /api/v1/pleroma/apps`
List applications
- **Auth:** public
- **Returns:** 200

### `POST /api/v1/apps`
Create an application
- **Auth:** public
- **Body:**
    - `client_name` (string), required — A name for your application.
    - `redirect_uris` (object), required — Where the user should be redirected after authorization. To display the authorization code to the user instead of redirecting to a web page, use `urn:ietf:wg:oauth:2.0:oob` in this parameter.
    - `scopes` (string) — Space separated list of scopes
    - `website` (string) — A URL to the homepage of your app
- **Returns:** 200, 422

### `GET /api/v1/apps/verify_credentials`
Verify the application works
- **Auth:** OAuth scope `read`
- **Returns:** 200, 422

## Backups


### `GET /api/v1/pleroma/backups`
List backups
- **Auth:** OAuth scope `read:backups`
- **Returns:** 200, 400

### `POST /api/v1/pleroma/backups`
Create a backup
- **Auth:** OAuth scope `read:backups`
- **Returns:** 200, 400

## Blocks and mutes


### `GET /api/v1/mutes`
Retrieve list of mutes
- **Auth:** OAuth scope `follow`, `read:mutes`
- **Params:**
    - `with_relationships` (query, object) — Embed relationships into accounts. **If this parameter is not set account's `pleroma.relationship` is going to be `null`.**
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200

### `GET /api/v1/blocks`
Retrieve list of blocks
- **Auth:** OAuth scope `read:blocks`
- **Params:**
    - `with_relationships` (query, object) — Embed relationships into accounts. **If this parameter is not set account's `pleroma.relationship` is going to be `null`.**
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200

## Bookmark folders


### `GET /api/v1/pleroma/bookmark_folders`
All bookmark folders
- **Auth:** OAuth scope `read:bookmarks`
- **Returns:** 200

### `POST /api/v1/pleroma/bookmark_folders`
Create a bookmark folder
- **Auth:** OAuth scope `write:bookmarks`
- **Body:**
    - `emoji` (string) — Folder emoji
    - `name` (string) — Folder name
- **Returns:** 200, 422

### `DELETE /api/v1/pleroma/bookmark_folders/{id}`
Delete a bookmark folder
- **Auth:** OAuth scope `write:bookmarks`
- **Params:**
    - `id` (path, required, string) — Bookmark Folder ID
- **Returns:** 200, 403, 404

### `PATCH /api/v1/pleroma/bookmark_folders/{id}`
Update a bookmark folder
- **Auth:** OAuth scope `write:bookmarks`
- **Params:**
    - `id` (path, required, string) — Bookmark Folder ID
- **Body:**
    - `emoji` (string) — Folder emoji
    - `name` (string) — Folder name
- **Returns:** 200, 403, 404, 422

## Chat administration


### `GET /api/v1/pleroma/admin/chats/{id}/messages`
Get chat's messages
- **Auth:** OAuth scope `admin:read:chats`
- **Params:**
    - `id` (path, required, string) — The ID of the Chat
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200

### `DELETE /api/v1/pleroma/admin/chats/{id}/messages/{message_id}`
Delete an individual chat message
- **Auth:** OAuth scope `admin:write:chats`
- **Params:**
    - `id` (path, required, string) — The ID of the Chat
    - `message_id` (path, required, string) — The ID of the message
- **Returns:** 200

### `GET /api/v1/pleroma/admin/chats/{id}`
Create a chat
- **Auth:** OAuth scope `admin:read`
- **Params:**
    - `id` (path, required, string) — The id of the chat
- **Returns:** 200

## Chats


### `GET /api/v1/pleroma/chats/{id}/messages`
Retrieve chat's messages
- **Auth:** OAuth scope `read:chats`
- **Params:**
    - `id` (path, required, string) — The ID of the Chat
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200, 404

### `POST /api/v1/pleroma/chats/{id}/messages`
Post a message to the chat
- **Auth:** OAuth scope `write:chats`
- **Params:**
    - `id` (path, required, string) — The ID of the Chat
- **Body:**
    - `content` (string) — The content of your message. Optional if media_id is present
    - `media_id` (string) — The id of an upload
- **Returns:** 200, 400, 422

### `POST /api/v1/pleroma/chats/{id}/pin`
Pin a chat
- **Auth:** OAuth scope `write:chats`
- **Params:**
    - `id` (path, required, string) — The id of the chat
- **Returns:** 200

### `POST /api/v1/pleroma/chats/{id}/messages/{message_id}/read`
Mark a message as read
- **Auth:** OAuth scope `write:chats`
- **Params:**
    - `id` (path, required, string) — The ID of the Chat
    - `message_id` (path, required, string) — The ID of the message
- **Returns:** 200

### `GET /api/v1/pleroma/chats`  *(deprecated)*
Retrieve list of chats (unpaginated)
- **Auth:** OAuth scope `read:chats`
- **Params:**
    - `with_muted` (query, object) — Include chats from muted users
    - `pinned` (query, object) — Include only pinned chats
- **Returns:** 200

### `POST /api/v1/pleroma/chats/{id}/read`
Mark all messages in the chat as read
- **Auth:** OAuth scope `write:chats`
- **Params:**
    - `id` (path, required, string) — The ID of the Chat
- **Body:**
    - `last_read_id` (string), required — The content of your message.
- **Returns:** 200

### `POST /api/v1/pleroma/chats/{id}/unpin`
Unpin a chat
- **Auth:** OAuth scope `write:chats`
- **Params:**
    - `id` (path, required, string) — The id of the chat
- **Returns:** 200

### `GET /api/v2/pleroma/chats`
Retrieve list of chats
- **Auth:** OAuth scope `read:chats`
- **Params:**
    - `with_muted` (query, object) — Include chats from muted users
    - `pinned` (query, object) — Include only pinned chats
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200

### `DELETE /api/v1/pleroma/chats/{id}/messages/{message_id}`
Delete message
- **Auth:** OAuth scope `write:chats`
- **Params:**
    - `id` (path, required, string) — The ID of the Chat
    - `message_id` (path, required, string) — The ID of the message
- **Returns:** 200

### `POST /api/v1/pleroma/chats/by-account-id/{id}`
Create a chat
- **Auth:** OAuth scope `write:chats`
- **Params:**
    - `id` (path, required, string) — The account id of the recipient of this chat
- **Returns:** 200

### `GET /api/v1/pleroma/chats/{id}`
Retrieve a chat
- **Auth:** OAuth scope `read`
- **Params:**
    - `id` (path, required, string) — The id of the chat
- **Returns:** 200

## Conversations


### `DELETE /api/v1/conversations/{id}`
Remove conversation
- **Auth:** OAuth scope `write:conversations`
- **Params:**
    - `id` (path, required, string) — Conversation ID
- **Returns:** 200

### `POST /api/v1/pleroma/conversations/read`
Marks all conversations as read
- **Auth:** OAuth scope `write:conversations`
- **Returns:** 200

### `GET /api/v1/conversations`
List of conversations
- **Auth:** OAuth scope `read:statuses`
- **Params:**
    - `recipients` (query, FlakeID[]) — Only return conversations with the given recipients (a list of user ids)
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200

### `POST /api/v1/conversations/{id}/read`
Mark conversation as read
- **Auth:** OAuth scope `write:conversations`
- **Params:**
    - `id` (path, required, string) — Conversation ID
- **Returns:** 200

### `GET /api/v1/pleroma/conversations/{id}/statuses`
Timeline for conversation
- **Auth:** OAuth scope `read:statuses`
- **Params:**
    - `id` (path, required, string) — Conversation ID
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200

### `GET /api/v1/pleroma/conversations/{id}`
Conversation
- **Auth:** OAuth scope `read:statuses`
- **Params:**
    - `id` (path, required, string) — Conversation ID
- **Returns:** 200

### `PATCH /api/v1/pleroma/conversations/{id}`
Update conversation
- **Auth:** OAuth scope `write:conversations`
- **Params:**
    - `id` (path, required, string) — Conversation ID
    - `recipients` (query, required, FlakeID[]) — A list of ids of users that should receive posts to this conversation. This will replace the current list of recipients, so submit the full list. The owner of owner of the conversation will always ...
- **Returns:** 200

## Custom emojis


### `GET /api/v1/pleroma/emoji`
List all custom emojis
- **Auth:** public
- **Returns:** 200

### `GET /api/v1/custom_emojis`
Retrieve a list of custom emojis
- **Auth:** public
- **Returns:** 200

## Data import


### `POST /api/pleroma/follow_import`
Import follows
- **Auth:** OAuth scope `write:follow`
- **Body:**
    - `list` (object), required — STRING or FILE containing a whitespace-separated list of accounts to import.
- **Returns:** 200, 403, 500

### `POST /api/pleroma/mutes_import`
Import mutes
- **Auth:** OAuth scope `write:mutes`
- **Body:**
    - `list` (object), required — STRING or FILE containing a whitespace-separated list of accounts to import.
- **Returns:** 200, 500

### `POST /api/pleroma/blocks_import`
Import blocks
- **Auth:** OAuth scope `write:blocks`
- **Body:**
    - `list` (object), required — STRING or FILE containing a whitespace-separated list of accounts to import.
- **Returns:** 200, 500

## Domain blocks


### `DELETE /api/v1/domain_blocks`
Unblock a domain
- **Auth:** OAuth scope `follow`, `write:blocks`
- **Params:**
    - `domain` (query, string) — Domain name
- **Body:**
    - `domain` (string)
- **Returns:** 200

### `GET /api/v1/domain_blocks`
Retrieve a list of blocked domains
- **Auth:** OAuth scope `follow`, `read:blocks`
- **Returns:** 200

### `POST /api/v1/domain_blocks`
Block a domain
- **Auth:** OAuth scope `follow`, `write:blocks`
- **Params:**
    - `domain` (query, string) — Domain name
- **Body:**
    - `domain` (string)
- **Returns:** 200

## Emoji pack administration


### `GET /api/v1/pleroma/emoji/packs/import`
Imports packs from filesystem
- **Auth:** OAuth scope `admin:write`
- **Returns:** 200

### `DELETE /api/v1/pleroma/emoji/packs/files`
Delete emoji file from pack
- **Auth:** OAuth scope `admin:write`
- **Params:**
    - `name` (query, required, string) — Pack Name
    - `shortcode` (query, required, string) — File shortcode
- **Returns:** 200, 400, 404, 422

### `PATCH /api/v1/pleroma/emoji/packs/files`
Add new file to the pack
- **Auth:** OAuth scope `admin:write`
- **Params:**
    - `name` (query, required, string) — Pack Name
- **Body:**
    - `force` (boolean) — With true value to overwrite existing emoji with new shortcode
    - `new_filename` (string), required — New filename for emoji file
    - `new_shortcode` (string), required — New emoji file shortcode
    - `shortcode` (string), required — Emoji file shortcode
- **Returns:** 200, 400, 404, 409, 422

### `POST /api/v1/pleroma/emoji/packs/files`
Add new file to the pack
- **Auth:** OAuth scope `admin:write`
- **Params:**
    - `name` (query, required, string) — Pack Name
- **Body:**
    - `file` (object), required — File needs to be uploaded with the multipart request or link to remote file
    - `filename` (string) — New emoji file name. If not specified will be taken from original filename.
    - `shortcode` (string) — Shortcode for new emoji, must be unique for all emoji. If not sended, shortcode will be taken from original filename.
- **Returns:** 200, 400, 404, 409, 422, 500

### `POST /api/v1/pleroma/emoji/packs/download`
Download pack from another instance
- **Auth:** OAuth scope `admin:write`
- **Body:**
    - `as` (string) — Save as
    - `name` (string), required — Pack Name
    - `url` (string), required — URL of the instance to download from
- **Returns:** 200, 500

### `POST /api/v1/pleroma/emoji/packs/download_zip`
Download a pack from a URL or an uploaded file
- **Auth:** OAuth scope `admin:write`
- **Body:**
    - `file` (object) — The uploaded ZIP file
    - `name` (string), required — Pack Name
    - `url` (string) — URL of the file
- **Returns:** 200, 400

### `GET /api/v1/pleroma/emoji/packs/remote`
Make request to another instance for emoji packs list
- **Auth:** OAuth scope `admin:write`
- **Params:**
    - `url` (query, required, string) — URL of the instance
    - `page` (query, integer) — Page
    - `page_size` (query, integer) — Number of emoji to return
- **Returns:** 200, 500

### `DELETE /api/v1/pleroma/emoji/pack`
Delete a custom emoji pack
- **Auth:** OAuth scope `admin:write`
- **Params:**
    - `name` (query, required, string) — Pack Name
- **Returns:** 200, 400, 404, 500

### `PATCH /api/v1/pleroma/emoji/pack`
Updates (replaces) pack metadata
- **Auth:** OAuth scope `admin:write`
- **Params:**
    - `name` (query, required, string) — Pack Name
- **Body:**
    - `metadata` (object) — Metadata to replace the old one
- **Returns:** 200, 400, 500

### `POST /api/v1/pleroma/emoji/pack`
Create an empty pack
- **Auth:** OAuth scope `admin:write`
- **Params:**
    - `name` (query, required, string) — Pack Name
- **Returns:** 200, 400, 409, 500

## Emoji packs


### `GET /api/v1/pleroma/emoji/packs/archive`
Requests a local pack archive from the instance
- **Auth:** public
- **Params:**
    - `name` (query, required, string) — Pack Name
- **Returns:** 200, 403, 404

### `GET /api/v1/pleroma/emoji/pack`
Show emoji pack
- **Auth:** public
- **Params:**
    - `name` (query, required, string) — Pack Name
    - `page` (query, integer) — Page
    - `page_size` (query, integer) — Number of emoji to return
- **Returns:** 200, 400, 404

### `GET /api/v1/pleroma/emoji/packs`
Lists local custom emoji packs
- **Auth:** public
- **Params:**
    - `page` (query, integer) — Page
    - `page_size` (query, integer) — Number of emoji packs to return
- **Returns:** 200

## Emoji reactions


### `DELETE /api/v1/pleroma/statuses/{id}/reactions/{emoji}`
Remove a reaction to a post with a unicode emoji
- **Auth:** OAuth scope `write:statuses`
- **Params:**
    - `id` (path, required, string) — Status ID
    - `emoji` (path, required, string) — A single character unicode emoji
- **Returns:** 200

### `GET /api/v1/pleroma/statuses/{id}/reactions/{emoji}`
Get an object of emoji to account mappings with accounts that reacted to the post
- **Auth:** OAuth scope `read:statuses`
- **Params:**
    - `id` (path, required, string) — Status ID
    - `emoji` (path, string) — Filter by a single unicode emoji
    - `with_muted` (query, boolean) — Include reactions from muted acccounts.
- **Returns:** 200, 404

### `PUT /api/v1/pleroma/statuses/{id}/reactions/{emoji}`
React to a post with a unicode emoji
- **Auth:** OAuth scope `write:statuses`
- **Params:**
    - `id` (path, required, string) — Status ID
    - `emoji` (path, required, string) — A single character unicode emoji
- **Returns:** 200, 400, 404

### `GET /api/v1/pleroma/statuses/{id}/reactions`
Get an object of emoji to account mappings with accounts that reacted to the post
- **Auth:** OAuth scope `read:statuses`
- **Params:**
    - `id` (path, required, string) — Status ID
    - `emoji` (path, string) — Filter by a single unicode emoji
    - `with_muted` (query, boolean) — Include reactions from muted acccounts.
- **Returns:** 200, 404

## Filters


### `DELETE /api/v1/filters/{id}`
Remove a filter
- **Auth:** OAuth scope `write:filters`
- **Params:**
    - `id` (path, required, string) — Filter ID
- **Returns:** 200, 403

### `GET /api/v1/filters/{id}`
Filter
- **Auth:** OAuth scope `read:filters`
- **Params:**
    - `id` (path, required, string) — Filter ID
- **Returns:** 200, 403, 404

### `PUT /api/v1/filters/{id}`
Update a filter
- **Auth:** OAuth scope `write:filters`
- **Params:**
    - `id` (path, required, string) — Filter ID
- **Body:**
    - `context` (string[]), required — Array of enumerable strings `home`, `notifications`, `public`, `thread`. At least one context must be specified.
    - `expires_in` (integer) — Number of seconds from now the filter should expire. Otherwise, null for a filter that doesn't expire.
    - `irreversible` (BooleanLike) — Should the server irreversibly drop matching entities from home and notifications?
    - `phrase` (string), required — The text to be filtered
    - `whole_word` (BooleanLike) — Consider word boundaries?
- **Returns:** 200, 403

### `GET /api/v1/filters`
All filters
- **Auth:** OAuth scope `read:filters`
- **Returns:** 200, 403

### `POST /api/v1/filters`
Create a filter
- **Auth:** OAuth scope `write:filters`
- **Returns:** 200, 403

## Follow requests


### `POST /api/v1/follow_requests/{id}/reject`
Reject follow request
- **Auth:** OAuth scope `follow`, `write:follows`
- **Params:**
    - `id` (path, required, string) — Conversation ID
- **Returns:** 200

### `GET /api/v1/follow_requests`
Retrieve follow requests
- **Auth:** OAuth scope `read:follows`, `follow`
- **Params:**
    - `max_id` (query, string) — Return items older than this ID
    - `since_id` (query, string) — Return the oldest items newer than this ID
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200

### `GET /api/v1/pleroma/outgoing_follow_requests`
Retrieve outgoing follow requests
- **Auth:** OAuth scope `read:follows`, `follow`
- **Params:**
    - `max_id` (query, string) — Return items older than this ID
    - `since_id` (query, string) — Return the oldest items newer than this ID
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200

### `POST /api/v1/follow_requests/{id}/authorize`
Accept follow request
- **Auth:** OAuth scope `follow`, `write:follows`
- **Params:**
    - `id` (path, required, string) — Conversation ID
- **Returns:** 200

## Frontend management


### `GET /api/v1/pleroma/admin/frontends`
Retrieve a list of available frontends
- **Auth:** OAuth scope `admin:read`
- **Returns:** 200, 403

### `POST /api/v1/pleroma/admin/frontends/install`
Install a frontend
- **Auth:** OAuth scope `admin:read`
- **Body:**
    - `build_dir` (string)
    - `build_url` (string)
    - `file` (string)
    - `name` (string), required
    - `ref` (string)
- **Returns:** 200, 400, 403

## Instance configuration


### `GET /api/v1/pleroma/admin/config/descriptions`
Retrieve config description
- **Auth:** OAuth scope `admin:read`
- **Params:**
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Returns:** 200, 400

### `GET /api/v1/pleroma/admin/config`
Retrieve instance configuration
- **Auth:** OAuth scope `admin:read`
- **Params:**
    - `only_db` (query, boolean) — Get only saved in database settings
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Returns:** 200, 400

### `POST /api/v1/pleroma/admin/config`
Update instance configuration
- **Auth:** OAuth scope `admin:write`
- **Params:**
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Body:**
    - `configs` (object[])
- **Returns:** 200, 400

## Instance documents


### `DELETE /api/v1/pleroma/admin/instance_document/{name}`
Delete an instance document
- **Auth:** OAuth scope `admin:write`
- **Params:**
    - `name` (path, required, string) — The document name
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Returns:** 200, 400, 403, 404

### `GET /api/v1/pleroma/admin/instance_document/{name}`
Retrieve an instance document
- **Auth:** OAuth scope `admin:read`
- **Params:**
    - `name` (path, required, string) — The document name
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Returns:** 200, 400, 403, 404

### `PATCH /api/v1/pleroma/admin/instance_document/{name}`
Update an instance document
- **Auth:** OAuth scope `admin:write`
- **Params:**
    - `name` (path, required, string) — The document name
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Body:**
    - `file` (string), required — The file to be uploaded, using multipart form data.
- **Returns:** 200, 400, 403, 404

## Instance misc


### `GET /api/v1/instance/domain_blocks`
Retrieve instance domain blocks
- **Auth:** public
- **Returns:** 200

### `GET /api/v1/instance/rules`
Retrieve list of instance rules
- **Auth:** public
- **Returns:** 200

### `GET /api/v1/instance`
Retrieve instance information
- **Auth:** public
- **Returns:** 200

### `GET /api/v1/instance/peers`
Retrieve list of known instances
- **Auth:** public
- **Returns:** 200

### `GET /api/v1/pleroma/federation_status`
Retrieve federation status
- **Auth:** public
- **Returns:** 200

### `GET /api/v1/instance/translation_languages`
Retrieve supported languages matrix
- **Auth:** public
- **Returns:** 200

### `GET /api/v2/instance`
Retrieve instance information
- **Auth:** public
- **Returns:** 200

## Instance rule management


### `DELETE /api/v1/pleroma/admin/rules/{id}`
Delete rule
- **Auth:** OAuth scope `admin:write`
- **Params:**
    - `id` (path, required, string) — Rule ID
- **Returns:** 200, 403, 404

### `PATCH /api/v1/pleroma/admin/rules/{id}`
Modify existing rule
- **Auth:** OAuth scope `admin:write`
- **Params:**
    - `id` (path, required, string) — Rule ID
- **Body:**
    - `hint` (string)
    - `priority` (integer)
    - `text` (string)
- **Returns:** 200, 400, 403

### `GET /api/v1/pleroma/admin/rules`
Retrieve list of instance rules
- **Auth:** OAuth scope `admin:read`
- **Returns:** 200, 403

### `POST /api/v1/pleroma/admin/rules`
Create new rule
- **Auth:** OAuth scope `admin:write`
- **Params:**
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Body:**
    - `hint` (string)
    - `priority` (integer)
    - `text` (string), required
- **Returns:** 200, 400, 403

## Invites


### `POST /api/v1/pleroma/admin/users/invite_token`
Create an account registration invite token
- **Auth:** OAuth scope `admin:write:invites`
- **Params:**
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Body:**
    - `expires_at` (string)
    - `max_use` (integer)
- **Returns:** 200

### `GET /api/v1/pleroma/admin/users/invites`
Get a list of generated invites
- **Auth:** OAuth scope `admin:read:invites`
- **Params:**
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Returns:** 200

### `POST /api/v1/pleroma/admin/users/email_invite`
Sends registration invite via email
- **Auth:** OAuth scope `admin:write:invites`
- **Params:**
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Body:**
    - `email` (string), required
    - `name` (string)
- **Returns:** 204, 400, 403

### `POST /api/v1/pleroma/admin/users/revoke_invite`
Revoke invite by token
- **Auth:** OAuth scope `admin:write:invites`
- **Params:**
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Body:**
    - `token` (string), required
- **Returns:** 200, 400, 404

## Lists


### `DELETE /api/v1/lists/{id}/accounts`
Remove accounts from list
- **Auth:** OAuth scope `write:lists`
- **Params:**
    - `id` (path, required, string) — List ID
    - `account_ids` (query, string[]) — Array of account IDs
- **Body:**
    - `account_ids` (FlakeID[]) — Array of account IDs
- **Returns:** 200

### `GET /api/v1/lists/{id}/accounts`
Retrieve accounts in list
- **Auth:** OAuth scope `read:lists`
- **Params:**
    - `id` (path, required, string) — List ID
- **Returns:** 200

### `POST /api/v1/lists/{id}/accounts`
Add accounts to list
- **Auth:** OAuth scope `write:lists`
- **Params:**
    - `id` (path, required, string) — List ID
- **Body:**
    - `account_ids` (FlakeID[]) — Array of account IDs
- **Returns:** 200

### `GET /api/v1/lists`
Retrieve a list of lists
- **Auth:** OAuth scope `read:lists`
- **Returns:** 200

### `POST /api/v1/lists`
Create a list
- **Auth:** OAuth scope `write:lists`
- **Body:**
    - `exclusive` (boolean) — Whether members of the list should be removed from the “Home” feed
    - `title` (string), required — List title
- **Returns:** 200, 400, 404

### `DELETE /api/v1/lists/{id}`
Delete a list
- **Auth:** OAuth scope `write:lists`
- **Params:**
    - `id` (path, required, string) — List ID
- **Returns:** 200

### `GET /api/v1/lists/{id}`
Retrieve a list
- **Auth:** OAuth scope `read:lists`
- **Params:**
    - `id` (path, required, string) — List ID
- **Returns:** 200, 404

### `PUT /api/v1/lists/{id}`
Update a list
- **Auth:** OAuth scope `write:lists`
- **Params:**
    - `id` (path, required, string) — List ID
- **Body:**
    - `exclusive` (boolean) — Whether members of the list should be removed from the “Home” feed
    - `title` (string) — List title
- **Returns:** 200, 422

## Markers


### `GET /api/v1/markers`
Get saved timeline position
- **Auth:** OAuth scope `read:statuses`
- **Params:**
    - `timeline` (query, string[]) — Array of markers to fetch. If not provided, an empty object will be returned.
- **Returns:** 200, 403

### `POST /api/v1/markers`
Save position in timeline
- **Auth:** OAuth scope `follow`, `write:blocks`
- **Body:**
    - `home` (object)
    - `notifications` (object)
- **Returns:** 200, 403

## Mascot


### `GET /api/v1/pleroma/mascot`
Retrieve mascot
- **Auth:** OAuth scope `read:accounts`
- **Returns:** 200

### `PUT /api/v1/pleroma/mascot`
Set or clear mascot
- **Auth:** OAuth scope `write:accounts`
- **Body:**
    - `file` (string)
- **Returns:** 200, 415

## Media attachments


### `POST /api/v1/media`
Upload media as attachment
- **Auth:** OAuth scope `write:media`
- **Body:**
    - `description` (string) — A plain-text description of the media, for accessibility purposes.
    - `file` (string), required — The file to be attached, using multipart form data.
    - `focus` (string) — Two floating points (x,y), comma-delimited, ranging from -1.0 to 1.0.
- **Returns:** 200, 400, 401, 422

### `POST /api/v2/media`
Upload media as attachment (v2)
- **Auth:** OAuth scope `write:media`
- **Body:**
    - `description` (string) — A plain-text description of the media, for accessibility purposes.
    - `file` (string), required — The file to be attached, using multipart form data.
    - `focus` (string) — Two floating points (x,y), comma-delimited, ranging from -1.0 to 1.0.
- **Returns:** 200, 400, 422, 500

### `GET /api/v1/media/{id}`
Attachment
- **Auth:** OAuth scope `read:media`
- **Params:**
    - `id` (path, required, string) — The ID of the Attachment entity
- **Returns:** 200, 401, 403, 422

### `PUT /api/v1/media/{id}`
Update attachment
- **Auth:** OAuth scope `write:media`
- **Params:**
    - `id` (path, required, string) — The ID of the Attachment entity
- **Body:**
    - `description` (string) — A plain-text description of the media, for accessibility purposes.
    - `file` (string) — The file to be attached, using multipart form data.
    - `focus` (string) — Two floating points (x,y), comma-delimited, ranging from -1.0 to 1.0.
- **Returns:** 200, 400, 401, 422

## MediaProxy cache


### `POST /api/v1/pleroma/admin/media_proxy_caches/delete`
Remove a banned MediaProxy URL
- **Auth:** OAuth scope `admin:write:media_proxy_caches`
- **Params:**
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Body:**
    - `urls` (string[]), required
- **Returns:** 200, 400

### `GET /api/v1/pleroma/admin/media_proxy_caches`
Retrieve a list of banned MediaProxy URLs
- **Auth:** OAuth scope `admin:read:media_proxy_caches`
- **Params:**
    - `query` (query, string) — Page
    - `page` (query, integer) — Page
    - `page_size` (query, integer) — Number of statuses to return
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Returns:** 200

### `POST /api/v1/pleroma/admin/media_proxy_caches/purge`
Purge a URL from MediaProxy cache and optionally ban it
- **Auth:** OAuth scope `admin:write:media_proxy_caches`
- **Params:**
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Body:**
    - `ban` (boolean)
    - `urls` (string[]), required
- **Returns:** 200, 400

## Notifications


### `GET /api/v1/notifications/{id}`
Retrieve a notification
- **Auth:** OAuth scope `read:notifications`
- **Params:**
    - `id` (path, required, string) — Notification ID
- **Returns:** 200

### `POST /api/v1/notifications/dismiss`  *(deprecated)*
Dismiss a single notification
- **Auth:** OAuth scope `write:notifications`
- **Body:**
    - `id` (string)
- **Returns:** 200

### `POST /api/v1/notifications/clear`
Dismiss all notifications
- **Auth:** OAuth scope `write:notifications`
- **Returns:** 200

### `GET /api/v1/notifications`
Retrieve a list of notifications
- **Auth:** OAuth scope `read:notifications`
- **Params:**
    - `exclude_types` (query, string[]) — Array of types to exclude
    - `account_id` (query, string) — Return only notifications received from this account
    - `exclude_visibilities` (query, VisibilityScope[]) — Exclude the notifications for activities with the given visibilities
    - `include_types` (query, string[]) — Deprecated, use `types` instead
    - `types` (query, string[]) — Include the notifications for activities with the given types
    - `with_muted` (query, object) — Include the notifications from muted users
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200, 404

### `POST /api/v1/pleroma/notifications/read`
Mark notifications as read
- **Auth:** OAuth scope `write:notifications`
- **Body:**
    - `id` (integer) — A single notification ID to read
    - `max_id` (integer) — Read all notifications up to this ID
- **Returns:** 200, 400

### `POST /api/v1/notifications/{id}/dismiss`
Dismiss a notification
- **Auth:** OAuth scope `write:notifications`
- **Params:**
    - `id` (path, required, string) — Notification ID
- **Returns:** 200

### `DELETE /api/v1/notifications/destroy_multiple`
Dismiss multiple notifications
- **Auth:** OAuth scope `write:notifications`
- **Params:**
    - `ids` (query, required, string[]) — Array of notification IDs to dismiss
- **Returns:** 200

## OAuth application management


### `GET /api/v1/pleroma/admin/oauth_app`
Retrieve a list of OAuth applications
- **Auth:** OAuth scope `admin:write`
- **Params:**
    - `name` (query, string) — App name
    - `client_id` (query, string) — Client ID
    - `page` (query, integer) — Page
    - `trusted` (query, boolean) — Trusted apps
    - `page_size` (query, integer) — Number of apps to return
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Returns:** 200

### `POST /api/v1/pleroma/admin/oauth_app`
Create an OAuth application
- **Auth:** OAuth scope `admin:write`
- **Params:**
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Body:**
    - `name` (string), required — Application Name
    - `redirect_uris` (object), required — Where the user should be redirected after authorization. To display the authorization code to the user instead of redirecting to a web page, use `urn:ietf:wg:oauth:2.0:oob` in this parameter.
    - `scopes` (string[]) — oAuth scopes
    - `trusted` (boolean) — Is the app trusted?
    - `website` (string) — A URL to the homepage of the app
- **Returns:** 200, 400

### `DELETE /api/v1/pleroma/admin/oauth_app/{id}`
Delete OAuth application
- **Auth:** OAuth scope `admin:write`
- **Params:**
    - `id` (path, required, integer) — App ID
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Returns:** 204, 400

### `PATCH /api/v1/pleroma/admin/oauth_app/{id}`
Update OAuth application
- **Auth:** OAuth scope `admin:write`
- **Params:**
    - `id` (path, required, integer) — App ID
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Body:**
    - `name` (string) — Application Name
    - `redirect_uris` (object) — Where the user should be redirected after authorization. To display the authorization code to the user instead of redirecting to a web page, use `urn:ietf:wg:oauth:2.0:oob` in this parameter.
    - `scopes` (string[]) — oAuth scopes
    - `trusted` (boolean) — Is the app trusted?
    - `website` (string) — A URL to the homepage of the app
- **Returns:** 200, 400

## Others


### `GET /api/v1/pleroma/healthcheck`
Quick status check on the instance
- **Auth:** OAuth scope `write:accounts`
- **Returns:** 200, 503

### `GET /api/v1/directory`
Profile directory
- **Auth:** public
- **Params:**
    - `order` (query, string) — Order by recent activity or account creation
    - `local` (query, object) — Include local users only
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200, 404

### `GET /api/v1/pleroma/captcha`
Get a captcha
- **Auth:** public
- **Returns:** 200

### `GET /api/pleroma/frontend_configurations`
Dump frontend configurations
- **Auth:** public
- **Returns:** 200

## Polls


### `GET /api/v1/polls/{id}`
View a poll
- **Auth:** OAuth scope `read:statuses`
- **Params:**
    - `id` (path, required, string) — Poll ID
- **Returns:** 200, 404

### `POST /api/v1/polls/{id}/votes`
Vote on a poll
- **Auth:** OAuth scope `write:statuses`
- **Params:**
    - `id` (path, required, string) — Poll ID
- **Body:**
    - `choices` (integer[]), required — Array of own votes containing index for each option (starting from 0)
- **Returns:** 200, 404, 422

## Preferred frontends


### `GET /api/v1/pleroma/preferred_frontend/available`
Frontend settings profiles
- **Auth:** public
- **Returns:** 200

### `PUT /api/v1/pleroma/preferred_frontend`
Update preferred frontend setting
- **Auth:** public
- **Body:**
    - `frontend_name` (string), required — Frontend name
- **Returns:** 200

## Push subscriptions


### `DELETE /api/v1/push/subscription`
Remove current subscription
- **Auth:** OAuth scope `push`
- **Returns:** 200, 403, 404

### `GET /api/v1/push/subscription`
Get current subscription
- **Auth:** OAuth scope `push`
- **Returns:** 200, 403, 404

### `POST /api/v1/push/subscription`
Subscribe to push notifications
- **Auth:** OAuth scope `push`
- **Body:**
    - `data` (object)
    - `subscription` (object), required
- **Returns:** 200, 400, 403

### `PUT /api/v1/push/subscription`
Change types of notifications
- **Auth:** OAuth scope `push`
- **Body:**
    - `data` (object)
- **Returns:** 200, 403

## Relays


### `DELETE /api/v1/pleroma/admin/relay`
Unfollow a relay
- **Auth:** OAuth scope `admin:write:follows`
- **Params:**
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Body:**
    - `force` (boolean)
    - `relay_url` (string)
- **Returns:** 200

### `GET /api/v1/pleroma/admin/relay`
Retrieve a list of relays
- **Auth:** OAuth scope `admin:read`
- **Params:**
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Returns:** 200

### `POST /api/v1/pleroma/admin/relay`
Follow a relay
- **Auth:** OAuth scope `admin:write:follows`
- **Params:**
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Body:**
    - `relay_url` (string)
- **Returns:** 200

## Remote interaction


### `POST /api/v1/pleroma/remote_interaction`
Remote interaction
- **Auth:** public
- **Body:**
    - `ap_id` (string), required — Profile or status ActivityPub ID
    - `profile` (string), required — Remote profile webfinger
- **Returns:** 200

### `GET /ostatus_subscribe`
Display follow form
- **Auth:** public
- **Returns:** 200, 302

### `POST /ostatus_subscribe`
Perform follow activity
- **Auth:** public
- **Returns:** 200, 302

### `GET /authorize_interaction`
Authorize remote interaction
- **Auth:** public
- **Returns:** 302

### `GET /main/ostatus`
Show remote subscribe form
- **Auth:** public
- **Returns:** 200

### `POST /main/ostatus`
Remote Subscribe
- **Auth:** public
- **Returns:** 200

## Report management


### `GET /api/v1/pleroma/admin/reports`
Retrieve a list of reports
- **Auth:** OAuth scope `admin:read:reports`
- **Params:**
    - `state` (query, string) — Filter by report state
    - `rule_id` (query, string) — Filter by selected rule id
    - `limit` (query, integer) — The number of records to retrieve
    - `page` (query, integer) — Page number
    - `page_size` (query, integer) — Number number of log entries per page
    - `assigned_account` (query, string) — Filter by assigned account ID
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Returns:** 200, 403

### `PATCH /api/v1/pleroma/admin/reports`
Change state of specified reports
- **Auth:** OAuth scope `admin:write:reports`
- **Params:**
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Body:**
    - `reports` (object[]), required
- **Returns:** 204, 400, 403

### `GET /api/v1/pleroma/admin/reports/{id}`
Retrieve a report
- **Auth:** OAuth scope `admin:read:reports`
- **Params:**
    - `id` (path, required, string) — Report ID
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Returns:** 200, 404

### `POST /api/v1/pleroma/admin/reports/{id}/notes`
Add a note to the report
- **Auth:** OAuth scope `admin:write:reports`
- **Params:**
    - `id` (path, required, string) — Report ID
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Body:**
    - `content` (string) — The message
- **Returns:** 204, 404

### `DELETE /api/v1/pleroma/admin/reports/{report_id}/notes/{id}`
Delete note attached to the report
- **Auth:** OAuth scope `admin:write:reports`
- **Params:**
    - `report_id` (path, required, string) — Report ID
    - `id` (path, required, string) — Note ID
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Returns:** 204, 404

### `POST /api/v1/pleroma/admin/reports/assign_account`
Assign account to specified reports
- **Auth:** OAuth scope `admin:write:reports`
- **Params:**
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Body:**
    - `reports` (object[]), required
- **Returns:** 204, 400, 403

## Report management (Mastodon API)


### `GET /api/v1/admin/reports`
View all reports
- **Auth:** OAuth scope `admin:read:reports`
- **Params:**
    - `resolved` (query, boolean) — Filter for resolved reports
    - `account_id` (query, string) — Filter by author account id
    - `target_account_id` (query, string) — Filter by report target account id (not implemented)
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200, 401

### `GET /api/v1/admin/reports/{id}`
View a single report
- **Auth:** OAuth scope `admin:read:reports`
- **Params:**
    - `id` (path, required, string) — ID of the report
- **Returns:** 200, 401, 404

### `POST /api/v1/admin/reports/{id}/resolve`
Mark as resolved
- **Auth:** OAuth scope `admin:write:reports`
- **Params:**
    - `id` (path, required, string) — ID of the report
- **Returns:** 200, 400, 401

### `POST /api/v1/admin/reports/{id}/reopen`
Re-open report
- **Auth:** OAuth scope `admin:write:reports`
- **Params:**
    - `id` (path, required, string) — ID of the report
- **Returns:** 200, 400, 401

## Reports


### `GET /api/v0/pleroma/reports/{id}`
Get an individual report
- **Auth:** OAuth scope `read:reports`
- **Params:**
    - `id` (path, required, string) — Report ID
- **Returns:** 200, 404

### `GET /api/v0/pleroma/reports`
Get a list of your own reports
- **Auth:** OAuth scope `read:reports`
- **Params:**
    - `state` (query, string) — Filter by report state
    - `limit` (query, integer) — The number of records to retrieve
    - `page` (query, integer) — Page number
    - `page_size` (query, integer) — Number number of log entries per page
- **Returns:** 200, 404

### `POST /api/v1/reports`
File a report
- **Auth:** OAuth scope `follow`, `write:reports`
- **Body:**
    - `account_id` (string), required — ID of the account to report
    - `comment` (string) — Reason for the report
    - `forward` (BooleanLike) — If the account is remote, should the report be forwarded to the remote admin?
    - `rule_ids` (string[]) — Array of rules
    - `status_ids` (string[]) — Array of Statuses to attach to the report, for context
- **Returns:** 200, 400, 404

## Retrieve account information


### `GET /api/v1/accounts/relationships`
Relationship with current account
- **Auth:** OAuth scope `read:follows`
- **Params:**
    - `id` (query, object) — Account IDs
- **Returns:** 200

### `GET /api/v1/pleroma/accounts/{id}/favourites`
Favorites
- **Auth:** OAuth scope `read:favourites`
- **Params:**
    - `id` (path, required, string) — Account ID
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200, 403, 404

### `GET /api/v1/accounts/lookup`
Find a user by nickname
- **Auth:** public
- **Params:**
    - `acct` (query, string) — User nickname
- **Returns:** 200, 401, 404

### `GET /api/v1/accounts/familiar_followers`
Followers that you follow
- **Auth:** OAuth scope `read:follows`
- **Params:**
    - `id` (query, object) — Account IDs
- **Returns:** 200

### `GET /api/v1/accounts/{id}/followers`
Followers
- **Auth:** OAuth scope `read:accounts`
- **Params:**
    - `id` (path, required, string) — Account ID or nickname
    - `id` (query, string) — ID of the resource owner
    - `with_relationships` (query, object) — Embed relationships into accounts. **If this parameter is not set account's `pleroma.relationship` is going to be `null`.**
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200

### `GET /api/v1/pleroma/accounts/{id}/endorsements`
Endorsements
- **Auth:** public
- **Params:**
    - `with_relationships` (query, object) — Embed relationships into accounts. **If this parameter is not set account's `pleroma.relationship` is going to be `null`.**
    - `id` (path, required, string) — Account ID or nickname
- **Returns:** 200, 404

### `GET /api/v1/endorsements`
Endorsements
- **Auth:** OAuth scope `read:accounts`
- **Returns:** 200

### `GET /api/v1/accounts/{id}`
Account
- **Auth:** public
- **Params:**
    - `id` (path, required, string) — Account ID or nickname
    - `with_relationships` (query, object) — Embed relationships into accounts. **If this parameter is not set account's `pleroma.relationship` is going to be `null`.**
- **Returns:** 200, 401, 404

### `GET /api/v1/accounts/{id}/statuses`
Statuses
- **Auth:** public
- **Params:**
    - `id` (path, required, string) — Account ID or nickname
    - `pinned` (query, object) — Include only pinned statuses
    - `tagged` (query, string) — With tag
    - `only_media` (query, object) — Include only statuses with media attached
    - `with_muted` (query, object) — Include statuses from muted accounts.
    - `exclude_reblogs` (query, object) — Exclude reblogs
    - `only_reblogs` (query, object) — Include only reblogs
    - `exclude_replies` (query, object) — Exclude replies
    - `exclude_visibilities` (query, VisibilityScope[]) — Exclude visibilities
    - `with_muted` (query, object) — Include reactions from muted accounts.
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200, 401, 404

### `GET /api/v1/accounts/{id}/endorsements`
Endorsements
- **Auth:** public
- **Params:**
    - `with_relationships` (query, object) — Embed relationships into accounts. **If this parameter is not set account's `pleroma.relationship` is going to be `null`.**
    - `id` (path, required, string) — Account ID or nickname
- **Returns:** 200, 404

### `GET /api/v1/accounts/{id}/lists`
Lists containing this account
- **Auth:** OAuth scope `read:lists`
- **Params:**
    - `id` (path, required, string) — Account ID or nickname
- **Returns:** 200

### `GET /api/v1/pleroma/birthdays`
Birthday reminders
- **Auth:** OAuth scope `read:accounts`
- **Params:**
    - `day` (query, integer) — Day of users' birthdays
    - `month` (query, integer) — Month of users' birthdays
- **Returns:** 200

### `GET /api/v1/accounts/{id}/following`
Following
- **Auth:** OAuth scope `read:accounts`
- **Params:**
    - `id` (path, required, string) — Account ID or nickname
    - `id` (query, string) — ID of the resource owner
    - `with_relationships` (query, object) — Embed relationships into accounts. **If this parameter is not set account's `pleroma.relationship` is going to be `null`.**
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200

## Retrieve status information


### `GET /api/v1/statuses/{id}/quotes`
Quoted by
- **Auth:** OAuth scope `read:statuses`
- **Params:**
    - `id` (path, required, string) — Status ID
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200, 403, 404

### `GET /api/v1/statuses/{id}/history`
Status history
- **Auth:** OAuth scope `read:statuses`
- **Params:**
    - `id` (path, required, string) — Status ID
- **Returns:** 200, 404

### `GET /api/v1/statuses/{id}/reblogged_by`
Reblogged by
- **Auth:** OAuth scope `read:accounts`
- **Params:**
    - `id` (path, required, string) — Status ID
- **Returns:** 200, 404

### `POST /api/v1/statuses/{id}/translate`
Translate status
- **Auth:** OAuth scope `read:statuses`
- **Params:**
    - `id` (path, required, string) — Status ID
- **Body:**
    - `lang` (string) — Translation target language.
- **Returns:** 200, 400, 404, 503

### `GET /api/v1/statuses`
Multiple statuses
- **Auth:** OAuth scope `read:statuses`
- **Params:**
    - `id` (query, FlakeID[]) — Array of status IDs
    - `ids` (query, FlakeID[]) — Deprecated, use `id` instead
    - `with_muted` (query, object) — Include reactions from muted acccounts.
- **Returns:** 200

### `GET /api/v1/statuses/{id}/favourited_by`
Favourited by
- **Auth:** OAuth scope `read:accounts`
- **Params:**
    - `id` (path, required, string) — Status ID
- **Returns:** 200, 404

### `GET /api/v1/statuses/{id}`
Status
- **Auth:** OAuth scope `read:statuses`
- **Params:**
    - `id` (path, required, string) — Status ID
    - `with_muted` (query, object) — Include reactions from muted acccounts.
- **Returns:** 200, 404

### `GET /api/v1/statuses/{id}/context`
Parent and child statuses
- **Auth:** OAuth scope `read:statuses`
- **Params:**
    - `id` (path, required, string) — Status ID
- **Returns:** 200

### `GET /api/v1/pleroma/statuses/{id}/quotes`  *(deprecated)*
Quoted by
- **Auth:** OAuth scope `read:statuses`
- **Params:**
    - `id` (path, required, string) — Status ID
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200, 403, 404

### `GET /api/v1/statuses/{id}/source`
Status source
- **Auth:** OAuth scope `read:statuses`
- **Params:**
    - `id` (path, required, string) — Status ID
- **Returns:** 200, 404

## Scheduled statuses


### `DELETE /api/v1/scheduled_statuses/{id}`
Cancel a scheduled status
- **Auth:** OAuth scope `write:statuses`
- **Params:**
    - `id` (path, required, string) — Poll ID
- **Returns:** 200, 404

### `GET /api/v1/scheduled_statuses/{id}`
View a single scheduled status
- **Auth:** OAuth scope `read:statuses`
- **Params:**
    - `id` (path, required, string) — Poll ID
- **Returns:** 200, 404

### `PUT /api/v1/scheduled_statuses/{id}`
Schedule a status
- **Auth:** OAuth scope `write:statuses`
- **Params:**
    - `id` (path, required, string) — Poll ID
- **Body:**
    - `scheduled_at` (string) — ISO 8601 Datetime at which the status will be published. Must be at least 5 minutes into the future.
- **Returns:** 200, 404

### `GET /api/v1/scheduled_statuses`
View scheduled statuses
- **Auth:** OAuth scope `read:statuses`
- **Params:**
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200

## Scrobbles


### `POST /api/v1/pleroma/scrobble`  *(deprecated)*
Creates a new Listen activity for an account
- **Auth:** OAuth scope `write:scrobbles`
- **Body:**
    - `album` (string) — The album of the media playing
    - `artist` (string) — The artist of the media playing
    - `externalLink` (string) — Deprecated, use `external_link` instead
    - `external_link` (string) — A URL referencing the media playing
    - `length` (integer) — The length of the media playing
    - `title` (string), required — The title of the media playing
    - `visibility` (VisibilityScope) — Scrobble visibility
- **Returns:** 200

### `GET /api/v1/pleroma/accounts/{id}/scrobbles`  *(deprecated)*
Requests a list of current and recent Listen activities for an account
- **Auth:** OAuth scope `read:scrobbles`
- **Params:**
    - `id` (path, required, string) — Account ID or nickname
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200

## Search


### `GET /api/v2/search`
Search results
- **Auth:** OAuth scope `read:search`
- **Params:**
    - `account_id` (query, string) — If provided, statuses returned will be authored only by this account
    - `type` (query, string) — Search type
    - `q` (query, required, string) — What to search for
    - `resolve` (query, BooleanLike) — Attempt WebFinger lookup
    - `following` (query, BooleanLike) — Only include accounts that the user is following
    - `with_relationships` (query, object) — Embed relationships into accounts. **If this parameter is not set account's `pleroma.relationship` is going to be `null`.**
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200

### `GET /api/v1/accounts/search`
Search for matching accounts by username or display name
- **Auth:** public
- **Params:**
    - `q` (query, required, string) — What to search for
    - `limit` (query, integer) — Maximum number of results
    - `resolve` (query, BooleanLike) — Attempt WebFinger lookup. Use this when `q` is an exact address.
    - `following` (query, BooleanLike) — Only include accounts that the user is following
    - `capabilities` (query, string[]) — Only include accounts with given capabilities
- **Returns:** 200

### `GET /api/v1/search`  *(deprecated)*
Search results
- **Auth:** OAuth scope `read:search`
- **Params:**
    - `account_id` (query, string) — If provided, statuses returned will be authored only by this account
    - `type` (query, string) — Search type
    - `q` (query, required, string) — The search query
    - `resolve` (query, BooleanLike) — Attempt WebFinger lookup
    - `following` (query, BooleanLike) — Only include accounts that the user is following
    - `offset` (query, integer) — Offset
    - `with_relationships` (query, object) — Embed relationships into accounts. **If this parameter is not set account's `pleroma.relationship` is going to be `null`.**
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200

## Settings


### `PUT /api/pleroma/notification_settings`
Update Notification Settings
- **Auth:** OAuth scope `write:accounts`
- **Params:**
    - `block_from_strangers` (query, object) — blocks notifications from accounts you do not follow
    - `hide_notification_contents` (query, object) — removes the contents of a message from the push notification
- **Returns:** 200, 400

### `GET /api/v1/pleroma/settings/{app}`
Get settings for an application
- **Auth:** OAuth scope `read:accounts`
- **Params:**
    - `app` (path, required, string) — Application name
- **Returns:** 200

### `PATCH /api/v1/pleroma/settings/{app}`
Update settings for an application
- **Auth:** OAuth scope `write:accounts`
- **Params:**
    - `app` (path, required, string) — Application name
- **Returns:** 200

## Status actions


### `POST /api/v1/statuses/{id}/unmute`
Unmute conversation
- **Auth:** OAuth scope `write:mutes`
- **Params:**
    - `id` (path, required, string) — Status ID
- **Returns:** 200, 400, 404

### `POST /api/v1/statuses/{id}/unreblog`
Undo reblog
- **Auth:** OAuth scope `write:statuses`
- **Params:**
    - `id` (path, required, string) — Status ID
- **Returns:** 200, 404

### `POST /api/v1/statuses/{id}/unpin`
Unpin from profile
- **Auth:** OAuth scope `write:accounts`
- **Params:**
    - `id` (path, required, string) — Status ID
- **Returns:** 200, 400, 404, 422

### `POST /api/v1/statuses/{id}/unbookmark`
Undo bookmark
- **Auth:** OAuth scope `write:bookmarks`
- **Params:**
    - `id` (path, required, string) — Status ID
- **Returns:** 200, 404

### `POST /api/v1/statuses`
Publish new status
- **Auth:** OAuth scope `write:statuses`
- **Body:**
    - `content_type` (string) — The MIME type of the status, it is transformed into HTML by the backend. You can get the list of the supported MIME types with the nodeinfo endpoint.
    - `expires_in` (integer) — The number of seconds the posted activity should expire in. When a posted activity expires it will be deleted from the server, and a delete request for it will be federated. This needs to be longer...
    - `in_reply_to_conversation_id` (string) — Will reply to a given conversation, addressing only the people who are part of the recipient set of that conversation. Sets the visibility to `direct`.
    - `in_reply_to_id` (FlakeID) — ID of the status being replied to, if status is a reply
    - `language` (string) — ISO 639 language code for this status.
    - `media_ids` (string[]) — Array of Attachment ids to be attached as media.
    - `poll` (object)
    - `preview` (BooleanLike) — If set to `true` the post won't be actually posted, but the status entity would still be rendered back. This could be useful for previewing rich text/custom emoji, for example
    - `quote_id` (FlakeID) — Deprecated in favor of `quoted_status_id`
    - `quoted_status_id` (FlakeID) — ID of the status being quoted, if any
    - `scheduled_at` (string) — ISO 8601 Datetime at which to schedule a status. Providing this parameter will cause ScheduledStatus to be returned instead of Status. Must be at least 5 minutes in the future.
    - `sensitive` (BooleanLike) — Mark status and attached media as sensitive?
    - `spoiler_text` (string) — Text to be shown as a warning or subject before the actual content. Statuses are generally collapsed behind this field.
    - `status` (string) — Text content of the status. If `media_ids` is provided, this becomes optional. Attaching a `poll` is optional while `status` is provided.
    - `to` (string[]) — A list of nicknames (like `lain@soykaf.club` or `lain` on the local server) that will be used to determine who is going to be addressed by this post. Using this will disable the implicit addressing...
    - `visibility` (object) — Visibility of the posted status. Besides standard MastoAPI values (`direct`, `private`, `unlisted` or `public`) it can be used to address a List by setting it to `list:LIST_ID`
- **Returns:** 200, 422

### `POST /api/v1/statuses/{id}/mute`
Mute conversation
- **Auth:** OAuth scope `write:mutes`
- **Params:**
    - `id` (path, required, string) — Status ID
    - `expires_in` (query, integer) — Expire the mute in `expires_in` seconds. Default 0 for infinity
- **Body:**
    - `expires_in` (integer) — Expire the mute in `expires_in` seconds. Default 0 for infinity
- **Returns:** 200, 400, 404

### `DELETE /api/v1/statuses/{id}`
Delete
- **Auth:** OAuth scope `write:statuses`
- **Params:**
    - `id` (path, required, string) — Status ID
- **Returns:** 200, 403, 404

### `PUT /api/v1/statuses/{id}`
Update status
- **Auth:** OAuth scope `write:statuses`
- **Params:**
    - `id` (path, required, string) — Status ID
- **Body:**
    - `content_type` (string) — The MIME type of the status, it is transformed into HTML by the backend. You can get the list of the supported MIME types with the nodeinfo endpoint.
    - `media_ids` (string[]) — Array of Attachment ids to be attached as media.
    - `poll` (object)
    - `sensitive` (BooleanLike) — Mark status and attached media as sensitive?
    - `spoiler_text` (string) — Text to be shown as a warning or subject before the actual content. Statuses are generally collapsed behind this field.
    - `status` (string) — Text content of the status. If `media_ids` is provided, this becomes optional. Attaching a `poll` is optional while `status` is provided.
    - `to` (string[]) — A list of nicknames (like `lain@soykaf.club` or `lain` on the local server) that will be used to determine who is going to be addressed by this post. Using this will disable the implicit addressing...
- **Returns:** 200, 403, 404

### `POST /api/v1/statuses/{id}/unfavourite`
Undo favourite
- **Auth:** OAuth scope `write:favourites`
- **Params:**
    - `id` (path, required, string) — Status ID
- **Returns:** 200, 400, 404

### `POST /api/v1/statuses/{id}/bookmark`
Bookmark
- **Auth:** OAuth scope `write:bookmarks`
- **Params:**
    - `id` (path, required, string) — Status ID
- **Body:**
    - `folder_id` (FlakeID) — ID of bookmarks folder, if any
- **Returns:** 200, 404

### `POST /api/v1/statuses/{id}/pin`
Pin to profile
- **Auth:** OAuth scope `write:accounts`
- **Params:**
    - `id` (path, required, string) — Status ID
- **Returns:** 200, 400, 404, 422

### `POST /api/v1/statuses/{id}/reblog`
Reblog
- **Auth:** OAuth scope `write:statuses`
- **Params:**
    - `id` (path, required, string) — Status ID
- **Body:**
    - `visibility` (VisibilityScope)
- **Returns:** 200, 404

### `POST /api/v1/statuses/{id}/favourite`
Favourite
- **Auth:** OAuth scope `write:favourites`
- **Params:**
    - `id` (path, required, string) — Status ID
- **Returns:** 200, 404

## Status administration


### `GET /api/v1/pleroma/admin/statuses`
Get all statuses
- **Auth:** OAuth scope `admin:read:statuses`
- **Params:**
    - `godmode` (query, boolean) — Allows to see private statuses
    - `local_only` (query, boolean) — Excludes remote statuses
    - `with_reblogs` (query, boolean) — Allows to see reblogs
    - `page` (query, integer) — Page
    - `page_size` (query, integer) — Number of statuses to return
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Returns:** 200

### `DELETE /api/v1/pleroma/admin/statuses/{id}`
Delete status
- **Auth:** OAuth scope `admin:write:statuses`
- **Params:**
    - `id` (path, required, string) — Status ID
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Returns:** 200, 404

### `GET /api/v1/pleroma/admin/statuses/{id}`
Get status
- **Auth:** OAuth scope `admin:read:statuses`
- **Params:**
    - `id` (path, required, string) — Status ID
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Returns:** 200, 404

### `PUT /api/v1/pleroma/admin/statuses/{id}`
Change the scope of a status
- **Auth:** OAuth scope `admin:write:statuses`
- **Params:**
    - `id` (path, required, string) — Status ID
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Body:**
    - `sensitive` (boolean) — Mark status and attached media as sensitive?
    - `visibility` (VisibilityScope)
- **Returns:** 200, 400

## Suggestions


### `GET /api/v1/suggestions`
Follow suggestions (Not implemented)
- **Auth:** public
- **Returns:** 200

### `DELETE /api/v1/suggestions/{account_id}`
Remove a suggestion
- **Auth:** public
- **Params:**
    - `account_id` (path, required, string) — Account to dismiss
- **Returns:** 200

### `GET /api/v2/suggestions`
Follow suggestions
- **Auth:** public
- **Returns:** 200

## Tags


### `POST /api/v1/tags/{id}/follow`
Follow a hashtag
- **Auth:** OAuth scope `write:follows`
- **Params:**
    - `id` (path, required, string) — Name of the hashtag
- **Returns:** 200, 404

### `GET /api/v1/followed_tags`
Followed hashtags
- **Auth:** OAuth scope `read:follows`
- **Params:**
    - `max_id` (query, integer) — Return items older than this ID
    - `min_id` (query, integer) — Return the oldest items newer than this ID
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200, 403, 404

### `GET /api/v1/tags/{id}`
Hashtag
- **Auth:** OAuth scope `read`
- **Params:**
    - `id` (path, required, string) — Name of the hashtag
- **Returns:** 200, 404

### `POST /api/v1/tags/{id}/unfollow`
Unfollow a hashtag
- **Auth:** OAuth scope `write:follows`
- **Params:**
    - `id` (path, required, string) — Name of the hashtag
- **Returns:** 200, 404

## Timelines


### `GET /api/v1/bookmarks`
Bookmarked statuses
- **Auth:** OAuth scope `read:bookmarks`
- **Params:**
    - `folder_id` (query, string) — If provided, only display bookmarks from given folder
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200

### `GET /api/v1/favourites`
Favourited statuses
- **Auth:** OAuth scope `read:favourites`
- **Params:**
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200

### `GET /api/v1/timelines/direct`
Direct timeline
- **Auth:** OAuth scope `read:statuses`
- **Params:**
    - `with_muted` (query, object) — Include activities by muted users
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200

### `GET /api/v1/streaming`
Establish streaming connection
- **Auth:** OAuth scope `read:statuses`, `read:notifications`
- **Params:**
    - `connection` (header, required, string) — connection header
    - `upgrade` (header, required, string) — upgrade header
    - `sec-websocket-key` (header, required, string) — sec-websocket-key header
    - `sec-websocket-version` (header, required, string) — sec-websocket-version header
    - `instance` (query, string) — Domain name of the instance. Required when `stream` is `public:remote` or `public:remote:media`.
    - `list` (query, string) — The id of the list. Required when `stream` is `list`.
    - `stream` (query, string) — The name of the stream.
    - `tag` (query, string) — The name of the hashtag. Required when `stream` is `hashtag`.
    - `access_token` (query, string) — An OAuth access token with corresponding permissions.
    - `sec-websocket-protocol` (header, string) — An OAuth access token with corresponding permissions.
- **Returns:** 101, 200

### `GET /api/v1/timelines/tag/{tag}`
Hashtag timeline
- **Auth:** OAuth scope `read:statuses`
- **Params:**
    - `tag` (path, required, string) — Content of a #hashtag, not including # symbol.
    - `any` (query, string[]) — Statuses that also includes any of these tags
    - `all` (query, string[]) — Statuses that also includes all of these tags
    - `none` (query, string[]) — Statuses that do not include these tags
    - `local` (query, BooleanLike) — Show only local statuses?
    - `only_media` (query, BooleanLike) — Show only statuses with media attached?
    - `remote` (query, BooleanLike) — Show only remote statuses?
    - `with_muted` (query, object) — Include activities by muted users
    - `exclude_visibilities` (query, VisibilityScope[]) — Exclude the statuses with the given visibilities
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200, 401

### `GET /api/v1/timelines/home`
Home timeline
- **Auth:** OAuth scope `read:statuses`
- **Params:**
    - `local` (query, BooleanLike) — Show only local statuses?
    - `remote` (query, BooleanLike) — Show only remote statuses?
    - `only_media` (query, BooleanLike) — Show only statuses with media attached?
    - `with_muted` (query, object) — Include activities by muted users
    - `exclude_visibilities` (query, VisibilityScope[]) — Exclude the statuses with the given visibilities
    - `reply_visibility` (query, string) — Filter replies. Possible values: without parameter (default) shows all replies, `following` - replies directed to you or users you follow, `self` - replies directed to you.
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200

### `GET /api/v1/timelines/public`
Public timeline
- **Auth:** OAuth scope `read:statuses`
- **Params:**
    - `local` (query, BooleanLike) — Show only local statuses?
    - `instance` (query, string) — Show only statuses from the given domain
    - `only_media` (query, BooleanLike) — Show only statuses with media attached?
    - `remote` (query, BooleanLike) — Show only remote statuses?
    - `with_muted` (query, object) — Include activities by muted users
    - `exclude_visibilities` (query, VisibilityScope[]) — Exclude the statuses with the given visibilities
    - `reply_visibility` (query, string) — Filter replies. Possible values: without parameter (default) shows all replies, `following` - replies directed to you or users you follow, `self` - replies directed to you.
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200, 401

### `GET /api/v1/timelines/list/{list_id}`
List timeline
- **Auth:** OAuth scope `read:lists`
- **Params:**
    - `list_id` (path, required, string) — Local ID of the list in the database
    - `with_muted` (query, object) — Include activities by muted users
    - `local` (query, BooleanLike) — Show only local statuses?
    - `remote` (query, BooleanLike) — Show only remote statuses?
    - `only_media` (query, BooleanLike) — Show only statuses with media attached?
    - `exclude_visibilities` (query, VisibilityScope[]) — Exclude the statuses with the given visibilities
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200

## User administration


### `PATCH /api/v1/pleroma/admin/users/deactivate`
Deactivates multiple users
- **Auth:** OAuth scope `admin:write:accounts`
- **Params:**
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Body:**
    - `nicknames` (string[])
- **Returns:** 200, 403

### `POST /api/v1/pleroma/admin/users/unfollow`
Unfollow
- **Auth:** OAuth scope `admin:write:follows`
- **Params:**
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Body:**
    - `followed` (string) — Followed nickname
    - `follower` (string) — Follower nickname
- **Returns:** 200, 403

### `PATCH /api/v1/pleroma/admin/users/{nickname}/toggle_activation`
Toggle user activation
- **Auth:** OAuth scope `admin:write:accounts`
- **Params:**
    - `nickname` (path, required, string) — User nickname
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Returns:** 200, 403

### `PATCH /api/v1/pleroma/admin/users/unsuggest`
Unsuggest multiple users
- **Auth:** OAuth scope `admin:write:accounts`
- **Params:**
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Body:**
    - `nicknames` (string[])
- **Returns:** 200, 403

### `PATCH /api/v1/pleroma/admin/users/approve`
Approve multiple users
- **Auth:** OAuth scope `admin:write:accounts`
- **Params:**
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Body:**
    - `nicknames` (string[])
- **Returns:** 200, 403

### `PATCH /api/v1/pleroma/admin/users/activate`
Activate multiple users
- **Auth:** OAuth scope `admin:write:accounts`
- **Params:**
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Body:**
    - `nicknames` (string[])
- **Returns:** 200, 403

### `DELETE /api/v1/pleroma/admin/users`
Removes a single or multiple users
- **Auth:** OAuth scope `admin:write:accounts`
- **Params:**
    - `nickname` (query, string) — User nickname
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Body:**
    - `nicknames` (string[])
- **Returns:** 200, 403

### `GET /api/v1/pleroma/admin/users`
List users
- **Auth:** OAuth scope `admin:read:accounts`
- **Params:**
    - `filters` (query, string) — Comma separated list of filters
    - `query` (query, string) — Search users query
    - `name` (query, string) — Search by display name
    - `email` (query, string) — Search by email
    - `page` (query, integer) — Page Number
    - `page_size` (query, integer) — Number of users to return per page
    - `actor_types` (query, ActorType[]) — Filter by actor type
    - `tags` (query, string[]) — Filter by tags
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Returns:** 200, 403

### `POST /api/v1/pleroma/admin/users`
Create a single or multiple users
- **Auth:** OAuth scope `admin:write:accounts`
- **Params:**
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Body:**
    - `users` (object[])
- **Returns:** 200, 403, 409

### `GET /api/v1/pleroma/admin/users/{nickname}`
Show user
- **Auth:** OAuth scope `admin:read:accounts`
- **Params:**
    - `nickname` (path, required, string) — User nickname or ID
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Returns:** 200, 403, 404

### `PATCH /api/v1/pleroma/admin/users/suggest`
Suggest multiple users
- **Auth:** OAuth scope `admin:write:accounts`
- **Params:**
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Body:**
    - `nicknames` (string[])
- **Returns:** 200, 403

### `POST /api/v1/pleroma/admin/users/follow`
Follow
- **Auth:** OAuth scope `admin:write:follows`
- **Params:**
    - `admin_token` (query, string) — Allows authorization via admin token.
- **Body:**
    - `followed` (string) — Followed nickname
    - `follower` (string) — Follower nickname
- **Returns:** 200, 403

## User administration (Mastodon API)


### `POST /api/v1/admin/accounts/{id}/action`
Perform an action against an account
- **Auth:** OAuth scope `admin:write:accounts`
- **Params:**
    - `id` (path, required, string) — ID of the account
- **Body:**
    - `report_id` (string) — ID of an associated report that caused this action to be taken
    - `type` (string)
- **Returns:** 204, 401

### `POST /api/v1/admin/accounts/{id}/enable`
Re-enable account
- **Auth:** OAuth scope `admin:write:accounts`
- **Params:**
    - `id` (path, required, string) — ID of the account
- **Returns:** 200, 401, 404

### `POST /api/v1/admin/accounts/{id}/reject`
Reject pending account
- **Auth:** public
- **Params:**
    - `id` (path, required, string) — ID of the account
- **Returns:** 200, 400, 401, 404

### `GET /api/v2/admin/accounts`
View accounts by criteria (v2)
- **Auth:** OAuth scope `admin:read:accounts`
- **Params:**
    - `origin` (query, string) — Filter for local or remote accounts
    - `status` (query, string) — Filter for active, pending, disabled, silenced or suspended accounts
    - `permissions` (query, string) — Filter for accounts with staff permissions (users that can manage reports). (not implemented yet)
    - `role_ids` (query, object) — Filter for users with these roles. (not implemented yet)
    - `invited_by` (query, string) — Lookup users invited by the account with this ID. (not implemented yet)
    - `username` (query, string) — Search for the given username
    - `display_name` (query, string) — Search for the given display name
    - `by_domain` (query, string) — Filter by the given domain
    - `email` (query, string) — Lookup a user with this email
    - `ip` (query, string) — Lookup users with this IP address (not implemented yet)
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200, 401

### `DELETE /api/v1/admin/accounts/{id}`
Delete a specific account
- **Auth:** OAuth scope `admin:write:accounts`
- **Params:**
    - `id` (path, required, string) — ID of the account
- **Returns:** 200, 401, 404

### `GET /api/v1/admin/accounts/{id}`
View a specific account
- **Auth:** OAuth scope `admin:read:accounts`
- **Params:**
    - `id` (path, required, string) — ID of the account
- **Returns:** 200, 401, 404

### `GET /api/v1/admin/accounts`
View accounts by criteria (v1)
- **Auth:** OAuth scope `admin:read:accounts`
- **Params:**
    - `local` (query, boolean) — Filter for local accounts?
    - `remote` (query, boolean) — Filter for remote accounts?
    - `active` (query, boolean) — Filter for currently active accounts??
    - `pending` (query, boolean) — Filter for currently pending accounts?
    - `disabled` (query, boolean) — Filter for currently disabled accounts?
    - `silenced` (query, boolean) — Filter for currently silenced accounts? (not implemented yet)
    - `suspended` (query, boolean) — Filter for currently suspended accounts? (not implemented yet)
    - `sensitized` (query, boolean) — Filter for accounts force-marked as sensitive? (not implemented yet)
    - `username` (query, string) — Search for the given username
    - `display_name` (query, string) — Search for the given display name
    - `by_domain` (query, string) — Filter by the given domain
    - `email` (query, string) — Lookup a user with this email
    - `ip` (query, string) — Lookup users with this IP address (not implemented yet)
    - `staff` (query, boolean) — Filter for staff accounts?
    - `max_id` (query, string) — Return items older than this ID
    - `min_id` (query, string) — Return the oldest items newer than this ID
    - `since_id` (query, string) — Return the newest items newer than this ID
    - `offset` (query, integer) — Return items past this number of items
    - `limit` (query, integer) — Maximum number of items to return. Will be ignored if it's more than 40
- **Returns:** 200, 401

### `POST /api/v1/admin/accounts/{id}/approve`
Approve pending account
- **Auth:** public
- **Params:**
    - `id` (path, required, string) — ID of the account
- **Returns:** 200, 401, 404
