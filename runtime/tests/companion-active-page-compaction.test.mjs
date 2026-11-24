import assert from 'node:assert/strict';
import test from 'node:test';
import {createFixture, textResponse, sseResponse} from './fixtures/companion-recall-engine.mjs';
import {golden, phoneHttp, phoneEnvelope, sendPhone} from './fixtures/companion-phone-replay.mjs';

const page = 'CURRENT_PAGE_REF_7028';
const selectedMemory = JSON.parse(golden.block).items[0].text;
const original = '先分批核对样本，最后把选中页面的编号和结果一起告诉我。';
const model = 'c750-fixture-model';
function requestRead(step) {
  const id = 'read-' + step;
  return sseResponse([
    {type: 'message_start', message: {id, type: 'message', role: 'assistant', model, content: [],
      stop_reason: null, usage: {input_tokens: 5, output_tokens: 0}}},
    {type: 'content_block_start', index: 0, content_block: {type: 'tool_use', id, name: 'read_samples', input: {}}},
    {type: 'content_block_delta', index: 0, delta: {type: 'input_json_delta', partial_json: '{}'}},
    {type: 'content_block_stop', index: 0},
    {type: 'message_delta', delta: {stop_reason: 'tool_use'}, usage: {output_tokens: 3}},
    {type: 'message_stop'},
  ]);
}

for (const replacement of ['none', 'owner', 'background']) {
  test('current page across automatic compaction with ' + replacement + ' replacement', {
    skip: !process.env.DSH_PREFIX && 'requires the pinned runtime', timeout: 30000, concurrency: false,
  }, async t => {
    const rows = [];
    let count = 0, summaries = 0, reads = 0, finished = false, claimed = false;
    let agent, steered, firstTurn, laterTurn;
    const f = await createFixture({
      deepseekOptions: {models: [{id: model, inputModalities: ['text'], maxTokens: 128, contextWindow: 131072}]},
      transport: ({body}) => {
        const summary = JSON.stringify(body.messages.at(-1)).includes('You are now acting as a compaction engine');
        const wire = JSON.stringify(body.messages);
        rows.push({summary, hasPage: wire.includes(page), hasMemory: wire.includes(selectedMemory), visibleOriginal: wire.includes(original), claimed});
        if (summary) {
          summaries++;
          return textResponse('此前已经查看本地样本，需完成当前用户请求。');
        }
        if (summaries && replacement !== 'none' && !steered) {
          const source = replacement === 'owner' ? {kind: 'user', rpcId: 'new-user'} : {kind: 'goal'};
          steered = f.engine.llm.createUserMessage({source, content: [{type: 'text', text: '改为只检查本地样本。'}]});
          agent.steer(steered);
        }
        assert(++count <= 120, 'the actual policy must reach pressure and make progress');
        if (finished || claimed || replacement === 'none' && summaries === 2) return textResponse('完成核对。');
        return requestRead(count);
      },
    });
    t.after(() => f.dispose());
    const http = await phoneHttp(f);
    t.after(() => http.close());
    await f.ctx.plugin((await f.engine.load('dsh-token-meter')).TokenMeter, {}).await();
    await f.ctx.plugin((await f.engine.load('dsh-compaction-tool-result-pruner')).ToolResultPruner,
      {thresholdChars: 8192, headChars: 4096, tailChars: 1024}).await();
    new (await f.engine.load('dsh-compaction-basic')).BasicCompactionEngine(f.ctx, {});
    f.ctx.tools.register({name: 'read_samples', description: 'Read one batch of synthetic samples',
      parameters: {type: 'object', properties: {}, additionalProperties: false},
      output: {schema: {type: 'string'}, render: (_args, value) => [{type: 'text', text: value}]},
      execute: async () => '样本批次' + (++reads) + '\n' + '一二三四五六七八九十'.repeat(740),
    });
    ({agent} = await f.createAgent('active-room'));
    f.ctx.on('agent/inbox/claimed', ({message, turn}) => {
      if (message.source.rpcId === 'active') firstTurn = turn;
      if (steered && message.content.some(block => block.text === '改为只检查本地样本。')) { claimed = true; laterTurn = turn; }
    });
    const cap = await http.request(agent.id);
    const input = phoneEnvelope(cap.body, 'active');
    input.deviceContext = {window: 'room', localTime: '2026-11-25T01:00+08:00', selectedPage: page};
    assert.equal((await http.request(input)).status, 200);
    await sendPhone(f, agent, 'active', original);
    const end = agent.session.snapshotEvents().filter(e => e.type === 'turn/end').at(-1).data.reason;
    assert.equal(end.kind, 'completed', JSON.stringify({end, reads, summaries, claimed, steered: !!steered, firstTurn, laterTurn}));
    assert(rows[0].visibleOriginal && rows[0].hasPage && rows[0].hasMemory);
    assert(summaries >= 1 && reads > 0);
    assert(rows.filter(r => r.summary).every(r => !r.hasPage && !r.hasMemory));
    const log = JSON.stringify(agent.session.snapshotEvents());
    assert(!log.includes(page) && !log.includes(selectedMemory), 'request-only selections never enter the log');
    const after = rows.at(-1);
    assert.equal(after.summary, false);
    assert.equal(after.visibleOriginal, false, 'the active original really was compacted');
    if (replacement === 'none') {
      assert.equal(summaries, 2);
      assert(rows.filter(r => !r.summary).every(r => r.hasPage && r.hasMemory), 'owner must keep the page through both summaries');
    } else {
      assert(claimed);
      assert.equal(laterTurn, firstTurn, 'replacement was a real steer in the same open turn');
      assert(!rows.filter(r => r.claimed).some(r => r.hasPage || r.hasMemory), 'a separate human or background claim retires the page');
    }
    finished = true;
    const endOfFirst = rows.length;
    await sendPhone(f, agent, 'next', '独立的下一轮。');
    const other = await f.createAgent('another-role');
    await sendPhone(f, other.agent, 'active', '另一个房间。');
    assert(rows.slice(endOfFirst).length >= 2);
    assert(rows.slice(endOfFirst).every(r => !r.hasPage && !r.hasMemory));
    t.diagnostic(JSON.stringify({replacement, summaries, completedReads: reads, firstTurn, laterTurn}));
  });
}
