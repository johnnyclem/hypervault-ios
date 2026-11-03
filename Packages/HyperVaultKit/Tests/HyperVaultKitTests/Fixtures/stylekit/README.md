# StyleKit fixtures

The JSON the server's StyleKit builder (`lib/stylekit.ts`, wire format v1) emits, which `StyleKitTests` and
`DashboardThemeKitTests` decode as they are.

* `newsprint.json`, `glassmorphism.json`, `hypervault-light.json`, `modern-dark.json`: the four golden kits. They are
  the server's `docs/stylekit/fixtures/*.json` copied byte for byte (step 4 of "Sync procedure" in the server's
  `docs/stylekit.md`), and each is the bare `kit` object, the member of the `GET /api/dashboard-theme` body that a kit
  decoder reads. The server tests its builder against the same files with `toEqual`; when either side changes, both
  change in the same release. Do not edit them here: change the server's theme, regenerate there
  (`STYLEKIT_UPDATE_FIXTURES=1 npx vitest run lib/__tests__/stylekit.test.ts`) and copy the files over.
* `all-presets.json`: what `GET /api/dashboard-theme` answers for each of the 39 style ids, `{ theme, kit }` (or
  `{ theme, kit: null, reason }` for `retro`). Used only to sweep "the app's own accessibility floors agree with the
  server's clamp for every preset". It is not a golden: regenerate it from the builder when the clamp or a palette
  changes. It is the server's own `themePayload` over every entry of `THEMES` (`lib/themes.ts`), in that order, written
  with `JSON.stringify(payloads, null, 2)` and a final newline:

  ```ts
  import { THEMES } from "./lib/themes.ts";
  import { themePayload } from "./lib/stylekit.ts";
  process.stdout.write(`${JSON.stringify(THEMES.map((t) => themePayload(t.styleId)), null, 2)}\n`);
  ```

  (run with Node 22 and `--experimental-strip-types`, after pointing the two `@/` imports of `lib/stylekit.ts` at
  `docs/brand/tokens.json` and `lib/themes.ts`). `testTheGoldensAreTheKitsOfTheSweep` holds the four goldens equal to their
  kits in this file, so the two cannot drift apart.
