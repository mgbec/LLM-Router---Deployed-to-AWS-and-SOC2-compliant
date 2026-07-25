FROM --platform=linux/arm64 python:3.13-slim

# Install OPA binary (ARM64)
ADD https://openpolicyagent.org/downloads/latest/opa_linux_arm64_static /usr/local/bin/opa
RUN chmod +x /usr/local/bin/opa

WORKDIR /app

# Install Python dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . .

# Copy OPA policies (placed here by the build script)
# The deploy script copies policies/opa/ into agent/policies/ before building
RUN mkdir -p /app/policies

EXPOSE 8080

CMD ["/app/entrypoint.sh"]
