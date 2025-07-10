#!/bin/bash
# Script de démarrage rapide pour pbm-exporter

set -e

# Configuration par défaut
DEFAULT_PORT=9090
DEFAULT_MONGODB_URI="mongodb://localhost:27017"

# Couleurs pour les messages
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Fonction d'affichage
print_header() {
    echo -e "${BLUE}"
    echo "=============================================="
    echo "         PBM Exporter - Démarrage Rapide"
    echo "=============================================="
    echo -e "${NC}"
}

print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Vérifier si le binaire existe
check_binary() {
    if [[ ! -f "build/pbm-exporter" ]]; then
        print_error "Binaire non trouvé dans build/pbm-exporter"
        print_info "Exécutez 'make build' pour construire le binaire"
        exit 1
    fi
}

# Vérifier la connexion MongoDB
check_mongodb() {
    local uri="$1"
    print_info "Test de connexion à MongoDB..."
    
    if command -v mongosh &> /dev/null; then
        if mongosh "$uri" --eval "db.adminCommand('ping')" --quiet; then
            print_info "✅ Connexion MongoDB réussie"
            return 0
        fi
    elif command -v mongo &> /dev/null; then
        if mongo "$uri" --eval "db.adminCommand('ping')" --quiet; then
            print_info "✅ Connexion MongoDB réussie"
            return 0
        fi
    else
        print_warn "Client MongoDB non trouvé, impossible de tester la connexion"
        print_warn "Assurez-vous que MongoDB est accessible"
        return 0
    fi
    
    print_error "❌ Impossible de se connecter à MongoDB"
    print_info "Vérifiez l'URI: $uri"
    return 1
}

# Tester l'endpoint metrics
test_metrics() {
    local port="$1"
    local max_attempts=30
    local attempt=1
    
    print_info "Test de l'endpoint metrics..."
    
    while [[ $attempt -le $max_attempts ]]; do
        if curl -s "http://localhost:$port/metrics" > /dev/null; then
            print_info "✅ Endpoint metrics accessible"
            print_info "🌐 Métriques disponibles sur: http://localhost:$port/metrics"
            return 0
        fi
        
        if [[ $attempt -eq 1 ]]; then
            print_info "En attente du démarrage du serveur..."
        fi
        
        sleep 1
        ((attempt++))
    done
    
    print_error "❌ Endpoint metrics non accessible après ${max_attempts}s"
    return 1
}

# Afficher les métriques
show_sample_metrics() {
    local port="$1"
    
    print_info "Exemples de métriques PBM:"
    echo
    
    # Essayer de récupérer quelques métriques d'exemple
    if curl -s "http://localhost:$port/metrics" | grep -E "^pbm_" | head -10; then
        echo
        print_info "💡 Consultez toutes les métriques: curl http://localhost:$port/metrics"
    else
        print_warn "Impossible de récupérer les métriques d'exemple"
    fi
}

# Fonction principale
main() {
    print_header
    
    # Récupérer la configuration depuis les arguments ou variables d'environnement
    local mongodb_uri="${PBM_MONGODB_URI:-$DEFAULT_MONGODB_URI}"
    local port="${PORT:-$DEFAULT_PORT}"
    
    # Traiter les arguments de ligne de commande
    while [[ $# -gt 0 ]]; do
        case $1 in
            --mongodb-uri)
                mongodb_uri="$2"
                shift 2
                ;;
            --port)
                port="$2"
                shift 2
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS]"
                echo ""
                echo "Options:"
                echo "  --mongodb-uri URI    URI de connexion MongoDB"
                echo "  --port PORT          Port d'écoute (défaut: $DEFAULT_PORT)"
                echo "  --help, -h           Afficher cette aide"
                echo ""
                echo "Variables d'environnement:"
                echo "  PBM_MONGODB_URI      URI de connexion MongoDB"
                echo "  PORT                 Port d'écoute"
                echo ""
                echo "Exemples:"
                echo "  $0"
                echo "  $0 --mongodb-uri mongodb://localhost:27017 --port 8080"
                echo "  PBM_MONGODB_URI=mongodb://user:pass@host:27017 $0"
                exit 0
                ;;
            *)
                print_error "Option inconnue: $1"
                echo "Utilisez --help pour l'aide"
                exit 1
                ;;
        esac
    done
    
    print_info "Configuration:"
    print_info "  MongoDB URI: $mongodb_uri"
    print_info "  Port: $port"
    echo
    
    # Vérifications
    check_binary
    
    if ! check_mongodb "$mongodb_uri"; then
        print_warn "Continuer malgré l'échec de connexion MongoDB? [y/N]"
        read -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    
    print_info "Démarrage de pbm-exporter..."
    echo
    
    # Démarrer l'exporter en arrière-plan
    PBM_MONGODB_URI="$mongodb_uri" PORT="$port" ./build/pbm-exporter &
    local exporter_pid=$!
    
    # Fonction de nettoyage
    cleanup() {
        print_info "Arrêt de pbm-exporter..."
        kill $exporter_pid 2>/dev/null || true
        wait $exporter_pid 2>/dev/null || true
        echo
        print_info "pbm-exporter arrêté"
    }
    
    # Intercepter les signaux pour un arrêt propre
    trap cleanup EXIT INT TERM
    
    # Tester l'endpoint
    if test_metrics "$port"; then
        echo
        show_sample_metrics "$port"
        echo
        print_info "🚀 pbm-exporter fonctionne correctement!"
        print_info "📊 Grafana/Prometheus peut maintenant scraper: http://localhost:$port/metrics"
        print_info "🔍 Pour les logs détaillés, consultez la sortie ci-dessus"
        echo
        print_info "Appuyez sur Ctrl+C pour arrêter..."
        
        # Attendre que l'utilisateur arrête le processus
        wait $exporter_pid
    else
        print_error "Échec du démarrage de pbm-exporter"
        exit 1
    fi
}

# Exécuter la fonction principale
main "$@"
