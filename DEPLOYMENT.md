# Guide de Déploiement - PBM Exporter v0.2.0 (Go)

## Vue d'ensemble

Ce guide décrit comment déployer l'exporteur PBM v0.2.0 écrit en Go sur un serveur de production. Cette version offre de meilleures performances, une consommation mémoire réduite et un déploiement sans dépendances.

## Prérequis

- Serveur Linux (Ubuntu 18.04+, CentOS 7+, Debian 9+, etc.)
- Accès sudo
- MongoDB avec PBM configuré
- Port 9090 disponible (ou autre port de votre choix)

## Options de Déploiement

### Option 1: Installation Automatique (Recommandée)

```bash
# 1. Cloner le repository
git clone https://github.com/your-org/pbm-exporter.git
cd pbm-exporter

# 2. Builder le binaire
make build

# 3. Installation automatique avec systemd
sudo ./install.sh --start

# 4. Configurer l'URI MongoDB
sudo vi /etc/default/pbm-exporter
# Modifier: PBM_MONGODB_URI=mongodb://votre-mongodb:27017

# 5. Redémarrer le service
sudo systemctl restart pbm-exporter

# 6. Vérifier le statut
sudo systemctl status pbm-exporter
curl http://localhost:9090/metrics
```

### Option 2: Déploiement Docker

```bash
# 1. Cloner le repository
git clone https://github.com/your-org/pbm-exporter.git
cd pbm-exporter

# 2. Builder l'image Docker
make docker

# 3. Lancer le conteneur
docker run -d \
  --name pbm-exporter \
  --restart unless-stopped \
  -p 9090:9090 \
  -e PBM_MONGODB_URI=mongodb://votre-mongodb:27017 \
  pbm-exporter:latest

# 4. Vérifier le déploiement
docker logs pbm-exporter
curl http://localhost:9090/metrics
```

### Option 3: Installation Manuelle

```bash
# 1. Télécharger ou builder le binaire
# Option A: Depuis les sources
git clone https://github.com/your-org/pbm-exporter.git
cd pbm-exporter
make build
sudo cp build/pbm-exporter /usr/local/bin/

# Option B: Télécharger le binaire pré-compilé
wget https://github.com/your-org/pbm-exporter/releases/download/v0.2.0/pbm-exporter-linux-amd64.tar.gz
tar -xzf pbm-exporter-linux-amd64.tar.gz
sudo cp pbm-exporter /usr/local/bin/
sudo chmod +x /usr/local/bin/pbm-exporter

# 2. Créer un utilisateur système
sudo useradd --system --no-create-home --shell /bin/false pbm-exporter

# 3. Créer le fichier de configuration
sudo mkdir -p /etc/default
sudo tee /etc/default/pbm-exporter > /dev/null <<EOF
PBM_MONGODB_URI=mongodb://votre-mongodb:27017
PORT=9090
EOF

# 4. Créer le service systemd
sudo tee /etc/systemd/system/pbm-exporter.service > /dev/null <<EOF
[Unit]
Description=PBM Prometheus Exporter
After=network.target

[Service]
Type=simple
User=pbm-exporter
Group=pbm-exporter
ExecStart=/usr/local/bin/pbm-exporter
Restart=always
RestartSec=5
EnvironmentFile=/etc/default/pbm-exporter

[Install]
WantedBy=multi-user.target
EOF

# 5. Activer et démarrer le service
sudo systemctl daemon-reload
sudo systemctl enable pbm-exporter
sudo systemctl start pbm-exporter

# 6. Vérifier le statut
sudo systemctl status pbm-exporter
```

## Configuration

### Variables d'Environnement

| Variable | Requis | Description | Défaut |
|----------|--------|-------------|--------|
| `PBM_MONGODB_URI` | ✅ | URI de connexion MongoDB | - |
| `PORT` | ❌ | Port d'écoute du serveur | 9090 |

### Exemple de Configuration

```bash
# /etc/default/pbm-exporter
PBM_MONGODB_URI=mongodb://mongodb-user:password@mongodb.example.com:27017/admin?replicaSet=myReplSet
PORT=9090
```

### Configuration MongoDB

L'URI MongoDB doit pointer vers une instance où PBM est configuré. L'utilisateur doit avoir les permissions de lecture sur la base `admin`.

```javascript
// Créer un utilisateur pour l'exporter (dans MongoDB)
use admin
db.createUser({
  user: "pbm-exporter",
  pwd: "secure-password",
  roles: [
    { role: "read", db: "admin" }
  ]
})
```

## Surveillance et Logs

### Vérification du Service

```bash
# Statut du service
sudo systemctl status pbm-exporter

# Logs en temps réel
sudo journalctl -u pbm-exporter -f

# Logs des dernières 24h
sudo journalctl -u pbm-exporter --since "24 hours ago"

# Test de l'endpoint metrics
curl http://localhost:9090/metrics

# Test de santé du service
curl -I http://localhost:9090/metrics
```

### Métriques Exposées

L'exporter expose les métriques suivantes:

- `pbm_snapshots_total{status}` - Nombre de snapshots par statut
- `pbm_snapshots{name,status}` - Détail des snapshots avec statuts
- `pbm_last_snapshot{status}` - Statut du dernier snapshot
- `pbm_last_snapshot_error` - 1 si le dernier snapshot est en erreur
- `pbm_last_snapshot_since_seconds` - Temps depuis le dernier snapshot
- `pbm_nodes_total{status}` - Nombre de nœuds par statut
- `pbm_nodes{rs,host,status}` - Détail des nœuds avec statuts
- `pbm_pitr_chunks_total` - Nombre de chunks PITR
- `pbm_pitr_error` - 1 si PITR est en erreur
- `pbm_last_pitr_chunk_since_seconds` - Temps depuis le dernier chunk PITR

