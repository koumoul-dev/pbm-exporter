package main

import "fmt"

var version = "0.2.0"

func init() {
	if version == "" {
		version = "dev"
	}
}

func printVersion() {
	fmt.Printf("pbm-exporter version %s\n", version)
}
