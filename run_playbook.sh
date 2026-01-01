#!/bin/bash

# Usage: ./run_playbook.sh [staging|production] playbook.yaml [additional-args]
# Example: ./run_playbook.sh staging ansible/playbooks/k8s_install.yaml
# Example: ./run_playbook.sh production ansible/playbooks/k8s_install.yaml --tags install

# Check if environment is specified
if [ "$#" -lt 2 ]; then
    echo "Usage: $0 [staging|production] playbook.yaml [additional-args]"
    echo "Example: $0 staging ansible/playbooks/k8s_install.yaml"
    exit 1
fi

ENVIRONMENT=$1
shift

# Validate environment
if [ "$ENVIRONMENT" != "staging" ] && [ "$ENVIRONMENT" != "production" ]; then
    echo "Error: Environment must be 'staging' or 'production'"
    exit 1
fi

# Set environment-specific variables
set -o allexport
source .env
set +o allexport

# Set inventory based on environment
INVENTORY="ansible/inventory/${ENVIRONMENT}.yaml"

if [ ! -f "$INVENTORY" ]; then
    echo "Error: Inventory file $INVENTORY not found"
    exit 1
fi

echo "Running playbook for $ENVIRONMENT environment..."
echo "Inventory: $INVENTORY"
echo "Playbook: $1"
echo ""

ansible-playbook -i "$INVENTORY" "$@"

