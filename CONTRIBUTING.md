# Contributing to Sommelier

Thank you for helping. A few things make a change easy to take.

## Before you start
- For anything larger than a small fix, open an issue first and say what you want to change. Someone may already be on
  it, or there may be a reason it is the way it is.
- A game that doesn't run is best reported with the "Game doesn't run" issue form and the report Sommelier makes
  (Fix Launch → Report a Problem); it already leaves out your name and paths.
- User-visible wording goes through the project's design review: keep new labels few and plain, and list them in the
  pull request.

## Making the change
- Build and test as the README says. `swift test` and, for the service, `npm test` in `server/api` must pass; add tests
  for what you change.
- Match the code around you: names, comment style (plain sentences on why, not what), no new dependencies without a
  reason given in the pull request.
- Every source file starts with the project's copyright line and its SPDX license identifier.
- Strings the player sees go through `String(localized:)` / `Text("…")` in English; add translations only if you know
  the language well.
- Never commit secrets, signing material, personal data (paths with your user name, account names, Steam IDs) or
  third-party game art.

## Signing off: the Developer Certificate of Origin
Sommelier does not ask contributors to sign a contributor license agreement. Instead every commit carries a
`Signed-off-by:` line with your real name and e-mail (`git commit -s`). It states that you wrote the change or have the
right to submit it under the project's license, as set out in the Developer Certificate of Origin 1.1
(https://developercertificate.org). Pull requests with unsigned commits can't be merged.

## Licence of contributions
Contributions are accepted under the license of the files they change: GPL-3.0-or-later, or LGPL-2.1-or-later for the
programs in `engine/` that run inside Wine.
