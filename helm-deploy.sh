#!/bin/bash

set -e

RELEASE_NAME="kube-guard"
CHART_PATH="./helm/kube-guard"
NAMESPACE="kube-guard"

# Parse command line arguments
WEBHOOK_URL=""
MONITORED_NS="my-namespace"
VALUES_FILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --webhook-url)
      WEBHOOK_URL="$2"
      shift 2
      ;;
    --monitored-namespace)
      MONITORED_NS="$2"
      shift 2
      ;;
    --values)
      VALUES_FILE="$2"
      shift 2
      ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo "Options:"
      echo "  --webhook-url URL          Mattermost webhook URL (required)"
      echo "  --monitored-namespace NS   Namespace to monitor (default: my-namespace)"
      echo "  --values FILE              Additional values file"
      echo "  -h, --help                 Show this help message"
      exit 0
      ;;
    *)
      echo "Unknown option $1"
      exit 1
      ;;
  esac
done

# Check if webhook URL is provided
if [ -z "$WEBHOOK_URL" ]; then
  echo "Error: Mattermost webhook URL is required. Use --webhook-url option."
  echo "Run '$0 --help' for more information."
  exit 1
fi

echo "Building KubeGuard Docker image..."
docker build -t kube-guard:latest .

echo "Installing/upgrading KubeGuard with Helm..."

# Build Helm command
HELM_CMD="helm upgrade --install $RELEASE_NAME $CHART_PATH"
HELM_CMD="$HELM_CMD --create-namespace"
HELM_CMD="$HELM_CMD --set config.mattermost.webhookUrl=\"$WEBHOOK_URL\""
HELM_CMD="$HELM_CMD --set config.monitoredNamespace=\"$MONITORED_NS\""

# Add values file if provided
if [ -n "$VALUES_FILE" ]; then
  HELM_CMD="$HELM_CMD --values $VALUES_FILE"
fi

# Execute Helm command
eval $HELM_CMD

echo "Waiting for deployment to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/$RELEASE_NAME -n $NAMESPACE

echo "Generating TLS certificate for webhook..."

# Generate a private key
openssl genrsa -out webhook.key 2048

# Create certificate signing request config
cat <<EOF > csr.conf
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_req]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = $RELEASE_NAME-webhook
DNS.2 = $RELEASE_NAME-webhook.$NAMESPACE
DNS.3 = $RELEASE_NAME-webhook.$NAMESPACE.svc
DNS.4 = $RELEASE_NAME-webhook.$NAMESPACE.svc.cluster.local
EOF

# Generate certificate signing request
openssl req -new -key webhook.key -out webhook.csr -config csr.conf -subj "/CN=$RELEASE_NAME-webhook.$NAMESPACE.svc"

# Create Kubernetes CSR
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: $RELEASE_NAME-webhook
spec:
  request: $(cat webhook.csr | base64 | tr -d '\n')
  signerName: kubernetes.io/kubelet-serving
  usages:
  - digital signature
  - key encipherment
  - server auth
EOF

echo "Approving certificate signing request..."
kubectl certificate approve $RELEASE_NAME-webhook

echo "Getting signed certificate..."
kubectl get csr $RELEASE_NAME-webhook -o jsonpath='{.status.certificate}' | base64 -d > webhook.crt

echo "Creating/updating TLS secret..."
kubectl create secret tls $RELEASE_NAME-tls --cert=webhook.crt --key=webhook.key -n $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Get CA bundle and update webhook
echo "Updating webhook configuration with CA bundle..."
CA_BUNDLE=$(kubectl get configmap -n kube-system extension-apiserver-authentication -o=jsonpath='{.data.client-ca-file}' | base64 | tr -d '\n')

# Update webhook with CA bundle
helm upgrade $RELEASE_NAME $CHART_PATH \
  --reuse-values \
  --set webhook.caBundle="$CA_BUNDLE"

echo "Restarting deployment to pick up new certificates..."
kubectl rollout restart deployment/$RELEASE_NAME -n $NAMESPACE
kubectl rollout status deployment/$RELEASE_NAME -n $NAMESPACE

echo "Cleaning up temporary files..."
rm -f webhook.key webhook.csr webhook.crt csr.conf

echo ""
echo "============================================"
echo "KubeGuard deployed successfully with Helm!"
echo "============================================"
echo "Release name: $RELEASE_NAME"
echo "Namespace: $NAMESPACE"
echo "Monitored namespace: $MONITORED_NS"
echo ""
echo "To check status:"
echo "  helm status $RELEASE_NAME"
echo "  kubectl get pods -n $NAMESPACE"
echo ""
echo "To view logs:"
echo "  kubectl logs -n $NAMESPACE deployment/$RELEASE_NAME"
echo ""
echo "To update configuration:"
echo "  helm upgrade $RELEASE_NAME $CHART_PATH --set config.mattermost.webhookUrl=\"NEW_URL\""
echo ""
echo "To uninstall:"
echo "  helm uninstall $RELEASE_NAME"
echo ""