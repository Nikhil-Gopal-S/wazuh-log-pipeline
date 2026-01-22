# Wazuh Log Pipeline Agent

This project provides a specialized **Wazuh Agent Docker container** designed for **log ingestion** via a REST API. Unlike a standard Wazuh agent that monitors the host system (files, processes, etc.), this agent acts as a gateway to accept external JSON events and forward them to the Wazuh Manager.

It includes a **FastAPI** service running alongside the Wazuh agent to handle high-throughput log ingestion.

---

## 🚀 Features

- **Custom Ingestion API**: Push JSON logs via HTTP `PUT` requests.
- **Batch Processing**: Support for bulk log ingestion.
- **Auto-Enrollment**: Automatically registers with the Wazuh Manager on startup.
- **Persistence**: Preserves agent identity (keys and certificates) across container restarts.
- **Health Monitoring**: Built-in health check endpoints for container orchestration.
- **Version Pinning**: Supports specific Wazuh Agent versions via build arguments.

---

## 🛠 Prerequisites

- **Docker** and **Docker Compose** installed.
- A running **Wazuh Manager** instance.
- Network connectivity from this container to the Wazuh Manager (ports 1514/1515).

---

## ⚙️ Configuration

The agent is configured entirely via environment variables in the `docker-compose.yml` file.

### Key Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `MANAGER_URL` | IP/Hostname of the Wazuh Manager. | `localhost` |
| `MANAGER_PORT` | Port for agent enrollment (TCP). | `1515` |
| `SERVER_URL` | IP/Hostname of the Wazuh Manager (Worker). | `localhost` |
| `SERVER_PORT` | Port for log data transmission (TCP/UDP). | `1514` |
| `NAME` | **Unique** name for this agent. Must be stable for persistence. | `agent-ingest` |
| `ENROL_TOKEN` | Password/Token for agent enrollment. | *(Optional)* |
| `API_KEY` | Secret key for securing the Ingest API. | *(Empty = No Auth)* |
| `GROUP` | Wazuh agent group to assign this agent to. | `default` |
| `WAZUH_AGENT_VERSION` | Specific Wazuh agent version to install (e.g., `4.11.0`). | *(Latest)* |
| `WAZUH_DECODER_HEADER` | Default internal routing header if no decoder is specified. | `1:Wazuh-AWS:` |

---

## 📦 Deployment

1.  **Clone the repository**:
    ```bash
    git clone <repository-url>
    cd wazuh-log-pipeline
    ```

2.  **Configure `docker-compose.yml`**:
    Edit the `environment` section to match your Wazuh Manager details.
    ```yaml
    services:
      agent-ingest:
        environment:
          - MANAGER_URL=192.168.1.100
          - ENROL_TOKEN=MySecretPassword
          - API_KEY=super-secret-key
    ```

3.  **Start the container**:
    ```bash
    docker-compose up -d --build
    ```

4.  **Verify Status**:
    Check if the container is healthy and the agent is connected.
    ```bash
    docker ps
    docker logs wazuh-log-pipeline-agent-ingest-1
    ```

---

## 🔌 API Documentation

The Ingest API listens on port **9000** by default.

### Authentication
If `API_KEY` is set, you must include the `X-API-Key` header in all requests.

### 1. Ingest Single Event (`PUT /`)
Ingest a single JSON object.

**Example:**
```bash
curl -X PUT "http://localhost:9000/" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: super-secret-key" \
  -d '{
    "event_type": "login",
    "user": "alice",
    "status": "failed",
    "src_ip": "10.0.0.5"
  }'
```

### 2. Ingest Batch Events (`PUT /batch`)
Ingest a list of JSON objects. Highly recommended for high volume.

**Example:**
```bash
curl -X PUT "http://localhost:9000/batch" \
  -H "Content-Type: application/json" \
  -H "X-API-Key: super-secret-key" \
  -d '[
    {"event_type": "login", "user": "bob"},
    {"event_type": "logout", "user": "alice"}
  ]'
```

### 3. Health Check (`GET /health`)
Verifies if the API can communicate with the local Wazuh socket.

**Example:**
```bash
curl -sS http://localhost:9000/health
# Output: {"status":"healthy","wazuh_socket":"connected"}
```

---

## 🧠 Advanced Usage

### Custom Decoders
By default, events are routed with the `Wazuh-AWS` header, which is a generic JSON decoder. To use a specific Wazuh decoder, include the `decoder` field in your JSON payload.

**Example:**
```json
{
  "decoder": "syslog",
  "message": "User root logged in via ssh"
}
```
This forces the agent to route the event through the `syslog` decoder chain in the Wazuh Manager.

### Persistence
The agent uses a **named Docker volume** (`agent-ingest-ossec-etc`) to store the `/var/ossec/etc` directory. This ensures that:
- The `client.keys` file (containing the agent's unique ID) is preserved.
- The agent retains the same ID on the Wazuh Manager even if the container is destroyed and recreated.
- **Note**: If you change the `NAME` env var, you should clear this volume to allow a fresh registration.

---

## 🔍 Troubleshooting

### Agent not showing in Manager
1.  Check logs: `docker logs wazuh-log-pipeline-agent-ingest-1`
2.  Verify `MANAGER_URL` is reachable from inside the container.
3.  Ensure `ENROL_TOKEN` matches the Manager's configuration.

### API returns 403 Forbidden
- Ensure you are sending the `X-API-Key` header.
- Verify the key matches the `API_KEY` environment variable.

### "Address already in use" error
- Check if port **9000** or **9001** is used by another service.
- You can change the published ports in `docker-compose.yml`.

---

## 📂 Project Structure

- `Dockerfile`: Main build file for the agent + API.
- `docker-compose.yml`: Orchestration config.
- `api/api.py`: FastAPI application source code.
- `bin/entrypoint.sh`: Startup script handling config generation and process management.
- `web/ready.sh`: Simple Python webserver for health checks (Port 9001).
- `config/ossec.tpl`: Template for `ossec.conf` generation.
