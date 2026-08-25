// ── A LOCAL STAND-IN FOR room.tokkah.com ─────────────────────────────────────
//
// crash-check.sh points the app here with --tel-endpoint, so nothing it does
// reaches the real server. Every POST body is appended to a file as one line of
// JSON, which is all the rig needs to assert on.
//
// It can also refuse. `touch <out>.fail` makes every crash POST answer 500, and
// removing the file makes it work again -- that is the whole of the "the network
// was down at that moment" arm, and it has to be switchable BETWEEN launches
// without restarting the sink, because the property being proved is that the
// second launch retries what the first one could not deliver.
import { createServer } from 'node:http';
import { appendFileSync, existsSync } from 'node:fs';

const arg = (n, d) => {
  const i = process.argv.indexOf('--' + n);
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : d;
};
const port = Number(arg('port', '8103'));
const out = arg('out', '/tmp/crash-sink');

const server = createServer((req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    const crash = req.url.includes('/crash');
    if (crash && existsSync(out + '.fail')) {
      // Refused, and NOT recorded: a rig that logged the refused post would
      // count it as delivered and the retry arm would prove nothing.
      appendFileSync(out + '.refused', body + '\n');
      res.writeHead(500, { 'content-type': 'application/json' });
      res.end('{"error":"sink is refusing on purpose"}');
      return;
    }
    appendFileSync(crash ? out + '.crash' : out + '.beat', body + '\n');
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end('{"ok":true}');
  });
});
server.listen(port, '127.0.0.1', () => {
  console.log(`sink: listening on 127.0.0.1:${port} -> ${out}.crash / ${out}.beat`);
});
