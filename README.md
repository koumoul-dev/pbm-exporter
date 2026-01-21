# pbm-exporter

Prometheus exporter for PBM (Percona Backup Mongodb)

## test docker image

Run PBM agent and MongoDB containers.

```
docker network create pbm-exporter-test
docker-compose up -d
```

PBM requires mongodb to run in replicaset mode:

```
docker compose exec mongo mongo
>> rs.initiate({_id: 'pbm-exporter-test', members: [{_id: 0, host: 'mongo:27017'}]})
>> db.test.insert({'test': 'Test !!'})
```

Configure PBM and prepare first backup:

```
docker compose exec pbm-agent bash
>> pbm config --file=/tmp/pbm-config.yaml
>> pbm backup
>> pbm config --set=pitr.enabled=true
```

Build and test the image:

```
docker build . -t pbm-exporter && docker run -it --rm -p 9090:9090 -e DEBUG=pbm-exporter -e PBM_MONGODB_URI=mongodb://mongo:27017 --network pbm-exporter-test --name pbm-exporter-test pbm-exporter
curl http://localhost:9090/metrics
```