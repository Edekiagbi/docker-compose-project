#!/bin/bash
set -euo pipefail

# ============================================================
# Check that every tool needed to build & deploy is installed
# ============================================================
# Usage: ./check-prereqs.sh
# Installs nothing — just verifies what is already on your machine.
# ============================================================

PASS=0
FAIL=0

check() {
  local name="$1"
  shift
  if command -v "$1" >/dev/null 2>&1; then
    echo "  [OK]   $name -> $($1 --version 2>&1 | head -1)"
    PASS=$((PASS+1))
  else
    echo "  [FAIL] $name -> NOT INSTALLED (need: $*)"
    FAIL=$((FAIL+1))
  fi
}

echo "==> Checking required tools..."
check "Git"       git
check "Bash"      bash
check "Docker"    docker
check "Docker Compose" docker
check "AWS CLI"   aws
check "jq"        jq

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "All required tools present ($PASS found). Your machine is ready."
else
  echo "$PASS found, $FAIL missing. Install the missing tools, then re-run."
fi

echo ""
echo "==> Checking Docker daemon..."
if docker info >/dev/null 2>&1; then
  echo "  [OK]   Docker daemon is running."
else
  echo "  [FAIL] Docker daemon is NOT running. Start Docker Desktop / docker service."
fi

echo ""
echo "==> Checking AWS authentication..."
if aws sts get-caller-identity >/dev/null 2>&1; then
  ACCOUNT=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || echo "?")
  echo "  [OK]   AWS authenticated. Account: $ACCOUNT"
else
  echo "  [FAIL] AWS not authenticated. Run 'aws configure' first."
fi