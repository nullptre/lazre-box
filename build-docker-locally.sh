#!/bin/bash

# This script is not meant to run from the CI/CD pipeline. It creates a build context directory and copies all needed files into it before building the Docker image.

# Create build context directory
mkdir -p build_context

# Copy current repository
cp -r ./* build_context/

# Copy other repositories locally since they are external to this repository
cp -r ../lazre build_context/lazre
cp -r ../bot915 build_context/bot915
cp -r ../taggregator build_context/taggregator

# Ensure .dockerignore is in the build context and not overridden
cp .dockerignore build_context/

# Build the Docker image
docker build -t lazre-box -f Dockerfile build_context

# Clean up build context
rm -rf build_context 