const test=require('node:test'),assert=require('node:assert/strict'),worker=require('./buddy-worker');
test('background task status distinguishes review, user handoff, errors and recovery',()=>{
  assert.equal(worker.labels.waiting_review,'Needs review');assert.equal(worker.labels.waiting_user,'Needs you');
  for(const status of ['paused','failed','interrupted','waiting_user'])assert.equal(worker.canResume(status),true);
  for(const status of ['completed','cancelled','running','waiting_review','queued'])assert.equal(worker.canResume(status),false);
  assert.deepEqual(worker.pending({reviews:[{id:'1',status:'pending'},{id:'2',status:'uncertain'},{id:'3',status:'completed'}]}).map(x=>x.id),['1']);
});
