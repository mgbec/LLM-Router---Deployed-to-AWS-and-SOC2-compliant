#!/bin/sh
# Start OPA as a background sidecar on port 8181 with decision logging
# Then start the FastAPI agent on port 8080

echo "Starting OPA sidecar with decision logging..."
opa run --server \
  --addr=localhost:8181 \
  --log-level=info \
  --set=decision_logs.console=true \
  /app/policies/ &

# Wait for OPA to be ready
sleep 1
echo "OPA sidecar running on localhost:8181 (decision logs enabled)"

echo "Starting LLM Router Agent..."
exec python app.py
