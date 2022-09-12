/* eslint-disable no-new */
const config = require('config')
const express = require('express')
const eventToPromise = require('event-to-promise')
const client = require('prom-client')
const { nextTick } = require('process')
const exec = require('node:util').promisify(require('node:child_process').exec)

const app = express()
const server = require('http').createServer(app)

const pbmSnapshotsTotalGauge = new client.Gauge({
  name: 'pbm_snapshots_total',
  help: 'Number of snapshots per status',
  labelNames: ['status']
})
const pbmSnapshotsGauge = new client.Gauge({
  name: 'pbm_snapshots',
  help: 'Detail of snapshots with statuses',
  labelNames: ['name', 'status']
})
const pbmLastSnapshotGauge = new client.Gauge({
  name: 'pbm_last_snapshot',
  help: 'Status of last snapshot',
  labelNames: ['status']
})
const pbmLastSnapshotErrorGauge = new client.Gauge({
  name: 'pbm_last_snapshot_error',
  help: '1 if last snapshot is in error',
  labelNames: ['status']
})
const pbmLastSnapshotSinceGauge = new client.Gauge({
  name: 'pbm_last_snapshot_since_seconds',
  help: 'Time since last snapshot'
})
const pbmNodesTotalGauge = new client.Gauge({
  name: 'pbm_nodes_total',
  help: 'Number of nodes per status',
  labelNames: ['status']
})
const pbmNodesGauge = new client.Gauge({
  name: 'pbm_nodes',
  help: 'Detail of nodes with statuses',
  labelNames: ['rs', 'host', 'status']
})
const pbmPITRTotalGauge = new client.Gauge({
  name: 'pbm_pitr_chunks_total',
  help: 'Number of PITR chunks'
})
const pbmPITRErrorGauge = new client.Gauge({
  name: 'pbm_pitr_error',
  help: '1 if PITR is in error',
  labelNames: ['status']
})
const pbmLastPITRSinceGauge = new client.Gauge({
  name: 'pbm_last_pitr_chunk_since_seconds',
  help: 'Time since last PITR chunk'
})

const snapshotStatuses = new Set()

const updateStatus = async () => {
  const { stdout, stderr } = await exec('pbm status --out=json')
  if (stderr && stderr.length) throw new Error(stderr)
  const status = JSON.parse(stdout)
  for (const snapshotStatus of [...snapshotStatuses]) {
    pbmSnapshotsTotalGauge.labels(snapshotStatus).set(0)
    pbmLastSnapshotGauge.labels(snapshotStatus).set(0)
    for (const snapshot of status.backups.snapshot) {
      pbmSnapshotsGauge.labels(snapshot.name, snapshotStatus).set(0)
    }
  }
  for (const snapshot of status.backups.snapshot) {
    snapshotStatuses.add(snapshot.status)
    pbmSnapshotsTotalGauge.labels(snapshot.status).inc(1)
    pbmSnapshotsGauge.labels(snapshot.name, snapshot.status).set(1)
  }
  const lastSnapshot = status.backups.snapshot[0]
  if (lastSnapshot) {
    pbmLastSnapshotGauge.labels(lastSnapshot.status).set(1)
    pbmLastSnapshotErrorGauge.set(lastSnapshot.status === 'error' ? 1 : 0)
    pbmLastSnapshotSinceGauge.set(Math.round((new Date().getTime() - new Date(lastSnapshot.name).getTime()) / 1000))
  }

  for (const nodeStatus of ['ok', 'error']) {
    pbmNodesTotalGauge.labels(nodeStatus).set(0)
    for (const rs of status.cluster) {
      for (const node of rs.nodes) {
        pbmNodesGauge.labels(rs.rs, node.host, nodeStatus).set(0)
      }
    }
  }
  for (const rs of status.cluster) {
    for (const node of rs.nodes) {
      const nodeStatus = node.ok ? 'ok' : 'error'
      pbmNodesTotalGauge.labels(nodeStatus).inc(1)
      pbmNodesGauge.labels(rs.rs, node.host, nodeStatus).set(1)
    }
  }

  if (status.backups.pitrChunks.pitrChunks) {
    pbmPITRTotalGauge.set(status.backups.pitrChunks.pitrChunks.length)
    const lastPITRChunk = status.backups.pitrChunks.pitrChunks[0]
    if (lastPITRChunk) {
      pbmLastPITRSinceGauge.set(Math.round((new Date().getTime() / 1000) - lastPITRChunk.range.end))
    }
  }
  pbmPITRErrorGauge.set(status.pitr && status.pitr.error ? 1 : 0)
  return status
}

app.get('/metrics', async (req, res, next) => {
  try {
    await updateStatus()
    res.set('Content-Type', client.register.contentType)
    res.send(await client.register.metrics())
  } catch (err) {
    nextTick(err)
  }
})
const start = async () => {
  console.log('initial PBM status', JSON.stringify(await updateStatus(), null, 2))
  server.listen(config.port)
  await eventToPromise(server, 'listening')
  console.log(`Prometheus exporter serving metrics on http://localhost:${config.port}/metrics`)
}
const stop = async () => {
  server.close()
  await eventToPromise(server, 'close')
}

start().then(() => {}, err => {
  console.error('Failure', err)
  process.exit(-1)
})

process.on('SIGTERM', function onSigterm () {
  console.info('Received SIGTERM signal, shutdown gracefully...')
  stop().then(() => {
    console.log('shutting down now')
    process.exit()
  }, err => {
    console.error('Failure while stopping', err)
    process.exit(-1)
  })
})
