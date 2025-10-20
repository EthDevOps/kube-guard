#!/usr/bin/env python3

import json
import yaml
import logging
import requests
import base64
from datetime import datetime
from flask import Flask, request, jsonify
from kubernetes import client, config
import os

app = Flask(__name__)
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

logger.info(f"DEBUG: Module loading, __name__ = {__name__}")

class KubeGuardController:
    def __init__(self):
        self.config_data = {}
        self.load_kubernetes_config()
        self.load_config()

    def load_kubernetes_config(self):
        """Load Kubernetes configuration"""
        try:
            config.load_incluster_config()
            logger.info("Loaded in-cluster Kubernetes config")
        except Exception:
            try:
                config.load_kube_config()
                logger.info("Loaded local Kubernetes config")
            except Exception as e:
                logger.error(f"Failed to load Kubernetes config: {e}")
                raise

        self.k8s_client = client.CoreV1Api()

    def load_config(self):
        """Load configuration from ConfigMap"""
        try:
            config_map_name = os.getenv('CONFIG_MAP_NAME', 'kube-guard-config')
            config_map_namespace = os.getenv('CONFIG_MAP_NAMESPACE', 'kube-guard')

            config_map = self.k8s_client.read_namespaced_config_map(
                name=config_map_name,
                namespace=config_map_namespace
            )

            config_yaml = config_map.data.get('config.yaml', '{}')
            self.config_data = yaml.safe_load(config_yaml)
            logger.info("Configuration loaded successfully")

        except Exception as e:
            logger.error(f"Failed to load config from ConfigMap: {e}")
            # Fallback to default config
            self.config_data = {
                'mattermost': {
                    'webhook_url': os.getenv('MATTERMOST_WEBHOOK_URL', ''),
                    'channel': os.getenv('MATTERMOST_CHANNEL', 'alerts')
                },
                'monitored_namespace': 'my-namespace',
                'notifications': {
                    'shell_access': True,
                    'port_forward': True
                }
            }

    def send_mattermost_notification(self, message, username='KubeGuard'):
        """Send notification to Mattermost"""
        webhook_url = self.config_data.get('mattermost', {}).get('webhook_url')
        channel = self.config_data.get('mattermost', {}).get('channel', 'alerts')

        if not webhook_url:
            logger.warning("Mattermost webhook URL not configured")
            return

        payload = {
            'channel': f"#{channel}",
            'username': username,
            'text': message,
            'icon_emoji': ':warning:'
        }

        try:
            response = requests.post(webhook_url, json=payload, timeout=10)
            response.raise_for_status()
            logger.info("Notification sent to Mattermost successfully")
        except Exception as e:
            logger.error(f"Failed to send Mattermost notification: {e}")

    def is_shell_access(self, admission_request):
        """Check if the request is for shell access (exec)"""
        resource = admission_request.get('kind', {})
        if resource.get('kind') != 'PodExecOptions':
            return False

        namespace = admission_request.get('namespace', '')
        return namespace == self.config_data.get('monitored_namespace', 'my-namespace')

    def is_port_forward(self, admission_request):
        """Check if the request is for port forwarding"""
        resource = admission_request.get('kind', {})
        if resource.get('kind') != 'PodPortForwardOptions':
            return False

        namespace = admission_request.get('namespace', '')
        return namespace == self.config_data.get('monitored_namespace', 'my-namespace')

    def get_user_info(self, admission_request):
        """Extract user information from the admission request"""
        user_info = admission_request.get('userInfo', {})
        username = user_info.get('username', 'unknown')
        groups = user_info.get('groups', [])
        return username, groups

    def process_admission_request(self, admission_request):
        """Process the admission request and send notifications if needed"""
        try:
            username, groups = self.get_user_info(admission_request)
            namespace = admission_request.get('namespace', '')
            resource = admission_request.get('kind', {}).get('kind', '')
            cluster_name = self.config_data.get('cluster_name','in-cluster')

            message = None

            if self.is_shell_access(admission_request):
                if self.config_data.get('notifications', {}).get('shell_access', True):
                    pod_name = admission_request.get('name', 'unknown')
                    message = (f":warning: **Shell Access Alert** on cluster `{cluster_name}`\n"
                             f"User `{username}` opened a shell to pod `{namespace}/{pod_name}`\n"
                             f"Time: {datetime.now().strftime('%Y-%m-%d %H:%M:%S UTC')}")

            elif self.is_port_forward(admission_request):
                if self.config_data.get('notifications', {}).get('port_forward', True):
                    pod_name = admission_request.get('name', 'unknown')
                    message = (f":warning: **Port Forward Alert** on cluster `{cluster_name}\n"
                             f"User `{username}` created a port-forward to pod `{namespace}/{pod_name}`\n"
                             f"Time: {datetime.now().strftime('%Y-%m-%d %H:%M:%S UTC')}")

            if message:
                self.send_mattermost_notification(message)

        except Exception as e:
            logger.error(f"Error processing admission request: {e}")

# Global controller instance
try:
    controller = KubeGuardController()
except Exception as e:
    logger.warning(f"Failed to initialize KubeGuardController: {e}")
    controller = None

@app.route('/healthz', methods=['GET'])
def health_check():
    """Health check endpoint"""
    return jsonify({'status': 'healthy'}), 200

@app.route('/readyz', methods=['GET'])
def readiness_check():
    """Readiness check endpoint"""
    return jsonify({'status': 'ready'}), 200

@app.route('/validate', methods=['POST'])
def validate():
    """Validation webhook endpoint"""
    try:
        admission_review = request.get_json()

        if not admission_review or 'request' not in admission_review:
            return jsonify({'error': 'Invalid admission review'}), 400

        admission_request = admission_review['request']

        # Process the request for notifications (this doesn't block the request)
        controller.process_admission_request(admission_request)

        # Always allow the request (we're just monitoring, not blocking)
        admission_response = {
            'uid': admission_request.get('uid'),
            'allowed': True
        }

        return jsonify({
            'apiVersion': 'admission.k8s.io/v1',
            'kind': 'AdmissionReview',
            'response': admission_response
        })

    except Exception as e:
        logger.error(f"Error in validation webhook: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/mutate', methods=['POST'])
def mutate():
    """Mutation webhook endpoint (not used but required for completeness)"""
    try:
        admission_review = request.get_json()
        admission_request = admission_review['request']

        # No mutations, just allow (notification handled by /validate endpoint)
        admission_response = {
            'uid': admission_request.get('uid'),
            'allowed': True,
            'patchType': 'JSONPatch',
            'patch': base64.b64encode(json.dumps([]).encode()).decode()
        }

        return jsonify({
            'apiVersion': 'admission.k8s.io/v1',
            'kind': 'AdmissionReview',
            'response': admission_response
        })

    except Exception as e:
        logger.error(f"Error in mutation webhook: {e}")
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    logger.info(f"DEBUG: Entering __main__ block, __name__ = {__name__}")
    port = int(os.getenv('PORT', 8443))

    # Check if TLS certificates are mounted
    tls_cert_path = '/etc/tls/tls.crt'
    tls_key_path = '/etc/tls/tls.key'

    if os.path.exists(tls_cert_path) and os.path.exists(tls_key_path):
        logger.info("Using mounted TLS certificates")
        ssl_context = (tls_cert_path, tls_key_path)
    else:
        logger.info("Using adhoc TLS certificates")
        ssl_context = 'adhoc'

    app.run(host='0.0.0.0', port=port, ssl_context=ssl_context)
