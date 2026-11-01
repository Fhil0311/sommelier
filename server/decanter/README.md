# Decanter

Sommelier's shader sharing service. Players who opt in send the Direct3D-to-Metal shader translations DXMT made
while they played; the service merges them per game and hands the merged pack to the next player before the
game's first run, so it skips the slow half of shader compilation. Packs hold shader hashes and compiled Metal
libraries only; nothing identifies a player.

Runs on Cloudflare Workers with an R2 bucket (free tier). `npm test` runs the format tests with Node;
`npx wrangler dev` runs the service locally; `npx wrangler deploy` publishes it.
