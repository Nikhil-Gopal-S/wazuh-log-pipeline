Deployment Instructions
=======================

1. Copy the 'wazuh-deploy.tar.gz' file to your VM (e.g., using scp):
   scp wazuh-deploy.tar.gz user@10.47.5.216:/tmp/

2. SSH into your VM:
   ssh user@10.47.5.216

3. Extract the package to /opt/wazuh-log-pipeline (this updates all files):
   sudo mkdir -p /opt/wazuh-log-pipeline
   sudo tar -xzf /tmp/wazuh-deploy.tar.gz -C /opt/wazuh-log-pipeline --strip-components=1

4. Make the script executable:
   sudo chmod +x /opt/wazuh-log-pipeline/scripts/migrate-deployment.sh

5. Run the deployment script:
   sudo /opt/wazuh-log-pipeline/scripts/migrate-deployment.sh --yes --local --manager 10.47.5.216

Note:
- The '--local' flag tells the script to use the files you just copied, instead of cloning from GitHub.
- This package includes fixes for:
  - "Permission denied" errors (containers now run as root)
  - Network connectivity (agents can now reach the Manager)
  - Docker Compose bugs
