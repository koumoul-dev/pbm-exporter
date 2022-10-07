/* eslint-disable no-new */
const config = require('config')
const express = require('express')
const eventToPromise = require('event-to-promise')
const client = require('prom-client')
const debug = require('debug')('pbm-exporter')
const { MongoClient } = require('mongodb')

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

const connect = async () => {
  const mongoUrl = process.env.PBM_MONGODB_URI
  debug('Connecting to mongodb ' + mongoUrl)
  const client = new MongoClient(mongoUrl, { maxPoolSize: 1 })
  try {
    await client.connect()
  } catch (err) {
    // 1 retry after 1s
    // solve the quite common case in docker-compose of the service starting at the same time as the db
    await new Promise(resolve => setTimeout(resolve, 1000))
    await client.connect()
  }
  const db = client.db('admin')
  debug('connected')
  return { db, client }
}

const updateStatus = async () => {
  // cf https://github.com/percona/percona-backup-mongodb/blob/main/cli/status.go

  const { db, client } = await connect()
  // const admin = client.db().admin()
  try {
    const pbmConfig = await db.collection('pbmConfig').findOne({})
    debug('pbm config', pbmConfig)
    const backups = await db.collection('pbmBackups').find().limit(10000).sort({ name: -1 }).toArray()
    for (const snapshotStatus of [...snapshotStatuses]) {
      pbmSnapshotsTotalGauge.labels(snapshotStatus).set(0)
      pbmLastSnapshotGauge.labels(snapshotStatus).set(0)
      for (const backup of backups) {
        pbmSnapshotsGauge.labels(backup.name, snapshotStatus).set(0)
      }
    }
    for (const backup of backups) {
      debug('backup', backup)
      snapshotStatuses.add(backup.status)
      pbmSnapshotsTotalGauge.labels(backup.status).inc(1)
      pbmSnapshotsGauge.labels(backup.name, backup.status).set(1)
    }
    const lastBackup = backups[0]
    if (lastBackup) {
      pbmLastSnapshotGauge.labels(lastBackup.status).set(1)
      pbmLastSnapshotErrorGauge.set(lastBackup.status === 'error' ? 1 : 0)
      pbmLastSnapshotSinceGauge.set(Math.round((new Date().getTime() - new Date(lastBackup.name).getTime()) / 1000))
    }
    const agents = await db.collection('pbmAgents').find().limit(10000).sort({ n: 1 }).toArray()
    debug('agents', agents)
    // const rsStatus = await admin.replSetGetStatus()
    // debug('RS status', rsStatus)

    for (const nodeStatus of ['ok', 'error']) {
      pbmNodesTotalGauge.labels(nodeStatus).set(0)
      for (const agent of agents) {
        pbmNodesGauge.labels(agent.rs, agent.rs + '/' + agent.n, nodeStatus).set(0)
      }
    }
    for (const agent of agents) {
      const nodeStatus = (agent.pbms.ok && agent.nodes.ok && agent.stors.ok) ? 'ok' : 'error'
      pbmNodesTotalGauge.labels(nodeStatus).inc(1)
      pbmNodesGauge.labels(agent.rs, agent.rs + '/' + agent.n, nodeStatus).set(1)
    }

    debug('PITR enabled', pbmConfig.pitr?.enabled)
    if (pbmConfig.pitr?.enabled) {
      const lock = await db.collection('pbmLock').findOne({ type: 'pitr' })
      debug('PITR lock', lock)
      const now = Math.round(new Date().getTime() / 1000)
      const pitrStale = !lock || (lock.hb.high + 30) < now
      debug('PITR stale', pitrStale, lock && (now - lock.hb.high))
      pbmPITRErrorGauge.set(pitrStale ? 1 : 0)
      const countPITRChunks = await db.collection('pbmPITRChunks').estimatedDocumentCount()
      debug('PITR count', countPITRChunks)
      pbmPITRTotalGauge.set(countPITRChunks)
      const lastPITRChunk = (await db.collection('pbmPITRChunks').find({}).sort({ start_ts: -1 }).limit(1).toArray())[0]
      debug('PITR last chunk', lastPITRChunk)
      if (lastPITRChunk) {
        debug('PITR last chunk delay', now - lastPITRChunk.end_ts.high)
        pbmLastPITRSinceGauge.set(now - lastPITRChunk.end_ts.high)
      }
    }
  } finally {
    await client.close()
  }
}

app.get('/metrics', async (req, res, next) => {
  try {
    await updateStatus()
    res.set('Content-Type', client.register.contentType)
    res.send(await client.register.metrics())
  } catch (err) {
    next(err)
  }
})
const start = async () => {
  await updateStatus()
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
