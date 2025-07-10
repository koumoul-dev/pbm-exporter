package main

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
	"go.mongodb.org/mongo-driver/bson"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

const (
	defaultPort = "9090"
)

var (
	// Prometheus metrics
	pbmSnapshotsTotalGauge = prometheus.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "pbm_snapshots_total",
			Help: "Number of snapshots per status",
		},
		[]string{"status"},
	)

	pbmSnapshotsGauge = prometheus.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "pbm_snapshots",
			Help: "Detail of snapshots with statuses",
		},
		[]string{"name", "status"},
	)

	pbmLastSnapshotGauge = prometheus.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "pbm_last_snapshot",
			Help: "Status of last snapshot",
		},
		[]string{"status"},
	)

	pbmLastSnapshotErrorGauge = prometheus.NewGauge(
		prometheus.GaugeOpts{
			Name: "pbm_last_snapshot_error",
			Help: "1 if last snapshot is in error",
		},
	)

	pbmLastSnapshotSinceGauge = prometheus.NewGauge(
		prometheus.GaugeOpts{
			Name: "pbm_last_snapshot_since_seconds",
			Help: "Time since last snapshot",
		},
	)

	pbmNodesTotalGauge = prometheus.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "pbm_nodes_total",
			Help: "Number of nodes per status",
		},
		[]string{"status"},
	)

	pbmNodesGauge = prometheus.NewGaugeVec(
		prometheus.GaugeOpts{
			Name: "pbm_nodes",
			Help: "Detail of nodes with statuses",
		},
		[]string{"rs", "host", "status"},
	)

	pbmPITRTotalGauge = prometheus.NewGauge(
		prometheus.GaugeOpts{
			Name: "pbm_pitr_chunks_total",
			Help: "Number of PITR chunks",
		},
	)

	pbmPITRErrorGauge = prometheus.NewGauge(
		prometheus.GaugeOpts{
			Name: "pbm_pitr_error",
			Help: "1 if PITR is in error",
		},
	)

	pbmLastPITRSinceGauge = prometheus.NewGauge(
		prometheus.GaugeOpts{
			Name: "pbm_last_pitr_chunk_since_seconds",
			Help: "Time since last PITR chunk",
		},
	)
)

// PBMConfig represents the PBM configuration
type PBMConfig struct {
	PITR struct {
		Enabled bool `bson:"enabled"`
	} `bson:"pitr"`
}

// PBMBackup represents a PBM backup entry
type PBMBackup struct {
	Name   string `bson:"name"`
	Status string `bson:"status"`
}

// PBMAgent represents a PBM agent
type PBMAgent struct {
	RS   string `bson:"rs"`
	Node string `bson:"n"`
	PBMS struct {
		OK bool `bson:"ok"`
	} `bson:"pbms"`
	Nodes struct {
		OK bool `bson:"ok"`
	} `bson:"nodes"`
	Stors struct {
		OK bool `bson:"ok"`
	} `bson:"stors"`
}

// PBMLock represents a PBM lock
type PBMLock struct {
	Type string `bson:"type"`
	HB   struct {
		High int64 `bson:"high"`
	} `bson:"hb"`
}

// PBMPITRChunk represents a PITR chunk
type PBMPITRChunk struct {
	StartTS struct {
		High int64 `bson:"high"`
	} `bson:"start_ts"`
	EndTS struct {
		High int64 `bson:"high"`
	} `bson:"end_ts"`
}

// PBMExporter holds the MongoDB client and other state
type PBMExporter struct {
	mongoURI         string
	snapshotStatuses map[string]bool
}

// NewPBMExporter creates a new PBM exporter
func NewPBMExporter(mongoURI string) *PBMExporter {
	return &PBMExporter{
		mongoURI:         mongoURI,
		snapshotStatuses: make(map[string]bool),
	}
}

// connectToMongoDB establishes a connection to MongoDB
func (e *PBMExporter) connectToMongoDB(ctx context.Context) (*mongo.Client, *mongo.Database, error) {
	clientOptions := options.Client().
		ApplyURI(e.mongoURI).
		SetMaxPoolSize(1).
		SetConnectTimeout(10 * time.Second)

	client, err := mongo.Connect(ctx, clientOptions)
	if err != nil {
		// Retry once after 1 second
		time.Sleep(1 * time.Second)
		client, err = mongo.Connect(ctx, clientOptions)
		if err != nil {
			return nil, nil, fmt.Errorf("failed to connect to MongoDB: %w", err)
		}
	}

	// Ping to verify connection
	if err := client.Ping(ctx, nil); err != nil {
		client.Disconnect(ctx)
		return nil, nil, fmt.Errorf("failed to ping MongoDB: %w", err)
	}

	db := client.Database("admin")
	return client, db, nil
}

