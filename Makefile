# Makefile for pbm-exporter

# Variables
BINARY_NAME=pbm-exporter
BUILD_DIR=build
VERSION?=0.2.0
LDFLAGS=-ldflags "-X main.version=$(VERSION) -s -w"

# Go parameters
GOCMD=go
GOBUILD=$(GOCMD) build
GOCLEAN=$(GOCMD) clean
GOTEST=$(GOCMD) test
GOGET=$(GOCMD) get
GOMOD=$(GOCMD) mod

# Supported platforms
PLATFORMS=linux/amd64 linux/arm64 darwin/amd64 darwin/arm64 windows/amd64

.PHONY: all build clean test deps help install cross-compile docker

# Default target
all: clean deps build

# Download dependencies
deps:
	$(GOMOD) download
	$(GOMOD) tidy

# Build the binary
build:
	@echo "Building $(BINARY_NAME)..."
	@mkdir -p $(BUILD_DIR)
	CGO_ENABLED=0 $(GOBUILD) $(LDFLAGS) -o $(BUILD_DIR)/$(BINARY_NAME) .
	@echo "Binary built: $(BUILD_DIR)/$(BINARY_NAME)"

# Build with debug info
build-debug:
	@echo "Building $(BINARY_NAME) with debug info..."
	@mkdir -p $(BUILD_DIR)
	$(GOBUILD) -o $(BUILD_DIR)/$(BINARY_NAME)-debug .

# Run tests
test:
	$(GOTEST) -v ./...

# Clean build artifacts
clean:
	@echo "Cleaning..."
	$(GOCLEAN)
	@rm -rf $(BUILD_DIR)

# Install binary to system
install: build
	@echo "Installing $(BINARY_NAME) to /usr/local/bin..."
	@sudo cp $(BUILD_DIR)/$(BINARY_NAME) /usr/local/bin/
	@sudo chmod +x /usr/local/bin/$(BINARY_NAME)
	@echo "$(BINARY_NAME) installed successfully!"

# Cross-compile for multiple platforms
cross-compile: clean deps
	@echo "Cross-compiling for multiple platforms..."
	@mkdir -p $(BUILD_DIR)
	@for platform in $(PLATFORMS); do \
		GOOS=$$(echo $$platform | cut -d'/' -f1); \
		GOARCH=$$(echo $$platform | cut -d'/' -f2); \
		output_name=$(BUILD_DIR)/$(BINARY_NAME)-$$GOOS-$$GOARCH; \
		if [ $$GOOS = "windows" ]; then output_name=$$output_name.exe; fi; \
		echo "Building for $$GOOS/$$GOARCH..."; \
		CGO_ENABLED=0 GOOS=$$GOOS GOARCH=$$GOARCH $(GOBUILD) $(LDFLAGS) -o $$output_name .; \
	done
	@echo "Cross-compilation completed!"

# Create release archives
release: cross-compile
	@echo "Creating release archives..."
	@cd $(BUILD_DIR) && \
	for binary in $(BINARY_NAME)-*; do \
		if [ -f "$$binary" ]; then \
			platform=$$(echo $$binary | sed 's/$(BINARY_NAME)-//'); \
			if echo "$$binary" | grep -q "windows"; then \
				zip "$$platform.zip" "$$binary" ../README.md ../LICENSE; \
			else \
				tar -czf "$$platform.tar.gz" "$$binary" ../README.md ../LICENSE; \
			fi; \
		fi; \
	done
	@echo "Release archives created in $(BUILD_DIR)/"

# Build Docker image
docker:
	@echo "Building Docker image..."
	docker build -t pbm-exporter:$(VERSION) .
	docker tag pbm-exporter:$(VERSION) pbm-exporter:latest

# Run locally (requires PBM_MONGODB_URI environment variable)
run:
	@if [ -z "$(PBM_MONGODB_URI)" ]; then \
		echo "Error: PBM_MONGODB_URI environment variable is required"; \
		echo "Usage: make run PBM_MONGODB_URI=mongodb://localhost:27017"; \
		exit 1; \
	fi
	$(BUILD_DIR)/$(BINARY_NAME)

# Development run with auto-rebuild
dev:
	@if [ -z "$(PBM_MONGODB_URI)" ]; then \
		echo "Error: PBM_MONGODB_URI environment variable is required"; \
		echo "Usage: make dev PBM_MONGODB_URI=mongodb://localhost:27017"; \
		exit 1; \
	fi
	@which reflex > /dev/null || (echo "Installing reflex..." && go install github.com/cespare/reflex@latest)
	reflex -r '\.go$$' -s -- sh -c 'make build && $(BUILD_DIR)/$(BINARY_NAME)'

# Show help
help:
	@echo "Available targets:"
	@echo "  all           - Clean, download dependencies and build"
	@echo "  build         - Build the binary"
	@echo "  build-debug   - Build with debug information"
	@echo "  clean         - Clean build artifacts"
	@echo "  deps          - Download and tidy Go dependencies"
	@echo "  test          - Run tests"
	@echo "  install       - Install binary to /usr/local/bin (requires sudo)"
	@echo "  cross-compile - Build for multiple platforms"
	@echo "  release       - Create release archives for all platforms"
	@echo "  docker        - Build Docker image"
	@echo "  run           - Run the binary (requires PBM_MONGODB_URI)"
	@echo "  dev           - Development mode with auto-rebuild (requires PBM_MONGODB_URI)"
	@echo "  help          - Show this help"
	@echo ""
	@echo "Environment variables:"
	@echo "  PBM_MONGODB_URI - MongoDB connection URI (required for run/dev)"
	@echo "  PORT            - Port to listen on (default: 9090)"
	@echo "  VERSION         - Version for building (default: $(VERSION))"