## Intégration Prometheus

### Configuration Prometheus

Ajoutez cette configuration à votre `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: 'pbm-exporter'
    static_configs:
      - targets: ['votre-serveur:9090']
    scrape_interval: 30s
    metrics_path: /metrics
    scrape_timeout: 10s
```

### Alertes Prometheus (Exemples)

```yaml
groups:
  - name: pbm-exporter
    rules:
      - alert: PBMLastSnapshotError
        expr: pbm_last_snapshot_error == 1
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "PBM last snapshot failed"
          description: "The last PBM snapshot is in error state"

      - alert: PBMSnapshotTooOld
        expr: pbm_last_snapshot_since_seconds > 86400
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "PBM snapshot too old"
          description: "Last PBM snapshot is older than 24 hours"

      - alert: PBMPITRError
        expr: pbm_pitr_error == 1
        for: 5m
        labels:
          severity: critical
        annotations:
          summary: "PBM PITR is in error"
          description: "PBM Point-in-Time Recovery is in error state"
```

## Dépannage

### Problèmes Courants

#### Service ne démarre pas

```bash
# Vérifier les logs
sudo journalctl -u pbm-exporter -n 50

# Vérifier la configuration
cat /etc/default/pbm-exporter

# Tester la connexion MongoDB
mongo $PBM_MONGODB_URI --eval "db.adminCommand('ping')"
```

#### Connexion MongoDB échoue

```bash
# Vérifier l'URI MongoDB
mongo "mongodb://votre-uri" --eval "show dbs"

# Vérifier les permissions de l'utilisateur
mongo "mongodb://votre-uri" --eval "db.runCommand({connectionStatus: 1})"

# Vérifier la connectivité réseau
telnet mongodb-host 27017
```

#### Métriques vides ou incorrectes

```bash
# Vérifier les collections PBM
mongo $PBM_MONGODB_URI --eval "
use admin;
print('pbmConfig:', db.pbmConfig.count());
print('pbmBackups:', db.pbmBackups.count());
print('pbmAgents:', db.pbmAgents.count());
"

# Tester l'exporter manuellement
PBM_MONGODB_URI=mongodb://votre-uri ./pbm-exporter
```

### Logs de Debug

Pour activer les logs détaillés, modifiez le service:

```bash
sudo systemctl edit pbm-exporter
```

Ajoutez:
```ini
[Service]
Environment=DEBUG=1
```

Puis redémarrez:
```bash
sudo systemctl daemon-reload
sudo systemctl restart pbm-exporter
```

## Sécurité

### Recommandations

1. **Utilisateur dédié**: L'exporter s'exécute sous un utilisateur système dédié
2. **Permissions minimales**: L'utilisateur MongoDB n'a que les permissions de lecture nécessaires
3. **Firewall**: Limitez l'accès au port 9090 aux seuls serveurs Prometheus
4. **TLS**: Configurez TLS pour MongoDB en production

### Configuration Firewall (exemple avec ufw)

```bash
# Autoriser Prometheus à accéder à l'exporter
sudo ufw allow from PROMETHEUS_IP to any port 9090

# Ou pour un réseau complet
sudo ufw allow from 10.0.0.0/8 to any port 9090
```

## Migration depuis Node.js

Si vous migrez depuis la version Node.js (v0.1.x):

1. **Arrêter l'ancien service**:
```bash
sudo systemctl stop pbm-exporter-nodejs
sudo systemctl disable pbm-exporter-nodejs
```

2. **Installer la nouvelle version** (voir options ci-dessus)

3. **Vérifier la compatibilité des métriques**: Les noms des métriques restent identiques

4. **Mettre à jour Prometheus**: Aucune modification nécessaire dans la configuration Prometheus

## Performance

### Améliorations de la Version Go

- **Mémoire**: ~5-10 MB vs ~50-100 MB (Node.js)
- **CPU**: Réduction de ~50% de l'utilisation CPU
- **Démarrage**: Instantané vs ~2-3 secondes
- **Taille**: Binaire de ~15 MB vs installation Node.js de ~100+ MB

### Recommandations de Dimensionnement

- **CPU**: 0.1 core suffisant pour la plupart des déploiements
- **Mémoire**: 50 MB de RAM alloués
- **Réseau**: Négligeable (~1 KB/scrape)
- **Stockage**: 20 MB pour le binaire

## Support

Pour obtenir de l'aide:

1. Consultez les logs: `sudo journalctl -u pbm-exporter -f`
2. Vérifiez la documentation PBM de Percona
3. Ouvrez une issue sur GitHub avec les logs et la configuration

## Désinstallation

Pour supprimer complètement l'exporter:

```bash
# Avec le script d'installation
sudo ./install.sh --uninstall

# Ou manuellement
sudo systemctl stop pbm-exporter
sudo systemctl disable pbm-exporter
sudo rm -f /usr/local/bin/pbm-exporter
sudo rm -f /etc/systemd/system/pbm-exporter.service
sudo rm -f /etc/default/pbm-exporter
sudo userdel pbm-exporter
sudo systemctl daemon-reload
```