// updateMetrics updates all Prometheus metrics by querying MongoDB
func (e *PBMExporter) updateMetrics(ctx context.Context) error {
	client, db, err := e.connectToMongoDB(ctx)
	if err != nil {
		return err
	}
	defer client.Disconnect(ctx)

	// Get PBM configuration
	var pbmConfig PBMConfig
	err = db.Collection("pbmConfig").FindOne(ctx, bson.M{}).Decode(&pbmConfig)
	if err != nil && err != mongo.ErrNoDocuments {
		log.Printf("Warning: failed to get pbm config: %v", err)
	}

	// Get backups
	findOptions := options.Find().SetLimit(10000).SetSort(bson.D{bson.E{Key: "name", Value: -1}})
	cursor, err := db.Collection("pbmBackups").Find(ctx, bson.M{}, findOptions)
	if err != nil {
		return fmt.Errorf("failed to find backups: %w", err)
	}
	defer cursor.Close(ctx)

	var backups []PBMBackup
	if err = cursor.All(ctx, &backups); err != nil {
		return fmt.Errorf("failed to decode backups: %w", err)
	}

	// Reset metrics for known statuses
	for status := range e.snapshotStatuses {
		pbmSnapshotsTotalGauge.WithLabelValues(status).Set(0)
		pbmLastSnapshotGauge.WithLabelValues(status).Set(0)
		for _, backup := range backups {
			pbmSnapshotsGauge.WithLabelValues(backup.Name, status).Set(0)
		}
	}

	// Update backup metrics
	statusCounts := make(map[string]int)
	for _, backup := range backups {
		e.snapshotStatuses[backup.Status] = true
		statusCounts[backup.Status]++
		pbmSnapshotsGauge.WithLabelValues(backup.Name, backup.Status).Set(1)
	}

	for status, count := range statusCounts {
		pbmSnapshotsTotalGauge.WithLabelValues(status).Set(float64(count))
	}

	// Update last snapshot metrics
	if len(backups) > 0 {
		lastBackup := backups[0]
		pbmLastSnapshotGauge.WithLabelValues(lastBackup.Status).Set(1)
		if lastBackup.Status == "error" {
			pbmLastSnapshotErrorGauge.Set(1)
		} else {
			pbmLastSnapshotErrorGauge.Set(0)
		}

		// Parse backup name as timestamp (assuming ISO format)
		if backupTime, err := time.Parse(time.RFC3339, lastBackup.Name); err == nil {
			sinceSeconds := time.Since(backupTime).Seconds()
			pbmLastSnapshotSinceGauge.Set(sinceSeconds)
		}
	}

	// Get agents
	agentsFindOptions := options.Find().SetLimit(10000).SetSort(bson.D{bson.E{Key: "n", Value: 1}})
	agentsCursor, err := db.Collection("pbmAgents").Find(ctx, bson.M{}, agentsFindOptions)
	if err != nil {
		return fmt.Errorf("failed to find agents: %w", err)
	}
	defer agentsCursor.Close(ctx)

	var agents []PBMAgent
	if err = agentsCursor.All(ctx, &agents); err != nil {
		return fmt.Errorf("failed to decode agents: %w", err)
	}

	// Reset node metrics
	for _, status := range []string{"ok", "error"} {
		pbmNodesTotalGauge.WithLabelValues(status).Set(0)
		for _, agent := range agents {
			host := agent.RS + "/" + agent.Node
			pbmNodesGauge.WithLabelValues(agent.RS, host, status).Set(0)
		}
	}

	// Update node metrics
	nodeStatusCounts := make(map[string]int)
	for _, agent := range agents {
		var nodeStatus string
		if agent.PBMS.OK && agent.Nodes.OK && agent.Stors.OK {
			nodeStatus = "ok"
		} else {
			nodeStatus = "error"
		}
		nodeStatusCounts[nodeStatus]++
		host := agent.RS + "/" + agent.Node
		pbmNodesGauge.WithLabelValues(agent.RS, host, nodeStatus).Set(1)
	}

	for status, count := range nodeStatusCounts {
		pbmNodesTotalGauge.WithLabelValues(status).Set(float64(count))
	}

	// Handle PITR metrics if enabled
	if pbmConfig.PITR.Enabled {
		// Check for PITR locks
		var lock PBMLock
		err := db.Collection("pbmLock").FindOne(ctx, bson.M{"type": "pitr"}).Decode(&lock)
		if err == mongo.ErrNoDocuments {
			// Try pbmLockOp collection
			err = db.Collection("pbmLockOp").FindOne(ctx, bson.M{"type": "pitr"}).Decode(&lock)
		}

		now := time.Now().Unix()
		pitrStale := err != nil || (lock.HB.High+30) < now
		if pitrStale {
			pbmPITRErrorGauge.Set(1)
		} else {
			pbmPITRErrorGauge.Set(0)
		}

		// Count PITR chunks
		count, err := db.Collection("pbmPITRChunks").EstimatedDocumentCount(ctx)
		if err != nil {
			log.Printf("Warning: failed to count PITR chunks: %v", err)
		} else {
			pbmPITRTotalGauge.Set(float64(count))
		}

		// Get last PITR chunk
		pitrFindOptions := options.Find().SetSort(bson.D{bson.E{Key: "start_ts", Value: -1}}).SetLimit(1)
		pitrCursor, err := db.Collection("pbmPITRChunks").Find(ctx, bson.M{}, pitrFindOptions)
		if err == nil {
			defer pitrCursor.Close(ctx)
			var pitrChunks []PBMPITRChunk
			if err = pitrCursor.All(ctx, &pitrChunks); err == nil && len(pitrChunks) > 0 {
				lastChunk := pitrChunks[0]
				sinceSeconds := now - lastChunk.EndTS.High
				pbmLastPITRSinceGauge.Set(float64(sinceSeconds))
			}
		}
	}

	return nil
}

