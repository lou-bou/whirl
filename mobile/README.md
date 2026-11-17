# Whirl mobile

A Flutter app for Whirl, for personal use: built here, installed as an APK from GitHub Releases,
never published. It replaces the installed PWA on the phone; the website stays for desktop. It
talks to the same API as the web app (`server/index.js`). The deploy ignores this folder (Vite
only builds what `index.html` imports, ESLint skips `mobile/`, the root `npm ci` doesn't see it).

```
mobile/
  packages/kit/   shared core, copied from Tack (API client, Access token, storage, theme, widgets)
  whirl/          the Whirl app: data layer, sync, wheel, screens, tests
  whirl/tool/     the server recorder and the screenshot tool
  keys/           release signing key and its passwords (gitignored, back it up)
```

## How it works

- **Auth.** Every request carries the Cloudflare Access service token
  (`CF-Access-Client-Id` / `CF-Access-Client-Secret`). No cookies, no browser, no login
  redirects; redirects are never followed. If Access refuses the token the app says so instead
  of looking offline. The server address and token are typed in on the phone and kept in the
  Android Keystore. Nothing secret is in this repo or in the APK. The connection check uses
  `GET /api/data` (there is no health route).
- **The same device queue as the web app.** `src/offline.js` in Dart (`whirl/lib/data/`): every
  change (create, edit, status, delete) goes into a queue in SQLite and is laid over the server's
  data, so it shows at once. Changes are sent oldest first, one at a time. One leaves the queue
  only when the server confirms it, or refuses it for good (a 4xx: then it is dropped and a
  "Couldn't save …" strip explains why). No connection, a 5xx, Cloudflare's error page or a
  refused token stop the run and keep the rest for later. The data is fetched only after the
  queue went through, and saved in one transaction.
- **Edits keep their time.** Phones send `editedAt` (the moment of the edit, on the server's
  clock, learned from `serverTime`), and category changes as `addCategoryIds` /
  `removeCategoryIds`. The server keeps a time per field and per category link, so a change sent
  late (offline, or replayed after a lost answer) never undoes a newer one. Deleted ideas leave a
  marker, so a create sent again can't bring one back, and links to deleted categories are
  dropped instead of refusing the idea. The web app's requests count as made when they arrive.
- **Fast open.** Ideas, categories and the queue are loaded from SQLite before the first frame;
  the UI never waits for the network. Sync runs on open, on resume, when the network returns,
  just after an edit and every 30 s while the app is open.
- **Proof.** `whirl/tool/record_server.mjs` runs the real `server/index.js` and `pg` against a
  throwaway Postgres (PGlite) and records its answers to a scripted sequence (creates, replays,
  late and early edits, category links, refusals, deletes, creates after a delete) into
  `whirl/test/server_recording.json`. The Dart fake server must answer identically
  (`fake_server_test.dart`), and the sync and app tests run against it: two phones editing
  offline end up the same as each other and the server; a lost answer, a request that never
  left, a replay or the app killed mid-send never duplicates or loses an idea. The workflows
  re-record and stop if the server has moved on.

## What works offline

| Feature | Offline |
|---|---|
| Backlog, search, every filter, Board, idea screen, Wheel and spinning | Yes |
| Create, edit, change status (Board drag, Start building), delete, pick categories for an idea | Yes, sent later |
| Theme, spin vibration | Yes (stored on the phone, like the web app's theme) |
| Add, rename or delete a category | Needs the server: queued ideas can point at categories (as on the web) |
| First load on a new phone, changes from other devices | Needs the server |

"Saved on this device" marks only appear while the queue is held back (offline, token
refused), so cards don't flicker on every edit while online. The header says "Offline · changes
will sync" or "Saving N…".

## The wheel

Drawn with a `CustomPainter` (only the rotation changes per frame, so it holds the display's
refresh rate). The winner is still picked first, uniformly over the pool, and the wheel lands
inside one of its slices, clear of the edges. Tap it or press Spin for a wound-up spin of 5–7
turns over about 4 s; or fling it with a finger and it starts at the finger's speed and slows
down like friction. The pointer is a sprung clapper pushed aside by each slice edge, with a
haptic tick per slice (at most every 40 ms) and a heavier one on landing. Settings → Spin turns
the vibration off. With reduced motion the winner is highlighted at once.

## Cloudflare Access setup (once)

1. Zero Trust → **Access → Service Auth → Service Tokens**: reuse Nook's, Cairn's or Tack's
   token, or create one.
2. **Access → Applications** → the Whirl application (or the wildcard `*.boussaid.me` one) →
   **Policies** → a policy with action **Service Auth**, Include → **Service Token** → that
   token. An Allow policy does not accept service tokens.
3. In the app: `https://wheel.boussaid.me`, the client ID and the secret, then **Test and
   save**, or **Paste setup** after **Copy setup** in another app (change the address).

## Install and update

Releases are built by GitHub (`.github/workflows/mobile-release.yml`):

```sh
git tag mobile-v1.0.0 && git push origin mobile-v1.0.0
```

A few minutes later the signed APK is on the repo's Releases page. Open that page on the phone,
tap `whirl-1.0.0.apk`, and allow the browser to install apps the first time. Updates install
over the existing app and keep the saved connection and data.

The workflow needs two repository secrets (Settings → Secrets and variables → Actions), the same
values as the other apps' but set again on this repository: `MOBILE_KEYSTORE_BASE64`
(`base64 -w0 mobile/keys/release.jks`) and `MOBILE_KEYSTORE_PASSWORD` (the `storePassword`
value in `mobile/keys/key.properties`).

**The server must be deployed first.** The app relies on the server change that keeps newer
edits (`editedAt`, per-category changes, deletion markers). On the old server, category changes
made on the phone would be lost and late edits would win.

To build on this machine (Flutter, JDK 17 and the Android SDK under `~/sdk`):

```sh
cd mobile/whirl
flutter build apk --release --target-platform android-arm64
```

## Develop

```sh
cd mobile/whirl/tool && npm ci && node record_server.mjs   # after changing server/index.js
cd mobile/packages/kit && flutter analyze && flutter test
cd mobile/whirl && flutter analyze && flutter test
flutter test tool/screenshots_test.dart --update-goldens    # PNGs of each screen in build/screens/
```

The recorder needs the root `npm ci` too (it runs `server/index.js` with the repo's `express`
and `pg`).

## Not done

- iOS: the project folder exists but has not been built or configured.
- No home-screen widget and no background sync.
- Plain `http://` server addresses are blocked by Android in release builds; use HTTPS.
