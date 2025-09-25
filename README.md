# KubeGuard - Kubernetes Admission Controller

KubeGuard is a Kubernetes admission controller that monitors shell access (`kubectl exec`) and port forwarding (`kubectl port-forward`) activities in specified namespaces and sends notifications to Mattermost.

## Features

- **Shell Access Monitoring**: Detects when users execute shells in pods via `kubectl exec`
- **Port Forward Monitoring**: Detects when users create port forwards via `kubectl port-forward`
- **Mattermost Integration**: Sends detailed notifications to Mattermost channels
- **ConfigMap Configuration**: Easy configuration management through Kubernetes ConfigMaps
- **Namespace Filtering**: Monitor specific namespaces (default: `my-namespace`)
- **User Information**: Includes user details in notifications for better auditing

## Quick Start

1. **Clone and build**:
   ```bash
   git clone <repository>
   cd kube-guard
   ```

2. **Update configuration**:
   Edit `k8s/configmap.yaml` to set your Mattermost webhook URL:
   ```yaml
   data:
     config.yaml: |
       mattermost:
         webhook_url: "https://your-mattermost.example.com/hooks/your-webhook-id"
         channel: "alerts"
       monitored_namespace: "my-namespace"
   ```

3. **Deploy**:
   ```bash
   ./deploy.sh
   ```

4. **Test**:
   ```bash
   kubectl exec -it <pod-name> -n my-namespace -- /bin/bash
   ```

## Configuration

The admission controller is configured via a ConfigMap (`kube-guard-config`) in the `kube-guard` namespace:

```yaml
mattermost:
  webhook_url: "https://your-mattermost.example.com/hooks/your-webhook-id"
  channel: "alerts"

monitored_namespace: "my-namespace"

notifications:
  shell_access: true
  port_forward: true
```

### Configuration Options

- `mattermost.webhook_url`: Your Mattermost incoming webhook URL
- `mattermost.channel`: Target channel for notifications (without #)
- `monitored_namespace`: Namespace to monitor (default: "my-namespace")
- `notifications.shell_access`: Enable/disable shell access notifications
- `notifications.port_forward`: Enable/disable port forward notifications

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   kubectl exec  │───▶│   API Server    │───▶│   KubeGuard     │
│kubectl port-fwd │    │                 │    │   Admission     │
└─────────────────┘    └─────────────────┘    │   Controller    │
                                              └─────────────────┘
                                                        │
                                                        ▼
                                              ┌─────────────────┐
                                              │   Mattermost    │
                                              │    Channel      │
                                              └─────────────────┘
```

## Notification Format

Shell access notifications:
```
⚠️ Shell Access Alert
User: john.doe@company.com
Namespace: my-namespace
Pod: web-app-123
Action: Shell access (kubectl exec)
Time: 2024-01-15 14:30:25 UTC
```

Port forward notifications:
```
⚠️ Port Forward Alert
User: jane.smith@company.com
Namespace: my-namespace
Pod: database-456
Action: Port forwarding
Time: 2024-01-15 14:31:10 UTC
```

## Security Considerations

- The admission controller runs with minimal RBAC permissions
- Uses non-root user in container
- Read-only root filesystem
- TLS encryption for webhook communication
- Fails open (doesn't block operations if webhook fails)

## Troubleshooting

1. **Check pod logs**:
   ```bash
   kubectl logs -n kube-guard deployment/kube-guard
   ```

2. **Verify webhook configuration**:
   ```bash
   kubectl get validatingadmissionwebhooks kube-guard-validator -o yaml
   ```

3. **Test webhook endpoint**:
   ```bash
   kubectl port-forward -n kube-guard svc/kube-guard-webhook 8443:443
   curl -k https://localhost:8443/healthz
   ```

4. **Update configuration**:
   ```bash
   kubectl edit configmap kube-guard-config -n kube-guard
   kubectl rollout restart deployment/kube-guard -n kube-guard
   ```

## Uninstall

```bash
kubectl delete validatingadmissionwebhook kube-guard-validator
kubectl delete mutatingadmissionwebhook kube-guard-mutator
kubectl delete namespace kube-guard
```