// metricsHandler handles the /metrics endpoint
func (e *PBMExporter) metricsHandler(w http.ResponseWriter, r *http.Request) {
	ctx, cancel := context.WithTimeout(r.Context(), 30*time.Second)
	defer cancel()

	if err := e.updateMetrics(ctx); err != nil {
		log.Printf("Error updating metrics: %v", err)
		http.Error(w, "Internal Server Error", http.StatusInternalServerError)
		return
	}

	promhttp.Handler().ServeHTTP(w, r)
}

func main() {
	// Check for version flag
	if len(os.Args) > 1 && (os.Args[1] == "--version" || os.Args[1] == "-v") {
		printVersion()
		return
	}

	// Get configuration from environment variables
	mongoURI := os.Getenv("PBM_MONGODB_URI")
	if mongoURI == "" {
		log.Fatal("PBM_MONGODB_URI environment variable is required")
	}

	port := os.Getenv("PORT")
	if port == "" {
		port = defaultPort
	}

	// Register Prometheus metrics
	prometheus.MustRegister(
		pbmSnapshotsTotalGauge,
		pbmSnapshotsGauge,
		pbmLastSnapshotGauge,
		pbmLastSnapshotErrorGauge,
		pbmLastSnapshotSinceGauge,
		pbmNodesTotalGauge,
		pbmNodesGauge,
		pbmPITRTotalGauge,
		pbmPITRErrorGauge,
		pbmLastPITRSinceGauge,
	)

	// Create exporter
	exporter := NewPBMExporter(mongoURI)

	// Test initial connection and update metrics
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	if err := exporter.updateMetrics(ctx); err != nil {
		log.Printf("Warning: initial metrics update failed: %v", err)
	}
	cancel()

	// Setup HTTP server
	http.HandleFunc("/metrics", exporter.metricsHandler)

	server := &http.Server{
		Addr:         ":" + port,
		ReadTimeout:  30 * time.Second,
		WriteTimeout: 30 * time.Second,
	}

	// Start server in a goroutine
	go func() {
		log.Printf("Prometheus exporter serving metrics on http://localhost:%s/metrics", port)
		if err := server.ListenAndServe(); err != http.ErrServerClosed {
			log.Fatalf("Server failed to start: %v", err)
		}
	}()

	// Wait for interrupt signal to gracefully shutdown
	quit := make(chan os.Signal, 1)
	signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
	<-quit

	log.Println("Received SIGTERM signal, shutdown gracefully...")

	// Graceful shutdown
	ctx, cancel = context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		log.Printf("Server forced to shutdown: %v", err)
	}

	log.Println("Server exited")
}
