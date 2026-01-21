// code instrumentation to expose metrics for prometheus
// follow this doc for naming conventions https://prometheus.io/docs/practices/naming/
// /metrics serves container/process/pod specific metrics while /global-metrics
// serves metrics for the whole service installation no matter the scaling

import { createServer, type Server } from 'node:http'
import { Gauge, register } from 'prom-client'
import debugModule from 'debug'
import { MongoClient } from 'mongodb'

const debug = debugModule('pbm-exporter')

const mongoUrl = process.env.PBM_MONGODB_URI
if (!mongoUrl) throw new Error('env var "PBM_MONGODB_URI" is required')

const pbmSnapshotsTotalGauge = new Gauge({
  name: 'pbm_snapshots_total',
  help: 'Number of snapshots per status',
  labelNames: ['status']
})
const pbmSnapshotsGauge = new Gauge({
  name: 'pbm_snapshots',
  help: 'Detail of snapshots with statuses',
  labelNames: ['name', 'status']
})
const pbmLastSnapshotGauge = new Gauge({
  name: 'pbm_last_snapshot',
  help: 'Status of last snapshot',
  labelNames: ['status']
})
const pbmLastSnapshotErrorGauge = new Gauge({
  name: 'pbm_last_snapshot_error',
  help: '1 if last snapshot is in error',
  labelNames: ['status']
})
const pbmLastSnapshotSinceGauge = new Gauge({
  name: 'pbm_last_snapshot_since_seconds',
  help: 'Time since last snapshot'
})
const pbmNodesTotalGauge = new Gauge({
  name: 'pbm_nodes_total',
  help: 'Number of nodes per status',
  labelNames: ['status']
})
const pbmNodesGauge = new Gauge({
  name: 'pbm_nodes',
  help: 'Detail of nodes with statuses',
  labelNames: ['rs', 'host', 'status']
})
const pbmPITRTotalGauge = new Gauge({
  name: 'pbm_pitr_chunks_total',
  help: 'Number of PITR chunks'
})
const pbmPITRErrorGauge = new Gauge({
  name: 'pbm_pitr_error',
  help: '1 if PITR is in error',
  labelNames: ['status']
})
const pbmLastPITRSinceGauge = new Gauge({
  name: 'pbm_last_pitr_chunk_since_seconds',
  help: 'Time since last PITR chunk'
})

const snapshotStatuses = new Set<string>()

const connect = async () => {
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
  try {
    const pbmConfig = await db.collection('pbmConfig').findOne({})
    if (!pbmConfig) throw new Error('no PBM config found in database')
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
      let lock = await db.collection('pbmLock').findOne({ type: 'pitr' })
      debug('PITR lock', lock)
      if (!lock) {
        lock = await db.collection('pbmLockOp').findOne({ type: 'pitr' })
        debug('PITR OP lock', lock)
      }

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

  return register.metrics()
}

let server: Server
export const start = async (port: number) => {
  server = createServer((req, res) => {
    if (req.method === 'GET' && req.url === '/metrics') {
      updateStatus()
        .then(metrics => {
          res.setHeader('Content-Type', register.contentType)
          res.writeHead(200)
          res.write(metrics)
          res.end()
        })
        .catch(err => {
          console.error('failed to serve prometheus /metrics', err)
          res.writeHead(500)
          res.end()
        })
    } else {
      res.writeHead(404)
      res.end()
    }
  })
  server.listen(port)
  await new Promise(resolve => server.once('listening', resolve))
  console.log(`Prometheus metrics server available on http://localhost:${port}/metrics`)
}

export const stop = async () => {
  if (server) server.close()
}
