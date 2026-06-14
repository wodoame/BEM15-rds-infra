#!/bin/bash
set -e

git config core.hooksPath .githooks
echo "Git hooks configured. Pre-push hook will sync stack templates to S3 before every push."
