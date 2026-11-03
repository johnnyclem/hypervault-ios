# StyleKit fixtures

The JSON the server's StyleKit builder (`lib/stylekit.ts`, wire format v1) emits, which `StyleKitTests` and
`DashboardThemeKitTests` decode as they are.

* `newsprint.json`, `glassmorphism.json`, `hypervault-light.json`, `modern-dark.json`: the four golden kits, the `kit`
  object of `GET /api/dashboard-theme`. The server publishes the same files under `docs/stylekit/fixtures` and tests its
  builder against them with `toEqual`; when either side changes, both change in the same release.
* `all-presets.json`: what `GET /api/dashboard-theme` answers for each of the 39 style ids, `{ theme, kit }` (or
  `{ theme, kit: null, reason }` for `retro`). Used only to sweep "the app's own accessibility floors agree with the
  server's clamp for every preset". It is not a golden: regenerate it from the builder when the clamp or a palette changes.

They were generated from the server prototype `stylekit.proto.ts` (Node 22, `--experimental-strip-types`) over the 39
preset blocks of `app/globals.css`.
