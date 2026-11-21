// A stand-in for the Anthropic Messages API, for the demo (scripts/seed-demo.sh).
//
//   node scripts/stub-anthropic.mjs reply1.json reply2.json ...
//
// Answers every POST /v1/messages with the next file, in order (the last one
// repeats), wrapped the way the real API wraps a reply. It prints `PORT <n>`
// once it is listening. The replies are the hand-written fakes in
// fixtures/demo: nothing here talks to the real API, so the demo needs no key,
// and what it exercises is reckon's real client, validation and import code.
import fs from 'node:fs'
import http from 'node:http'

const replies = process.argv.slice(2).map((file) => fs.readFileSync(file, 'utf8'))
if (replies.length === 0) {
  console.error('usage: node scripts/stub-anthropic.mjs REPLY.json...')
  process.exit(2)
}

let served = 0
const server = http.createServer((request, response) => {
  if (request.method !== 'POST' || request.url !== '/v1/messages') {
    response.writeHead(404).end()
    return
  }
  request.resume()
  request.on('end', () => {
    const text = replies[Math.min(served, replies.length - 1)]
    served += 1
    const body = JSON.stringify({
      id: `msg_demo_${served}`,
      type: 'message',
      role: 'assistant',
      model: 'demo-stub',
      stop_reason: 'end_turn',
      content: [{ type: 'text', text }],
    })
    response.writeHead(200, { 'content-type': 'application/json' }).end(body)
  })
})

server.listen(0, '127.0.0.1', () => console.log(`PORT ${server.address().port}`))
