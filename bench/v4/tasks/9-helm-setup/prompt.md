I need to set up a Valkey cluster for our dev team using Helm. We're running minikube locally.

Requirements:
- 3 primary nodes with 1 replica each (6 pods total)
- TLS enabled between nodes and for client connections
- Password authentication with a specific password from a Kubernetes secret
- 512MB memory limit per node with maxmemory-policy allkeys-lru
- AOF persistence enabled with 1Gi PVCs
- Liveness and readiness probes configured
- Resource requests: 256m CPU, 512Mi memory per pod
- The cluster should be accessible from outside the cluster on NodePort 30000

Write these files:
1. `values.yaml` - Complete Helm values file for the Valkey Helm chart
2. `setup.sh` - Script that creates the namespace, generates TLS certs, creates the secret, and runs helm install
3. `README.md` - Quick start instructions for the team

I want to use the official Valkey Helm chart. Make sure the values are correct for the actual chart - don't guess the value keys.
