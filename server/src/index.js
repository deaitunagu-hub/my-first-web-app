import path from 'node:path';
import { GroupStore } from './store.js';
import { createApp } from './server.js';
import { createApnsFromEnv } from './apns.js';
import { parseUrlList } from './turn.js';

const env = process.env;
const port = Number(env.PORT ?? 8080);
const host = env.HOST ?? '0.0.0.0';
const dataDir = env.DATA_DIR ?? path.resolve('data');

const config = {
  setupToken: env.SETUP_TOKEN || null,
  publicUrl: env.PUBLIC_URL ?? `http://localhost:${port}`,
  inviteScheme: env.INVITE_SCHEME ?? 'kidscall',
  stunUrls: parseUrlList(env.STUN_URLS),
  turnUrls: parseUrlList(env.TURN_URLS),
  turnSecret: env.TURN_SECRET || null,
};

if (config.turnUrls.length > 0 && !config.turnSecret) {
  console.error('TURN_URLS is set but TURN_SECRET is missing');
  process.exit(1);
}

const store = await new GroupStore(path.join(dataDir, 'group.json')).load();
const apns = createApnsFromEnv(env);
const app = createApp({ store, config, apns });

const address = await app.listen(port, host);
console.log(`[kidscall] listening on ${address.address}:${address.port}`);
console.log(`[kidscall] group: ${store.hasGroup() ? `"${store.group.name}" (${store.members().length} devices)` : 'not created yet'}`);
if (!store.hasGroup() && !config.setupToken) {
  console.warn('[kidscall] no group exists and SETUP_TOKEN is unset: nobody can create one');
}
if (store.hasGroup() && config.setupToken) {
  console.warn('[kidscall] group already exists: you can unset SETUP_TOKEN now');
}

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, async () => {
    await app.close();
    process.exit(0);
  });
}
