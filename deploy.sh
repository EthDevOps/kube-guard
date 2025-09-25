#!/bin/bash

set -e

echo "Building KubeGuard Docker image..."
docker build -t kube-guard:latest .

echo "Creating namespace..."
kubectl apply -f k8s/namespace.yaml

echo "Applying RBAC configuration..."
kubectl apply -f k8s/rbac.yaml

echo "Applying ConfigMap..."
kubectl apply -f k8s/configmap.yaml

echo "Deploying KubeGuard..."
kubectl apply -f k8s/deployment.yaml
kubectl apply -f k8s/service.yaml

echo "Waiting for deployment to be ready..."
kubectl wait --for=condition=available --timeout=300s deployment/kube-guard -n kube-guard

echo "Creating TLS certificate for webhook..."
# Generate a private key
openssl genrsa -out webhook.key 2048

# Create certificate signing request
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
DNS.1 = kube-guard-webhook
DNS.2 = kube-guard-webhook.kube-guard
DNS.3 = kube-guard-webhook.kube-guard.svc
DNS.4 = kube-guard-webhook.kube-guard.svc.cluster.local
EOF

# Generate certificate signing request
openssl req -new -key webhook.key -out webhook.csr -config csr.conf -subj "/CN=kube-guard-webhook.kube-guard.svc"

# Create Kubernetes CSR
cat <<EOF | kubectl apply -f -
apiVersion: certificates.k8s.io/v1
kind: CertificateSigningRequest
metadata:
  name: kube-guard-webhook
spec:
  request: $(cat webhook.csr | base64 | tr -d '\n')
  signerName: kubernetes.io/kubelet-serving
  usages:
  - digital signature
  - key encipherment
  - server auth
EOF

echo "Approving certificate signing request..."
kubectl certificate approve kube-guard-webhook

echo "Getting signed certificate..."
kubectl get csr kube-guard-webhook -o jsonpath='{.status.certificate}' | base64 -d > webhook.crt

echo "Creating TLS secret..."
kubectl create secret tls kube-guard-tls --cert=webhook.crt --key=webhook.key -n kube-guard --dry-run=client -o yaml | kubectl apply -f -

# Get CA bundle
CA_BUNDLE=$(kubectl get configmap -n kube-system extension-apiserver-authentication -o=jsonpath='{.data.client-ca-file}' | base64 | tr -d '\n')

echo "Updating webhook configuration with CA bundle..."
sed "s/CA_BUNDLE_PLACEHOLDER/$CA_BUNDLE/g" k8s/webhook-config.yaml | kubectl apply -f -

echo "Cleaning up temporary files..."
rm -f webhook.key webhook.csr webhook.crt csr.conf

echo "KubeGuard deployed successfully!"
echo "Don't forget to update the ConfigMap with your Mattermost webhook URL:"
echo "kubectl edit configmap kube-guard-config -n kube-guard"